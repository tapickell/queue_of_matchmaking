defmodule QueueOfMatchmaking.QueueMangement do
  @moduledoc """
  Management functions for queue manager
  """

  alias QueueOfMatchmaking.{
    QueueMatches,
    QueueRequests,
    QueueState
  }

  def init(opts, schedule_policy_timeout) do
    queue_module = Keyword.get(opts, :queue_module, QueueOfMatchmaking.QueueStorage.Simple)
    queue_opts = Keyword.get(opts, :queue_opts, [])

    policy_module =
      Keyword.get(opts, :policy_module, QueueOfMatchmaking.MatchPolicies.DeferredCapped)

    policy_opts = Keyword.get(opts, :policy_opts, [])
    time_fn = Keyword.get(opts, :time_fn, &System.monotonic_time/1)
    max_history = Keyword.get(opts, :max_match_history, 100)

    {:ok, queue_state} = queue_module.init(queue_opts)
    {:ok, policy_state, timeout} = policy_module.init(policy_opts)

    state = %QueueState{
      queue_module: queue_module,
      queue_state: queue_state,
      policy_module: policy_module,
      policy_state: policy_state,
      time_fn: time_fn,
      matches: [],
      max_match_history: max_history
    }

    {:ok, schedule_policy_timeout.(state, timeout)}
  end

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
