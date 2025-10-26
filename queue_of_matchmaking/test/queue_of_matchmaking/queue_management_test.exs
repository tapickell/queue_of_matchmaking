defmodule QueueOfMatchmaking.QueueManagementTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.{
    QueueManagement,
    QueueState
  }

  alias QueueOfMatchmaking.TestSupport.QueueTestHelpers, as: Helpers
  alias Helpers.{PublisherStub, RaisingPublisherStub}

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
end
