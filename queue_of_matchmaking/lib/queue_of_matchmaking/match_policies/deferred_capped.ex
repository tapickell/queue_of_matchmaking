defmodule QueueOfMatchmaking.MatchPolicies.DeferredCapped do
  @moduledoc """
  Default match policy that delays attempts until either the queue reaches a
  configured size or an individual request waits past a maximum threshold.

  Once the wait threshold is exceeded, the policy relaxes the rank delta cap
  to improve the odds of forming a match.
  """

  @behaviour QueueOfMatchmaking.MatchPolicy

  defmodule State do
    @moduledoc false

    defstruct opts: %{
                min_queue: 2,
                max_wait_ms: :infinity,
                tick_ms: 1_000,
                initial_delta: :unbounded,
                relaxed_delta: :unbounded
              },
              waiting: %{}
  end

  @impl true
  def init(opts) do
    opts =
      opts
      |> Keyword.validate!(
        min_queue: 20,
        max_wait_ms: 60_000,
        tick_ms: 1_000,
        initial_delta: :unbounded,
        relaxed_delta: :unbounded
      )
      |> Map.new()

    tick =
      case opts[:tick_ms] do
        :infinity -> :infinity
        nil -> :infinity
        value when is_integer(value) and value > 0 -> value
        _ -> 1_000
      end

    {:ok, %State{opts: opts, waiting: %{}}, tick}
  end

  @impl true
  def before_enqueue(_entry, _manager_state, policy_state) do
    {:proceed, policy_state}
  end

  @impl true
  def matchmaking_mode(entry, manager_state, %State{opts: opts, waiting: waiting} = policy_state) do
    queue_size = manager_state.queue_size
    now = manager_state.now

    cond do
      queue_size >= opts[:min_queue] ->
        {:attempt, %{relaxed?: false}, policy_state}

      exceeded_wait?(now, entry.inserted_at, opts[:max_wait_ms]) ->
        {:attempt, %{relaxed?: true}, policy_state}

      true ->
        waiting_entry = %{
          user_id: entry.user_id,
          handle: entry.handle,
          inserted_at: entry.inserted_at
        }

        {:defer, %{policy_state | waiting: Map.put(waiting, entry.handle, waiting_entry)}}
    end
  end

  @impl true
  def max_delta(
        _entry,
        _manager_state,
        _context,
        %State{opts: %{initial_delta: :unbounded}} = state
      ) do
    {:unbounded, state}
  end

  def max_delta(
        _entry,
        _manager_state,
        %{relaxed?: true},
        %State{
          opts: %{relaxed_delta: :unbounded}
        } = state
      ) do
    {:unbounded, state}
  end

  def max_delta(
        _entry,
        _manager_state,
        %{relaxed?: true},
        %State{
          opts: %{relaxed_delta: limit}
        } = state
      )
      when is_integer(limit) and limit >= 0 do
    {:bounded, limit, state}
  end

  def max_delta(_entry, _manager_state, _context, %State{opts: %{initial_delta: limit}} = state)
      when is_integer(limit) and limit >= 0 do
    {:bounded, limit, state}
  end

  @impl true
  def after_match(%{users: users}, _manager_state, %State{waiting: waiting} = state) do
    handles =
      users
      |> Enum.filter(&Map.has_key?(&1, :handle))
      |> Enum.map(& &1.handle)

    new_waiting =
      Enum.reduce(handles, waiting, fn handle, acc ->
        Map.delete(acc, handle)
      end)

    {:ok, %{state | waiting: new_waiting}}
  end

  @impl true
  def handle_timeout(manager_state, %State{opts: opts, waiting: waiting} = state) do
    tick = normalize_tick(opts[:tick_ms])
    now = manager_state.now

    {due, pending} =
      Enum.reduce(waiting, {[], %{}}, fn {handle, meta}, {due_acc, pending_acc} ->
        if exceeded_wait?(now, meta.inserted_at, opts[:max_wait_ms]) do
          {[{handle, meta} | due_acc], Map.put(pending_acc, handle, meta)}
        else
          {due_acc, Map.put(pending_acc, handle, meta)}
        end
      end)

    case due do
      [] ->
        {:ok, %{state | waiting: pending}, tick}

      due_handles ->
        instructions =
          Enum.map(due_handles, fn {handle, meta} ->
            wait_ms = waiting_duration(now, meta)
            relaxed? = opts[:relaxed_delta] != :unbounded
            {handle, %{relaxed?: relaxed?, wait_ms: wait_ms}}
          end)

        {:retry, instructions, %{state | waiting: pending}, tick}
    end
  end

  @impl true
  def terminate(_reason, _policy_state), do: :ok

  defp exceeded_wait?(_now, _inserted_at, :infinity), do: false

  defp exceeded_wait?(now, inserted_at, max_wait) when is_integer(max_wait) and max_wait >= 0 do
    now - inserted_at >= max_wait
  end

  defp exceeded_wait?(_now, _inserted_at, _), do: false

  defp waiting_duration(now, %{inserted_at: inserted_at}) do
    now - inserted_at
  end

  defp normalize_tick(:infinity), do: :infinity
  defp normalize_tick(nil), do: :infinity

  defp normalize_tick(value) when is_integer(value) and value > 0 do
    value
  end

  defp normalize_tick(_), do: 1_000
end
