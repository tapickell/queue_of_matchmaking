defmodule QueueOfMatchmakingWeb.UserSocket do
  @moduledoc false

  use Phoenix.Socket
  use Absinthe.Phoenix.Socket, schema: QueueOfMatchmakingWeb.Schema

  channel "__absinthe__:*", Absinthe.Phoenix.Channel

  @impl true
  def connect(_params, socket, _connect_info), do: {:ok, socket}

  @impl true
  def id(_socket), do: nil
end
