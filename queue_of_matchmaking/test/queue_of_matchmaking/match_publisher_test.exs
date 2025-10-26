defmodule QueueOfMatchmaking.MatchPublisherTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.MatchPublisher.Noop

  test "noop publisher always returns :ok" do
    assert :ok = Noop.publish(%{users: []})
  end
end
