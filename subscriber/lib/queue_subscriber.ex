defmodule QueueSubscriber do
  @moduledoc """
  Minimal CLI helper that opens GraphQL websocket subscriptions for the players
  listed in `player_data.csv`. Intended for manual matchmaking tests.
  """

  alias Absinthe.GraphqlWS.Client

  @subscription """
  subscription($userId: String!) {
    matchFound(userId: $userId) {
      users {
        userId
        userRank
      }
      delta
    }
  }
  """

  @default_endpoint "ws://localhost:4000/graphql/websocket"
  @default_csv Path.expand("../../scripts/player_data.csv", __DIR__)
  @default_concurrency 100

  @doc """
  Read the CSV file and open subscriptions for each player ID.

  Accepts optional overrides via keyword list or environment variables:

    * `QUEUE_MATCHMAKING_GQL_WS_ENDPOINT` - websocket endpoint.
    * `QUEUE_SUBSCRIBER_PLAYER_CSV` - path to the CSV file.
    * `QUEUE_SUBSCRIBER_CONCURRENCY` - maximum concurrent subscriptions.
  """
  def subscribe_all(opts \\ []) do
    csv_path = csv_path(opts)

    with {:ok, players} <- load_players(csv_path) do
      cond do
        players == [] ->
          IO.puts("No player entries found in #{csv_path}")
          :ok

        true ->
          endpoint = endpoint(opts)
          concurrency = concurrency(opts)

          IO.puts("Subscribing #{length(players)} players (concurrency #{concurrency})")

          players
          |> Task.async_stream(
            fn player -> subscribe_user(player, endpoint) end,
            max_concurrency: concurrency,
            timeout: :infinity,
            ordered: false
          )
          |> Enum.each(fn
            {:ok, :ok} -> :ok
            {:exit, reason} -> IO.puts("[task-exit] #{inspect(reason)}")
          end)

          :ok
      end
    else
      {:error, reason} ->
        IO.puts("Failed to load players: #{reason}")
        {:error, reason}
    end
  end

  defp subscribe_user({user_id, rank}, endpoint) do
    IO.puts("[subscribe] #{user_id} (rank #{rank})")

    result =
      try do
        do_subscribe(endpoint, user_id)
      rescue
        exception ->
          {:error, {:exception, exception, __STACKTRACE__}}
      catch
        :exit, reason ->
          {:error, {:exit, reason}}
      end

    case result do
      {:ok, match} ->
        log_match(user_id, match)

      {:error, reason} ->
        log_error(user_id, reason)
    end

    :ok
  end

  defp do_subscribe(endpoint, user_id) do
    case start_client(endpoint) do
      {:ok, client} ->
        try do
          with {:ok, subscription_id} <-
                 Client.subscribe(client, @subscription, %{"userId" => user_id}, self()),
               {:ok, match} <- await_match(subscription_id) do
            {:ok, match}
          else
            {:error, {:graphql_errors, _} = reason} -> {:error, reason}
            {:error, {:unexpected_payload, _} = reason} -> {:error, reason}
            {:error, reason} -> {:error, {:subscription_failed, reason}}
          end
        after
          safe_close(client)
        end

      {:error, reason} ->
        {:error, {:connection_failed, reason}}
    end
  end

  defp start_client(endpoint) do
    try do
      Client.start(endpoint)
    catch
      :exit, reason ->
        {:error, reason}
    end
  end

  defp safe_close(nil), do: :ok

  defp safe_close(client) do
    try do
      Client.close(client)
    catch
      :exit, _ -> :ok
    end
  end

  defp log_match(user_id, match) do
    users =
      match
      |> Map.get("users", [])
      |> Enum.map(&Map.get(&1, "userId"))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    delta = Map.get(match, "delta")

    IO.puts("[match] #{user_id}: users=#{Enum.join(users, ", ")} delta=#{delta}")
  end

  defp log_error(user_id, reason) do
    IO.puts("[error] #{user_id}: #{format_reason(reason)}")
  end

  defp await_match(subscription_id) do
    receive do
      {:subscription, ^subscription_id, %{"data" => %{"matchFound" => match}}} ->
        {:ok, match}

      {:subscription, ^subscription_id, %{"errors" => errors}} ->
        {:error, {:graphql_errors, errors}}

      {:subscription, ^subscription_id, payload} ->
        {:error, {:unexpected_payload, payload}}
    end
  end

  defp load_players(path) do
    if File.exists?(path) do
      try do
        players =
          path
          |> File.stream!()
          |> Stream.drop(1)
          |> Stream.map(&String.trim/1)
          |> Stream.reject(&(&1 == ""))
          |> Enum.map(&parse_player_line/1)

        {:ok, players}
      rescue
        e in ArgumentError -> {:error, e.message}
      end
    else
      {:error, "CSV file not found at #{path}"}
    end
  end

  defp parse_player_line(line) do
    case String.split(line, ",", parts: 2) do
      [user_id, rank_str] ->
        user =
          user_id
          |> String.trim()

        if user == "" do
          raise ArgumentError, "missing userId in row #{inspect(line)}"
        end

        {user, parse_rank(rank_str, user)}

      _ ->
        raise ArgumentError, "unexpected row format #{inspect(line)}"
    end
  end

  defp parse_rank(rank_str, user) do
    rank_text = String.trim(rank_str)

    case Integer.parse(rank_text) do
      {rank, ""} ->
        rank

      _ ->
        raise ArgumentError, "invalid rank #{inspect(rank_text)} for user #{inspect(user)}"
    end
  end

  defp endpoint(opts) do
    opts[:endpoint] ||
      System.get_env("QUEUE_MATCHMAKING_GQL_WS_ENDPOINT") ||
      @default_endpoint
  end

  defp csv_path(opts) do
    path =
      opts[:csv_path] ||
        System.get_env("QUEUE_SUBSCRIBER_PLAYER_CSV") ||
        @default_csv

    Path.expand(path)
  end

  defp concurrency(opts) do
    case opts[:concurrency] || System.get_env("QUEUE_SUBSCRIBER_CONCURRENCY") do
      nil -> @default_concurrency
      value -> parse_positive_integer(value)
    end
  end

  defp format_reason({:graphql_errors, errors}),
    do: "GraphQL errors: #{inspect(errors)}"

  defp format_reason({:unexpected_payload, payload}),
    do: "unexpected payload: #{inspect(payload)}"

  defp format_reason({:connection_failed, reason}),
    do: "connection failed: #{inspect(reason)}"

  defp format_reason({:subscription_failed, reason}),
    do: "subscription failed: #{inspect(reason)}"

  defp format_reason({:exception, exception, stacktrace}),
    do: Exception.format(:error, exception, stacktrace)

  defp format_reason({:exit, reason}),
    do: "subscription process exited: #{inspect(reason)}"

  defp format_reason(other),
    do: inspect(other)

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_integer(value) do
    raise ArgumentError, "QUEUE_SUBSCRIBER_CONCURRENCY must be > 0, got #{inspect(value)}"
  end

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int > 0 -> int
      {int, ""} -> raise ArgumentError, "QUEUE_SUBSCRIBER_CONCURRENCY must be > 0, got #{inspect(int)}"
      _ -> raise ArgumentError, "QUEUE_SUBSCRIBER_CONCURRENCY must be an integer, got #{inspect(value)}"
    end
  end

  defp parse_positive_integer(value) do
    raise ArgumentError,
          "QUEUE_SUBSCRIBER_CONCURRENCY must be a positive integer, got #{inspect(value)}"
  end
end
