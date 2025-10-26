defmodule QueueOfMatchmaking.QueueStorage.SimpleTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.QueueStorage.Simple

  setup do
    {:ok, state} = Simple.init([])
    %{state: state}
  end

  describe "insert/2" do
    test "rejects duplicate user_ids", %{state: state} do
      {:ok, handle, state} = Simple.insert(%{user_id: "dup", rank: 100}, state)
      assert is_reference(handle)

      assert {:error, :duplicate, ^state} =
               Simple.insert(%{user_id: "dup", rank: 200}, state)
    end
  end

  describe "head/1" do
    test "returns :empty when queue has no entries", %{state: state} do
      assert {:error, :empty, ^state} = Simple.head(state)
    end

    test "returns first entry when queue populated", %{state: state} do
      {:ok, handle, state} = Simple.insert(%{user_id: "a", rank: 10}, state)
      {:ok, entry, _state_after_head} = Simple.head(state)
      assert entry.handle == handle
    end
  end

  describe "pop_head/1" do
    test "returns :empty when queue empty", %{state: state} do
      assert {:error, :empty, ^state} = Simple.pop_head(state)
    end

    test "removes and returns the head entry", %{state: state} do
      {:ok, handle, state} = Simple.insert(%{user_id: "a", rank: 10}, state)
      assert {:ok, %{handle: ^handle}, _state_after_pop} = Simple.pop_head(state)
    end
  end

  describe "prune/2" do
    test "removes entries that match predicate", %{state: state} do
      {:ok, handle_keep, state} = Simple.insert(%{user_id: "keep", rank: 10}, state)
      {:ok, handle_drop, state} = Simple.insert(%{user_id: "drop", rank: 20}, state)

      predicate = fn entry -> entry.rank >= 15 end

      assert {:ok, [%{handle: ^handle_drop}], state} = Simple.prune(predicate, state)

      # Remaining entry still accessible
      assert {:ok, %{handle: ^handle_keep}, _} = Simple.lookup(handle_keep, state)
    end

    test "ignores entries already removed during prune traversal", %{state: state} do
      {:ok, handle, state} = Simple.insert(%{user_id: "first", rank: 10}, state)

      # Manually remove to simulate concurrent removal
      {:ok, _entry, state} = Simple.remove(handle, state)

      predicate = fn entry -> entry.user_id == "first" end

      assert {:ok, [], ^state} = Simple.prune(predicate, state)
    end
  end
end
