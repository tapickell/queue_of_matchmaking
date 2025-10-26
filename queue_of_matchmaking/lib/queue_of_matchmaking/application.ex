defmodule QueueOfMatchmaking.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      QueueOfMatchmakingWeb.Telemetry,
      {DNSCluster,
       query: Application.get_env(:queue_of_matchmaking, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: QueueOfMatchmaking.PubSub},
      {QueueOfMatchmaking.QueueManager,
       [publisher_module: QueueOfMatchmakingWeb.MatchPublisher]},
      # Start a worker by calling: QueueOfMatchmaking.Worker.start_link(arg)
      # {QueueOfMatchmaking.Worker, arg},
      # Start to serve requests, typically the last entry
      QueueOfMatchmakingWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: QueueOfMatchmaking.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    QueueOfMatchmakingWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
