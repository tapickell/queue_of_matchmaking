defmodule QueueOfMatchmaking.QueueRequests do
  @moduledoc """
  Functions for the QueueManager to use.
  Keeps the Genserver skinny.
  """

  def enqueue(request, state) do
    with {:ok, entry} <- build_entry(request, state),
         {:ok, state} <- QueuePolicy.before_enqueue(entry, state),
         {:ok, handle, state} <- insert_entry(entry, state) do
      fetch_entry(handle, state)
    end
  end

  def fetch(handle, %State{queue_module: queue_module, queue_state: queue_state} = state) do
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
    normalize_request(%{user_id: user_id, rank: rank})
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

  defp build_entry(%{user_id: user_id, rank: rank}, %State{time_fn: time_fn} = state) do
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

  defp remove_entry(handle, %State{queue_module: queue_module, queue_state: queue_state} = state) do
    case queue_module.remove(handle, queue_state) do
      {:ok, entry, queue_state} ->
        {:ok, entry, %{state | queue_state: queue_state}}

      {:error, :not_found, queue_state} ->
        {:error, :not_found, %{state | queue_state: queue_state}}
    end
  end

  defp insert_entry(entry, %State{queue_module: queue_module, queue_state: queue_state} = state) do
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

defmodule QueueOfMatchmaking.QueuePolicy do
  @moduledoc """
  wrapper for policy module calls with context building
  """
  def before_enqueue(entry, %State{} = state) do
    {manager_ctx, state} = build_context(state, size_adjustment: 0)

    case state.policy_module.before_enqueue(entry, manager_ctx, state.policy_state) do
      {:proceed, policy_state} ->
        {:ok, Map.put(state, :policy_state, policy_state)}

      {:reject, :duplicate, policy_state} ->
        {:error, :already_enqueued, Map.put(state, :policy_state, policy_state)}

      {:reject, reason, policy_state} ->
        {:error, {:policy_rejected, reason}, Map.put(state, :policy_state, policy_state)}
    end
  end

  def handle_timeout(state) do
    {manager_ctx, state} = build_context(state, size_adjustment: 0)
    state.policy_module.handle_timeout(manager_ctx, state.policy_state)
  end

  def max_delta(%{policy_state: policy_state} = state) do
    {manager_ctx, state} = build_context(state)
    state.policy_module.max_delta(entry, manager_ctx, context, policy_state)
  end

  def matchmaking_mode(%{policy_state: policy_state} = state, override) do
    {manager_ctx, state} = build_context(state, size_adjustment: 0, override_now: override)

    state.policy_module.matchmaking_mode(entry, manager_ctx, policy_state)
  end

  def after_match(state) do
    {match_ctx, state} = build_context(state)
    state.policy_module.after_match(match, match_ctx, state.policy_state)
  end

  defp build_context(state, opts \\ []) do
    size_adjustment = Keyword.get(opts, :size_adjustment, 0)
    now_override = Keyword.get(opts, :override_now, nil)

    {size, state} = queue_size(state)
    now = now_override || state.time_fn.(:millisecond)

    context = %{
      queue_size: max(size + size_adjustment, 0),
      now: now
    }

    {context, state}
  end

  defp queue_size(%State{queue_module: queue_module, queue_state: queue_state} = state) do
    {size, queue_state} = queue_module.size(queue_state)
    {size, %{state | queue_state: queue_state}}
  end
end

defmodule QueueOfMatchmaking.QueueMatches do
  def find(entry_with_handle, state) do
    with {:ok, decision, state} <- decide_match(entry_with_handle, state),
         {:reply, reply, state} <- process_match_decision(entry_with_handle, decision, state) do
      {:ok, reply, state}
    end
  end

  # TODO abstract this call to a publisher module
  def publish({:ok, %{match: match}}, state) do
    endpoint_module = QueueOfMatchmakingWeb.Endpoint

    Absinthe.Subscription.publish(
      endpoint_module,
      %{
        users:
          Enum.map(match.users, fn user ->
            %{
              userId: user.user_id,
              userRank: user.rank
            }
          end)
      },
      match_found: Enum.map(match.users, fn user -> "user:#{user.user_id}" end)
    )

    :ok
  rescue
    _ -> :ok
  end

  def publish(_other, _state), do: :ok

  def attempt(entry, context, state) do
    case QueuePolicy.max_delta(entry, context, state) do
      {:unbounded, policy_state} ->
        state = %{state | policy_state: policy_state}
        do_attempt_match(entry, :unbounded, context, state, manager_ctx)

      {:bounded, limit, policy_state} ->
        state = %{state | policy_state: policy_state}
        do_attempt_match(entry, {:bounded, limit}, context, state, manager_ctx)
    end
  end

  defp decide_match(entry, %State{} = state) do
    case QueuePolicy.matchmaking_mode(state, entry.inserted_at) do
      {:attempt, context, policy_state} ->
        {:ok, {:attempt, context}, %{state | policy_state: policy_state}}

      {:defer, policy_state} ->
        {:ok, :defer, %{state | policy_state: policy_state}}

      {:cancel, policy_state} ->
        {:ok, :cancel, %{state | policy_state: policy_state}}
    end
  end

  defp process_match_decision(entry, {:attempt, context}, state) do
    {reply, state} = attempt_match(entry, context, state)
    publish_match(reply, state)
    {:reply, reply, state}
  end

  defp process_match_decision(_entry, :defer, state) do
    {:reply, {:ok, :queued}, state}
  end

  defp process_match_decision(entry, :cancel, state) do
    {:ok, _entry, state} = remove_entry(entry.handle, state)
    {:reply, {:error, {:policy_rejected, :cancelled}}, state}
  end

  defp do_attempt_match(entry, delta_mode, context, state, manager_ctx) do
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
        finalize_match(entry, candidate_entry, context, state, manager_ctx)
    end
  end

  defp snapshot(%State{queue_module: queue_module, queue_state: queue_state} = state) do
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

  defp finalize_match(entry, candidate_entry, context, state, manager_ctx) do
    {:ok, candidate_entry, state} = remove_entry(candidate_entry.handle, state)
    {:ok, entry, state} = remove_entry(entry.handle, state)

    now = state.time_fn.(:millisecond)

    match = %{
      users: sanitize_entries([entry, candidate_entry]),
      delta: abs(entry.rank - candidate_entry.rank),
      matched_at: now,
      context: context
    }

    {:ok, policy_state} = QueuePolicy.after_match(state)

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

  defp store_match(%State{matches: matches, max_match_history: max} = state, match) do
    updated =
      [match | matches]
      |> Enum.take(max)

    %{state | matches: updated}
  end
end

defmodule QueueOfMatchmaking.QueueMangement do
  def enqueue(params, state) do
    with {:ok, request} <- QueueRequests.normalize(params),
         {:ok, entry_with_handle, state} <- QueueRequests.enqueue(request, state),
         {:ok, reply, state} <- QueueMatches.find(entry_with_handle, state) do
      {:ok, reply, state}
    end
  end

  def policy_retry(handle, context, state) do
    case QueueRequests.fetch(handle, state) do
      {:ok, entry, state} ->
        {reply, state} = QueueMatches.attempt(entry, context, state)
        QueueMatches.publish(reply, state)
        {:ok, state}

      other ->
        other
    end
  end

  def policy_tick(state, schedule_timeout, return_handles) do
    case QueuePolicy.handle_timeout(state) do
      {:ok, policy_state, timeout} ->
        state
        |> Map.put(:policy_state, policy_state)
        |> schedule_policy_timeout.(timeout)

      {:retry, instructions, policy_state, timeout} ->
          state
          |> Map.put(:policy_state, policy_state)
          |> schedule_policy_timeout.(timeout)
          |> retry_handles.(instructions)

    end
    end
end
