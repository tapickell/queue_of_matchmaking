defmodule QueueOfMatchmaking.MatchMaking do
  @moduledoc """
  Lightweight façade that drives the core matching engine with simple lists.

  This enables legacy tests and tooling to exercise the deterministic matching
  algorithm without spinning up the full queue manager GenServer stack.
  """

  alias QueueOfMatchmaking.{
    MatchPolicy,
    QueueMatches,
    QueueState
  }

  @spec find_match(list()) :: {:ok, [map()]} | {:error, :no_matches}
  def find_match(queue) when length(queue) < 2, do: {:error, :no_matches}

  def find_match(queue) when is_list(queue) do
    {entry_with_handle, state} = seed_state(queue)

    {:ok, reply, _state} = QueueMatches.find(entry_with_handle, state)

    case reply do
      {:ok, %{match: %{users: users}}} ->
        {:ok, users}

      {:ok, :queued} ->
        {:error, :no_matches}

      {:error, _reason} ->
        {:error, :no_matches}
    end
  end

  defp seed_state(queue) do
    {queue_module, queue_state} = init_queue_module()

    state =
      %QueueState{
        queue_module: queue_module,
        queue_state: queue_state,
        policy_module: __MODULE__.NaivePolicy,
        policy_state: %{},
        matches: [],
        max_match_history: max(length(queue), 5)
      }
      |> attach_time_fn()

    Enum.reduce(queue, {nil, state}, fn request, {_last_entry, acc_state} ->
      entry = normalize_request(request)

      {:ok, handle, acc_state} = QueueState.insert_entry(entry, acc_state)
      {:ok, entry_with_handle, acc_state} = QueueState.fetch(handle, acc_state)

      {entry_with_handle, acc_state}
    end)
  end

  defp normalize_request(%{user_id: user_id, rank: rank} = request) do
    inserted_at =
      request
      |> Map.get(:inserted_at)
      |> case do
        nil -> Map.get(request, :added_to_queue)
        value -> value
      end
      |> timestamp_from()

    %{
      user_id: user_id,
      rank: rank,
      inserted_at: inserted_at,
      manager_now: inserted_at,
      meta: Map.get(request, :meta, %{})
    }
  end

  defp timestamp_from(%DateTime{} = datetime), do: DateTime.to_unix(datetime, :millisecond)

  defp timestamp_from(%NaiveDateTime{} = ndt) do
    ndt
    |> DateTime.from_naive!("Etc/UTC")
    |> DateTime.to_unix(:millisecond)
  end

  defp timestamp_from(int) when is_integer(int), do: int
  defp timestamp_from(nil), do: System.system_time(:millisecond)

  defp timestamp_from(datetime_string) when is_binary(datetime_string) do
    case DateTime.from_iso8601(datetime_string) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> System.system_time(:millisecond)
    end
  end

  defp timestamp_from({:ok, %DateTime{} = dt}), do: DateTime.to_unix(dt, :millisecond)
  defp timestamp_from({:ok, %NaiveDateTime{} = ndt}), do: timestamp_from(ndt)
  defp timestamp_from(_other), do: System.system_time(:millisecond)

  defp init_queue_module do
    queue_module = QueueOfMatchmaking.QueueStorage.Simple
    {:ok, queue_state} = queue_module.init([])
    {queue_module, queue_state}
  end

  defp attach_time_fn(state) do
    start_time =
      state.queue_state
      |> Map.get(:entries, %{})
      |> Map.values()
      |> Enum.map(& &1.inserted_at)
      |> Enum.max(fn -> System.system_time(:millisecond) end)

    counter = :erlang.unique_integer([:positive])

    time_fn =
      fn
        :millisecond -> start_time + System.unique_integer([:positive]) + counter
        unit -> System.monotonic_time(unit)
      end

    %{state | time_fn: time_fn}
  end

  defmodule NaivePolicy do
    @moduledoc false
    @behaviour MatchPolicy

    @impl true
    def init(_opts), do: {:ok, %{}, :infinity}

    @impl true
    def before_enqueue(_entry, _context, state), do: {:proceed, state}

    @impl true
    def matchmaking_mode(_entry, _context, state), do: {:attempt, %{}, state}

    @impl true
    def max_delta(_entry, _context, _retry_context, state), do: {:unbounded, state}

    @impl true
    def after_match(_match, _context, state), do: {:ok, state}

    @impl true
    def handle_timeout(_context, state), do: {:ok, state, :infinity}

    @impl true
    def terminate(_reason, _state), do: :ok
  end
end
