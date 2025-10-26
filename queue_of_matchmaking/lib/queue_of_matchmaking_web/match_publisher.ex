defmodule QueueOfMatchmakingWeb.MatchPublisher do
  @moduledoc """
  Publishes match events to Absinthe subscriptions.
  """

  @behaviour QueueOfMatchmaking.MatchPublisher

  alias QueueOfMatchmakingWeb.Endpoint

  @impl true
  def publish(%{users: users}) do
    Absinthe.Subscription.publish(
      Endpoint,
      %{users: Enum.map(users, &format_user/1)},
      match_found: Enum.map(users, &topic/1)
    )

    :ok
  rescue
    _ -> :ok
  end

  defp format_user(user) do
    %{
      userId: user.user_id,
      userRank: user.rank
    }
  end

  defp topic(user), do: "user:#{user.user_id}"
end
