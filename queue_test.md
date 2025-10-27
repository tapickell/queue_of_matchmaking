# Candidate Task for QueueOfMatchmaking

- Implement a matchmaking queue application using Elixir (with Absinthe for GraphQL).

## Specifics for the Task

1. [x] **Codebase**:  
   Host all your code in a git repository of your choice.
2. [x] **Project Type**:  
   The application should be a standard mix project.
3. [x] **Naming**:
   - The application should be named `:queue_of_matchmaking`.
   - The main Elixir module should be `QueueOfMatchmaking`.
4. [X] **API Interface**:
   - Provide a GraphQL interface using Absinthe.
   - Expose a GraphQL mutation to add a match request to the queue.
   - Expose a GraphQL subscription to notify clients when two users are matched.
5. [X] **Data Storage**:
   - Do not use any persistent storage.
   - All data (requests, matched pairs) must be stored in memory.
6. [X] **Libraries**:
   - You may use any Elixir/Erlang library for handling concurrency or scheduling.
   - Use Absinthe for the GraphQL schema and endpoint.
7. [X] **Testing**:
   - Include tests that verify the correct behavior of the queueing and matching logic.
   - Our automated tests will interact with the public GraphQL interface only.
8. [ ] **Code Quality**:
   - Code should be clear, maintainable, and idiomatic.

## Matchmaking Logic

1. [ ] **Request Data**:
   - Each request to join the matchmaking queue will provide:
     - A unique user identifier (String).
     - A rank (Integer) for skill rating or performance level.
   - Validate that the user ID is a non-empty string and the rank is a non-negative integer.
2. [ ] **Enqueuing Requests**:
   - The GraphQL mutation should accept a user ID and a rank.
   - If the user is already in the queue, return an error.
   - Otherwise, add the user to the internal queue and return confirmation.
3. [ ] **Matching Criteria**:
   - When a match occurs, it should pair two users with the closest possible rank difference.
   - Once a pair of requests is matched, remove them from the queue and store the pair as a matched set.
   - If no immediate close match is found at the current rank difference, gradually expand the search range both above and below the user's rank until a suitable match is found.

## API Functions

1. [ ] **GraphQL Mutation: addRequest(userId: String!, rank: Int!): RequestResponse**
   - **Response**: `{ ok: Boolean!, error: String }`
   - Adds a user to the matchmaking queue.
   - Returns `ok: true` if the user was successfully added.
   - Returns `ok: false` and an `error` message if the user cannot be added.
2. [ ] **GraphQL Subscription: matchFound(userId: String!): MatchPayload**
   - Triggered when two users are matched based on nearest rank difference.
   - Only subscriptions listening with a `userId` that is part of the matched pair should be notified.
   - **Response**:
     ```graphql
     {
       matchFound {
         users {
           userId
           userRank
         }
       }
     }
     ```

## Performance Requirements

1. [ ] **Concurrent Requests**:
   - The system should handle multiple requests concurrently without losing data integrity.
2. [ ] **Fast Matching**:
   - Matching logic should pair users with minimal rank differences efficiently.
   - Define a metric for Fast? Benchmark for this?_

## Example

- **Mutation Query**:
  ```graphql
  mutation {
    addRequest(userId: "Player123", rank: 1500) {
      ok
      error
    }
  }
  ```

- **Subscription Query**:
  ```graphql
  subscription {
    matchFound(userId: "Player123") {
      users {
        userId
        userRank
      }
    }
  }
  ```

If another user (e.g., "Player456" with rank 1480) is matched with "Player123", the subscription `matchFound` for "Player123" should be triggered, returning something like:

```json
{
  "data": {
    "matchFound": {
      "users": [
        {
          "userId": "Player123",
          "userRank": 1500
        },
        {
          "userId": "Player456",
          "userRank": 1480
        }
      ]
    }
  }
}
```
