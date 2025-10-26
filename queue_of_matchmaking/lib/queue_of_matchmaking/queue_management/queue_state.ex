defmodule QueueOfMatchmaking.QueueState do
  @moduledoc false

  @type queue_module :: module()
  @type queue_state :: term()
  @type policy_module :: module()
  @type policy_state :: term()
  @type match_record :: map()

  defstruct queue_module: nil,
            queue_state: nil,
            policy_module: nil,
            policy_state: nil,
            policy_timer_ref: nil,
            time_fn: &System.monotonic_time/1,
            publisher_module: QueueOfMatchmaking.MatchPublisher.Noop,
            matches: [],
            max_match_history: 100

  @type t :: %__MODULE__{
          queue_module: queue_module(),
          queue_state: queue_state(),
          policy_module: policy_module(),
          policy_state: policy_state(),
          policy_timer_ref: reference() | nil,
          time_fn: (atom() -> integer()),
          publisher_module: module(),
          matches: [match_record()],
          max_match_history: non_neg_integer()
        }

  @type entry :: map()
  @type handle :: term()

  @spec insert_entry(entry(), t()) ::
          {:ok, handle(), t()}
          | {:error, :already_enqueued, t()}
          | {:error, {:queue_error, term()}, t()}
  def insert_entry(
        entry,
        %__MODULE__{queue_module: queue_module, queue_state: queue_state} = state
      ) do
    case queue_module.insert(Map.delete(entry, :manager_now), queue_state) do
      {:ok, handle, queue_state} ->
        {:ok, handle, %{state | queue_state: queue_state}}

      {:error, :duplicate, queue_state} ->
        {:error, :already_enqueued, %{state | queue_state: queue_state}}

      {:error, reason, queue_state} ->
        {:error, {:queue_error, reason}, %{state | queue_state: queue_state}}
    end
  end

  @spec fetch(handle(), t()) ::
          {:ok, entry(), t()}
          | {:error, :not_found, t()}
  def fetch(handle, %__MODULE__{queue_module: queue_module, queue_state: queue_state} = state) do
    case queue_module.lookup(handle, queue_state) do
      {:ok, entry, queue_state} ->
        {:ok, Map.put(entry, :handle, handle), %{state | queue_state: queue_state}}

      {:error, :not_found, queue_state} ->
        {:error, :not_found, %{state | queue_state: queue_state}}
    end
  end

  @spec remove_entry(handle(), t()) ::
          {:ok, entry(), t()}
          | {:error, :not_found, t()}
  def remove_entry(
        handle,
        %__MODULE__{queue_module: queue_module, queue_state: queue_state} = state
      ) do
    case queue_module.remove(handle, queue_state) do
      {:ok, entry, queue_state} ->
        {:ok, entry, %{state | queue_state: queue_state}}

      {:error, :not_found, queue_state} ->
        {:error, :not_found, %{state | queue_state: queue_state}}
    end
  end
end
