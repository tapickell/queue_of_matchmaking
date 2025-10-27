defmodule QueueOfMatchmakingWeb.GraphqlSocket do
  @moduledoc false

  use Absinthe.GraphqlWS.Socket,
    schema: QueueOfMatchmakingWeb.Schema
end
