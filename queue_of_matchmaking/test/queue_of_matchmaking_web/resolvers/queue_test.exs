defmodule QueueOfMatchmakingWeb.Resolvers.QueueTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmakingWeb.Schema

  defmodule QueueManagerStub do
    @moduledoc false

    def enqueue(params) do
      send(self(), {:enqueue_called, params})
      {:ok, :queued}
    end
  end

  defmodule ErrorQueueManagerStub do
    @moduledoc false

    def enqueue(_params), do: {:error, :already_enqueued}
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
end
