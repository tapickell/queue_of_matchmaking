defmodule QueueOfMatchmaking.TestSupport.QueueTestHelpers do
  @moduledoc false

  alias QueueOfMatchmaking.{
    MatchPublisher,
    QueueState
  }

  alias QueueOfMatchmaking.QueueStorage.Simple

  defmodule PolicyStub do
    @moduledoc false
    @behaviour QueueOfMatchmaking.MatchPolicy

    @impl true
    def init(_opts), do: {:ok, %{}, :infinity}

    @impl true
    def before_enqueue(_entry, _manager_ctx, state), do: {:proceed, state}

    @impl true
    def matchmaking_mode(_entry, _manager_ctx, %{decision: {:attempt, context}} = state) do
      {:attempt, context, state}
    end

    def matchmaking_mode(_entry, _manager_ctx, %{decision: :attempt} = state) do
      {:attempt, %{}, state}
    end

    def matchmaking_mode(_entry, _manager_ctx, %{decision: :defer} = state) do
      {:defer, state}
    end

    def matchmaking_mode(_entry, _manager_ctx, %{decision: :cancel} = state) do
      {:cancel, state}
    end

    @impl true
    def max_delta(_entry, _manager_ctx, _context, %{max_delta: {:bounded, limit}} = state) do
      {:bounded, limit, state}
    end

    def max_delta(_entry, _manager_ctx, _context, %{max_delta: :unbounded} = state) do
      {:unbounded, state}
    end

    def max_delta(_entry, _manager_ctx, _context, state) do
      {:bounded, 0, state}
    end

    @impl true
    def after_match(_match, _manager_ctx, state), do: {:ok, state}

    @impl true
    def handle_timeout(_manager_ctx, state), do: {:ok, state, :infinity}

    @impl true
    def terminate(_reason, _state), do: :ok
  end

  defmodule PublisherStub do
    @moduledoc false
    @behaviour MatchPublisher

    @impl true
    def publish(match) do
      target = Process.get({__MODULE__, :pid}, self())
      send(target, {:published, match})
      :ok
    end
  end

  defmodule RaisingPublisherStub do
    @moduledoc false
    @behaviour MatchPublisher

    @impl true
    def publish(_match) do
      raise "publisher failure"
    end
  end

  @default_decision {:attempt, %{}}

  def build_state(opts \\ []) do
    queue_module = Keyword.get(opts, :queue_module, Simple)
    {:ok, queue_state} = queue_module.init([])

    policy_state =
      opts
      |> Keyword.get(:policy_state, %{
        decision: Keyword.get(opts, :decision, @default_decision),
        max_delta: Keyword.get(opts, :max_delta, {:bounded, 0})
      })

    publisher_module = Keyword.get(opts, :publisher_module, MatchPublisher.Noop)

    start_time = Keyword.get(opts, :time_start, 0)
    Process.put(counter_key(), start_time)

    time_fn = Keyword.get(opts, :time_fn, default_time_fn())

    %QueueState{
      queue_module: queue_module,
      queue_state: queue_state,
      policy_module: Keyword.get(opts, :policy_module, PolicyStub),
      policy_state: policy_state,
      time_fn: time_fn,
      publisher_module: publisher_module,
      matches: Keyword.get(opts, :matches, []),
      max_match_history: Keyword.get(opts, :max_match_history, 5)
    }
  end

  def insert_entry(state, attrs) do
    entry =
      attrs
      |> Map.put_new(:user_id, "user_#{System.unique_integer([:positive])}")
      |> Map.put_new(:rank, 1000)
      |> ensure_inserted_at()
      |> then(fn entry_with_time ->
        entry_with_time
        |> Map.put(:manager_now, entry_with_time.inserted_at)
        |> Map.put_new(:meta, %{})
      end)

    {:ok, handle, state} = QueueState.insert_entry(entry, state)
    {:ok, entry_with_handle, state} = QueueState.fetch(handle, state)
    {entry_with_handle, state}
  end

  def reset_publisher_stub(pid \\ self()) do
    Process.put({PublisherStub, :pid}, pid)
  end

  def next_time do
    counter = Process.get(counter_key(), 0) + 1
    Process.put(counter_key(), counter)
    counter
  end

  defp ensure_inserted_at(%{inserted_at: _} = entry), do: entry

  defp ensure_inserted_at(entry) do
    Map.put(entry, :inserted_at, next_time())
  end

  defp default_time_fn do
    fn
      :millisecond -> next_time()
    end
  end

  defp counter_key, do: {__MODULE__, :time_counter}
end
