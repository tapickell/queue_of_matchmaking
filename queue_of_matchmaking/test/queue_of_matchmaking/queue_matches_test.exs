defmodule QueueOfMatchmaking.QueueMatchesTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.{
    QueueMatches,
    QueueState
  }

  alias QueueOfMatchmaking.TestSupport.QueueTestHelpers, as: Helpers

  describe "find/2" do
    test "returns a match, stores it, and removes matched entries" do
      Helpers.reset_publisher_stub()

      state =
        Helpers.build_state(
          decision: {:attempt, %{reason: :test}},
          max_delta: {:bounded, 0}
        )

      {candidate_entry, state} =
        Helpers.insert_entry(state, %{
          user_id: "candidate",
          rank: 1100,
          inserted_at: Helpers.next_time()
        })

      {entry, state} =
        Helpers.insert_entry(state, %{user_id: "requester", rank: 1100})

      assert {:ok, {:ok, %{match: match}}, updated_state} = QueueMatches.find(entry, state)

      user_ids =
        match.users
        |> Enum.map(& &1.user_id)
        |> Enum.sort()

      assert user_ids == ["candidate", "requester"]
      assert match.context == %{reason: :test}
      assert match.delta == 0
      assert updated_state.matches == [match]

      assert {:error, :not_found, _} = QueueState.fetch(candidate_entry.handle, updated_state)
      assert {:error, :not_found, _} = QueueState.fetch(entry.handle, updated_state)
    end

    test "returns queued when policy defers and leaves entries in place" do
      state =
        Helpers.build_state(
          decision: :defer,
          max_delta: {:bounded, 0}
        )

      {entry, state} =
        Helpers.insert_entry(state, %{user_id: "requester", rank: 1100})

      assert {:ok, {:ok, :queued}, updated_state} = QueueMatches.find(entry, state)

      assert updated_state.matches == []
      assert {:ok, _entry_again, _} = QueueState.fetch(entry.handle, updated_state)
    end

    test "cancels entry when policy rejects matching" do
      state =
        Helpers.build_state(
          decision: :cancel,
          max_delta: {:bounded, 0}
        )

      {entry, state} =
        Helpers.insert_entry(state, %{user_id: "requester", rank: 1200})

      assert {:ok, {:error, {:policy_rejected, :cancelled}}, updated_state} =
               QueueMatches.find(entry, state)

      assert updated_state.matches == []
      assert {:error, :not_found, _} = QueueState.fetch(entry.handle, updated_state)
    end
  end
end
