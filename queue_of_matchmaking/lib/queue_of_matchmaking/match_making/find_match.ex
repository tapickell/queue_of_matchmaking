defmodule QueueOfMatchmaking.MatchMaking do
  @moduledoc """
  Entry point for match making functionality
  """

  @spec find_match([Request]) :: {:ok, [Request]} | {:error, :no_matches}
  def find_match(queue) when length(queue) < 2 do
    {:error, :no_matches}
  end

  def find_match(queue) when length(queue) == 2 do
    {:ok, queue}
  end

  def find_match(_queue) do
    # TODO - implement matching logic passing the queue with probable matches
    {:error, :no_matches}
  end
end
