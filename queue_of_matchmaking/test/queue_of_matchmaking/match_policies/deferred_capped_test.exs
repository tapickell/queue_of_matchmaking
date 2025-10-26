defmodule QueueOfMatchmaking.MatchPolicies.DeferredCappedTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.MatchPolicies.DeferredCapped
  alias QueueOfMatchmaking.MatchPolicies.DeferredCapped.State

  describe "init/1" do
    test "applies defaults and returns tick interval" do
      assert {:ok, %State{opts: opts, waiting: %{}}, 1_000} = DeferredCapped.init([])

      assert opts[:min_queue] == 2
      assert opts[:max_wait_ms] == :infinity
      assert opts[:initial_delta] == :unbounded
      assert opts[:relaxed_delta] == :unbounded
    end

    test "normalizes the tick interval" do
      assert {:ok, %State{}, :infinity} = DeferredCapped.init(tick_ms: :infinity)
      assert {:ok, %State{}, 500} = DeferredCapped.init(tick_ms: 500)
      assert {:ok, %State{}, 1_000} = DeferredCapped.init(tick_ms: -10)
    end
  end

  describe "matchmaking_mode/3" do
    test "attempts immediately when queue meets minimum size" do
      {state, _tick} = build_state(min_queue: 3)
      entry = build_entry(handle: :h1, inserted_at: 100)
      manager = %{queue_size: 3, now: 150}

      assert {:attempt, %{relaxed?: false}, ^state} =
               DeferredCapped.matchmaking_mode(entry, manager, state)
    end

    test "attempts with relaxed context when wait threshold exceeded" do
      {state, _tick} = build_state(min_queue: 5, max_wait_ms: 20)
      entry = build_entry(handle: :h1, inserted_at: 10)
      manager = %{queue_size: 2, now: 40}

      assert {:attempt, %{relaxed?: true}, ^state} =
               DeferredCapped.matchmaking_mode(entry, manager, state)
    end

    test "defers and tracks waiting entries when conditions not met" do
      {state, _tick} = build_state(min_queue: 4, max_wait_ms: 50)
      entry = build_entry(handle: :h1, inserted_at: 100)
      manager = %{queue_size: 1, now: 120}

      assert {:defer, %State{waiting: waiting}} =
               DeferredCapped.matchmaking_mode(entry, manager, state)

      assert waiting[:h1][:user_id] == entry.user_id
      assert waiting[:h1][:inserted_at] == entry.inserted_at
    end
  end

  describe "max_delta/4" do
    test "returns unbounded when initial delta is unbounded" do
      {state, _tick} = build_state(initial_delta: :unbounded)
      assert {:unbounded, ^state} = DeferredCapped.max_delta(%{}, %{}, %{}, state)
    end

    test "respects bounded initial delta" do
      {state, _tick} = build_state(initial_delta: 25)
      assert {:bounded, 25, ^state} = DeferredCapped.max_delta(%{}, %{}, %{}, state)
    end

    test "uses relaxed delta when context requests relaxed matching" do
      {state, _tick} = build_state(initial_delta: 5, relaxed_delta: 50)

      assert {:bounded, 50, ^state} =
               DeferredCapped.max_delta(%{}, %{}, %{relaxed?: true}, state)
    end

    test "keeps relaxed delta unbounded when configured" do
      {state, _tick} = build_state(initial_delta: 5, relaxed_delta: :unbounded)

      assert {:unbounded, ^state} =
               DeferredCapped.max_delta(%{}, %{}, %{relaxed?: true}, state)
    end
  end

  describe "after_match/3" do
    test "removes matched handles from waiting set" do
      {state, _tick} = build_state()

      state =
        %{state | waiting: %{h1: %{inserted_at: 10}, h2: %{inserted_at: 15}}}

      match = %{users: [%{handle: :h1}, %{handle: :other}]}

      assert {:ok, %State{waiting: waiting}} =
               DeferredCapped.after_match(match, %{}, state)

      refute Map.has_key?(waiting, :h1)
      assert Map.has_key?(waiting, :h2)
    end
  end

  describe "handle_timeout/2" do
    test "keeps waiting list intact when no entries are due" do
      {state, tick} = build_state(max_wait_ms: 100)
      state = %{state | waiting: %{h1: %{inserted_at: 50}}}
      manager = %{now: 120}

      assert {:ok, %State{waiting: waiting}, ^tick} =
               DeferredCapped.handle_timeout(manager, state)

      assert Map.has_key?(waiting, :h1)
    end

    test "returns retry instructions for overdue entries with relaxed context" do
      opts = [max_wait_ms: 20, relaxed_delta: 10, tick_ms: 200]
      {state, tick} = build_state(opts)

      inserted_at = 10
      state = %{state | waiting: %{h1: %{inserted_at: inserted_at}}}
      manager = %{now: 40}

      assert {:retry, instructions, %State{waiting: waiting}, ^tick} =
               DeferredCapped.handle_timeout(manager, state)

      assert [{:h1, %{relaxed?: true, wait_ms: 30}}] = Enum.sort(instructions)
      assert Map.has_key?(waiting, :h1)
    end
  end

  describe "before_enqueue/3" do
    test "always allows the enqueue" do
      {state, _tick} = build_state()
      assert {:proceed, ^state} = DeferredCapped.before_enqueue(%{}, %{}, state)
    end
  end

  defp build_state(opts \\ []) do
    {:ok, state, tick} = DeferredCapped.init(opts)
    {state, tick}
  end

  defp build_entry(attrs) do
    defaults = %{user_id: "user", handle: :handle, inserted_at: 0}
    Map.merge(defaults, Map.new(attrs))
  end
end
