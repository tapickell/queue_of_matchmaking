#!/usr/bin/env python3
"""Enqueue players through the GraphQL mutation."""

import asyncio
import csv
import os
import random
import sys
from pathlib import Path
from typing import Iterable, Tuple

import requests
HTTP_ENDPOINT = os.getenv("QUEUE_MATCHMAKING_GQL_ENDPOINT", "http://localhost:4000/api")
PLAYER_DATA = Path(__file__).resolve().parent / "player_data.csv"

MUTATION = """
mutation($userId: String!, $rank: Int!) {
  addRequest(userId: $userId, rank: $rank) {
    ok
    error
  }
}
"""

def add_request(user_id: str, rank: int) -> None:
    response = requests.post(
        HTTP_ENDPOINT,
        json={"query": MUTATION, "variables": {"userId": user_id, "rank": rank}},
        timeout=5,
    )
    payload = response.json()
    result = payload.get("data", {}).get("addRequest")
    if not result or not result.get("ok"):
        raise RuntimeError(f"addRequest failed: {payload}")


def load_players(parity: str) -> Iterable[Tuple[str, int]]:
    if not PLAYER_DATA.exists():
        raise FileNotFoundError(f"Player data CSV not found at {PLAYER_DATA}")

    with PLAYER_DATA.open("r", newline="") as handle:
        reader = csv.DictReader(handle)
        for idx, row in enumerate(reader, start=1):
            if parity == "odd" and idx % 2 == 0:
                continue
            if parity == "even" and idx % 2 == 1:
                continue
            yield row["userId"], int(row["rank"])


async def enqueue_players(parity: str) -> None:
    players = list(load_players(parity))

    if not players:
        print(f"No players matched the '{parity}' selection.")
        return

    print(f"▶️  Enqueuing {len(players)} {parity} players")
    for user_id, rank in players:
        add_request(user_id, rank)
        print(f"  • Enqueued {user_id} (rank {rank})")
        delay = random.uniform(0.001, 1.0)
        print(f" • Sleeping for {delay}")
        await asyncio.sleep(delay)

    print("✅ Completed mutation batch")


async def main(parity: str) -> None:
    await enqueue_players(parity)


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2 or sys.argv[1] not in {"odd", "even"}:
            print("Usage: python scripts/gql_mutation.py [odd|even]")
            sys.exit(1)

        selection = sys.argv[1]
        asyncio.run(main(selection))
    except KeyboardInterrupt:
        sys.exit(1)
