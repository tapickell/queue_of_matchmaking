defmodule QueueOfMatchmaking.MatchMakingTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.MatchMaking

  # Helper to create timestamps in the past
  defp minutes_ago(minutes) do
    DateTime.utc_now() |> DateTime.add(-minutes * 60, :second)
  end

  describe "find_match/1 - incremental range expansion with FIFO fairness" do
    test "returns error when queue is empty" do
      assert {:error, :no_matches} = MatchMaking.find_match([])
    end

    test "returns error when queue has only one request" do
      assert {:error, :no_matches} =
               MatchMaking.find_match([
                 %{user_id: "player1", rank: 1500, added_to_queue: minutes_ago(5)}
               ])
    end

    test "incremental range expansion - only two in queue will auto match" do
      # Only one other player, must expand to range 100 to find them
      queue = [
        %{user_id: "player1", rank: 100_000, added_to_queue: minutes_ago(50)},
        %{user_id: "player_new", rank: 100, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()
      assert ranks == [100, 100_000]
    end

    test "matches newest player with oldest player at exact rank (range 0)" do
      # Queue: player1 waited 10 min, player2 waited 5 min, new player just joined
      # [oldest ... newest]
      queue = [
        # oldest (head)
        %{user_id: "player1", rank: 1100, added_to_queue: minutes_ago(10)},
        %{user_id: "player2", rank: 1200, added_to_queue: minutes_ago(5)},
        # newest (tail)
        %{user_id: "player_new", rank: 1100, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      # Should match player1 (exact match, oldest) with player_new
      assert user_ids == ["player1", "player_new"]
      assert ranks == [1100, 1100]
    end

    test "incremental range expansion - stops at range 1 when match found" do
      # New player rank 1051, oldest eligible is at rank 1050 (range 1)
      queue = [
        # oldest
        %{user_id: "player1", rank: 1000, added_to_queue: minutes_ago(20)},
        %{user_id: "player2", rank: 1050, added_to_queue: minutes_ago(10)},
        %{user_id: "player3", rank: 1200, added_to_queue: minutes_ago(5)},
        # newest
        %{user_id: "player_new", rank: 1051, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      # Should match player2 (range 1) with player_new, not continue to player1
      assert user_ids == ["player2", "player_new"]
      assert ranks == [1050, 1051]
    end

    test "FIFO within same range - matches oldest player at range 0" do
      # Multiple players at same rank, should match the one who waited longest
      queue = [
        # oldest (waited longest)
        %{user_id: "player1", rank: 1100, added_to_queue: minutes_ago(30)},
        %{user_id: "player2", rank: 1100, added_to_queue: minutes_ago(20)},
        %{user_id: "player3", rank: 1200, added_to_queue: minutes_ago(10)},
        # newest
        %{user_id: "player_new", rank: 1100, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      # Should match player1 (oldest/waited longest) with player_new
      assert user_ids == ["player1", "player_new"]
    end

    test "FIFO within range 1 - matches oldest player at that distance" do
      # Multiple players at range 1, should match the one who waited longest
      queue = [
        # oldest, range 1
        %{user_id: "player1", rank: 1099, added_to_queue: minutes_ago(30)},
        # range 1
        %{user_id: "player2", rank: 1101, added_to_queue: minutes_ago(20)},
        %{user_id: "player3", rank: 1500, added_to_queue: minutes_ago(10)},
        # newest
        %{user_id: "player_new", rank: 1100, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      # Should match player1 (oldest at range 1) with player_new
      assert user_ids == ["player1", "player_new"]
    end

    test "incremental range expansion - skips empty ranges, finds at range 2" do
      # Range 0: no match, Range 1: no match, Range 2: match found
      queue = [
        %{user_id: "player1", rank: 1000, added_to_queue: minutes_ago(20)},
        # range 2
        %{user_id: "player2", rank: 1098, added_to_queue: minutes_ago(10)},
        %{user_id: "player3", rank: 1200, added_to_queue: minutes_ago(5)},
        # newest
        %{user_id: "player_new", rank: 1100, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      assert user_ids == ["player2", "player_new"]
      assert ranks == [1098, 1100]
    end

    test "incremental range expansion - expands far to find distant match" do
      # Only one other player, must expand to range 100 to find them
      queue = [
        %{user_id: "player1", rank: 1000, added_to_queue: minutes_ago(10)},
        %{user_id: "player_new", rank: 1100, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()
      assert ranks == [1000, 1100]
    end

    test "range expansion with above and below - FIFO picks oldest at that range" do
      # Two players at range 2 (one above, one below), should pick oldest
      queue = [
        # oldest, range 2
        %{user_id: "player1", rank: 1098, added_to_queue: minutes_ago(30)},
        # range 2
        %{user_id: "player2", rank: 1102, added_to_queue: minutes_ago(20)},
        %{user_id: "player3", rank: 1500, added_to_queue: minutes_ago(10)},
        %{user_id: "player_new", rank: 1100, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      # Should match player1 (oldest at range 2)
      assert user_ids == ["player1", "player_new"]
    end

    test "multiple candidates at different ranges - picks closest range first" do
      # player1 at range 5, player2 at range 3, player3 at range 1
      # Should pick player3 (smallest range), not player1 (oldest)
      queue = [
        # oldest, range 5
        %{user_id: "player1", rank: 1095, added_to_queue: minutes_ago(30)},
        # range 3
        %{user_id: "player2", rank: 1103, added_to_queue: minutes_ago(20)},
        # range 1
        %{user_id: "player3", rank: 1101, added_to_queue: minutes_ago(10)},
        %{user_id: "player_new", rank: 1100, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      # Should match player3 (closest range) with player_new
      assert user_ids == ["player3", "player_new"]
      assert ranks == [1100, 1101]
    end

    test "range with multiple candidates - FIFO picks oldest at that range" do
      # Two players at range 2, one at range 4
      # Should pick oldest at range 2
      queue = [
        # oldest, range 4
        %{user_id: "player1", rank: 1104, added_to_queue: minutes_ago(40)},
        # older, range 2
        %{user_id: "player2", rank: 1102, added_to_queue: minutes_ago(30)},
        # younger, range 2
        %{user_id: "player3", rank: 1098, added_to_queue: minutes_ago(20)},
        %{user_id: "player_new", rank: 1100, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      # Should match player2 (oldest at range 2), not player3
      assert user_ids == ["player2", "player_new"]
    end

    test "handles rank 0 correctly" do
      queue = [
        %{user_id: "player1", rank: 0, added_to_queue: minutes_ago(10)},
        %{user_id: "player2", rank: 100, added_to_queue: minutes_ago(5)},
        %{user_id: "player_new", rank: 0, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      assert user_ids == ["player1", "player_new"]
    end

    test "handles very high ranks correctly" do
      queue = [
        %{user_id: "player1", rank: 9998, added_to_queue: minutes_ago(10)},
        %{user_id: "player2", rank: 5000, added_to_queue: minutes_ago(5)},
        %{user_id: "player_new", rank: 9999, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      assert user_ids == ["player1", "player_new"]
      assert ranks == [9998, 9999]
    end

    test "preserves player data in match result" do
      queue = [
        %{user_id: "bob", rank: 1480, added_to_queue: minutes_ago(10)},
        %{user_id: "alice", rank: 1500, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)

      alice = Enum.find(matched_players, &(&1.user_id == "alice"))
      bob = Enum.find(matched_players, &(&1.user_id == "bob"))

      assert alice.rank == 1500
      assert bob.rank == 1480
    end

    test "returns {:ok, list} tuple structure" do
      queue = [
        %{user_id: "player1", rank: 1500, added_to_queue: minutes_ago(10)},
        %{user_id: "player2", rank: 1490, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert is_list(matched_players)
      assert length(matched_players) == 2

      Enum.each(matched_players, fn player ->
        assert Map.has_key?(player, :user_id)
        assert Map.has_key?(player, :rank)
        assert is_binary(player.user_id)
        assert is_integer(player.rank)
      end)
    end

    test "complex scenario - newest seeks match through mixed queue" do
      # Newest player rank 1200 seeks match
      # Closest matches: player3 (1195, range 5) and player4 (1205, range 5)
      # player3 is older, should win
      queue = [
        %{user_id: "player1", rank: 1500, added_to_queue: minutes_ago(40)},
        %{user_id: "player2", rank: 1100, added_to_queue: minutes_ago(30)},
        # older at range 5
        %{user_id: "player3", rank: 1195, added_to_queue: minutes_ago(20)},
        # younger at range 5
        %{user_id: "player4", rank: 1205, added_to_queue: minutes_ago(10)},
        %{user_id: "player_new", rank: 1200, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      # Should match player3 (oldest at range 5)
      assert user_ids == ["player3", "player_new"]
      assert ranks == [1195, 1200]
    end

    test "does not match more than two players" do
      queue = [
        %{user_id: "player1", rank: 1500, added_to_queue: minutes_ago(30)},
        %{user_id: "player2", rank: 1500, added_to_queue: minutes_ago(20)},
        %{user_id: "player3", rank: 1500, added_to_queue: minutes_ago(10)},
        %{user_id: "player_new", rank: 1500, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      # Should match player1 (oldest) and player_new
      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      assert user_ids == ["player1", "player_new"]
    end

    test "explicit fairness test - oldest at minimum range wins" do
      # New player seeks at rank 1000
      # player3 (999, range 1, waited 5 min)
      # player2 (998, range 2, waited 10 min)
      # player1 (1001, range 1, waited 15 min) <- OLDEST at range 1, should win
      queue = [
        # oldest, range 1
        %{user_id: "player1", rank: 1001, added_to_queue: minutes_ago(15)},
        # range 2
        %{user_id: "player2", rank: 998, added_to_queue: minutes_ago(10)},
        # younger, range 1
        %{user_id: "player3", rank: 999, added_to_queue: minutes_ago(5)},
        %{user_id: "new", rank: 1000, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()

      # player1 is oldest at range 1, should match (not player3, even though player3 is range 1 too)
      assert user_ids == ["new", "player1"]
    end

    test "scan must find oldest at minimum range, not first encountered" do
      # New player at rank 1000
      # Queue order: p1 (1001, t=15, range 1), p4 (1001, t=5, range 1), p3 (1002, range 2), p2 (999, t=10, range 1)
      # All of p1, p4, p2 are at range 1
      # p1 waited longest (t=15), should match
      queue = [
        # oldest at range 1
        %{user_id: "p1", rank: 1001, added_to_queue: minutes_ago(15)},
        # youngest at range 1
        %{user_id: "p4", rank: 1001, added_to_queue: minutes_ago(5)},
        # range 2
        %{user_id: "p3", rank: 1002, added_to_queue: minutes_ago(8)},
        # middle at range 1
        %{user_id: "p2", rank: 999, added_to_queue: minutes_ago(10)},
        %{user_id: "new", rank: 1000, added_to_queue: minutes_ago(0)}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      # p1 waited longest among all players at range 1
      assert user_ids == ["new", "p1"]
    end
  end
end
