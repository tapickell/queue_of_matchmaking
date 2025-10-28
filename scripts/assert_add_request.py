#!/usr/bin/env python3
"""Quick assertion script verifying the GraphQL `addRequest` behaviour."""

from __future__ import annotations

import argparse
import os
import sys
import uuid
from typing import Any, Dict

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


def post_add_request(user_id: str, rank: int) -> Dict[str, Any]:
    response = requests.post(
        HTTP_ENDPOINT,
        json={"query": MUTATION, "variables": {"userId": user_id, "rank": rank}},
        timeout=5,
    )
    response.raise_for_status()
    payload = response.json()

    if "errors" in payload:
        messages = ", ".join(err.get("message", str(err)) for err in payload["errors"])
        raise RuntimeError(f"GraphQL errors: {messages}")

    result = payload.get("data", {}).get("addRequest")
    if result is None:
        raise RuntimeError(f"Unexpected response payload: {payload}")

    return result


def main(user_id: str, rank: int) -> int:
    print(f"➕ Enqueuing {user_id} (rank {rank})")
    first = post_add_request(user_id, rank)

    if not first.get("ok"):
        print(f"❌ Expected success but got {first}")
        return 1

    print("✅ First enqueue succeeded, checking duplicate rejection…")
    duplicate = post_add_request(user_id, rank)

    if duplicate.get("ok") is not False:
        print(f"❌ Expected duplicate to fail but got {duplicate}")
        return 1

    error = duplicate.get("error")
    if error != "already_enqueued":
        print(f"❌ Unexpected error payload: {duplicate}")
        return 1

    print("✅ Duplicate enqueue rejected with error:", error)
    return 0


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--user-id",
        default=None,
        help="User ID to enqueue. Defaults to a random value each run.",
    )
    parser.add_argument(
        "--rank",
        type=int,
        default=1200,
        help="Rank to use for the enqueue mutation (default: 1200).",
    )

    args = parser.parse_args()
    user_id = args.user_id or f"script-user-{uuid.uuid4().hex}"

    try:
        sys.exit(main(user_id, args.rank))
    except KeyboardInterrupt:
        sys.exit(1)
    except Exception as exc:
        print(f"❌ {exc}", file=sys.stderr)
        sys.exit(1)
