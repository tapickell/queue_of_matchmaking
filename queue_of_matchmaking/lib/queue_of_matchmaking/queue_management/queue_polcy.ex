defmodule QueueOfMatchmaking.QueuePolicy do
  @moduledoc """
  wrapper for policy module calls with context building
  """
  alias QueueOfMatchmaking.QueueState

  def before_enqueue(entry, %QueueState{} = state) do
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

  defp queue_size(%QueueState{queue_module: queue_module, queue_state: queue_state} = state) do
    {size, queue_state} = queue_module.size(queue_state)
    {size, %{state | queue_state: queue_state}}
  end
end
