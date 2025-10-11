defmodule QueueOfMatchmakingWeb.Schema do
  use Absinthe.Schema
  import_types(QueueOfMatchmakingWeb.Schema.Types)

  # alias QueueOfMatchmakingWeb.Resolvers

  query do
    field :_empty, :string do
      resolve(fn _, _ -> {:ok, "ok"} end)
    end
  end

  mutation do
    field :add_request, :request_response do
      arg(:user_id, non_null(:string))
      arg(:rank, non_null(:integer))

      # resolve &Resolvers.add_request/3
      resolve(fn %{user_id: _, rank: _} ->
        :ok
      end)
    end
  end

  subscription do
    field :match_found, :match_payload do
      arg(:user_id, non_null(:string))

      config(fn args, _info ->
        {:ok, topic: "match_found:#{args.user_id}"}
      end)

      trigger(:add_request,
        topic: fn
          %{user_id: user_id}, _ -> ["match_found:#{user_id}"]
          _, _ -> []
        end
      )
    end
  end
end
