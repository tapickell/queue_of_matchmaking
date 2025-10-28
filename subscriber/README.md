# QueueSubscriber

A lightweight Mix project that opens GraphQL websocket subscriptions for every
player listed in `../scripts/player_data.csv`. Use it to observe matchmaking
results while exercising the queue with the accompanying load scripts.

## Usage

```
mix run -e "QueueSubscriber.subscribe_all()"
```

The command expects to run from this `subscriber/` directory. It loads player
records from the shared CSV file, then maintains a limited number of concurrent
subscriptions until each user receives a match.

### Configuration

Control runtime behaviour with environment variables (or pass overrides as
options to `subscribe_all/1`):

- `QUEUE_MATCHMAKING_GQL_WS_ENDPOINT` – websocket endpoint  
  (default `ws://localhost:4000/graphql/websocket`)
- `QUEUE_SUBSCRIBER_PLAYER_CSV` – path to the player CSV  
  (default `../scripts/player_data.csv`)
- `QUEUE_SUBSCRIBER_CONCURRENCY` – maximum in-flight subscriptions (default `10`)

Each subscription stays open until the server replies, logging either the match
participants and delta or a clear error if the request fails.
