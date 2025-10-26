## Queue + Match Policy Integration Example

This appendix narrates how a concrete queue storage module and a match policy module collaborate inside the queue manager to satisfy the matchmaking requirements.

### Actors

- `QueueOfMatchmaking.QueueManager`: GenServer orchestrating requests.
- `QueueOfMatchmaking.QueueStorage.Simple`: reference implementation using in-memory maps and `:queue`.
- `QueueOfMatchmaking.MatchPolicies.DeferredCapped`: policy that waits for either a minimum queue size or a maximum wait time and enforces a rank delta cap.

### Boot Sequence

1. The application supervisor starts `QueueManager` with:
   ```elixir
   {:ok, _pid} =
     QueueManager.start_link(
       queue_module: QueueOfMatchmaking.QueueStorage.Simple,
       queue_opts: [],
       policy_module: QueueOfMatchmaking.MatchPolicies.DeferredCapped,
       policy_opts: [min_queue: 3, max_wait_ms: 5_000, initial_delta: 50, relaxed_delta: 200]
     )
   ```
2. `QueueManager.init/1`
   - Calls `QueueStorage.Simple.init/1` → returns empty queue state.
   - Calls `MatchPolicies.DeferredCapped.init/1` → returns policy state plus timeout (e.g. `{:ok, policy_state, 1_000}`) to request periodic ticks.
   - Stores `{queue_module, queue_state, policy_module, policy_state, timeout}` in GenServer state and sets `Process.send_after/3` if needed.

### Enqueue Flow

When the GraphQL resolver invokes `QueueManager.enqueue(%{user_id: "alice", rank: 1500})`:

1. QueueManager validates inputs (trim user ID, ensure rank ≥ 0).
2. Calls `policy.before_enqueue(entry, mgr_state, policy_state)`.
   - If the policy returns `{:reject, :duplicate, policy_state}`, resolver surfaces `{ok: false, error: "already_enqueued"}`.
   - Else `{:proceed, policy_state}` allows the manager to continue.
3. Manager timestamps entry with `System.monotonic_time(:millisecond)` and delegates to queue implementation:
   - `QueueStorage.Simple.insert(entry, queue_state)` -> `{:ok, handle, queue_state}`. The simple queue maintains:
     ```elixir
     %{
       order: :queue.in(handle, order_queue),
       index: %{user_id => handle},
       entries: %{handle => entry},
       by_rank: %{rank => :queue.of(handle)}
     }
     ```
4. Updated queue state is stored in manager state.

### Deciding Whether to Match

5. Manager calls `policy.matchmaking_mode(entry, mgr_state, policy_state)`:
   - Suppose the queue now holds 3 entries. Policy sees `size >= min_queue` and returns `{:attempt, %{attempted_at: now}, policy_state}`.
   - If queue size were smaller and wait time < max, it would return `{:defer, policy_state}`; the manager would stop here, leaving entry queued until next timeout tick.

### Matching Attempt

6. With `{:attempt, context, policy_state}`, manager obtains a snapshot via `queue.snapshot/1` such as:
   ```elixir
   %{
     by_rank: %{1498 => [%{handle: h1, user_id: "bob", inserted_at: ...}],
                1500 => [%{handle: h2, user_id: "carol", inserted_at: ...},
                         %{handle: h3, user_id: "alice", inserted_at: ...}]},
     order: [%{handle: h1, ...}, %{handle: h2, ...}, %{handle: h3, ...}],
     size: 3
   }
   ```
7. Manager calls `policy.max_delta(entry, mgr_state, context, policy_state)`. Initially returns `{:bounded, 50, policy_state}`.
8. Manager runs incremental expansion algorithm:
   - Δ=0 → find head handles at rank 1500.
   - Δ=1..50 → gather candidates from `by_rank`.
   - Using `order` list (or per-rank :queue) to respect FIFO, chooses oldest eligible handle whose rank difference ≤ 50.
9. Suppose it picks handle `h1` (user rank 1498). Manager removes both entries:
   - `queue.remove(h1, queue_state)`
   - `queue.remove(entry.handle, queue_state)` (handle of entrant).
10. Manager constructs match payload:
    ```elixir
    match = %{
      users: [
        %{user_id: "bob", rank: 1498, inserted_at: ..., handle: h1},
        %{user_id: "alice", rank: 1500, inserted_at: ..., handle: entry.handle}
      ],
      delta: 2,
      matched_at: now
    }
    ```

### Post-Match Hooks

11. Manager notifies policy via `policy.after_match(match, mgr_state, policy_state)`.
    - Policy may log wait times or adjust internal counters.
12. Manager publishes to subscriptions:
    ```elixir
    Absinthe.Subscription.publish(
      QueueOfMatchmakingWeb.Endpoint,
      %{users: [%{user_id: "alice", user_rank: 1500}, %{user_id: "bob", user_rank: 1498}]},
      match_found: ["user:alice", "user:bob"]
    )
    ```

### Timeout Tick Handling

If the policy had deferred matching:
- `handle_timeout` callback fires after scheduled interval.
- Policy inspects queue snapshot (passed via manager state) and may return `{:ok, new_policy_state, 1_000}`. It can also request immediate matching for entrants that exceeded `max_wait_ms`.
- Manager iterates deferred entrants (tracked by handles/meta) and replays steps 5–12.

### Example Modules (Pseudo-Code)

For concrete reference, check the production modules `QueueOfMatchmaking.QueueStorage.Simple`
and `QueueOfMatchmaking.MatchPolicies.DeferredCapped` in the repository—they implement the
behaviours described above and mirror the flow outlined in this document.

### Key Takeaways

- Queue behaviour isolates storage concerns (insertion order, rank buckets).
- Match policy governs when matching occurs and how aggressive rank expansion can be.
- Combining both via QueueManager yields a flexible system where alternative policies or storage engines can be swapped with minimal disruption.
