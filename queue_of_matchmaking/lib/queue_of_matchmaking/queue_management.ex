defmodule QueueOfMatchmaking.QueueManagement do
  @moduledoc """
  Management functions for queue manager
  """

  alias QueueOfMatchmaking.{
    QueueMatches,
    QueuePolicy,
    QueueRequests,
    QueueState
  }

  @type timeout_value :: non_neg_integer() | :infinity | :hibernate
  @type schedule_policy_timeout_fun ::
          (QueueState.t(), timeout_value() -> QueueState.t())
  @type retry_handles_fun :: (QueueState.t(), [{term(), term()}] -> QueueState.t())
  @type enqueue_params :: map() | struct()
  @type enqueue_result ::
          {:ok, QueueMatches.match_reply(), QueueState.t()}
          | {:error, term(), QueueState.t()}
          | {:error, term()}

  @spec init(keyword(), schedule_policy_timeout_fun()) ::
          {:ok, QueueState.t()}
  def init(opts, schedule_policy_timeout) do
    queue_module = Keyword.get(opts, :queue_module, QueueOfMatchmaking.QueueStorage.Simple)
    queue_opts = Keyword.get(opts, :queue_opts, [])

    policy_module =
      Keyword.get(opts, :policy_module, QueueOfMatchmaking.MatchPolicies.DeferredCapped)

    policy_opts = Keyword.get(opts, :policy_opts, [])
    time_fn = Keyword.get(opts, :time_fn, &System.monotonic_time/1)
    max_history = Keyword.get(opts, :max_match_history, 100)

    publisher_module =
      Keyword.get(opts, :publisher_module, QueueOfMatchmaking.MatchPublisher.Noop)

    {:ok, queue_state} = queue_module.init(queue_opts)
    {:ok, policy_state, timeout} = policy_module.init(policy_opts)

    state = %QueueState{
      queue_module: queue_module,
      queue_state: queue_state,
      policy_module: policy_module,
      policy_state: policy_state,
      time_fn: time_fn,
      publisher_module: publisher_module,
      matches: [],
      max_match_history: max_history
    }

    {:ok, schedule_policy_timeout.(state, timeout)}
  end

  @spec enqueue(enqueue_params(), QueueState.t()) :: enqueue_result()
  def enqueue(params, state) do
    with {:ok, entry_with_handle, state} <- QueueRequests.enqueue(params, state),
         {:ok, reply, state} <- QueueMatches.find(entry_with_handle, state) do
      publish_reply(reply, state)
      {:ok, reply, state}
    end
  end

  @spec policy_retry(term(), term(), QueueState.t()) ::
          {:ok, QueueState.t()} | {:error, :not_found, QueueState.t()}
  def policy_retry(handle, context, state) do
    case QueueState.fetch(handle, state) do
      {:ok, entry, state} ->
        {reply, state} = QueueMatches.attempt(entry, context, state)
        publish_reply(reply, state)
        {:ok, state}

      other ->
        other
    end
  end

  @spec policy_tick(
          QueueState.t(),
          schedule_policy_timeout_fun(),
          retry_handles_fun()
        ) :: QueueState.t()
  def policy_tick(state, schedule_policy_timeout, retry_handles) do
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

  defp publish_reply({:ok, %{match: match}}, %QueueState{publisher_module: publisher_module}) do
    safe_publish(publisher_module, match)
  end

  defp publish_reply(_reply, _state), do: :ok

  defp safe_publish(nil, _match), do: :ok

  defp safe_publish(publisher_module, match) do
    publisher_module.publish(match)
  rescue
    _ -> :ok
  end
end
