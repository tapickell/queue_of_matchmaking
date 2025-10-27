defmodule QueueOfMatchmakingWeb.GraphqlSocket do
  @moduledoc false

  use Absinthe.GraphqlWS.Socket,
    schema: QueueOfMatchmakingWeb.Schema

  alias Absinthe.GraphqlWS.{Transport, Util}

  defoverridable handle_in: 2, handle_info: 2

  @impl true
  def handle_in({text, [opcode: :text]} = frame, socket) when is_binary(text) do
    json = Util.json_library()

    if is_binary(text) do
      case json.decode(text) do
        {:ok, message} ->
          case translate_incoming(message, socket) do
            {:ok, translated, socket} ->
              case encode(json, translated) do
                {:ok, encoded} ->
                  Transport.handle_in({encoded, [opcode: :text]}, socket)

                :error ->
                  Transport.handle_in(frame, socket)
              end

            {:stop, reason, socket} ->
              {:stop, reason, socket}
          end

        _ ->
          Transport.handle_in(frame, socket)
      end
    else
      Transport.handle_in(frame, socket)
    end
  end

  @impl true
  def handle_info(message, socket) do
    case Transport.handle_info(message, socket) do
      {:push, {:text, payload}, updated_socket} ->
        {:push, {:text, rewrite_outgoing(payload, updated_socket)}, updated_socket}

      other ->
        other
    end
  end

  defp translate_incoming(%{"type" => "start"} = message, socket) do
    socket = maybe_set_protocol(socket, :apollo)
    {:ok, Map.put(message, "type", "subscribe"), socket}
  end

  defp translate_incoming(%{"type" => "stop"} = message, socket) do
    {:ok, Map.put(message, "type", "complete"), socket}
  end

  defp translate_incoming(%{"type" => "connection_terminate"}, socket),
    do: {:stop, :normal, socket}

  defp translate_incoming(%{"type" => "subscribe"} = message, socket) do
    socket = maybe_set_protocol(socket, :graphql_transport_ws)
    {:ok, message, socket}
  end

  defp translate_incoming(message, socket), do: {:ok, message, socket}

  defp rewrite_outgoing(payload, %{assigns: %{protocol: :apollo}}) do
    json = Util.json_library()

    with {:ok, message} <- json.decode(payload),
         "next" <- Map.get(message, "type"),
         {:ok, encoded} <- encode(json, Map.put(message, "type", "data")) do
      encoded
    else
      _ -> payload
    end
  end

  defp rewrite_outgoing(payload, _socket), do: payload

  defp maybe_set_protocol(%{assigns: %{protocol: protocol}} = socket, _protocol) when not is_nil(protocol),
    do: socket

  defp maybe_set_protocol(socket, protocol) do
    %{socket | assigns: Map.put(socket.assigns, :protocol, protocol)}
  end

  defp encode(json, message), do: json_encode(json, message)

  defp json_encode(json, message) do
    {:ok, json.encode!(message)}
  rescue
    _ -> :error
  end
end
