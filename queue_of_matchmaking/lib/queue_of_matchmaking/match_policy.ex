defmodule QueueOfMatchmaking.MatchPolicy do
  @moduledoc """
  Behaviour describing the lifecycle hooks the queue manager exposes to
  matching policies.

  Policies determine when to attempt matches, how far the rank search may
  expand, and how deferred requests should be revisited. Implementations
  should be pure and rely only on the data passed into each callback.
  """

  @type opts :: keyword()
  @type policy_state :: term()

  alias QueueOfMatchmaking.QueueBehaviour

  @type entry :: %{
          required(:user_id) => String.t(),
          required(:rank) => non_neg_integer(),
          required(:inserted_at) => integer(),
          optional(:handle) => term(),
          optional(:meta) => map()
        }

  @type manager_state :: term()
  @type handle :: QueueBehaviour.handle()

  @type match_info :: %{
          required(:users) => [entry()],
          required(:delta) => non_neg_integer(),
          required(:matched_at) => integer()
        }

  @type timeout_return :: non_neg_integer() | :infinity | :hibernate

  @callback init(opts()) ::
              {:ok, policy_state(), timeout_return()}

  @callback before_enqueue(entry(), manager_state(), policy_state()) ::
              {:proceed, policy_state()}
              | {:reject, reason :: :invalid | :duplicate | term(), policy_state()}

  @callback matchmaking_mode(entry(), manager_state(), policy_state()) ::
              {:attempt, context :: map(), policy_state()}
              | {:defer, policy_state()}
              | {:cancel, policy_state()}

  @callback max_delta(entry(), manager_state(), map(), policy_state()) ::
              {:unbounded, policy_state()} | {:bounded, non_neg_integer(), policy_state()}

  @callback after_match(match_info(), manager_state(), policy_state()) ::
              {:ok, policy_state()}

  @type retry_instruction :: {handle(), map()}

  @callback handle_timeout(manager_state(), policy_state()) ::
              {:ok, policy_state(), timeout_return()}
              | {:retry, [retry_instruction()], policy_state(), timeout_return()}

  @callback terminate(reason :: term(), policy_state()) :: :ok
end
