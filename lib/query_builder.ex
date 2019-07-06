defmodule QueryBuilder do
  @moduledoc """
  TODO
  """

  @type repo :: Ecto.Repo.t()
  @type query :: term() # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  @type field :: atom()
  @type params :: %{required(String.t()) => String.t()}
  @type param_type :: term()
  @type param_types :: %{required(field()) => param_type()}
  @type filter_fun :: (query(), term() -> query())
  @type filters :: %{required(field()) => filter_fun()}
  @type optional_changeset :: Ecto.Changeset.t() | nil
  @type t :: %__MODULE__{
    repo: repo(),
    base_query: query(),
    params: params(),
    param_types: param_types(),
    filters: filters(),
    changeset: optional_changeset()
  }

  defguard is_module(m) when is_atom(m)
  defguard is_repo(r) when is_module(r)
  defguard is_query(_q) when true # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  defguard is_field(x) when is_atom(x)
  defguard is_params(p) when is_map(p) and map_size(p) > 0
  defguard is_param_types(p) when is_map(p) and map_size(p) > 0
  defguard is_filter(f) when is_function(f, 2)

  @enforce_keys [:repo, :params, :base_query]
  defstruct [
    repo: nil,
    base_query: nil,
    params: nil,
    param_types: nil,
    filters: %{},
    changeset: nil
  ]

  @spec new(repo(), query(), params(), param_types()) :: t()
  def new(repo, base_query, params, param_types)
      when is_repo(repo) and is_query(base_query) and is_params(params)
      and is_param_types(param_types) do
    %__MODULE__{
      repo: repo,
      base_query: base_query,
      params: params,
      param_types: param_types
    }
    |> validate_params()
  end

  @spec validate_params(t()) :: t()
  defp validate_params(%__MODULE__{params: params, param_types: param_types} = qb)
       when is_params(params) and is_param_types(param_types) do
    %__MODULE__{qb |
      changeset: Ecto.Changeset.cast({%{}, param_types}, params, Map.keys(param_types))
    }
  end

  @spec add_filter(t(), field(), filter_fun()) :: t()
  def add_filter(%__MODULE__{filters: filters} = qb, field, filter_fun)
      when is_field(field) and is_filter(filter_fun) do
    %__MODULE__{qb |
      filters: Map.update(filters, field, [filter_fun], &(&1 ++ [filter_fun]))
    }
  end
end
