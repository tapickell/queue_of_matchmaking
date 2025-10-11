import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :queue_of_matchmaking, QueueOfMatchmakingWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "bLqLd4x5tImlbUy9U6z03hr7Uf89Gwi7BZ9bAsv2ivL8BNdqw7secELuiYVusUO7",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime
