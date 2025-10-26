defmodule QueueOfMatchmaking.QueueMatches do
  @moduledoc """
  Funcitons specific to matching that use the QueuePolicy
  """

  alias QueueOfMatchmaking.{
    QueuePolicy,
    QueueState
  }

  def find(entry_with_handle, state) do
    with {:ok, decision, state} <- decide_match(entry_with_handle, state),
         {:reply, reply, state} <- process_match_decision(entry_with_handle, decision, state) do
      {:ok, reply, state}
    end
  end

  def attempt(entry, context, state) do
    case QueuePolicy.max_delta(entry, context, state) do
      {:unbounded, policy_state} ->
        state = %{state | policy_state: policy_state}
        do_attempt_match(entry, :unbounded, context, state)

      {:bounded, limit, policy_state} ->
        state = %{state | policy_state: policy_state}
        do_attempt_match(entry, {:bounded, limit}, context, state)
    end
  end

  defp decide_match(entry, %QueueState{} = state) do
    case QueuePolicy.matchmaking_mode(entry, state, entry.inserted_at) do
      {:attempt, context, policy_state} ->
        {:ok, {:attempt, context}, %{state | policy_state: policy_state}}

      {:defer, policy_state} ->
        {:ok, :defer, %{state | policy_state: policy_state}}

      {:cancel, policy_state} ->
        {:ok, :cancel, %{state | policy_state: policy_state}}
    end
  end

  defp process_match_decision(entry, {:attempt, context}, state) do
    {reply, state} = attempt(entry, context, state)
    {:reply, reply, state}
  end

  defp process_match_decision(_entry, :defer, state) do
    {:reply, {:ok, :queued}, state}
  end

  defp process_match_decision(entry, :cancel, state) do
    {:ok, _entry, state} = QueueState.remove_entry(entry.handle, state)
    {:reply, {:error, {:policy_rejected, :cancelled}}, state}
  end

  defp do_attempt_match(entry, delta_mode, context, state) do
    {snapshot, state} = snapshot(state)
    rank = entry.rank

    candidates_by_rank =
      snapshot.by_rank
      |> Map.update(rank, [], fn entries ->
        Enum.reject(entries, &(&1.handle == entry.handle))
      end)

    limit = calculate_limit(delta_mode, rank, candidates_by_rank)

    candidate =
      0..limit
      |> Enum.reduce_while(nil, fn delta, acc ->
        with nil <- acc,
             candidate <- pick_candidate(rank, delta, candidates_by_rank) do
          if candidate, do: {:halt, candidate}, else: {:cont, nil}
        else
          candidate -> {:halt, candidate}
        end
      end)

    case candidate do
      nil ->
        {{:ok, :queued}, state}

      candidate_entry ->
        finalize_match(entry, candidate_entry, context, state)
    end
  end

  defp snapshot(%QueueState{queue_module: queue_module, queue_state: queue_state} = state) do
    {snapshot, queue_state} = queue_module.snapshot(queue_state)
    {snapshot, %{state | queue_state: queue_state}}
  end

  defp calculate_limit(:unbounded, rank, by_rank) do
    ranks = Map.keys(by_rank)

    ranks
    |> Enum.map(&abs(&1 - rank))
    |> Enum.max(fn -> 0 end)
  end

  defp calculate_limit({:bounded, limit}, _rank, _by_rank), do: limit

  defp pick_candidate(rank, 0, by_rank) do
    by_rank
    |> Map.get(rank, [])
    |> List.first()
  end

  defp pick_candidate(rank, delta, by_rank) when delta > 0 do
    lower = Map.get(by_rank, rank - delta, [])
    upper = Map.get(by_rank, rank + delta, [])

    (lower ++ upper)
    |> Enum.min_by(
      fn candidate -> {candidate.inserted_at, candidate.user_id} end,
      fn -> nil end
    )
  end

  defp finalize_match(entry, candidate_entry, context, state) do
    {:ok, candidate_entry, state} = QueueState.remove_entry(candidate_entry.handle, state)
    {:ok, entry, state} = QueueState.remove_entry(entry.handle, state)

    now = state.time_fn.(:millisecond)

    match = %{
      users: sanitize_entries([entry, candidate_entry]),
      delta: abs(entry.rank - candidate_entry.rank),
      matched_at: now,
      context: context
    }

    {:ok, policy_state} = QueuePolicy.after_match(match, state)

    state =
      state
      |> Map.put(:policy_state, policy_state)
      |> store_match(match)

    {{:ok, %{match: match}}, state}
  end

  defp sanitize_entries(entries) do
    Enum.map(entries, fn entry ->
      entry
      |> Map.take([:user_id, :rank, :inserted_at, :handle])
    end)
  end

  defp store_match(%QueueState{matches: matches, max_match_history: max} = state, match) do
    updated =
      [match | matches]
      |> Enum.take(max)

    %{state | matches: updated}
  end
end
