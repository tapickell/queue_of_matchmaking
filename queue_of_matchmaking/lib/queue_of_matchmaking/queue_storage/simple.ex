defmodule QueueOfMatchmaking.QueueStorage.Simple do
  @moduledoc """
  Reference in-memory queue implementation backed by `:queue` and plain maps.

  Maintains FIFO order per rank as well as overall insertion order, enabling
  the matching algorithm to evaluate candidates deterministically.
  """

  @behaviour QueueOfMatchmaking.QueueBehaviour

  @impl true
  def init(_opts) do
    {:ok,
     %{
       order: :queue.new(),
       entries: %{},
       index: %{},
       by_rank: %{}
     }}
  end

  @impl true
  def insert(%{user_id: user_id} = entry, %{index: index} = state) do
    if Map.has_key?(index, user_id) do
      {:error, :duplicate, state}
    else
      handle = make_ref()

      stored_entry =
        entry
        |> Map.put(:handle, handle)

      new_state =
        state
        |> put_in([:entries, handle], stored_entry)
        |> put_in([:index, user_id], handle)
        |> update_in([:order], &:queue.in(handle, &1))
        |> update_in([:by_rank, stored_entry.rank], fn
          nil -> :queue.in(handle, :queue.new())
          queue -> :queue.in(handle, queue)
        end)

      {:ok, handle, new_state}
    end
  end

  @impl true
  def remove(handle, state) do
    case Map.pop(state.entries, handle) do
      {nil, _} ->
        {:error, :not_found, state}

      {entry, entries} ->
        state =
          state
          |> Map.put(:entries, entries)
          |> update_in([:index], &Map.delete(&1, entry.user_id))
          |> update_in([:order], &delete_handle_from_queue(&1, handle))
          |> update_in([:by_rank], &delete_handle_from_rank(&1, entry.rank, handle))

        {:ok, entry, state}
    end
  end

  @impl true
  def lookup(handle, %{entries: entries} = state) do
    case Map.fetch(entries, handle) do
      {:ok, entry} -> {:ok, entry, state}
      :error -> {:error, :not_found, state}
    end
  end

  @impl true
  def snapshot(%{entries: entries, by_rank: by_rank, order: order} = state) do
    rank_snapshot =
      by_rank
      |> Enum.into(%{}, fn {rank, queue} ->
        {rank, queue |> :queue.to_list() |> Enum.map(&Map.fetch!(entries, &1))}
      end)

    order_snapshot =
      order
      |> :queue.to_list()
      |> Enum.map(&Map.fetch!(entries, &1))

    {%{by_rank: rank_snapshot, order: order_snapshot, size: map_size(entries)}, state}
  end

  @impl true
  def head(%{order: order, entries: entries} = state) do
    case :queue.out(order) do
      {:empty, _} ->
        {:error, :empty, state}

      {{:value, handle}, _} ->
        {:ok, Map.fetch!(entries, handle), state}
    end
  end

  @impl true
  def pop_head(%{order: order} = state) do
    case :queue.out(order) do
      {:empty, _} ->
        {:error, :empty, state}

      {{:value, handle}, _} ->
        remove(handle, state)
    end
  end

  @impl true
  def size(%{entries: entries} = state) do
    {map_size(entries), state}
  end

  @impl true
  def prune(predicate, state) when is_function(predicate, 1) do
    state.entries
    |> Enum.reduce({[], state}, pruner(predicate))
    |> then(fn {pruned, new_state} -> {:ok, Enum.reverse(pruned), new_state} end)
  end

  defp pruner(predicate) do
    fn {handle, entry}, {pruned, acc_state} ->
      if predicate.(entry) do
        remover(handle, pruned, acc_state)
      else
        {pruned, acc_state}
      end
    end
  end

  defp remover(handle, pruned, acc_state) do
    case remove(handle, acc_state) do
      {:ok, removed_entry, new_state} ->
        {[removed_entry | pruned], new_state}

      {:error, :not_found, new_state} ->
        {pruned, new_state}
    end
  end

  defp delete_handle_from_queue(queue, handle) do
    queue
    |> :queue.to_list()
    |> Enum.reject(&(&1 == handle))
    |> Enum.reduce(:queue.new(), fn value, acc -> :queue.in(value, acc) end)
  end

  defp delete_handle_from_rank(by_rank, rank, handle) do
    updated_queue =
      by_rank
      |> Map.get(rank, :queue.new())
      |> delete_handle_from_queue(handle)

    if :queue.is_empty(updated_queue) do
      Map.delete(by_rank, rank)
    else
      Map.put(by_rank, rank, updated_queue)
    end
  end
end
