defmodule QueueOfMatchmaking.QueueBehaviour do
  @moduledoc """
  Behaviour for queue storage engines backing the matchmaking system.

  Queue implementations are responsible for inserting validated entries,
  removing them, and providing deterministic read access so the matching
  logic can evaluate candidates.
  """

  @type opts :: keyword()
  @type queue_state :: term()

  @type entry :: %{
          required(:user_id) => String.t(),
          required(:rank) => non_neg_integer(),
          required(:inserted_at) => integer(),
          optional(:handle) => term(),
          optional(:meta) => map()
        }

  @type handle :: term()

  @type snapshot :: %{
          required(:by_rank) => %{non_neg_integer() => [entry()]},
          required(:order) => [entry()],
          required(:size) => non_neg_integer()
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

  @callback prune((entry() -> boolean()), queue_state()) ::
              {:ok, [entry()], queue_state()}
end
