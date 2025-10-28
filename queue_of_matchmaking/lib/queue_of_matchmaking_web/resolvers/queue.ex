defmodule QueueOfMatchmakingWeb.Resolvers.Queue do
  @moduledoc false

  @queue_manager Application.compile_env(
                   :queue_of_matchmaking,
                   :queue_manager,
                   QueueOfMatchmaking.QueueManager
                 )

  def add_request(_parent, args, _resolution) do
    queue_manager = queue_manager()

    case queue_manager.enqueue(%{user_id: args.user_id, rank: args.rank}) do
      {:ok, :queued} ->
        {:ok, %{ok: true, error: nil}}

      {:ok, %{match: _match}} ->
        {:ok, %{ok: true, error: nil}}

      {:error, reason} ->
        {:ok, %{ok: false, error: format_error(reason)}}
    end
  rescue
    error ->
      {:ok, %{ok: false, error: Exception.message(error)}}
  end

  defp queue_manager do
    Application.get_env(:queue_of_matchmaking, :queue_manager, @queue_manager)
  end

  defp format_error({:policy_rejected, reason}), do: "policy rejected: #{inspect(reason)}"
  defp format_error({:queue_error, reason}), do: "queue error: #{inspect(reason)}"
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
