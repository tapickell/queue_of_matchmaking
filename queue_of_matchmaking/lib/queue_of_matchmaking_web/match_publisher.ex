defmodule QueueOfMatchmakingWeb.MatchPublisher do
  @moduledoc """
  Publishes match events to Absinthe subscriptions.
  """

  @behaviour QueueOfMatchmaking.MatchPublisher

  alias QueueOfMatchmakingWeb.Endpoint

  @subscription_module Application.compile_env(
                         :queue_of_matchmaking,
                         :subscription_module,
                         Absinthe.Subscription
                       )

  @impl true
  @spec publish(%{required(:users) => [map()]}) :: :ok
  def publish(%{users: users}) do
    subscription_module().publish(
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

  defp topic(user), do: "match_found:#{user.user_id}"

  defp subscription_module do
    Application.get_env(:queue_of_matchmaking, :subscription_module, @subscription_module)
  end
end
