#!/usr/bin/env python3
"""Exercise GraphQL subscriptions using the gql library (graphql-transport-ws)."""

import asyncio
import os
import sys
from typing import Any

import requests
HTTP_ENDPOINT = os.getenv("QUEUE_MATCHMAKING_GQL_ENDPOINT", "http://localhost:4000/api")

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


def unique(label: str) -> str:
    counter = unique.counters.setdefault(label, 0) + 1
    unique.counters[label] = counter
    return f"{label}_{counter}"


unique.counters = {}


async def expect_match(user_a: str, rank_a: int, user_b: str, rank_b: int) -> None:
    add_request(user_a, rank_a)
    add_request(user_b, rank_b)

    print(f"✅ Mutations sent for {user_a} & {user_b}")


async def main() -> None:
    user_a = "sub_exact_a"
    user_b = "sub_exact_b"
    await expect_match(user_a, 1500, user_b, 1500)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(1)

