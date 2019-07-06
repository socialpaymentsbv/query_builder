defmodule QueryBuilder do
  @moduledoc """
  TODO
  """

  @type repo :: Ecto.Repo.t()
  @type query :: term() # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  @type params :: %{required(String.t()) => String.t()}
  @type param_type :: term()
  @type param_types :: %{required(atom()) => param_type()}
  @type optional_changeset :: Ecto.Changeset.t() | nil
  @type t :: %__MODULE__{
    repo: repo(),
    base_query: query(),
    params: params(),
    param_types: param_types(),
    changeset: optional_changeset()
  }

  defguard is_module(m) when is_atom(m)
  defguard is_repo(r) when is_module(r)
  defguard is_query(_q) when true # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  defguard is_params(p) when is_map(p) and map_size(p) > 0
  defguard is_param_types(p) when is_map(p) and map_size(p) > 0

  @enforce_keys [:repo, :params, :base_query]
  defstruct [
    :repo,
    :base_query,
    :params,
    :param_types,
    :changeset
  ]

  @spec new(repo(), query(), params(), param_types()) :: t()
  def new(repo, base_query, params, param_types)
      when is_repo(repo) and is_query(base_query) and is_params(params)
      and is_param_types(param_types) do
    qb = %__MODULE__{
      repo: repo,
      base_query: base_query,
      params: params,
      param_types: param_types
    }

    %__MODULE__{qb |
      changeset: validate_params(qb)
    }
  end

  defp validate_params(%__MODULE__{params: params, param_types: param_types})
       when is_params(params) and is_param_types(param_types) do
    {%{}, param_types}
    |> Ecto.Changeset.cast(params, Map.keys(param_types))
  end
end
