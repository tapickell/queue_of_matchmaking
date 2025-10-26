# Queue Match Policy Behaviour Specification

The queue manager delegates “when and whether to attempt matching” decisions to a pluggable policy module. Each policy module must implement the `QueueOfMatchmaking.MatchPolicy` behaviour defined by this specification.

## Behaviour Module

```elixir
defmodule QueueOfMatchmaking.MatchPolicy do
  @callback init(opts :: keyword()) ::
              {:ok, policy_state :: term(), timeout() | :hibernate | :infinity}

  @callback before_enqueue(entry :: QueueOfMatchmaking.QueueManager.entry(),
                           manager_state :: QueueOfMatchmaking.QueueManager.state(),
                           policy_state :: term()) ::
              {:proceed, updated_policy_state :: term()} |
              {:reject, reason :: :invalid | :duplicate | term(), updated_policy_state :: term()}

  @callback matchmaking_mode(entry :: QueueOfMatchmaking.QueueManager.entry(),
                              manager_state :: QueueOfMatchmaking.QueueManager.state(),
                              policy_state :: term()) ::
              {:attempt, match_context :: map(), updated_policy_state :: term()} |
              {:defer, updated_policy_state :: term()} |
              {:cancel, updated_policy_state :: term()}

  @callback max_delta(entry :: QueueOfMatchmaking.QueueManager.entry(),
                      manager_state :: QueueOfMatchmaking.QueueManager.state(),
                      attempt_context :: map(),
                      policy_state :: term()) ::
              {:unbounded, updated_policy_state :: term()} |
              {:bounded, non_neg_integer(), updated_policy_state :: term()}

  @callback after_match(match :: QueueOfMatchmaking.QueueManager.match(),
                        manager_state :: QueueOfMatchmaking.QueueManager.state(),
                        policy_state :: term()) ::
              {:ok, updated_policy_state :: term()}

  @callback handle_timeout(manager_state :: QueueOfMatchmaking.QueueManager.state(),
                           policy_state :: term()) ::
              {:ok, updated_policy_state :: term(), timeout() | :hibernate | :infinity}
              | {:retry, [{QueueOfMatchmaking.QueueBehaviour.handle(), map()}],
                  updated_policy_state :: term(), timeout() | :hibernate | :infinity}

  @callback terminate(reason :: term(), policy_state :: term()) :: :ok
end
```

### Type Aliases

`QueueOfMatchmaking.QueueManager.entry()` references the queue entry map exposed by
the queue behaviour:

```elixir
%{
  user_id: String.t(),
  rank: non_neg_integer(),
  inserted_at: integer(),
  handle: term()
}
```

`QueueOfMatchmaking.QueueManager.match()` references the two-user tuple emitted by the queue manager:

```elixir
%{
  users: [
    %{user_id: String.t(), rank: non_neg_integer(), inserted_at: integer(), handle: term()},
    %{user_id: String.t(), rank: non_neg_integer(), inserted_at: integer(), handle: term()}
  ],
  delta: non_neg_integer(),
  matched_at: integer()
}
```

### Callback Semantics

- **init/1**  
  Called when the queue manager starts. Returns an initial policy-state term along with the next timeout. Use the timeout to request periodic ticks (e.g., for aging logic). `:hibernate` and `:infinity` follow the standard GenServer semantics.

- **before_enqueue/3**  
  Invoked immediately after the queue manager validates an incoming request and before it is added to state. Return `{:proceed, policy_state}` to allow the enqueue, or `{:reject, reason, policy_state}` to veto it. `reason` is surfaced as the GraphQL error atom.

- **matchmaking_mode/3**  
  Called after the entrant is inserted. Determines the matching flow for this entrant:
  * `{:attempt, context, policy_state}` instructs the manager to run the incremental expansion algorithm immediately. `context` is an opaque map that is passed back to the policy via `max_delta/3`, enabling per-attempt metadata.
  * `{:defer, policy_state}` skips matching for now. The entry remains queued until the policy triggers a retry (e.g., via timeout).
  * `{:cancel, policy_state}` removes the entrant (e.g., after waiting too long) and emits no match.

- **max_delta/4**  
  Controls the allowable rank distance for the current matching attempt. Receives the opaque `context` emitted by `matchmaking_mode/3`, making it easy to relax constraints on demand. Return `{:bounded, n, policy_state}` to enforce a maximum `Δ`, or `{:unbounded, policy_state}` to allow unrestricted expansion.

- **after_match/3**  
  Runs after a successful match has been committed to queue state but before PubSub notifications fire. Suitable for telemetry, quality tracking, or altering policy state based on outcomes.

- **handle_timeout/3**  
  Invoked when the queue manager schedules a timeout for the policy. Use this to re-evaluate deferred entrants, relax thresholds, or trigger retries. Policies may either return `{:ok, state, timeout}` (no action) or `{:retry, instructions, state, timeout}` where `instructions` is a list of `{handle, context}` tuples that the manager should match immediately.

- **terminate/2**  
  Called during queue manager shutdown for cleanup. Optional, but useful when the policy maintains external resources.

## Integration Notes

- The queue manager holds the policy module and policy-state in its GenServer state; the policy must remain pure (no side-effects except through return values).
- Multiple policies can coexist by providing different modules (e.g., `QueueOfMatchmaking.MatchPolicy.Immediate`, `QueueOfMatchmaking.MatchPolicy.DeferredCapped`). Select the desired module during QueueManager startup.
- All callbacks run inside the queue manager’s GenServer process—avoid long-running work.
- When policies veto or cancel requests, the queue manager translates the returned `reason` into the GraphQL error payload.

## Testing Expectations

- Provide a lightweight default policy module for unit tests (e.g. `MatchPolicies.DeferredCapped` configured with `initial_delta: :unbounded`) so deterministic test expectations stay simple.
- Ensure the queue manager can accept a custom policy during tests to simulate deferred or bounded scenarios.
- Policy modules should be deterministic; rely only on data passed into callbacks to keep behaviour predictable.
