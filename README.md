# Queue of Matchmaking

A GraphQL-based matchmaking queue system built with Elixir and Phoenix. The system efficiently matches users based on rank proximity using pluggable queue storage and matching policies.

## Overview

The matchmaking system maintains an in-memory queue of user requests and uses an incremental rank-delta expansion algorithm to find the closest rank matches. Once matched, pairs are removed from the queue and stored in-memory match history.

### Architecture Highlights

- **In-Memory Storage**: All data (requests, matches) lives in GenServer state—no persistent storage
- **Pluggable Components**: Queue storage and match policies are behaviour modules, allowing different strategies without changing core logic
- **Concurrent-Safe**: Built on Erlang's GenServer for thread-safe queue operations
- **GraphQL API**: Full mutation and subscription support via Absinthe

## Key Design Patterns: Behaviours

The system leverages two core Elixir behaviours for modularity:

### 1. **QueueBehaviour**
Defines the contract for queue storage engines. Implementations handle entry insertion, removal, snapshots grouped by rank, and pruning.

- **Module**: `QueueOfMatchmaking.QueueBehaviour`
- **Reference Implementation**: `QueueOfMatchmaking.QueueStorage.Simple` (backed by `:queue` and maps)
- **Key Operations**: `insert/2`, `remove/2`, `snapshot/1`, `lookup/2`, `head/1`, `pop_head/1`, `prune/2`

See [Queue Behaviour Specification](queue_of_matchmaking/queue_behaviour_spec.md) for full details.

### 2. **MatchPolicy**
Defines hooks for when and how to attempt matches. Policies control rank delta bounds, deferred retries, and queue size thresholds.

- **Module**: `QueueOfMatchmaking.MatchPolicy`
- **Reference Implementation**: `QueueOfMatchmaking.MatchPolicies.DeferredCapped` (defer until queue ≥ min size or timeout)
- **Key Callbacks**: `before_enqueue/3`, `matchmaking_mode/3`, `max_delta/4`, `after_match/3`, `handle_timeout/3`

See [Match Policy Specification](queue_of_matchmaking/match_policy_spec.md) for full details.

## Testing the System

### Setup

1. Start the Phoenix server:
   ```bash
   cd queue_of_matchmaking
   mix phx.server
   ```
   Server runs on `http://localhost:4000`

2. GraphQL endpoint: `http://localhost:4000/api`
3. WebSocket endpoint: `ws://localhost:4000/graphql/websocket`

### Running Test Scenarios

The system comes with two Python mutation scripts that split the 500-player dataset. Run them **simultaneously** to trigger matches:

### Observing Matches

- Python Subscriber
Run the Python subscription script (in a third terminal) to monitor matches in real-time:

```bash
python3 scripts/gql_subscription.py
```

- Elixir Subscriber

1. Start the Phoenix server:
   ```bash
   cd subscriber
   iex -S mix phx.server
   1> QueueSubscriber.subscribe_all()
   ```

This subscribes all 500 players from two different subscribers and prints matches as they occur, showing matched user pairs and rank delta.

### Example Output

```
▶️  Subscribing for Player1 (rank 1409)
▶️  Subscribing for Player2 (rank 328)
...
✅ Match for Player1: users=['Player1', 'Player47'], delta=5
✅ Match for Player2: users=['Player2', 'Player156'], delta=12
```

#### Terminal 1: Enqueue Odd-Indexed Players
```bash
python3 scripts/gql_mutation.py odd
```
Enqueues Players 1, 3, 5, ..., 499 with randomized delays.

#### Terminal 2: Enqueue Even-Indexed Players
```bash
python3 scripts/gql_mutation.py even
```
Enqueues Players 2, 4, 6, ..., 500 with randomized delays.

## GraphQL API

### Mutation: `addRequest`

Enqueue a user for matchmaking.

```graphql
mutation {
  addRequest(userId: "Player1", rank: 1500) {
    ok
    error
  }
}
```

**Response:**
- `ok: true` — User queued successfully or immediately matched
- `ok: false, error: "..."` — Validation or policy rejection error

### Subscription: `matchFound`

Receive notifications when matched with another user.

```graphql
subscription {
  matchFound(userId: "Player1") {
    users {
      userId
      userRank
    }
    delta
  }
}
```

Triggered only when the subscribed `userId` is part of a match.

## Project Structure

```
queue_of_matchmaking/
├── lib/
│   ├── queue_of_matchmaking/
│   │   ├── queue_behaviour.ex          # Storage behaviour definition
│   │   ├── match_policy.ex             # Matching policy behaviour
│   │   ├── queue_manager.ex            # GenServer orchestrating all
│   │   ├── match_policies/
│   │   │   └── deferred_capped.ex      # Default policy implementation
│   │   └── queue_storage/
│   │       └── simple.ex               # Reference queue implementation
│   └── queue_of_matchmaking_web/
│       ├── schema.ex                   # GraphQL schema
│       └── resolvers/
│           └── queue.ex                # Mutation resolver
├── test/                               # Full test suite
└── queue_behaviour_spec.md
└── match_policy_spec.md
```

## Documentation

- **[Queue Behaviour Spec](queue_of_matchmaking/queue_behaviour_spec.md)**: Behaviour contract for queue storage engines
- **[Match Policy Spec](queue_of_matchmaking/match_policy_spec.md)**: Behaviour contract for matching policies
- **[Architecture & Call Stack](architecture_call_stack.md)**: Detailed flow diagrams and module interactions
- **[Test Requirements](queue_of_matchmaking/queue_test.md)**: Full acceptance criteria

## Matching Algorithm

1. **Immediate Check**: If queue size ≥ 20, attempt immediate match
2. **Deferred Check**: Otherwise, defer and retry on timeout
3. **Incremental Expansion**: Search for candidates at delta 0, 1, 2, ... until a match is found
4. **Finalization**: Remove both users from queue, publish match to subscriptions, store in history

The matching is efficient: O(n) per attempt where n is the queue size, and uses a rank-delta snapshot to avoid repeated scans.

## Testing

All tests pass:
```bash
cd queue_of_matchmaking
mix test
```

11 test files cover:
- Queue storage operations
- Match policy lifecycle
- Queue manager integration
- GraphQL resolver behavior
- End-to-end matching scenarios

## Performance

- **Matching**: O(n) per attempt (queue snapshot + linear search)
- **Storage**: O(1) insertion/removal with handle-based lookups
- **Memory**: O(n) where n = queue size + match history (capped at 100 by default)

---

**Start with**: [Architecture & Call Stack](architecture_call_stack.md) for a visual overview, or dive into [Queue Behaviour Spec](queue_of_matchmaking/queue_behaviour_spec.md) for the first behaviour module.
