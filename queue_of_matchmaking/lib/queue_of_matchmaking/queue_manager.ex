defmodule QueueOfMatchmaking.QueueManager do
  @moduledoc """
  GenServer responsible for managing the matchmaking queue, delegating storage
  and policy decisions to pluggable modules.
  """

  use GenServer

  alias QueueOfMatchmaking.QueueManagement

  @type enqueue_error ::
          :invalid_user_id
          | :invalid_rank
          | :already_enqueued
          | {:policy_rejected, term()}

  ## Public API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec enqueue(term(), GenServer.server()) ::
          {:ok, :queued}
          | {:ok, %{match: map()}}
          | {:error, enqueue_error()}
  def enqueue(request, server \\ __MODULE__) do
    GenServer.call(server, {:enqueue, request})
  end

  @spec recent_matches(non_neg_integer(), GenServer.server()) :: [map()]
  def recent_matches(limit \\ 10, server \\ __MODULE__) do
    GenServer.call(server, {:recent_matches, limit})
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    QueueMamangement.init(opts, &schedule_policy_timeout/2)
  end

  @impl true
  def handle_call({:enqueue, params}, _from, state) do
    case QueueMangement.enqueue(params, state) do
      {:ok, reply, state} ->
        {:reply, reply, state}

      {:error, reason, state} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:recent_matches, limit}, _from, state) do
    reply =
      state.matches
      |> Enum.take(limit)
      |> Enum.reverse()

    {:reply, reply, state}
  end

  @impl true
  def handle_info(:policy_tick, state) do
    state = QueueManagement.policy_tick(state, &schedule_policy_timeout/2, &retry_handles/2)
    {:noreply, state}
  end

  def handle_info({:policy_retry, handle, context}, state) do
    case QueueMangement.policy_retry(handle, context, state) do
      {:ok, state} -> {:noreply, state}

      {:error, :not_found, state} ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(reason, state) do
    cancel_timer(state.policy_timer_ref)
    state.policy_module.terminate(reason, state.policy_state)
  end

  ## Internal helpers

  defp schedule_policy_timeout(state, :infinity), do: %{state | policy_timer_ref: nil}

  defp schedule_policy_timeout(state, timeout) when is_integer(timeout) and timeout > 0 do
    cancel_timer(state.policy_timer_ref)
    ref = Process.send_after(self(), :policy_tick, timeout)
    %{state | policy_timer_ref: ref}
  end

  defp retry_handles(state, instructions) do
    Enum.each(instructions, fn {handle, context} ->
      send(self(), {:policy_retry, handle, context})
    end)

    state
  end

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) do
    Process.cancel_timer(ref)
    :ok
  end
end
