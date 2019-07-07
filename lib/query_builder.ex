defmodule QueryBuilder do
  @moduledoc """
  TODO
  """

  @string_special_parameters ~w(sort page page_size)

  @type repo :: Ecto.Repo.t()
  @type query :: term() # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  @type field :: atom()
  @type params :: %{required(String.t()) => String.t()}
  @type param_type :: term()
  @type param_types :: %{required(field()) => param_type()}
  @type filter_value :: term()
  @type filter_fun :: (query(), term() -> query())
  @type filters :: %{required(field()) => filter_value()}
  @type filter_functions :: %{required(field()) => filter_fun()}
  @type optional_changeset :: Ecto.Changeset.t() | nil
  @type t :: %__MODULE__{
    repo: repo(),
    base_query: query(),
    params: params(),
    param_types: param_types(),
    filters: filters(),
    filter_functions: filter_functions(),
    changeset: optional_changeset()
  }

  defguard is_module(m) when is_atom(m)
  defguard is_repo(r) when is_module(r)
  defguard is_query(_q) when true # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  defguard is_field(x) when is_atom(x)
  defguard is_params(p) when is_map(p) and map_size(p) > 0
  defguard is_param_types(p) when is_map(p) and map_size(p) > 0
  defguard is_filter_value(_x) when true
  defguard is_filter_function(f) when is_function(f, 2)

  @enforce_keys [:repo, :base_query, :params, :param_types]
  defstruct [
    repo: nil,
    base_query: nil,
    params: nil,
    param_types: nil,
    filters: %{},
    filter_functions: %{},
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
    |> extract_filters()
  end

  @spec validate_params(t()) :: t()
  defp validate_params(%__MODULE__{params: params, param_types: param_types} = qb)
       when is_params(params) and is_param_types(param_types) do
    %__MODULE__{qb |
      changeset: Ecto.Changeset.cast({%{}, param_types}, params, Map.keys(param_types))
    }
  end

  @spec extract_filters(t()) :: t()
  defp extract_filters(%__MODULE__{changeset: %Ecto.Changeset{valid?: true} = cs, params: params} = qb) do
    filters =
      params
      |> Map.drop(@string_special_parameters)
      |> Enum.map(fn {key, _} ->
        k = String.to_atom(key)
        {k, Ecto.Changeset.get_change(cs, k)}
      end)
      |> Map.new()

    %__MODULE__{qb |
      filters: filters
    }
  end

  defp extract_filters(%__MODULE__{changeset: %Ecto.Changeset{valid?: false}} = qb) do
    qb
  end

  @spec invalid?(t(), field()) :: boolean()
  def invalid?(%__MODULE__{changeset: cs}, field)
      when is_field(field) do
    match?({_msg, [type: _, validation: :cast]}, cs.errors[field])
  end

  @spec filter(t(), field()) :: filter_value()
  def filter(%__MODULE__{filters: filters}, field)
      when is_field(field) do
    Map.get(filters, field)
  end

  @spec add_filter_function(t(), field(), filter_fun()) :: t()
  def add_filter_function(%__MODULE__{filter_functions: filter_functions} = qb, field, filter_fun)
      when is_field(field) and is_filter_function(filter_fun) do
    %__MODULE__{qb |
      filter_functions: Map.update(filter_functions, field, [filter_fun], &(&1 ++ [filter_fun]))
    }
  end

  @spec query(t()) :: query()
  def query(%__MODULE__{base_query: base_query, filter_functions: filter_functions} = qb) do
    Enum.reduce(filter_functions, base_query, fn {field, functions}, outer_query ->
      # Each field might have several filtering functions attached.
      Enum.reduce(functions, outer_query, fn filter_fun, inner_query ->
        filter_fun.(inner_query, __MODULE__.filter(qb, field))
      end)
    end)
  end
end
