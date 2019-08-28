use Mix.Config

config :logger, :console, level: :error

config :query_builder, ecto_repos: [QueryBuilder.Repo]

config :query_builder, QueryBuilder.Repo,
  username: System.get_env("QUERY_BUILDER_POSTGRES_USER"),
  password: System.get_env("QUERY_BUILDER_POSTGRES_PASSWORD"),
  database: System.get_env("QUERY_BUILDER_POSTGRES_DATABASE"),
  pool: Ecto.Adapters.SQL.Sandbox
