defmodule QueueSubscriber.MixProject do
  use Mix.Project

  def project do
    [
      app: :queue_subscriber,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:absinthe_graphql_ws, "~> 0.3.6"},
      {:gun, "~> 1.3"},
      {:jason, "~> 1.4"}
    ]
  end
end
