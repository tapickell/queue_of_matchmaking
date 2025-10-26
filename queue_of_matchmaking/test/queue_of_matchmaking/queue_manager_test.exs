defmodule QueueOfMatchmaking.QueueManagerTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.QueueManager

  @moduledoc false

  defmodule PolicyStub do
    @moduledoc false
    @behaviour QueueOfMatchmaking.MatchPolicy

    @impl true
    def init(opts) when is_list(opts) do
      state =
        %{
          decision: Keyword.get(opts, :decision, {:attempt, %{}}),
          max_delta: Keyword.get(opts, :max_delta, :unbounded)
        }

      {:ok, state, :infinity}
    end

    def init(opts) when is_map(opts) do
      init(Enum.to_list(opts))
    end

    @impl true
    def before_enqueue(_entry, _context, state), do: {:proceed, state}

    @impl true
    def matchmaking_mode(_entry, _context, %{decision: {:attempt, context}} = state) do
      {:attempt, context, state}
    end

    def matchmaking_mode(_entry, _context, %{decision: :attempt} = state) do
      {:attempt, %{}, state}
    end

    def matchmaking_mode(_entry, _context, %{decision: :defer} = state) do
      {:defer, state}
    end

    def matchmaking_mode(_entry, _context, %{decision: :cancel} = state) do
      {:cancel, state}
    end

    @impl true
    def max_delta(_entry, _context, _retry_context, %{max_delta: :unbounded} = state) do
      {:unbounded, state}
    end

    def max_delta(_entry, _context, _retry_context, %{max_delta: {:bounded, limit}} = state) do
      {:bounded, limit, state}
    end

    @impl true
    def after_match(_match, _context, state), do: {:ok, state}

    @impl true
    def handle_timeout(_context, state), do: {:ok, state, :infinity}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule PublisherStub do
    @moduledoc false
    @behaviour QueueOfMatchmaking.MatchPublisher

    @impl true
    def publish(match) do
      case Application.get_env(:queue_of_matchmaking, :publisher_test_target) do
        pid when is_pid(pid) -> send(pid, {:published, match})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule ErrorQueueModule do
    @moduledoc false

    def init(_opts), do: {:ok, :error_state}

    def insert(_entry, _state), do: {:error, :boom, :error_state}

    def remove(_handle, state), do: {:error, :not_found, state}

    def size(state), do: {0, state}
  end

  defmodule PolicyTimeoutStub do
    @moduledoc false
    @behaviour QueueOfMatchmaking.MatchPolicy

    @impl true
    def init(opts), do: {:ok, Map.new(opts), :infinity}

    @impl true
    def before_enqueue(_entry, _context, state), do: {:proceed, state}

    @impl true
    def matchmaking_mode(_entry, _context, state), do: {:attempt, %{}, state}

    @impl true
    def max_delta(_entry, _context, _retry_context, state), do: {:unbounded, state}

    @impl true
    def after_match(_match, _context, state), do: {:ok, state}

    @impl true
    def handle_timeout(_context, %{handle_timeout_result: {:ok, new_state, timeout}}) do
      {:ok, new_state, timeout}
    end

    def handle_timeout(_context, %{
          handle_timeout_result: {:retry, instructions, new_state, timeout}
        }) do
      {:retry, instructions, new_state, timeout}
    end

    def handle_timeout(_context, state), do: {:ok, state, :infinity}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  setup do
    Application.put_env(:queue_of_matchmaking, :publisher_test_target, self())

    on_exit(fn ->
      Application.delete_env(:queue_of_matchmaking, :publisher_test_target)
    end)

    :ok
  end

  describe "enqueue/2" do
    test "matches players, publishes result, and records history" do
      server =
        start_manager(
          policy_opts: %{decision: {:attempt, %{source: :queue}}, max_delta: {:bounded, 0}}
        )

      assert {:ok, :queued} =
               QueueManager.enqueue(%{user_id: "candidate", rank: 1500}, server)

      assert {:ok, %{match: match}} =
               QueueManager.enqueue(%{user_id: "requester", rank: 1500}, server)

      assert_receive {:published, ^match}
      assert Enum.map(match.users, & &1.user_id) |> Enum.sort() == ["candidate", "requester"]

      [recent] = QueueManager.recent_matches(1, server)
      assert recent == match
    end

    test "returns queued without publishing when policy defers" do
      server = start_manager(policy_opts: %{decision: :defer})

      assert {:ok, :queued} =
               QueueManager.enqueue(%{user_id: "player_one", rank: 1700}, server)

      refute_received {:published, _}
      assert QueueManager.recent_matches(5, server) == []
    end
  end

  describe "enqueue error handling" do
    test "returns queue errors surfaced from QueueManagement" do
      duplicate_server = start_manager(policy_opts: %{decision: :defer})

      assert {:ok, :queued} =
               QueueManager.enqueue(%{user_id: "dup", rank: 1_000}, duplicate_server)

      assert {:error, :already_enqueued} =
               QueueManager.enqueue(%{user_id: "dup", rank: 1_000}, duplicate_server)

      assert {:error, :invalid_params} = QueueManager.enqueue(%{}, duplicate_server)

      queue_error_server =
        start_manager(
          queue_module: ErrorQueueModule,
          policy_opts: %{decision: {:attempt, %{}}, max_delta: :unbounded}
        )

      assert {:error, {:queue_error, :boom}} =
               QueueManager.enqueue(%{user_id: "err", rank: 1_000}, queue_error_server)
    end
  end

  describe "policy messages" do
    test "policy_tick updates state via QueueManagement" do
      server =
        start_manager(
          policy_module: PolicyTimeoutStub,
          policy_opts: %{
            handle_timeout_result: {:ok, %{policy_state: :tick_updated}, 100}
          }
        )

      flush_mailbox()
      send(server, :policy_tick)
      state_after = :sys.get_state(server)
      assert state_after.policy_state == %{policy_state: :tick_updated}
    end

    test "policy_retry ignores not_found responses" do
      server =
        start_manager(policy_opts: %{decision: {:attempt, %{}}, max_delta: :unbounded})

      send(server, {:policy_retry, :missing, %{}})
      # No crash and no messages is success.
      refute_receive {:policy_retry_processed, _}
    end
  end

  defp start_manager(opts) do
    name = :"queue_manager_test_#{System.unique_integer([:positive])}"

    base_opts = [
      name: name,
      queue_module: QueueOfMatchmaking.QueueStorage.Simple,
      policy_module: __MODULE__.PolicyStub,
      publisher_module: __MODULE__.PublisherStub,
      time_fn: fn :millisecond -> System.unique_integer([:positive]) end
    ]

    merged_opts =
      base_opts
      |> Keyword.merge(opts)
      |> Keyword.put(:schedule_policy_timeout, &schedule_policy_timeout_stub/2)

    {:ok, _pid} = start_supervised({QueueManager, merged_opts}, id: name)

    name
  end

  defp schedule_policy_timeout_stub(state, timeout) do
    send(self(), {:policy_state, state.policy_state})
    Map.put(state, :policy_timer_ref, timeout)
  end

  defp flush_mailbox do
    receive do
      _ -> flush_mailbox()
    after
      0 -> :ok
    end
  end
end
