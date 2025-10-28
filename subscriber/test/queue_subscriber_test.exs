defmodule QueueSubscriberTest do
  use ExUnit.Case
  doctest QueueSubscriber

  test "greets the world" do
    assert QueueSubscriber.hello() == :world
  end
end
