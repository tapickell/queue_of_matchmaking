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
  @spec publish(%{required(:users) => [map()], optional(:delta) => non_neg_integer()}) :: :ok
  def publish(%{users: users} = match) do
    payload = %{
      users: Enum.map(users, &format_user/1),
      delta: normalize_delta(match)
    }

    subscription_module().publish(Endpoint, payload, match_found: Enum.map(users, &topic/1))

    :ok
  rescue
    _ -> :ok
  end

  defp format_user(user) do
    %{
      user_id: user.user_id,
      user_rank: user.rank,
      rank: user.rank,
      userId: user.user_id,
      userRank: user.rank
    }
  end

  defp topic(user), do: "match_found:#{user.user_id}"

  defp normalize_delta(%{delta: delta}) when is_integer(delta), do: delta
  defp normalize_delta(_), do: 0

  defp subscription_module do
    Application.get_env(:queue_of_matchmaking, :subscription_module, @subscription_module)
  end
end
