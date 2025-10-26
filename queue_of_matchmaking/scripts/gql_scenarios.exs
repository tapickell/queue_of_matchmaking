#!/usr/bin/env elixir

Mix.install([:jason])

defmodule QueueOfMatchmaking.Script.GQLScenarios do
  @moduledoc """
  Drives the public GraphQL API through a set of matchmaking scenarios to ensure
  the queue behaves according to the specification.
  """

  @endpoint System.get_env("QUEUE_MATCHMAKING_GQL_ENDPOINT") || "http://localhost:4000/api"
  @headers [{~c"content-type", ~c"application/json"}]

  def run do
    :ok = :inets.start()
    :ok = :ssl.start()

    scenarios = [
      {:exact_rank_match, &scenario_exact_rank/0},
      {:range_expansion, &scenario_range_expansion/0},
      {:fifo_within_same_rank, &scenario_fifo_same_rank/0},
      {:closest_range_priority, &scenario_closest_range_priority/0}
    ]

    Enum.each(scenarios, fn {name, fun} ->
      IO.puts("\n== Scenario: #{format_name(name)} ==")
      baseline = recent_match_signatures()

      fun.()

      case new_matches_since(baseline) do
        [] ->
          IO.puts("ℹ️ Match already present in history (scenario re-run)")

        matches ->
          Enum.each(matches, fn signature ->
            IO.puts("✅ Produced match: #{inspect(signature)}")
          end)
      end
    end)

    IO.puts("\nAll scenarios executed successfully.")
  end

  ## Scenarios ---------------------------------------------------------------

  defp scenario_exact_rank do
    a = uid("exact_rank_a")
    b = uid("exact_rank_b")

    add_request!(a, 1500)
    add_request!(b, 1500)
    assert_latest_match!([a, b])
  end

  defp scenario_range_expansion do
    p1 = uid("range_player1")
    p2 = uid("range_player2")
    p3 = uid("range_player3")
    new = uid("range_new")

    add_request!(p1, 1000)
    add_request!(p2, 1050)
    assert_latest_match!([p1, p2])

    add_request!(p3, 1200)
    add_request!(new, 1051)
    assert_latest_match!([p3, new])
  end

  defp scenario_fifo_same_rank do
    oldest = uid("fifo_oldest")
    newest = uid("fifo_new")

    add_request!(oldest, 1100)
    add_request!(newest, 1100)
    assert_latest_match!([oldest, newest])
  end

  defp scenario_closest_range_priority do
    near = uid("closest_near")
    new = uid("closest_new")

    add_request!(near, 1101)
    add_request!(new, 1100)
    assert_latest_match!([near, new])
  end

  ## Helpers ----------------------------------------------------------------

  defp add_request!(user_id, rank) do
    mutation = """
    mutation($userId: String!, $rank: Int!) {
      addRequest(userId: $userId, rank: $rank) {
        ok
        error
      }
    }
    """

    variables = %{"userId" => user_id, "rank" => rank}

    response = gql_request!(mutation, variables)

    case response["data"]["addRequest"] do
      %{"ok" => true} ->
        :ok

      %{"error" => error} ->
        raise "Failed to enqueue #{user_id}: #{inspect(error)}"

      other ->
        raise "Unexpected addRequest response: #{inspect(other)}"
    end
  end

  defp assert_latest_match!(expected_user_ids) do
    matches = recent_matches(5)

    case Enum.find(matches, fn match ->
           sorted_users(match) == Enum.sort(expected_user_ids)
         end) do
      nil ->
        raise "Expected match #{inspect(expected_user_ids)} not found. Recent matches: #{inspect(matches)}"

      match ->
        IO.puts("✅ Verified match #{inspect(sorted_users(match))} (delta #{match["delta"]})")
        match
    end
  end

  defp recent_matches(limit) do
    query = """
    query($limit: Int) {
      recentMatches(limit: $limit) {
        users { userId userRank }
        delta
      }
    }
    """

    response = gql_request!(query, %{"limit" => limit})

    case get_in(response, ["data", "recentMatches"]) do
      nil -> []
      matches when is_list(matches) -> matches
      other -> raise "Unexpected recentMatches response: #{inspect(other)}"
    end
  end

  defp recent_match_signatures do
    recent_matches(50)
    |> Enum.map(&sorted_users/1)
    |> MapSet.new()
  end

  defp new_matches_since(baseline) do
    recent_match_signatures()
    |> MapSet.difference(baseline)
    |> MapSet.to_list()
  end

  defp sorted_users(match) do
    match["users"]
    |> Enum.map(& &1["userId"])
    |> Enum.sort()
  end

  defp uid(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp gql_request!(query, variables) do
    body = Jason.encode!(%{query: query, variables: variables})
    url = String.to_charlist(@endpoint)

    case :httpc.request(:post, {url, @headers, ~c"application/json", body}, [], []) do
      {:ok, {{_, 200, _}, _headers, raw_body}} ->
        handle_graphql_response(Jason.decode!(raw_body))

      {:ok, {{_, status, _}, _headers, raw_body}} ->
        raise "HTTP #{status}: #{raw_body}"

      {:error, reason} ->
        raise "HTTP error: #{inspect(reason)}"
    end
  end

  defp handle_graphql_response(%{"errors" => errors}) when is_list(errors) do
    raise "GraphQL errors: #{inspect(errors)}"
  end

  defp handle_graphql_response(response), do: response

  defp format_name(name) do
    name
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end

QueueOfMatchmaking.Script.GQLScenarios.run()
