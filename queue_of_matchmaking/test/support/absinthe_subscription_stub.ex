defmodule QueueOfMatchmaking.TestSupport.AbsintheSubscriptionStub do
  @moduledoc false

  def publish(endpoint, payload, options) do
    send(self(), {:subscription_publish, endpoint, payload, options})
    :ok
  end
end
