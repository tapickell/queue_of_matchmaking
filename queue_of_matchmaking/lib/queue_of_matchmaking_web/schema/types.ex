defmodule QueueOfMatchmakingWeb.Schema.Types do
  @moduledoc """
  Defines GraphQL types for the matchmaking queue API.

  Types include:
  - `RequestResponse`: Success/error response for mutations
  - `User`: User information with ID and rank
  - `MatchPayload`: Contains matched users for subscription notifications
  """
  use Absinthe.Schema.Notation

  object :request_response do
    field(:ok, non_null(:boolean))
    field(:error, :string)
  end

  object :user do
    field(:user_id, non_null(:string))

    field :user_rank, non_null(:integer) do
      resolve(fn user, _, _ ->
        {:ok, Map.fetch!(user, :rank)}
      end)
    end
  end

  object :match_payload do
    field(:users, non_null(list_of(non_null(:user))))
    field(:delta, non_null(:integer))
  end
end
