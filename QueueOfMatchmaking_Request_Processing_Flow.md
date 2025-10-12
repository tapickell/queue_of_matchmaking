# Queue of Matchmaking - Request Processing Flow

This document describes the complete flow of how matchmaking requests are processed, from GraphQL mutation to subscription notification.

## Prerequisites

- Clients are subscribed to the `matchFound(userId: String!)` GraphQL subscription for their respective user IDs
- The matchmaking queue is initially empty
- All requests include: `user_id` (String), `rank` (Integer), and `added_to_queue` (DateTime)

---

## Request Processing Flow

### Step 1: First User Joins Queue

**Action:** `addRequest(userId: "1", rank: 42)` mutation is called

```
┌─────────────────────────────────────┐
│ GraphQL Mutation: addRequest        │
│ userId: "1"                         │
│ rank: 42                            │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Add to Queue with Timestamp         │
│                                     │
│ Queue State:                        │
│ [                                   │
│   %{user_id: "1",                  │
│      rank: 42,                      │
│      added_to_queue: T1}            │
│ ]                                   │
│                                     │
│ Queue Length: 1                     │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Trigger: find_match(queue)          │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Match Logic: Queue Length Check     │
│                                     │
│ length(queue) < 2?                  │
│ YES → Return {:error, :no_matches}  │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Result: No Match Found              │
│                                     │
│ - No players removed from queue     │
│ - No subscriptions triggered        │
│ - User "1" remains in queue         │
└─────────────────────────────────────┘
```

**State After Step 1:**
- Queue: `[user_id: "1", rank: 42]`
- User "1" subscription: **No notification sent**
- Queue length: 1

---

### Step 2: Second User Joins Queue

**Action:** `addRequest(userId: "2", rank: 9001)` mutation is called

```
┌─────────────────────────────────────┐
│ GraphQL Mutation: addRequest        │
│ userId: "2"                         │
│ rank: 9001                          │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Add to Tail of Queue with Timestamp │
│                                     │
│ Queue State:                        │
│ [                                   │
│   %{user_id: "1",                  │   ← HEAD (oldest)
│      rank: 42,                      │
│      added_to_queue: T1},           │
│   %{user_id: "2",                  │   ← TAIL (newest)
│      rank: 9001,                    │
│      added_to_queue: T2}            │
│ ]                                   │
│                                     │
│ Queue Length: 2                     │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Trigger: find_match(queue)          │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Match Logic: Queue Length Check     │
│                                     │
│ length(queue) == 2?                 │
│ YES → Return {:ok, queue}           │
│                                     │
│ Rationale:                          │
│ - Only 2 players available          │
│ - Incremental range expansion       │
│   would eventually match them       │
│ - Auto-match to reduce wait time    │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Result: Match Found!                │
│                                     │
│ Matched Players:                    │
│ [                                   │
│   %{user_id: "1", rank: 42},       │
│   %{user_id: "2", rank: 9001}      │
│ ]                                   │
│                                     │
│ Rank Difference: 8959               │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Remove Matched Players from Queue   │
│                                     │
│ Queue State: []                     │
│ Queue Length: 0                     │
└──────────────┬──────────────────────┘
               │
               ▼
┌─────────────────────────────────────┐
│ Trigger GraphQL Subscriptions       │
│                                     │
│ matchFound(userId: "1") receives:   │
│ {                                   │
│   "users": [                        │
│     {"userId": "1", "userRank": 42},│
│     {"userId": "2", "userRank": 9001}│
│   ]                                 │
│ }                                   │
│                                     │
│ matchFound(userId: "2") receives:   │
│ {                                   │
│   "users": [                        │
│     {"userId": "1", "userRank": 42},│
│     {"userId": "2", "userRank": 9001}│
│   ]                                 │
│ }                                   │
└─────────────────────────────────────┘
```

**State After Step 2:**
- Queue: `[]` (empty)
- User "1" subscription: **Notification sent** ✓
- User "2" subscription: **Notification sent** ✓
- Both users matched and removed from queue

---

## Match Logic Decision Tree

```
find_match(queue) called
        │
        ▼
   ┌─────────┐
   │ Length? │
   └────┬────┘
        │
        ├─────────────┬─────────────┬─────────────┐
        │             │             │             │
     < 2            == 2          > 2            │
        │             │             │             │
        ▼             ▼             ▼             │
  ┌─────────┐   ┌─────────┐   ┌──────────────┐  │
  │ Return  │   │ Return  │   │  Incremental  │  │
  │ :error  │   │ {:ok,   │   │    Range      │  │
  │         │   │  queue} │   │  Expansion    │  │
  └─────────┘   └─────────┘   └──────┬───────┘  │
                                      │          │
                                      ▼          │
                              ┌─────────────────┐│
                              │ Find min range  ││
                              │ with matches    ││
                              └────────┬────────┘│
                                       │         │
                                       ▼         │
                              ┌─────────────────┐│
                              │ Among matches   ││
                              │ at min range,   ││
                              │ pick OLDEST     ││
                              │ (FIFO fairness) ││
                              └────────┬────────┘│
                                       │         │
                                       ▼         │
                              ┌─────────────────┐│
                              │ Match with      ││
                              │ newest player   ││
                              │ (tail of queue) ││
                              └────────┬────────┘│
                                       │         │
                                       ▼         │
                              ┌─────────────────┐│
                              │ Return {:ok,    ││
                              │ [oldest,newest]}││
                              └─────────────────┘│
```

---

## Key Principles

### Queue Structure (FIFO)
```
[HEAD/OLDEST ... MIDDLE ... TAIL/NEWEST]
```

- **HEAD** = Oldest player (waited longest) - First In
- **TAIL** = Newest player (just joined) - Last In
- **Matching** = Newest player seeks match with oldest eligible player - First Out

### Matching Priority

1. **Queue Length == 2**: Auto-match (inevitable match, optimize wait time)
2. **Queue Length > 2**: Incremental range expansion with FIFO fairness
   - Find minimum range with available matches
   - Select player with oldest `added_to_queue` timestamp at that range
   - Match with newest player (who triggered the match attempt)

### Fairness Guarantee

Within any given rank range, the player who has **waited longest** (oldest timestamp) gets matched first.

**Example:**
```
Queue: [
  %{user_id: "A", rank: 1000, added_to_queue: T1},  # oldest
  %{user_id: "B", rank: 1001, added_to_queue: T2},
  %{user_id: "C", rank: 1001, added_to_queue: T3},
  %{user_id: "D", rank: 1000, added_to_queue: T4}   # newest
]

When D (rank 1000) joins:
- Range 0: A (rank 1000) is available
- Match: A and D (A waited longest at rank 1000)
```

---

## Subscription Notification Format

When a match is found, both matched users receive a notification via their GraphQL subscription:

```graphql
subscription {
  matchFound(userId: "1") {
    users {
      userId
      userRank
    }
  }
}
```

**Notification payload:**
```json
{
  "data": {
    "matchFound": {
      "users": [
        {
          "userId": "1",
          "userRank": 42
        },
        {
          "userId": "2",
          "userRank": 9001
        }
      ]
    }
  }
}
```

**Important:** Only the subscriptions for the two matched `userId` values receive notifications. Other subscribed users are not notified.

---

## State Transitions

```
Empty Queue → Add User 1 → Queue [User 1] → No Match
                                  ↓
                              Add User 2
                                  ↓
                          Queue [User 1, User 2]
                                  ↓
                              Match Found
                                  ↓
                          Notify Both Users
                                  ↓
                        Remove from Queue → Empty Queue
```

---

## Error Handling

| Scenario | Result | Subscription Triggered? |
|----------|--------|------------------------|
| Empty queue | `{:error, :no_matches}` | No |
| Single user | `{:error, :no_matches}` | No |
| Two users | `{:ok, [user1, user2]}` | Yes (both) |
| Multiple users | `{:ok, [oldest_match, newest]}` | Yes (both) |
| User already in queue | Mutation returns error | No |

---

## Implementation Notes

1. **Queue State Change Triggers Matching**: Every time a user is added to the queue, `find_match/1` is called
2. **Atomic Operations**: Match finding and queue updates must be atomic to prevent race conditions
3. **Timestamp Precision**: Use `DateTime.utc_now()` for consistent, comparable timestamps
4. **In-Memory Storage**: All queue data stored in memory (no persistent storage per spec)
5. **Concurrency**: Must handle multiple concurrent `addRequest` mutations safely
