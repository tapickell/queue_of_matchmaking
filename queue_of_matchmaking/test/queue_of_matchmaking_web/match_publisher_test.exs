defmodule QueueOfMatchmakingWeb.MatchPublisherTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.TestSupport.AbsintheSubscriptionStub
  alias QueueOfMatchmakingWeb.MatchPublisher

  defmodule RaisingSubscriptionStub do
    def publish(_endpoint, _payload, _options), do: raise("boom")
  end

  setup do
    original = Application.get_env(:queue_of_matchmaking, :subscription_module)
    Application.put_env(:queue_of_matchmaking, :subscription_module, AbsintheSubscriptionStub)

    on_exit(fn ->
      if original do
        Application.put_env(:queue_of_matchmaking, :subscription_module, original)
      else
        Application.delete_env(:queue_of_matchmaking, :subscription_module)
      end
    end)

    :ok
  end

  test "formats payload and topics before publishing" do
    match = %{
      users: [
        %{user_id: "alice", rank: 1200},
        %{user_id: "bob", rank: 1250}
      ]
    }

    assert :ok = MatchPublisher.publish(match)

    assert_receive {:subscription_publish, endpoint, payload, options}
    assert endpoint == QueueOfMatchmakingWeb.Endpoint

    assert payload == %{
             users: [
               %{userId: "alice", userRank: 1200},
               %{userId: "bob", userRank: 1250}
             ]
           }

    assert Keyword.fetch!(options, :match_found) |> Enum.sort() == [
             "match_found:alice",
             "match_found:bob"
           ]
  end

  test "returns :ok even if the subscription module raises" do
    Application.put_env(:queue_of_matchmaking, :subscription_module, RaisingSubscriptionStub)

    match = %{users: [%{user_id: "alice", rank: 1200}]}
    assert :ok = MatchPublisher.publish(match)

    Application.put_env(:queue_of_matchmaking, :subscription_module, AbsintheSubscriptionStub)
  end
end
