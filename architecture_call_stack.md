# Queue Manager Architecture: Call Stack & Module Dependencies

## Overview

This document describes the complete call stack and module interdependencies for the QueueManager system, from the entry point at `QueueManager` down through the layers to the pluggable `QueueBehaviour` implementations and `MatchPolicy` modules.

---

## Layered Architecture

The system is organized in clean vertical layers:

```
┌──────────────────────────────────────────────────────────────────┐
│ Layer 0: OTP Supervision & Server Management                     │
│ - QueueManager (GenServer)                                       │
│ - Handles lifecycle, message dispatch, timer management          │
└──────────────────┬───────────────────────────────────────────────┘
                   │
┌──────────────────▼───────────────────────────────────────────────┐
│ Layer 1: Business Logic Orchestration                            │
│ - QueueManagement (coordinator)                                  │
│ - Routes between request handling, matching, and policy         │
└──┬──────────────┬──────────────────┬──────────────┬──────────────┘
   │              │                  │              │
┌──▼────┐  ┌─────▼────────┐  ┌──────▼────┐  ┌─────▼────────┐
│Layer 2: Input Processing & Matching Logic    │
├────────┤  ├──────────────┤  ├───────────┤  ├──────────────┤
│ Queue  │  │ Queue        │  │ Queue     │  │ Queue        │
│Requests│  │ Matches      │  │ Policy    │  │ State        │
│        │  │              │  │ (wrapper) │  │ (struct)     │
└────────┘  └──────────────┘  └───────────┘  └──────────────┘
   │            │                  │
└───┴────────────┴──────────────────┘
                │
┌───────────────▼────────────────────────────────────────────────┐
│ Layer 3: Pluggable Implementations                             │
│                                                                 │
│ ┌─────────────────────────┐  ┌──────────────────────────────┐ │
│ │ QueueBehaviour          │  │ MatchPolicy Behaviour        │ │
│ │ (Interface)             │  │ (Interface)                  │ │
│ └─────────────────────────┘  └──────────────────────────────┘ │
│                                                                 │
│ ┌─────────────────────────┐  ┌──────────────────────────────┐ │
│ │ Queue Storage (Simple)  │  │ Match Policy (DeferredCapped)│ │
│ │ (Default Implementation)│  │ (Default Implementation)     │ │
│ └─────────────────────────┘  └──────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

---

## Call Stack by Operation

### 1. **Enqueue Request** (Primary Flow)

User calls: `QueueManager.enqueue(request, server)`

```
QueueManager.enqueue(request)
│
├─ GenServer.call(server, {:enqueue, request})
│  ↓
├─ QueueManager.handle_call({:enqueue, params}, state)
│  ↓
├─ QueueManagement.enqueue(params, state)
│  │
│  ├─ QueueRequests.normalize(params)
│  │  └─ Validates user_id and rank
│  │     Returns: {:ok, request} | {:error, reason}
│  │
│  ├─ QueueRequests.enqueue(request, state)
│  │  ├─ build_entry(request, state)
│  │  │  └─ Creates entry with timestamp
│  │  │
│  │  ├─ QueuePolicy.before_enqueue(entry, state)
│  │  │  ├─ Builds manager context: {queue_size, now}
│  │  │  ├─ Delegates to: policy_module.before_enqueue(entry, context, policy_state)
│  │  │  └─ Returns: {:ok, state} | {:error, reason, state}
│  │  │
│  │  └─ insert_entry(entry, state)
│  │     ├─ Calls: queue_module.insert(entry, queue_state)
│  │     └─ Returns: {:ok, handle, state} | {:error, reason, state}
│  │
│  └─ QueueMatches.find(entry_with_handle, state)
│     │
│     ├─ decide_match(entry, state)
│     │  ├─ QueuePolicy.matchmaking_mode(entry, state, timestamp)
│     │  │  ├─ Builds manager context: {queue_size, now}
│     │  │  ├─ Delegates to: policy_module.matchmaking_mode(entry, context, policy_state)
│     │  │  └─ Returns: {:attempt, context, policy_state}
│     │  │         | {:defer, policy_state}
│     │  │         | {:cancel, policy_state}
│     │  └─ Returns: {:ok, decision, state}
│     │
│     └─ process_match_decision(entry, decision, state)
│        │
│        ├─ IF decision == {:attempt, context}:
│        │  │
│        │  ├─ QueueMatches.attempt(entry, context, state)
│        │  │  │
│        │  │  ├─ QueuePolicy.max_delta(entry, context, state)
│        │  │  │  ├─ Builds manager context: {queue_size, now}
│        │  │  │  ├─ Delegates to: policy_module.max_delta(entry, context, policy_state)
│        │  │  │  └─ Returns: {:unbounded, policy_state} | {:bounded, limit, policy_state}
│        │  │  │
│        │  │  └─ do_attempt_match(entry, delta_mode, context, state)
│        │  │     │
│        │  │     ├─ queue_module.snapshot(queue_state)
│        │  │     │  └─ Returns full snapshot: {by_rank, order, size}
│        │  │     │
│        │  │     ├─ Calculate candidates by expanding rank delta (0, ±1, ±2, ...)
│        │  │     │
│        │  │     ├─ pick_candidate(rank, delta, by_rank)
│        │  │     │  └─ Selects oldest by (inserted_at, user_id)
│        │  │     │
│        │  │     └─ finalize_match(entry, candidate_entry, context, state)
│        │  │        │
│        │  │        ├─ QueueState.remove_entry(handle, state) [2x]
│        │  │        │  └─ queue_module.remove(handle, queue_state)
│        │  │        │
│        │  │        ├─ QueuePolicy.after_match(match, state)
│        │  │        │  ├─ Builds manager context: {queue_size, now}
│        │  │        │  ├─ Delegates to: policy_module.after_match(match, context, policy_state)
│        │  │        │  └─ Updates policy state after successful match
│        │  │        │
│        │  │        └─ store_match(state, match)
│        │  │           └─ Stores match in bounded history
│        │  │
│        │  ├─ QueueManagement.publish_reply(reply, state)
│        │  │  └─ Delegates to configured MatchPublisher
│        │  │
│        │  └─ Returns: {{:ok, :queued} | {:ok, %{match: match}}, state}
│        │
│        ├─ IF decision == :defer:
│        │  └─ Returns: {:reply, {:ok, :queued}, state}
│        │
│        └─ IF decision == :cancel:
│           ├─ QueueRequests.remove_entry(entry.handle, state)
│           └─ Returns: {:reply, {:error, {:policy_rejected, :cancelled}}, state}
│
└─ Returns to client: {:ok, :queued} | {:ok, %{match: match}} | {:error, reason}
```

### 2. **Policy Timeout Tick** (Periodic Retry)

GenServer periodic message: `:policy_tick`

```
QueueManager.handle_info(:policy_tick, state)
│
├─ QueueManagement.policy_tick(state, schedule_policy_timeout, retry_handles)
│  │
│  ├─ QueuePolicy.handle_timeout(state)
│  │  ├─ Builds manager context: {queue_size, now}
│  │  ├─ Delegates to: policy_module.handle_timeout(context, policy_state)
│  │  └─ Returns: {:ok, policy_state, timeout}
│  │         | {:retry, instructions, policy_state, timeout}
│  │
│  ├─ schedule_policy_timeout.(state, timeout)
│  │  └─ Schedules next :policy_tick or cancels if :infinity
│  │
│  └─ IF {:retry, instructions}:
│     ├─ retry_handles.(state, instructions)
│     │  └─ For each {handle, context}: send({:policy_retry, handle, context})
│     └─ Returns updated state
│
└─ {:noreply, updated_state}
```

### 3. **Policy Retry for Specific Handle** (Deferred Matching)

GenServer message: `{:policy_retry, handle, context}`

```
QueueManager.handle_info({:policy_retry, handle, context}, state)
│
├─ QueueManagement.policy_retry(handle, context, state)
│  │
│  ├─ QueueState.fetch(handle, state)
│  │  └─ queue_module.lookup(handle, queue_state)
│  │
│  ├─ IF found:
│  │  │
│  │  ├─ QueueMatches.attempt(entry, context, state)
│  │  │  └─ (Same as enqueue attempt flow above)
│  │  │
│  │  └─ QueueManagement.publish_reply(reply, state)
│  │
│  └─ Returns: {:ok, state} | {:error, :not_found, state}
│
└─ {:noreply, state}
```

### 4. **Recent Matches Query**

User calls: `QueueManager.recent_matches(limit, server)`

```
QueueManager.recent_matches(limit, server)
│
├─ GenServer.call(server, {:recent_matches, limit})
│  ↓
├─ QueueManager.handle_call({:recent_matches, limit}, state)
│  │
│  ├─ state.matches (bounded list)
│  │  ├─ Take first N
│  │  └─ Reverse (most recent first)
│  │
│  └─ Returns list of match records
│
└─ Returns to client: [match1, match2, ...]
```

---

## Module Interdependencies

### QueueManager
- **Imports:** `QueueManagement`
- **Functions called:**
  - `QueueManagement.init/2` (in `init/1`)
  - `QueueManagement.enqueue/2` (in `handle_call`)
  - `QueueManagement.policy_tick/3` (in `handle_info`)
  - `QueueManagement.policy_retry/3` (in `handle_info`)
- **Provides:** Public API (`enqueue/1`, `recent_matches/1`)
- **Responsibility:** GenServer lifecycle, message routing, timer scheduling

### QueueManagement
- **Imports:** `QueueMatches`, `QueuePolicy`, `QueueRequests`, `QueueState`
- **Functions called:**
  - `QueueRequests.normalize/1` → `QueueRequests.enqueue/2` → `QueueMatches.find/2`
  - `QueueRequests.fetch/2` → `QueueMatches.attempt/3`
  - `QueuePolicy.handle_timeout/1`
- **Provides:** Business logic orchestration
- **Responsibility:** Coordinates request validation, matching attempts, and policy callbacks

### QueueRequests
- **Imports:** `QueuePolicy`, `QueueState`
- **Functions called:**
  - `QueuePolicy.before_enqueue/2` (in `enqueue/2`)
  - `queue_module.insert/2` (in `insert_entry/2`)
  - `queue_module.lookup/2` (in `fetch/2`)
  - `queue_module.remove/2` (in `remove_entry/2`)
- **Provides:** `normalize/1`, `enqueue/2`, `fetch/2`, `insert_entry/2`, `remove_entry/2`
- **Responsibility:** Input validation, entry creation, queue storage delegation

### QueueMatches
- **Imports:** `QueuePolicy`, `QueueState`
- **Functions called:**
  - `QueuePolicy.matchmaking_mode/3` (in `decide_match/2`)
  - `QueuePolicy.max_delta/3` (in `attempt/3`)
  - `queue_module.snapshot/1` (in `do_attempt_match/4`)
  - `QueueState.remove_entry/2` (in `finalize_match/4`)
  - `QueuePolicy.after_match/2` (in `finalize_match/4`)
- **Provides:** `find/2`, `attempt/3`
- **Responsibility:** Matching algorithm, candidate selection, match finalization

### QueuePolicy
- **Imports:** `QueueState`
- **Functions called:**
  - `policy_module.before_enqueue/3` (in `before_enqueue/2`)
  - `policy_module.matchmaking_mode/3` (in `matchmaking_mode/3`)
  - `policy_module.max_delta/4` (in `max_delta/3`)
  - `policy_module.after_match/3` (in `after_match/2`)
  - `policy_module.handle_timeout/2` (in `handle_timeout/1`)
  - `queue_module.size/1` (in `build_context/2`)
- **Provides:** Context building, policy delegation wrappers
- **Responsibility:** Abstracts pluggable policy implementations, provides consistent interface

### QueueState
- **Imports:** None
- **Provides:** State struct definition
- **Responsibility:** Defines the complete queue manager state (queue_module, queue_state, policy_module, policy_state, etc.)

---

## Pluggable Implementations

### QueueBehaviour Interface

All queue storage implementations must implement these callbacks:

```elixir
@callback init(opts()) :: {:ok, queue_state()}
@callback insert(entry(), queue_state()) :: {:ok, handle(), queue_state()} | {:error, :duplicate | term(), queue_state()}
@callback remove(handle(), queue_state()) :: {:ok, entry(), queue_state()} | {:error, :not_found, queue_state()}
@callback lookup(handle(), queue_state()) :: {:ok, entry(), queue_state()} | {:error, :not_found, queue_state()}
@callback snapshot(queue_state()) :: {snapshot(), queue_state()}
@callback head(queue_state()) :: {:ok, entry(), queue_state()} | {:error, :empty, queue_state()}
@callback pop_head(queue_state()) :: {:ok, entry(), queue_state()} | {:error, :empty, queue_state()}
@callback size(queue_state()) :: {non_neg_integer(), queue_state()}
@callback prune((entry() -> boolean()), queue_state()) :: {:ok, [entry()], queue_state()}
```

**Default Implementation:** `QueueStorage.Simple`
- In-memory FIFO with rank-based indexing
- Data structures:
  - `order`: Erlang queue for FIFO ordering
  - `entries`: Map of handle → entry
  - `index`: Map of user_id → handle (duplicate detection)
  - `by_rank`: Map of rank → Erlang queue of handles

### MatchPolicy Behaviour Interface

All match policy implementations must implement these callbacks:

```elixir
@callback init(opts()) :: {:ok, policy_state(), timeout_ms | :infinity}
@callback before_enqueue(entry(), manager_context(), policy_state()) :: {:proceed, policy_state()} | {:reject, reason, policy_state()}
@callback matchmaking_mode(entry(), manager_context(), policy_state()) :: {:attempt, context, policy_state} | {:defer, policy_state} | {:cancel, policy_state}
@callback max_delta(entry(), manager_context(), retry_context(), policy_state()) :: {:unbounded, policy_state} | {:bounded, limit, policy_state}
@callback after_match(match(), manager_context(), policy_state()) :: {:ok, policy_state}
@callback handle_timeout(manager_context(), policy_state()) :: {:ok, policy_state, timeout} | {:retry, [{handle, context}], policy_state, timeout}
@callback terminate(reason(), policy_state()) :: :ok
```

**Default Implementation:** `MatchPolicies.DeferredCapped`
- Defers matching until queue reaches threshold or timeout
- Configuration: min_queue, max_wait_ms, tick_ms, initial_delta, relaxed_delta

---

## Data Flow Diagram

### Entry Through the System

```
┌─────────────────────────────────────────────────────────────┐
│ Normalized Request: {user_id, rank}                         │
└────────────────────────┬────────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────────┐
│ QueueRequests: Build Entry with timestamp & metadata        │
│ Entry: {user_id, rank, inserted_at, meta}                  │
└────────────────────────┬────────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────────┐
│ QueuePolicy.before_enqueue: Pre-insertion validation        │
│ ← Manager Context: {queue_size, now}                       │
└────────────────────────┬────────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────────┐
│ QueueBehaviour.insert: Store in queue, get handle          │
│ Queue Storage: by_rank, order, index updated              │
└────────────────────────┬────────────────────────────────────┘
                         ▼
┌─────────────────────────────────────────────────────────────┐
│ QueuePolicy.matchmaking_mode: Decide action                │
│ ← Manager Context: {queue_size, now}                       │
│ ↓ attempt | defer | cancel                                 │
└────────────────────────┬────────────────────────────────────┘
                         ▼
     ┌─────────────────────┬──────────────────┐
     │                     │                  │
    DEFER              CANCEL            ATTEMPT
     │                     │                  │
     │              Remove from queue    QueueMatches.attempt:
     │              Return error         ├─ Get snapshot (by_rank)
     │                                  ├─ Expand rank delta
     │                                  ├─ Pick oldest candidate
     │                                  ├─ If found:
     │                                  │  ├─ Remove both entries
     │                                  │  ├─ Create match record
     │                                  │  ├─ QueuePolicy.after_match
     │                                  │  └─ Return match for publisher
     │                                  └─ If not found:
     │                                     └─ Entry stays queued
     └──────────────────┬─────────────────┘
                        ▼
           ┌──────────────────────────────────┐
           │ Return to Client:                │
           │ {:ok, :queued}                   │
           │ {:ok, %{match: match}}           │
           │ {:error, reason}                 │
           └──────────────────────────────────┘
```

### Periodic Policy Timeout

```
GenServer Timer Fires
         │
         ▼
QueuePolicy.handle_timeout
├─ Manager Context: {queue_size, now}
├─ Policy checks waiting entries
└─ Returns:
   ├─ {:ok, policy_state, new_timeout}
   └─ {:retry, [{handle, context}, ...], policy_state, new_timeout}
         │
         ├─ Schedule next timeout
         │
         └─ For each handle: send({:policy_retry, handle, context})
                │
                ▼
         QueueMatches.attempt (same logic as above)
```

---

## State Evolution

```
Initial State (created in QueueManagement.init):
├─ queue_module: QueueStorage.Simple
├─ queue_state: {order: empty_queue, entries: {}, index: {}, by_rank: {}}
├─ policy_module: MatchPolicies.DeferredCapped
├─ policy_state: initial policy state
├─ policy_timer_ref: scheduled timer reference
├─ time_fn: &System.monotonic_time/1
├─ publisher_module: MatchPublisher.Noop
├─ matches: []
└─ max_match_history: 100

After each operation:
├─ queue_state: Updated with new entries/removals
├─ policy_state: Updated based on policy callbacks
├─ policy_timer_ref: Rescheduled if needed
├─ matches: Bounded list of recent matches (newest first)
└─ publisher_module: Delegated publisher module (configurable)
```

---

## Key Design Principles

1. **Separation of Concerns:**
   - QueueManager: Server lifecycle only
   - QueueManagement: Business logic coordination
   - QueueRequests: Input validation
   - QueueMatches: Matching algorithm
   - QueuePolicy: Policy abstraction
   - QueueState: Immutable state definition

2. **Pluggability:**
   - Queue storage via QueueBehaviour
   - Match policy via MatchPolicy
   - Both instantiated at startup via options

3. **Determinism:**
   - FIFO fairness via (inserted_at, user_id) tuples
   - Snapshot-based candidate selection (read-only)
   - Incremental rank expansion

4. **State Immutability:**
   - All functions return updated state
   - GenServer message handlers accumulate state changes
   - No side effects in business logic; external publishing handled via configurable module

5. **Context Passing:**
   - Manager context built once per decision point
   - Includes queue_size and current_time
   - Passed to pluggable policy implementations

---

## Extension Points

To extend the system:

1. **New Queue Storage:**
   - Implement `QueueBehaviour` callbacks
   - Return custom queue_state from `init/1`
   - Implement all required callbacks

2. **New Match Policy:**
   - Implement `MatchPolicy` callbacks
   - Track custom state in policy_state
   - Return decisions: attempt/defer/cancel

3. **Custom Matching Logic:**
   - Policy's `max_delta` callback controls search radius
   - Candidate selection in QueueMatches is deterministic (FIFO)

4. **New Events/Hooks:**
   - Policy `before_enqueue`, `matchmaking_mode`, `after_match` callbacks
   - Can reject, defer, or modify decisions
   - Receives manager context for decisions

---

## Performance Considerations

- **Lookup:** O(1) via handle in queue storage
- **Duplicate Detection:** O(1) via index in queue storage
- **Insert/Remove:** O(1) FIFO operations
- **Candidate Selection:** O(queue_size) for snapshot + O(num_deltas × delta_size) for expansion
- **Policy Timeout:** O(1) to schedule next tick
- **Retry:** O(1) to schedule specific retry message

Memory:
- Queue storage tracks all entries + indices
- Policy state depends on implementation (deferred capped: bounded waiting list)
- Match history: bounded by `max_match_history` (default 100)
