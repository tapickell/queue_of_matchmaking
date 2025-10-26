defmodule QueueOfMatchmaking.QueueManagementTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.{
    QueueManagement,
    QueueState
  }

  alias QueueOfMatchmaking.TestSupport.QueueTestHelpers, as: Helpers
  alias Helpers.{PublisherStub, RaisingPublisherStub}

  defmodule DuplicateQueueModule do
    @moduledoc false

    def init(_opts), do: {:ok, :state}

    def insert(_entry, _state), do: {:error, :duplicate, :duplicate_state}
  end

  defmodule ErrorQueueModule do
    @moduledoc false

    def init(_opts), do: {:ok, :state}

    def insert(_entry, _state), do: {:error, :boom, :error_state}

    def remove(_handle, state), do: {:error, :not_found, state}
  end

  describe "queue state error mapping" do
    test "insert_entry maps duplicate errors to already_enqueued" do
      state =
        Helpers.build_state(queue_module: DuplicateQueueModule)

      entry = %{user_id: "dup", rank: 1_200, inserted_at: Helpers.next_time(), manager_now: 0}

      assert {:error, :already_enqueued, %QueueState{queue_state: :duplicate_state}} =
               QueueState.insert_entry(entry, state)
    end

    test "insert_entry wraps unexpected errors and remove_entry preserves queue error" do
      state =
        Helpers.build_state(queue_module: ErrorQueueModule)

      entry = %{user_id: "err", rank: 1_200, inserted_at: Helpers.next_time(), manager_now: 0}

      assert {:error, {:queue_error, :boom}, %QueueState{queue_state: :error_state}} =
               QueueState.insert_entry(entry, state)

      assert {:error, :not_found, %QueueState{queue_state: :error_state}} =
               QueueState.remove_entry(:missing, %{state | queue_state: :error_state})
    end
  end

  describe "enqueue/2 publishing" do
    test "publishes match via configured publisher when a match is found" do
      Helpers.reset_publisher_stub(self())

      state =
        Helpers.build_state(
          decision: {:attempt, %{origin: :enqueue}},
          max_delta: {:bounded, 0},
          publisher_module: PublisherStub
        )

      {existing_entry, state} =
        Helpers.insert_entry(state, %{user_id: "candidate", rank: 1500})

      assert {:ok, {:ok, %{match: match}}, updated_state} =
               QueueManagement.enqueue(%{user_id: "requester", rank: 1500}, state)

      assert_receive {:published, ^match}
      assert updated_state.matches == [match]

      assert {:error, :not_found, _} = QueueState.fetch(existing_entry.handle, updated_state)
    end

    test "does not publish when match is deferred" do
      Helpers.reset_publisher_stub(self())

      state =
        Helpers.build_state(
          decision: :defer,
          max_delta: {:bounded, 0},
          publisher_module: PublisherStub
        )

      assert {:ok, {:ok, :queued}, updated_state} =
               QueueManagement.enqueue(%{user_id: "requester", rank: 1500}, state)

      refute_received {:published, _}
      assert updated_state.matches == []
    end

    test "swallows publisher errors to keep queue flow running" do
      state =
        Helpers.build_state(
          decision: {:attempt, %{}},
          max_delta: {:bounded, 0},
          publisher_module: RaisingPublisherStub
        )

      {_candidate_entry, state} =
        Helpers.insert_entry(state, %{user_id: "candidate", rank: 1800})

      assert {:ok, {:ok, %{match: _match}}, _updated_state} =
               QueueManagement.enqueue(%{user_id: "requester", rank: 1800}, state)
    end
  end

  describe "policy_retry/3" do
    test "publishes match results produced during policy retries" do
      Helpers.reset_publisher_stub(self())

      state =
        Helpers.build_state(
          decision: {:attempt, %{origin: :retry}},
          max_delta: {:bounded, 0},
          publisher_module: PublisherStub
        )

      {candidate_entry, state} =
        Helpers.insert_entry(state, %{user_id: "candidate", rank: 2000})

      {entry, state} =
        Helpers.insert_entry(state, %{user_id: "requester", rank: 2000})

      assert {:ok, updated_state} =
               QueueManagement.policy_retry(entry.handle, %{source: :timer}, state)

      assert_receive {:published, match}
      assert match.context == %{source: :timer}
      assert updated_state.matches == [match]

      assert {:error, :not_found, _} = QueueState.fetch(candidate_entry.handle, updated_state)
      assert {:error, :not_found, _} = QueueState.fetch(entry.handle, updated_state)
    end
  end

  defmodule PolicyTimeoutStub do
    @moduledoc false
    @behaviour QueueOfMatchmaking.MatchPolicy

    @impl true
    def init(opts), do: {:ok, Map.new(opts), :infinity}

    @impl true
    def before_enqueue(_entry, _manager_ctx, state), do: {:proceed, state}

    @impl true
    def matchmaking_mode(_entry, _manager_ctx, state), do: {:attempt, %{}, state}

    @impl true
    def max_delta(_entry, _manager_ctx, _context, state), do: {:unbounded, state}

    @impl true
    def after_match(_match, _manager_ctx, state), do: {:ok, state}

    @impl true
    def handle_timeout(_manager_ctx, %{handle_timeout_result: {:ok, new_state, timeout}}) do
      {:ok, new_state, timeout}
    end

    def handle_timeout(
          _manager_ctx,
          %{handle_timeout_result: {:retry, instructions, new_state, timeout}}
        ) do
      {:retry, instructions, new_state, timeout}
    end

    def handle_timeout(_manager_ctx, state), do: {:ok, state, :infinity}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  describe "policy_tick/3" do
    test "updates policy state and reschedules when no retries required" do
      initial_state =
        Helpers.build_state(
          policy_module: PolicyTimeoutStub,
          policy_state: %{
            decision: {:attempt, %{}},
            max_delta: :unbounded,
            handle_timeout_result: {:ok, %{policy_state: :updated}, 250}
          }
        )

      schedule_fun = fn state, timeout ->
        send(self(), {:scheduled, timeout})
        state
      end

      retry_fun = fn state, _instructions ->
        send(self(), :unexpected_retry)
        state
      end

      result_state = QueueManagement.policy_tick(initial_state, schedule_fun, retry_fun)

      assert_receive {:scheduled, 250}
      refute_received :unexpected_retry
      assert result_state.policy_state == %{policy_state: :updated}
    end

    test "delegates retry instructions when entries are due" do
      instructions = [{:handle, %{relaxed?: true}}]

      initial_state =
        Helpers.build_state(
          policy_module: PolicyTimeoutStub,
          policy_state: %{
            decision: {:attempt, %{}},
            max_delta: :unbounded,
            handle_timeout_result: {:retry, instructions, %{policy_state: :retrying}, 500}
          }
        )

      schedule_fun = fn state, timeout ->
        send(self(), {:scheduled, timeout})
        state
      end

      retry_fun = fn state, received ->
        send(self(), {:retrying, received})
        state
      end

      result_state = QueueManagement.policy_tick(initial_state, schedule_fun, retry_fun)

      assert_receive {:scheduled, 500}
      assert_receive {:retrying, ^instructions}
      assert result_state.policy_state == %{policy_state: :retrying}
    end
  end
end
