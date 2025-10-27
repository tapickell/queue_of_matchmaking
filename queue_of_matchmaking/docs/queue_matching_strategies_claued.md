# Queue Matching Strategies - Design Analysis

## The Problem: Unbounded Incremental Expansion (The "2-in-Queue Dilemma")

### Discovery
Starting implementation and identified a critical issue with the matching logic as specified in the original requirements.

**The Issue:**
With unbounded incremental expansion and the stated criteria in the MD file:
- Starting with an empty queue
- Adding one request at a time via mutation
- After each request, running the updated queue through matching logic
- If 2 requests exist in queue, they will **eventually match** with unbounded incremental approach
- **Result**: Queue will only ever have a max of 2 requests at any one time
- **Problem**: This short-circuits the fairness of matching closest by ranking

### Current Behavior Example
```
Queue: []
Add Player1 (rank: 1000) → Queue: [Player1] → No match (length < 2)
Add Player2 (rank: 9999) → Queue: [Player1, Player2] → length == 2 → AUTO-MATCH ❌
  Rank difference: 8999 points!
```

### Why This Defeats the Purpose
- Any 2 players match instantly, regardless of skill gap
- Queue never grows beyond 2 users
- FIFO fairness becomes irrelevant (no queue depth to be fair about)
- No actual "matchmaking" happening - just pairing random arrivals
- The sophisticated incremental expansion algorithm is wasted

### Jason's Response
> "This work was left a little open-ended in an attempt to elicit this kind of thinking. All three of those strategies could be valid, depending on the circumstances, and It might be an excellent place to use a behaviour or some other policy mechanism. Pick whichever you think is the best showcase of your skillset, and we can talk about the design choices when we do the walk through this week. It's a fun little problem."

**Interpretation**: This is intentional - a design challenge, not just an implementation exercise.

---

## Strategy 1: Timer-Based Matching (Max Wait Time)

### Concept
Defer matching until a user has waited X seconds, allowing queue to build up.

### Implementation Approach
```elixir
# Each entry gets a "can_match_after" timestamp
%Entry{
  user_id: "player1",
  rank: 1500,
  added_to_queue: ~U[2025-10-24 10:00:00Z],
  can_match_after: ~U[2025-10-24 10:00:30Z]  # 30s wait
}

# Matching logic:
# Only consider users where DateTime.after?(now, can_match_after)
```

### Pros
- **Fairness**: Guarantees everyone waits minimum time, builds queue depth
- **Predictable UX**: Users know max wait time upfront
- **Natural batching**: Creates waves of matchable users
- **Good for low-traffic**: Even with few users, prevents bad matches

### Cons
- **Artificial delay**: Player waits even if perfect match exists
- **Timer management complexity**: Need Process.send_after or similar
- **Variable queue size**: Can't predict how many will be eligible
- **Poor for high-traffic**: Unnecessary waits when queue is deep

### Behaviour Hook Points
```elixir
@callback should_attempt_match?(entry :: Entry.t(), queue_state :: State.t()) :: boolean()
```

**Timer policy would return**: `DateTime.after?(now, entry.can_match_after)`

---

## Strategy 2: Queue Size Threshold

### Concept
Only run matching when queue reaches minimum size (e.g., 10 users).

### Implementation Approach
```elixir
def handle_call({:add_request, user_id, rank}, _from, state) do
  state = add_to_queue(state, user_id, rank)

  state = if queue_size(state) >= @min_queue_size do
    attempt_match(state)
  else
    state  # Skip matching
  end

  {:reply, {:ok, ...}, state}
end
```

### Pros
- **Queue depth guarantee**: Always enough candidates for good matches
- **Simplicity**: No timers, just count check
- **Rank proximity**: More users = better chance of close rank matches
- **Efficient**: Matching runs less frequently

### Cons
- **Cold start problem**: First 9 users wait indefinitely
- **Variable wait times**: User 10 matches instantly, user 1 waited forever
- **Unfair to early arrivals**: FIFO violated (later arrivals match before earlier if threshold met)
- **Traffic dependency**: Works poorly during low-traffic periods

### Behaviour Hook Points
```elixir
@callback should_attempt_match?(queue_state :: State.t()) :: boolean()
```

**Size policy would return**: `map_size(state.index) >= min_size`

---

## Strategy 3: Rank Distance Threshold

### Concept
Only match if rank difference is within acceptable range (e.g., ±200 points).

### Implementation Approach
```elixir
# In incremental expansion:
for delta <- 0..@max_expansion do
  candidates = find_at_distance(queue, new_user.rank, delta)

  if delta <= @max_allowed_delta do  # e.g., 200
    # Match found within tolerance
    return match(new_user, best_candidate)
  end
end

# If we exhausted max_expansion without finding close match:
# Add to queue, no match
```

### Pros
- **Match quality guarantee**: No terrible mismatches
- **Configurable fairness**: Admins tune the threshold
- **Immediate good matches**: If rank 1500 joins and 1510 exists, match now
- **Self-regulating**: Queue grows when no good matches exist

### Cons
- **Risk of starvation**: Outlier ranks (99th percentile) may never match
- **Threshold tuning**: Too strict = no matches, too loose = defeats purpose
- **Unpredictable waits**: High rank (9000) might wait indefinitely
- **Business decision required**: What's "acceptable" rank gap?

### Behaviour Hook Points
```elixir
@callback acceptable_match?(user1 :: Entry.t(), user2 :: Entry.t()) :: boolean()
```

**Rank threshold policy would return**: `abs(user1.rank - user2.rank) <= @max_delta`

---

## Using Elixir Behaviours for Pluggable Policies

### Behaviour Definition

```elixir
defmodule QueueOfMatchmaking.MatchPolicy do
  @moduledoc """
  Behaviour for defining when and how matches should occur.
  Allows pluggable strategies without changing core queue logic.
  """

  @type entry :: %{user_id: String.t(), rank: non_neg_integer(), added_to_queue: DateTime.t()}
  @type queue_state :: map()

  # Should we even attempt matching right now?
  @callback should_attempt_match?(queue_state) :: boolean()

  # Is this candidate eligible to be matched?
  @callback is_matchable?(entry, queue_state) :: boolean()

  # Is this specific pairing acceptable?
  @callback acceptable_match?(entry, entry) :: boolean()

  # Optional: max distance to search (unbounded if nil)
  @callback max_search_distance() :: pos_integer() | :infinity
end
```

### Example Policy Implementations

#### 1. Timer Policy
```elixir
defmodule QueueOfMatchmaking.Policies.TimerPolicy do
  @behaviour QueueOfMatchmaking.MatchPolicy

  @min_wait_seconds 30

  def should_attempt_match?(_state), do: true

  def is_matchable?(entry, _state) do
    wait_time = DateTime.diff(DateTime.utc_now(), entry.added_to_queue)
    wait_time >= @min_wait_seconds
  end

  def acceptable_match?(_user1, _user2), do: true

  def max_search_distance(), do: :infinity
end
```

#### 2. Queue Size Policy
```elixir
defmodule QueueOfMatchmaking.Policies.QueueSizePolicy do
  @behaviour QueueOfMatchmaking.MatchPolicy

  @min_queue_size 10

  def should_attempt_match?(state) do
    map_size(state.index) >= @min_queue_size
  end

  def is_matchable?(_entry, _state), do: true

  def acceptable_match?(_user1, _user2), do: true

  def max_search_distance(), do: :infinity
end
```

#### 3. Rank Distance Policy
```elixir
defmodule QueueOfMatchmaking.Policies.RankDistancePolicy do
  @behaviour QueueOfMatchmaking.MatchPolicy

  @max_rank_delta 200

  def should_attempt_match?(_state), do: true

  def is_matchable?(_entry, _state), do: true

  def acceptable_match?(user1, user2) do
    abs(user1.rank - user2.rank) <= @max_rank_delta
  end

  def max_search_distance(), do: @max_rank_delta
end
```

### Using the Policy in QueueManager

```elixir
defmodule QueueOfMatchmaking.QueueManager do
  use GenServer

  @policy Application.compile_env(:queue_of_matchmaking, :match_policy)

  def handle_call({:add_request, user_id, rank}, _from, state) do
    state = add_to_queue(state, user_id, rank)

    state = if @policy.should_attempt_match?(state) do
      attempt_match(state, @policy)
    else
      state
    end

    {:reply, {:ok, ...}, state}
  end

  defp attempt_match(state, policy) do
    # Filter to only matchable entries
    matchable = Enum.filter(state.queue, &policy.is_matchable?(&1, state))

    case find_match_with_policy(matchable, policy) do
      {:ok, {user1, user2}} ->
        if policy.acceptable_match?(user1, user2) do
          create_match(state, user1, user2)
        else
          state  # Found match but policy rejected it
        end
      :no_match ->
        state
    end
  end
end
```

---

## Strategy Combinations

### Combo 1: Timer + Rank Distance (RECOMMENDED)
**Strategy**: Wait minimum time, but only match if rank is close enough.

```elixir
defmodule QueueOfMatchmaking.Policies.TimerAndRankPolicy do
  @behaviour QueueOfMatchmaking.MatchPolicy

  @min_wait_seconds 15
  @max_rank_delta 300

  def should_attempt_match?(_state), do: true

  def is_matchable?(entry, _state) do
    wait_time = DateTime.diff(DateTime.utc_now(), entry.added_to_queue)
    wait_time >= @min_wait_seconds
  end

  def acceptable_match?(user1, user2) do
    abs(user1.rank - user2.rank) <= @max_rank_delta
  end

  def max_search_distance(), do: @max_rank_delta
end
```

**Pros:**
- ✅ Prevents instant bad matches (2-user problem solved)
- ✅ Guarantees minimum match quality
- ✅ Predictable max wait (15s)
- ✅ Queue builds to 15s depth

**Cons:**
- ⚠️ Outlier ranks still may not match after waiting
- ⚠️ Requires tuning both parameters

**Use case**: **Best for production** - balances wait time and quality

---

### Combo 2: Queue Size OR Rank Distance
**Strategy**: Match when queue reaches size threshold OR rank is very close.

```elixir
defmodule QueueOfMatchmaking.Policies.SizeOrCloseRankPolicy do
  @min_queue_size 8
  @instant_match_delta 50  # Very close ranks can match immediately

  def should_attempt_match?(state) do
    queue_size = map_size(state.index)

    # Always attempt if queue is deep
    queue_size >= @min_queue_size
  end

  def is_matchable?(_entry, _state), do: true

  def acceptable_match?(user1, user2) do
    delta = abs(user1.rank - user2.rank)

    # Allow if very close match, even in small queue
    delta <= @instant_match_delta
  end

  def max_search_distance(), do: :infinity
end
```

**Pros:**
- ✅ Fast matches for perfect pairs
- ✅ Queue builds for non-perfect matches
- ✅ Balances speed and quality

**Cons:**
- ⚠️ Complex logic (OR conditions harder to reason about)
- ⚠️ Variable experience (some instant, some wait)

**Use case**: High-traffic systems with many close-rank users

---

### Combo 3: Adaptive Timer (Advanced)
**Strategy**: Timer duration scales with queue size or rank rarity.

```elixir
defmodule QueueOfMatchmaking.Policies.AdaptiveTimerPolicy do
  @behaviour QueueOfMatchmaking.MatchPolicy

  def is_matchable?(entry, state) do
    wait_time = DateTime.diff(DateTime.utc_now(), entry.added_to_queue)
    required_wait = calculate_adaptive_wait(entry, state)

    wait_time >= required_wait
  end

  defp calculate_adaptive_wait(entry, state) do
    # Shorter wait if queue is large (many potential matches)
    base_wait = 30
    queue_size = map_size(state.index)

    cond do
      queue_size >= 20 -> 5   # Lots of candidates, quick match
      queue_size >= 10 -> 15  # Moderate wait
      queue_size >= 5 -> 30   # Longer wait to build queue
      true -> 60              # Very small queue, wait for more
    end
  end

  def should_attempt_match?(_state), do: true

  def acceptable_match?(_user1, _user2), do: true

  def max_search_distance(), do: :infinity
end
```

**Pros:**
- ✅ Self-optimizing based on traffic
- ✅ Fast when busy, patient when slow
- ✅ Demonstrates sophisticated thinking

**Cons:**
- ⚠️ Unpredictable UX (wait time varies)
- ⚠️ Complex to test and tune
- ⚠️ May be over-engineering

**Use case**: **Showcase solution** - demonstrates systems thinking

---

### Combo 4: ALL THREE - Composite Policy (Production-Grade)
**Strategy**: Use composition to combine all policies with AND/OR logic.

```elixir
defmodule QueueOfMatchmaking.Policies.CompositePolicy do
  @behaviour QueueOfMatchmaking.MatchPolicy

  @min_wait 10
  @min_queue 5
  @max_rank_delta 400

  # Match when: (Timer expired AND Queue has min size) OR Rank very close
  def should_attempt_match?(state) do
    map_size(state.index) >= @min_queue
  end

  def is_matchable?(entry, state) do
    wait_time = DateTime.diff(DateTime.utc_now(), entry.added_to_queue)
    queue_size = map_size(state.index)

    # Must wait minimum time unless queue is huge
    cond do
      wait_time >= @min_wait -> true
      queue_size >= 20 -> true  # Override timer if queue is very deep
      true -> false
    end
  end

  def acceptable_match?(user1, user2) do
    delta = abs(user1.rank - user2.rank)

    # Stricter requirements early, looser as time passes
    user1_wait = DateTime.diff(DateTime.utc_now(), user1.added_to_queue)

    max_delta = case user1_wait do
      t when t < 15 -> 100   # First 15s: very strict
      t when t < 30 -> 200   # 15-30s: moderate
      t when t < 60 -> 400   # 30-60s: loose
      _ -> :infinity         # After 60s: match anyone
    end

    delta <= max_delta
  end

  def max_search_distance(), do: @max_rank_delta
end
```

**Progressive Relaxation Strategy:**
The rank distance threshold **relaxes over time**:
- 0-15s: Only match within 100 points (strict quality)
- 15-30s: Match within 200 points (moderate)
- 30-60s: Match within 400 points (loose)
- 60s+: Match anyone (prevent indefinite waiting)

**Pros:**
- ✅ Handles all scenarios gracefully
- ✅ Progressive relaxation (quality → speed over time)
- ✅ Production-ready robustness
- ✅ Great for take-home (shows deep thinking)

**Cons:**
- ⚠️ Most complex to implement and test
- ⚠️ Many parameters to tune
- ⚠️ May be harder to explain

**Use case**: **Production matchmaking at scale** (LoL, Dota 2, Overwatch, Chess.com)

**Real-world examples:**
- **League of Legends**: Strict matchmaking early, expands after 2-3 minutes
- **Overwatch**: "Expanding search" message = progressive relaxation
- **Chess.com**: Time controls determine how strict rank matching is

---

## Configuration Strategy

Make policies configurable in `config/config.exs`:

```elixir
config :queue_of_matchmaking, :match_policy,
  module: QueueOfMatchmaking.Policies.TimerAndRankPolicy,
  config: [
    min_wait_seconds: 15,
    max_rank_delta: 300
  ]

# Or switch to different policy:
# config :queue_of_matchmaking, :match_policy,
#   module: QueueOfMatchmaking.Policies.CompositePolicy,
#   config: [
#     min_wait: 10,
#     min_queue: 5,
#     max_rank_delta: 400
#   ]

# Or for testing:
# config :queue_of_matchmaking, :match_policy,
#   module: QueueOfMatchmaking.Policies.NoRestrictionPolicy  # Auto-match any 2
```

---

## Testing Approach for Policies

Each policy gets its own test suite:

```elixir
# test/queue_of_matchmaking/policies/timer_and_rank_policy_test.exs
defmodule QueueOfMatchmaking.Policies.TimerAndRankPolicyTest do
  use ExUnit.Case

  alias QueueOfMatchmaking.Policies.TimerAndRankPolicy, as: Policy

  test "rejects matches before minimum wait time" do
    entry = %{added_to_queue: DateTime.utc_now()}
    refute Policy.is_matchable?(entry, %{})
  end

  test "accepts matches after wait time within rank delta" do
    entry1 = %{
      rank: 1500,
      added_to_queue: DateTime.add(DateTime.utc_now(), -20, :second)
    }
    entry2 = %{
      rank: 1550,
      added_to_queue: DateTime.add(DateTime.utc_now(), -20, :second)
    }

    assert Policy.is_matchable?(entry1, %{})
    assert Policy.acceptable_match?(entry1, entry2)  # delta = 50 < 300
  end

  test "rejects matches outside rank delta even after waiting" do
    entry1 = %{
      rank: 1500,
      added_to_queue: DateTime.add(DateTime.utc_now(), -60, :second)
    }
    entry2 = %{
      rank: 2000,
      added_to_queue: DateTime.add(DateTime.utc_now(), -60, :second)
    }

    refute Policy.acceptable_match?(entry1, entry2)  # delta = 500 > 300
  end

  test "allows perfect matches after wait time" do
    entry1 = %{
      rank: 1500,
      added_to_queue: DateTime.add(DateTime.utc_now(), -20, :second)
    }
    entry2 = %{
      rank: 1500,
      added_to_queue: DateTime.add(DateTime.utc_now(), -20, :second)
    }

    assert Policy.acceptable_match?(entry1, entry2)  # delta = 0
  end
end
```

**Separation of Concerns:**
- Existing 20 tests in `match_making_test.exs` test the **core algorithm** (incremental expansion + FIFO)
- **Policy tests** verify the business rules (when to match, quality thresholds)

---

## Recommendation for Take-Home Implementation

### Primary Recommendation: Timer + Rank Distance Policy

**Why this showcases skills best:**

1. **Solves the stated problem**: No more 2-user instant mismatches
2. **Real-world applicability**: This is how actual games (Rocket League, Valorant) work
3. **Demonstrates architecture**: Behaviour pattern shows OTP knowledge
4. **Testable**: Clear acceptance criteria for each callback
5. **Discussable**: Gives talking points in the walkthrough about tradeoffs
6. **Balanced complexity**: Not too simple, not over-engineered

### Implementation Priority

```
Phase 1: Core Foundation
  1. Implement QueueManager GenServer with no policy (just get it working)
  2. Implement incremental expansion algorithm (pass the 20 existing tests)
  3. Wire up GraphQL mutations and subscriptions

Phase 2: Add Policy System
  4. Define MatchPolicy behaviour
  5. Implement RankDistancePolicy first (easiest to test)
  6. Add policy injection to QueueManager

Phase 3: Enhance
  7. Add TimerPolicy
  8. Combine into TimerAndRankPolicy
  9. Make policy configurable via config.exs

Phase 4: Polish (Time Permitting)
  10. Add CompositePolicy as "future enhancement"
  11. Add telemetry for match quality metrics
  12. Document all policies in README
```

---

## Walkthrough Talking Points

When Jason asks about your design choices:

### Opening
**"I identified the 2-user problem immediately..."**
- Shows critical thinking
- "Unbounded expansion defeats the purpose of skill-based matchmaking"
- "Any two users would match regardless of rank difference"
- "This would make the sophisticated FIFO fairness algorithm irrelevant"

### Design Choice Rationale
**"I chose Timer + Rank Distance because..."**
- **Balances UX with match quality**: Predictable wait time + guaranteed quality
- **Prevents starvation**: Timer guarantees eventual matchability
- **Allows tuning**: Both params can be adjusted based on traffic patterns
- **Real-world proven**: Similar to Rocket League, Valorant matchmaking
- **Testable**: Clear success criteria for each policy callback

### Architecture Decision
**"I used a behaviour to make policies pluggable..."**
- **Easy to A/B test**: Swap policies without changing core logic
- **Config-driven**: No code deploy to adjust parameters
- **Extensible**: Future requirements (party matchmaking, region, MMR decay)
- **Separation of concerns**: Business rules separate from algorithm
- **OTP best practices**: Following Elixir conventions

### Future Enhancements
**"If we had more time, I'd add..."**
- **Adaptive timers** based on queue depth (self-optimizing)
- **Telemetry integration** to measure match quality over time
- **Percentile-based thresholds**: ±10% rank instead of fixed 200
- **Progressive relaxation**: CompositePolicy with time-based loosening
- **Multiple queue tiers**: Casual vs competitive with different policies
- **Regional matchmaking**: Add geo-proximity as a policy factor

### Tradeoff Discussion
**"I considered all three strategies..."**

| Strategy | Best For | Weakness |
|----------|----------|----------|
| Timer Only | Predictable UX | May match poor ranks |
| Queue Size | Deep queues | Cold start problem |
| Rank Distance | Match quality | Outlier starvation |
| Timer + Rank | **Production use** | Requires tuning |
| Composite | Scale (millions) | Complex to tune |

**"I chose Timer + Rank as the sweet spot for this take-home."**

---

## Final Architecture

```
lib/queue_of_matchmaking/
├── queue_manager.ex              # GenServer with policy injection
├── match_policy.ex               # Behaviour definition
├── match_making/
│   └── find_match.ex            # Core algorithm (policy-agnostic)
└── policies/
    ├── no_restriction_policy.ex # For testing: matches any 2
    ├── rank_distance_policy.ex  # Strategy 3 (simple, good starting point)
    ├── timer_policy.ex          # Strategy 1
    ├── timer_and_rank_policy.ex # Combo (RECOMMENDED for production)
    └── composite_policy.ex      # All 3 with progressive relaxation (BONUS)

test/queue_of_matchmaking/
├── queue_manager_test.exs
├── match_making_test.exs         # 20 existing algorithm tests
└── policies/
    ├── rank_distance_policy_test.exs
    ├── timer_policy_test.exs
    └── timer_and_rank_policy_test.exs
```

---

## Key Insights

### The Core Problem
**Unbounded incremental expansion + immediate matching = no actual matchmaking**

### The Solution Space
Three orthogonal strategies that can be combined:
1. **When to match**: Timer, queue size, or immediate
2. **Who can match**: Eligibility based on wait time
3. **What's acceptable**: Quality thresholds on rank distance

### The Winner
**Timer + Rank Distance** because:
- Solves the 2-user problem
- Maintains match quality
- Predictable user experience
- Production-proven approach
- Architecturally elegant with behaviours

### The Bonus
**Composite Policy with progressive relaxation** shows:
- Deep systems thinking
- Real-world matchmaking knowledge
- Ability to handle complexity
- Production-scale considerations

---

## Next Steps

1. **Start simple**: Implement core QueueManager with no policy
2. **Add foundation**: RankDistancePolicy first
3. **Demonstrate pattern**: Refactor to behaviour
4. **Deliver value**: TimerAndRankPolicy as production solution
5. **Show vision**: Document CompositePolicy as future enhancement

**The goal**: Show you can solve the problem (Timer+Rank) AND architect for the future (behaviour pattern + composite strategy).
