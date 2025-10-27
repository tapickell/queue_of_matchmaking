#!/usr/bin/env python3
"""Exercise GraphQL subscriptions using the gql library (graphql-transport-ws)."""

import asyncio
import os
import sys
from typing import Any

import requests
from gql import Client, gql
from gql.transport.websockets import WebsocketsTransport

HTTP_ENDPOINT = os.getenv("QUEUE_MATCHMAKING_GQL_ENDPOINT", "http://localhost:4000/api")
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

async def subscribe_once(user_id: str) -> dict[str, Any]:
    transport = WebsocketsTransport(url=WS_ENDPOINT, subprotocols=["graphql-transport-ws"])
    async with Client(
        transport=transport,
        fetch_schema_from_transport=False,
    ) as session:
        async for result in session.subscribe(SUBSCRIPTION, variable_values={"userId": user_id}):
            return result
    raise RuntimeError("Subscription completed without emitting data")


async def expect_match(user_a: str, rank_a: int, user_b: str, rank_b: int) -> None:
    task_a = asyncio.create_task(subscribe_once(user_a))
    task_b = asyncio.create_task(subscribe_once(user_b))

    result_a, result_b = await asyncio.gather(task_a, task_b)

    users_a = sorted(u["userId"] for u in result_a["matchFound"]["users"])
    users_b = sorted(u["userId"] for u in result_b["matchFound"]["users"])
    expected = sorted([user_a, user_b])

    if users_a != expected:
        raise RuntimeError(f"Subscription for {user_a} expected {expected}, got {users_a}")
    if users_b != expected:
        raise RuntimeError(f"Subscription for {user_b} expected {expected}, got {users_b}")

    print(f"✅ Subscription match received for {user_a} & {user_b} (delta {result_a['matchFound']['delta']})")


async def main() -> None:
    user_a = "sub_exact_a"
    user_b = "sub_exact_b"
    await expect_match(user_a, 1500, user_b, 1500)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(1)
