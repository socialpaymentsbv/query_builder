use Mix.Config

config :logger, :console, level: :error

config :qb, ecto_repos: [QB.Repo]

config :qb, QB.Repo,
  username: System.get_env("QB_POSTGRES_USER"),
  password: System.get_env("QB_POSTGRES_PASSWORD"),
  database: System.get_env("QB_POSTGRES_DATABASE"),
  pool: Ecto.Adapters.SQL.Sandbox
