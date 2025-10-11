defmodule QueueOfMatchmaking.MatchMakingTest do
  use ExUnit.Case, async: true

  alias QueueOfMatchmaking.MatchMaking

  describe "find_match/1 - incremental range expansion with FIFO" do
    test "returns error when queue is empty" do
      assert {:error, :no_matches} = MatchMaking.find_match([])
    end

    test "returns error when queue has only one request" do
      assert {:error, :no_matches} = MatchMaking.find_match([%{user_id: "player1", rank: 1500}])
    end

    test "matches newest player (head) with exact rank match in queue (range 0)" do
      # newest player (head) has rank 1100
      # Queue tail has: player3 (1000), player2 (1500), player1 (1100)
      # Should match with player1 (exact match at range 0)
      queue = [
        %{user_id: "player_new", rank: 1100},  # newest (head)
        %{user_id: "player3", rank: 1000},
        %{user_id: "player2", rank: 1500},
        %{user_id: "player1", rank: 1100}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      assert user_ids == ["player1", "player_new"]
      assert ranks == [1100, 1100]
    end

    test "incremental range expansion - stops at range 1 when match found" do
      # newest: 1051
      # Queue: 1050 (range 1), 1000 (range 51), 1200 (range 149)
      # Should match with 1050 at range 1, not continue searching
      queue = [
        %{user_id: "player_new", rank: 1051},  # newest (head)
        %{user_id: "player2", rank: 1050},
        %{user_id: "player1", rank: 1000},
        %{user_id: "player3", rank: 1200}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      assert user_ids == ["player2", "player_new"]
      assert ranks == [1050, 1051]
    end

    test "FIFO within same range - matches first player in tail at range 0" do
      # newest: 1100
      # Queue tail: player1 (1100), player2 (1100), player3 (1200)
      # Multiple exact matches - should match with player1 (first in tail)
      queue = [
        %{user_id: "player_new", rank: 1100},  # newest (head)
        %{user_id: "player1", rank: 1100},
        %{user_id: "player2", rank: 1100},
        %{user_id: "player3", rank: 1200}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      assert user_ids == ["player1", "player_new"]
    end

    test "FIFO within range 1 - matches first player at that distance" do
      # newest: 1100
      # Queue: player1 (1099, range 1), player2 (1101, range 1), player3 (1500)
      # Both at range 1 - should match player1 (first at range 1)
      queue = [
        %{user_id: "player_new", rank: 1100},  # newest (head)
        %{user_id: "player1", rank: 1099},
        %{user_id: "player2", rank: 1101},
        %{user_id: "player3", rank: 1500}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      assert user_ids == ["player1", "player_new"]
    end

    test "incremental range expansion - skips empty ranges, finds at range 2" do
      # newest: 1100
      # Queue: 1098 (range 2), 1000 (range 100), 1200 (range 100)
      # Range 0: no match
      # Range 1: no matches at 1099 or 1101
      # Range 2: match at 1098
      queue = [
        %{user_id: "player_new", rank: 1100},  # newest (head)
        %{user_id: "player2", rank: 1098},
        %{user_id: "player1", rank: 1000},
        %{user_id: "player3", rank: 1200}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      assert user_ids == ["player2", "player_new"]
      assert ranks == [1098, 1100]
    end

    test "incremental range expansion - expands far to find distant match" do
      # newest: 1100
      # Queue: only 1000 (range 100)
      # Must expand through ranges 0-99 until finding match at range 100
      queue = [
        %{user_id: "player_new", rank: 1100},  # newest (head)
        %{user_id: "player1", rank: 1000}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()
      assert ranks == [1000, 1100]
    end

    test "range expansion with above and below - FIFO determines winner" do
      # newest: 1100
      # Queue: player1 (1098, range 2 below), player2 (1102, range 2 above)
      # Both at range 2 - should match player1 (first in queue at range 2)
      queue = [
        %{user_id: "player_new", rank: 1100},  # newest (head)
        %{user_id: "player1", rank: 1098},
        %{user_id: "player2", rank: 1102},
        %{user_id: "player3", rank: 1500}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      assert user_ids == ["player1", "player_new"]
    end

    test "multiple candidates at different ranges - picks closest (smallest range)" do
      # newest: 1100
      # Queue: player1 (1095, range 5), player2 (1103, range 3), player3 (1101, range 1)
      # Should match with player3 at range 1, not player2 or player1
      queue = [
        %{user_id: "player_new", rank: 1100},  # newest (head)
        %{user_id: "player1", rank: 1095},
        %{user_id: "player2", rank: 1103},
        %{user_id: "player3", rank: 1101}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      assert user_ids == ["player3", "player_new"]
      assert ranks == [1100, 1101]
    end

    test "range with multiple candidates - FIFO picks first" do
      # newest: 1100
      # Queue: player1 (1102, range 2), player2 (1098, range 2), player3 (1104, range 4)
      # At range 2: player1 and player2 both qualify
      # Should match player1 (appears first in queue)
      queue = [
        %{user_id: "player_new", rank: 1100},  # newest (head)
        %{user_id: "player1", rank: 1102},
        %{user_id: "player2", rank: 1098},
        %{user_id: "player3", rank: 1104}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      assert user_ids == ["player1", "player_new"]
    end

    test "handles rank 0 correctly" do
      # newest: 0
      # Queue: player1 (0, range 0), player2 (100)
      # Should match with player1 at range 0
      queue = [
        %{user_id: "player_new", rank: 0},  # newest (head)
        %{user_id: "player1", rank: 0},
        %{user_id: "player2", rank: 100}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      assert user_ids == ["player1", "player_new"]
    end

    test "handles very high ranks correctly" do
      # newest: 9999
      # Queue: player1 (9998, range 1), player2 (5000)
      # Should match with player1 at range 1
      queue = [
        %{user_id: "player_new", rank: 9999},  # newest (head)
        %{user_id: "player1", rank: 9998},
        %{user_id: "player2", rank: 5000}
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
        %{user_id: "alice", rank: 1500},
        %{user_id: "bob", rank: 1480}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)

      alice = Enum.find(matched_players, &(&1.user_id == "alice"))
      bob = Enum.find(matched_players, &(&1.user_id == "bob"))

      assert alice.rank == 1500
      assert bob.rank == 1480
    end

    test "returns {:ok, list} tuple structure" do
      queue = [
        %{user_id: "player1", rank: 1500},
        %{user_id: "player2", rank: 1490}
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

    test "complex scenario - newest seeks through mixed queue" do
      # newest: 1200
      # Queue: 1500 (range 300), 1100 (range 100), 1195 (range 5), 1205 (range 5)
      # Should match with 1195 or 1205 (both at range 5)
      # FIFO: should match 1195 (appears first)
      queue = [
        %{user_id: "player_new", rank: 1200},  # newest (head)
        %{user_id: "player1", rank: 1500},
        %{user_id: "player2", rank: 1100},
        %{user_id: "player3", rank: 1195},
        %{user_id: "player4", rank: 1205}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      ranks = Enum.map(matched_players, & &1.rank) |> Enum.sort()

      assert user_ids == ["player3", "player_new"]
      assert ranks == [1195, 1200]
    end

    test "does not match more than two players" do
      # Even with multiple exact matches, only return 2 players
      queue = [
        %{user_id: "player_new", rank: 1500},  # newest (head)
        %{user_id: "player1", rank: 1500},
        %{user_id: "player2", rank: 1500},
        %{user_id: "player3", rank: 1500}
      ]

      assert {:ok, matched_players} = MatchMaking.find_match(queue)
      assert length(matched_players) == 2

      # Should be player_new and player1 (first exact match)
      user_ids = Enum.map(matched_players, & &1.user_id) |> Enum.sort()
      assert user_ids == ["player1", "player_new"]
    end
  end
end
