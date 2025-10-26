defmodule QueueOfMatchmakingWeb.Resolvers.QueueTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmakingWeb.Schema

  defmodule QueueManagerStub do
    @moduledoc false

    def enqueue(params) do
      send(self(), {:enqueue_called, params})
      {:ok, :queued}
    end

    def recent_matches(_limit), do: []
  end

  defmodule ErrorQueueManagerStub do
    @moduledoc false

    def enqueue(_params), do: {:error, :already_enqueued}

    def recent_matches(_limit), do: []
  end

  defmodule QueueManagerMatchesStub do
    @moduledoc false

    def enqueue(_params), do: {:ok, :queued}

    def recent_matches(limit) do
      matches = [
        %{
          users: [
            %{user_id: "alice", user_rank: 1200},
            %{user_id: "bob", user_rank: 1190}
          ],
          delta: 10,
          matched_at: 1_700_000_000
        }
      ]

      Enum.take(matches, limit)
    end
  end

  setup do
    original = Application.get_env(:queue_of_matchmaking, :queue_manager)

    on_exit(fn ->
      if original do
        Application.put_env(:queue_of_matchmaking, :queue_manager, original)
      else
        Application.delete_env(:queue_of_matchmaking, :queue_manager)
      end
    end)

    :ok
  end

  test "addRequest mutation enqueues user via queue manager" do
    Application.put_env(:queue_of_matchmaking, :queue_manager, QueueManagerStub)

    mutation = """
    mutation($userId: String!, $rank: Int!) {
      addRequest(userId: $userId, rank: $rank) {
        ok
        error
      }
    }
    """

    variables = %{"userId" => "alice", "rank" => 1200}

    assert {:ok, %{data: %{"addRequest" => %{"ok" => true, "error" => nil}}}} =
             Absinthe.run(mutation, Schema, variables: variables)

    assert_receive {:enqueue_called, %{user_id: "alice", rank: 1200}}
  end

  test "addRequest surfaces queue errors" do
    Application.put_env(:queue_of_matchmaking, :queue_manager, ErrorQueueManagerStub)

    mutation = """
    mutation {
      addRequest(userId: "bob", rank: 1500) {
        ok
        error
      }
    }
    """

    assert {:ok,
            %{
              data: %{
                "addRequest" => %{
                  "ok" => false,
                  "error" => "already_enqueued"
                }
              }
            }} = Absinthe.run(mutation, Schema)
  end

  test "recentMatches query returns recent match payloads" do
    Application.put_env(:queue_of_matchmaking, :queue_manager, QueueManagerMatchesStub)

    query = """
    query($limit: Int) {
      recentMatches(limit: $limit) {
        users { userId userRank }
        delta
      }
    }
    """

    assert {:ok,
            %{
              data: %{
                "recentMatches" => [
                  %{
                    "users" => [
                      %{"userId" => "alice", "userRank" => 1200},
                      %{"userId" => "bob", "userRank" => 1190}
                    ],
                    "delta" => 10
                  }
                ]
              }
            }} =
             Absinthe.run(query, Schema, variables: %{"limit" => 1})
  end
end
