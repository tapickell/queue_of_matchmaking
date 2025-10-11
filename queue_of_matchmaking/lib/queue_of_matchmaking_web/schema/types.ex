defmodule QueueOfMatchmakingWeb.Schema.Types do
  use Absinthe.Schema.Notation

  object :request_response do
    field(:ok, non_null(:boolean))
    field(:error, :string)
  end

  object :user do
    field(:user_id, non_null(:string))
    field(:user_rank, non_null(:integer))
  end

  object :match_payload do
    field(:users, non_null(list_of(non_null(:user))))
  end
end
