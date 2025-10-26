defmodule QueueOfMatchmaking.QueueState do
  @moduledoc false

  defstruct queue_module: nil,
            queue_state: nil,
            policy_module: nil,
            policy_state: nil,
            policy_timer_ref: nil,
            time_fn: &System.monotonic_time/1,
            matches: [],
            max_match_history: 100

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

  def fetch(handle, %__MODULE__{queue_module: queue_module, queue_state: queue_state} = state) do
    case queue_module.lookup(handle, queue_state) do
      {:ok, entry, queue_state} ->
        {:ok, Map.put(entry, :handle, handle), %{state | queue_state: queue_state}}

      {:error, :not_found, queue_state} ->
        {:error, :not_found, %{state | queue_state: queue_state}}
    end
  end

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
