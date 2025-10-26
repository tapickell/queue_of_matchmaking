defmodule QueueOfMatchmaking.QueueState do
  @moduledoc false

  defstruct queue_module: nil,
            queue_state: nil,
            policy_module: nil,
            policy_state: nil,
            policy_timer_ref: nil,
            time_fn: &System.monotonic_time/1,
            matches: [],
            max_match_history: 100
end
