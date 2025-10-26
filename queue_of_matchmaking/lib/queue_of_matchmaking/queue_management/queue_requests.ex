defmodule QueueOfMatchmaking.QueueRequests do
  @moduledoc """
  Functions for the Queue Requests
  """

  alias QueueOfMatchmaking.{
    QueuePolicy,
    QueueState
  }

  def enqueue(request, state) do
    with {:ok, entry} <- build_entry(request, state),
         {:ok, state} <- QueuePolicy.before_enqueue(entry, state),
         {:ok, handle, state} <- insert_entry(entry, state) do
      fetch(handle, state)
    end
  end

  def fetch(handle, %QueueState{queue_module: queue_module, queue_state: queue_state} = state) do
    case queue_module.lookup(handle, queue_state) do
      {:ok, entry, queue_state} ->
        {:ok, Map.put(entry, :handle, handle), %{state | queue_state: queue_state}}

      {:error, :not_found, queue_state} ->
        {:error, :not_found, %{state | queue_state: queue_state}}
    end
  end

  def normalize(%{user_id: user_id, rank: rank}) do
    with {:ok, user_id} <- normalize_user_id(user_id),
         {:ok, rank} <- normalize_rank(rank) do
      {:ok, %{user_id: user_id, rank: rank}}
    end
  end

  def normalize(%{"userId" => user_id, "rank" => rank}) do
    normalize(%{user_id: user_id, rank: rank})
  end

  def normalize(_), do: {:error, :invalid_params}

  defp normalize_user_id(user_id) when is_binary(user_id) do
    trimmed = String.trim(user_id)

    cond do
      trimmed == "" -> {:error, :invalid_user_id}
      String.length(trimmed) > 255 -> {:error, :invalid_user_id}
      true -> {:ok, trimmed}
    end
  end

  defp normalize_user_id(_), do: {:error, :invalid_user_id}

  defp normalize_rank(rank) when is_integer(rank) and rank >= 0, do: {:ok, rank}
  defp normalize_rank(_), do: {:error, :invalid_rank}

  defp build_entry(%{user_id: user_id, rank: rank}, %QueueState{time_fn: time_fn}) do
    now = time_fn.(:millisecond)

    {:ok,
     %{
       user_id: user_id,
       rank: rank,
       inserted_at: now,
       meta: %{source: :enqueue},
       manager_now: now
     }}
  end

  def remove_entry(
         handle,
         %QueueState{queue_module: queue_module, queue_state: queue_state} = state
       ) do
    case queue_module.remove(handle, queue_state) do
      {:ok, entry, queue_state} ->
        {:ok, entry, %{state | queue_state: queue_state}}

      {:error, :not_found, queue_state} ->
        {:error, :not_found, %{state | queue_state: queue_state}}
    end
  end

  def insert_entry(
         entry,
         %QueueState{queue_module: queue_module, queue_state: queue_state} = state
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
end
