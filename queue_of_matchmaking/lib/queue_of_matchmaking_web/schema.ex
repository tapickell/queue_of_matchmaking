defmodule QueueOfMatchmakingWeb.Schema do
  @moduledoc """
  GraphQL schema for the matchmaking queue application.

  Provides:
  - Mutation: `addRequest` - Add a user to the matchmaking queue
  - Subscription: `matchFound` - Receive notifications when matched with another user
  """
  use Absinthe.Schema
  import_types(QueueOfMatchmakingWeb.Schema.Types)

  alias QueueOfMatchmakingWeb.Resolvers.Queue, as: QueueResolver

  query do
    @desc "Minimal placeholder to satisfy the GraphQL spec requirement for a Query root."
    field :status, :string do
      resolve(fn _, _ -> {:ok, "ok"} end)
    end
  end

  mutation do
    field :add_request, :request_response do
      arg(:user_id, non_null(:string))
      arg(:rank, non_null(:integer))

      resolve(&QueueResolver.add_request/3)
    end
  end

  subscription do
    field :match_found, :match_payload do
      arg(:user_id, non_null(:string))

      config(fn args, _info ->
        {:ok, topic: "match_found:#{args.user_id}"}
      end)
    end
  end
end
