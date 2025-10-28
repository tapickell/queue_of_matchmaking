## Implementation Phases

### Phase 1: Core Setup
- [X] Initialize Mix project
- [X] Add dependencies (Absinthe, Phoenix)
- [X] Configure application
- [X] Define project structure

### Phase 2: Queue Manager
- [X] Implement GenServer for queue
- [X] Add/remove operations
- [X] Basic state management
- [X] Input validation

### Phase 3: Matching Logic
- [X] Implement closest-rank algorithm
- [X] Handle match creation
- [X] Remove matched users from queue
- [X] Store matched pairs

### Phase 4: GraphQL Layer
- [X] Define Absinthe schema
- [X] Implement addRequest mutation
- [X] Implement matchFound subscription
- [X] Connect to Queue Manager
- [X] Configure PubSub

### Phase 5: Testing
- [X] Unit tests for queue operations
- [X] Unit tests for matching logic
- [X] Integration tests for GraphQL API
- [X] Concurrent request tests
- [X] Edge case coverage

### Phase 6: Polish
- [X] Code review and refactoring
- [X] Documentation (inline and README)
- [ ] Performance benchmarking with Benchee
  - [ ] Create benchmark suite for matching algorithm
  - [ ] Compare data structure options (list vs map)
  - [ ] Benchmark with various queue sizes
  - [ ] Generate HTML reports
- [X] Error handling improvements


NOTE - REarrange these to be more TDD
