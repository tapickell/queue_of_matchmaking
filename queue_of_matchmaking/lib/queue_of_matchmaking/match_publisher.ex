defmodule QueueOfMatchmaking.MatchPublisher do
  @moduledoc """
  Behaviour for publishing match events produced by the queue manager.

  The default implementation performs no action, allowing core queue logic
  to remain free of transport or delivery concerns.
  """

  @callback publish(match :: map()) :: :ok

  defmodule Noop do
    @moduledoc """
    Default publisher that ignores match events.
    """
    @behaviour QueueOfMatchmaking.MatchPublisher

    @impl true
    def publish(_match), do: :ok
  end
end
