# Queue Storage Behaviour Specification

The matchmaking system treats its backing queue as a pluggable component responsible for request storage, retrieval, and removal. The behaviour below captures the contract the queue manager will rely on when coordinating with match policies.

## Core Concepts

- **Entry**: immutable request record containing `user_id`, `rank`, `inserted_at` (monotonic timestamp), and optional metadata.
- **Handle**: opaque token returned by the queue when an entry is inserted; used to reference the entry for removal.
- **Snapshot**: read-only projection of queue contents used by matching logic to inspect candidates without mutating state.

## Behaviour Module

```elixir
defmodule QueueOfMatchmaking.QueueBehaviour do
  @moduledoc """
  Behaviour for queue storage engines backing the matchmaking system.
  """

  @type opts :: keyword()
  @type queue_state :: term()
  @type entry :: %{
          user_id: String.t(),
          rank: non_neg_integer(),
          inserted_at: integer(),
          handle: term(),
          meta: map()
        }
  @type handle :: term()
  @type snapshot :: %{
          by_rank: %{non_neg_integer() => [entry()]},
          order: [entry()],
          size: non_neg_integer()
        }

  @callback init(opts()) :: {:ok, queue_state()}

  @callback insert(entry(), queue_state()) ::
              {:ok, handle(), queue_state()} | {:error, :duplicate | term(), queue_state()}

  @callback remove(handle(), queue_state()) ::
              {:ok, entry(), queue_state()} | {:error, :not_found, queue_state()}

  @callback lookup(handle(), queue_state()) ::
              {:ok, entry(), queue_state()} | {:error, :not_found, queue_state()}

  @callback snapshot(queue_state()) :: {snapshot(), queue_state()}

  @callback head(queue_state()) ::
              {:ok, entry(), queue_state()} | {:error, :empty, queue_state()}

  @callback pop_head(queue_state()) ::
              {:ok, entry(), queue_state()} | {:error, :empty, queue_state()}

  @callback size(queue_state()) :: {non_neg_integer(), queue_state()}

  @callback prune(fun :: (entry() -> boolean()), queue_state()) ::
              {:ok, pruned :: [entry()], queue_state()}
end
```

### Callback Roles

- **init/1**  
  Establishes an empty queue state. Accepts options such as maximum retention or initial seed data.

- **insert/2**  
  Adds a new entry. Returns a handle used later for removal or lookup. Duplicate detection lives here; return `{:error, :duplicate, state}` when an entry with the same `user_id` already exists.

- **remove/2**  
  Deletes the entry referenced by the handle, returning the removed entry for downstream use (e.g., after matching).

- **lookup/2**  
  Provides a per-entry read without altering queue order—useful when match policies need metadata tied to handles.

- **snapshot/1**  
  Produces a read-only view of the queue grouped by rank plus insertion order. Each bucket contains fully-populated entry maps (including the opaque handle) so the matcher can remove winners without performing additional lookups.

- **head/1** and **pop_head/1**  
  Convenience helpers for FIFO operations. `head/1` peeks at the oldest entry, `pop_head/1` removes it.

- **size/1**  
  Lightweight current length check used by policies (e.g., minimum queue length triggers).

- **prune/2**  
  Removes all entries matching a predicate (e.g., timed out). Returns the removed entries so the caller can emit notifications.

## Design Notes

- Queue implementations may hold additional indices (e.g., `user_id` map, rank buckets). These stay opaque to callers; only the behaviour’s callbacks are stable.
- All callbacks are synchronous and must remain fast; heavy computation should live in higher-level modules.
- The queue manager will wrap these callbacks inside its GenServer, so you may store the queue_state directly in the manager’s state record.
- This abstraction allows experimentation with different storage strategies (plain lists, buckets backed by `:queue`, ETS) without disturbing policy or matching code.
