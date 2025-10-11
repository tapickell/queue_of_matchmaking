## Implementation Phases

### Phase 1: Core Setup
- [X] Initialize Mix project
- [X] Add dependencies (Absinthe, Phoenix)
- [X] Configure application
- [ ] Define project structure

### Phase 2: Queue Manager
- [ ] Implement GenServer for queue
- [ ] Add/remove operations
- [ ] Basic state management
- [ ] Input validation

### Phase 3: Matching Logic
- [ ] Implement closest-rank algorithm
- [ ] Handle match creation
- [ ] Remove matched users from queue
- [ ] Store matched pairs

### Phase 4: GraphQL Layer
- [ ] Define Absinthe schema
- [ ] Implement addRequest mutation
- [ ] Implement matchFound subscription
- [ ] Connect to Queue Manager
- [ ] Configure PubSub

### Phase 5: Testing
- [ ] Unit tests for queue operations
- [ ] Unit tests for matching logic
- [ ] Integration tests for GraphQL API
- [ ] Concurrent request tests
- [ ] Edge case coverage

### Phase 6: Polish
- [ ] Code review and refactoring
- [ ] Documentation (inline and README)
- [ ] Performance benchmarking with Benchee
  - [ ] Create benchmark suite for matching algorithm
  - [ ] Compare data structure options (list vs map)
  - [ ] Benchmark with various queue sizes
  - [ ] Generate HTML reports
- [ ] Error handling improvements


NOTE - REarrange these to be more TDD
