defmodule QueueOfMatchmaking.QueuePolicyTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.TestSupport.QueueTestHelpers, as: Helpers
  alias QueueOfMatchmaking.{QueuePolicy, QueueState}

  defmodule BeforeEnqueueStub do
    @moduledoc false
    @behaviour QueueOfMatchmaking.MatchPolicy

    @impl true
    def init(opts), do: {:ok, Map.new(opts), :infinity}

    @impl true
    def before_enqueue(entry, manager_ctx, state) do
      Process.put({__MODULE__, :last_context}, {entry, manager_ctx})
      Process.get({__MODULE__, :return}, {:proceed, state})
    end

    @impl true
    def matchmaking_mode(_entry, _context, state), do: {:attempt, %{}, state}

    @impl true
    def max_delta(_entry, _context, _retry_context, state), do: {:unbounded, state}

    @impl true
    def after_match(_match, _context, state), do: {:ok, state}

    @impl true
    def handle_timeout(_context, state), do: {:ok, state, :infinity}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule HandleTimeoutStub do
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
    def handle_timeout(manager_ctx, state) do
      if pid = Process.get({__MODULE__, :pid}) do
        send(pid, {:timeout_context, manager_ctx, state})
      end

      Process.get({__MODULE__, :return}, {:ok, state, :infinity})
    end

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  describe "before_enqueue/2" do
    test "translates duplicate rejection into :already_enqueued error" do
      Process.put({BeforeEnqueueStub, :return}, {:reject, :duplicate, %{policy_state: :dup}})

      state = Helpers.build_state(policy_module: BeforeEnqueueStub)
      entry = %{user_id: "dup", rank: 1000}

      assert {:error, :already_enqueued, %QueueState{policy_state: %{policy_state: :dup}}} =
               QueuePolicy.before_enqueue(entry, state)
    end

    test "wraps arbitrary rejection reasons under :policy_rejected" do
      Process.put(
        {BeforeEnqueueStub, :return},
        {:reject, {:custom, :reason}, %{policy_state: :reject}}
      )

      state = Helpers.build_state(policy_module: BeforeEnqueueStub)

      assert {:error, {:policy_rejected, {:custom, :reason}},
              %QueueState{policy_state: %{policy_state: :reject}}} =
               QueuePolicy.before_enqueue(%{user_id: "p1", rank: 42}, state)
    end
  end

  describe "handle_timeout/1" do
    test "passes manager context to policy module" do
      Process.put({HandleTimeoutStub, :pid}, self())

      Process.put(
        {HandleTimeoutStub, :return},
        {:ok, %{policy_state: :after}, 500}
      )

      state =
        Helpers.build_state(
          policy_module: HandleTimeoutStub,
          policy_state: %{decision: {:attempt, %{}}, max_delta: :unbounded}
        )

      # Seed the queue with an entry to exercise queue_size context building.
      {_entry, state} =
        Helpers.insert_entry(state, %{user_id: "queued", rank: 1_200})

      assert {:ok, %{policy_state: :after}, 500} = QueuePolicy.handle_timeout(state)

      assert_receive {:timeout_context, %{queue_size: 1, now: _now}, %{decision: {:attempt, %{}}}}
    end

    test "returns retry instructions untouched when provided by the policy" do
      Process.put({HandleTimeoutStub, :pid}, self())
      instructions = [{:handle, %{relaxed?: true}}]

      Process.put(
        {HandleTimeoutStub, :return},
        {:retry, instructions, %{policy_state: :retrying}, 250}
      )

      state =
        Helpers.build_state(
          policy_module: HandleTimeoutStub,
          policy_state: %{decision: {:attempt, %{}}, max_delta: :unbounded}
        )

      assert {:retry, ^instructions, %{policy_state: :retrying}, 250} =
               QueuePolicy.handle_timeout(state)
    end
  end
end
