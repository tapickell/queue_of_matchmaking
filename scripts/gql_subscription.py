#!/usr/bin/env python3
"""Exercise GraphQL subscriptions using the gql library (graphql-transport-ws)."""

import asyncio
import csv
import os
import sys
from pathlib import Path
from typing import Any, Iterable

import requests
from gql import Client, gql
from gql.transport.websockets import WebsocketsTransport

WS_ENDPOINT = os.getenv(
    "QUEUE_MATCHMAKING_GQL_WS_ENDPOINT", "ws://localhost:4000/graphql/websocket"
)

SUBSCRIPTION = gql(
    """
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
)


def concurrency_limit() -> int:
    raw_value = os.getenv("QUEUE_MATCHMAKING_SUBSCRIPTION_CONCURRENCY", "50")
    try:
        value = int(raw_value)
    except ValueError:
        raise ValueError(
            f"QUEUE_MATCHMAKING_SUBSCRIPTION_CONCURRENCY must be an integer, got {raw_value!r}"
        ) from None

    if value <= 0:
        raise ValueError(
            f"QUEUE_MATCHMAKING_SUBSCRIPTION_CONCURRENCY must be > 0, got {raw_value!r}"
        )

    return value


async def subscribe_once(user_id: str) -> dict[str, Any]:
    transport = WebsocketsTransport(url=WS_ENDPOINT, subprotocols=["graphql-transport-ws"])
    async with Client(
        transport=transport,
        fetch_schema_from_transport=False,
    ) as session:
        async for result in session.subscribe(SUBSCRIPTION, variable_values={"userId": user_id}):
            return result
    raise RuntimeError("Subscription completed without emitting data")


def load_players(csv_path: Path) -> Iterable[tuple[str, int]]:
    with csv_path.open("r", newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            yield row["userId"], int(row["rank"])


async def monitor_user(user_id: str, rank: int, semaphore: asyncio.Semaphore) -> None:
    print(f"▶️  Subscribing for {user_id} (rank {rank})")
    async with semaphore:
        result = await subscribe_once(user_id)

        match = result.get("matchFound")
        if not match:
            print(f"⚠️  Subscription for {user_id} returned unexpected payload: {result}")
            return

        users = sorted(u["userId"] for u in match["users"])
        delta = match["delta"]
        print(f"✅ Match for {user_id}: users={users}, delta={delta}")


async def main() -> None:
    csv_path = Path(__file__).resolve().parent / "player_data.csv"
    players = list(load_players(csv_path))

    if not players:
        print(f"No player entries found in {csv_path}")
        return

    semaphore = asyncio.Semaphore(concurrency_limit())
    await asyncio.gather(
        *(monitor_user(user_id, rank, semaphore) for user_id, rank in players)
    )


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(1)
