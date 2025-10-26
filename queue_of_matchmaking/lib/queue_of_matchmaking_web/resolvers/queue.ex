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

  def recent_matches(_parent, args, _resolution) do
    queue_manager = queue_manager()
    limit = Map.get(args, :limit, 10)

    matches =
      queue_manager.recent_matches(limit)
      |> Enum.map(&sanitize_match/1)

    {:ok, matches}
  end

  defp queue_manager do
    Application.get_env(:queue_of_matchmaking, :queue_manager, @queue_manager)
  end

  defp sanitize_match(%{users: users} = match) do
    sanitized_users =
      Enum.map(users, fn user ->
        %{
          user_id: user.user_id,
          rank: user.rank
        }
      end)

    match
    |> Map.put(:users, sanitized_users)
    |> Map.delete(:matched_at)
    |> Map.delete(:context)
  end

  defp format_error({:policy_rejected, reason}), do: "policy rejected: #{inspect(reason)}"
  defp format_error({:queue_error, reason}), do: "queue error: #{inspect(reason)}"
  defp format_error(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_error(reason), do: inspect(reason)
end
