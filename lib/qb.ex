defmodule QB do
  @moduledoc """
  TODO
  """

  @default_pagination %{page: 1, page_size: 50}

  @special_parameters ~w(sort page page_size)
  @special_param_types %{page: :integer, page_size: :integer}

  @pagination_parameters ~w(page page_size)

  @type repo :: Ecto.Repo.t()
  # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  @type query :: term()
  @type field :: atom()
  @type params :: %{required(String.t()) => String.t()}
  @type param_type :: term()
  @type param_types :: %{required(field()) => param_type()}
  @type filter_value :: term()
  @type filter_fun :: (query(), term() -> query())
  @type filters :: %{required(field()) => filter_value()}
  @type filter_functions :: %{required(field()) => filter_fun()}
  @type page :: pos_integer()
  @type page_size :: pos_integer()
  @type pagination :: %{page: page(), page_size: page_size()}
  @type optional_pagination :: pagination() | nil
  # really ugly but we cannot specify a map with string keys as we can with the atom keys.
  @type string_keyed_pagination :: %{required(String.t) => pos_integer()}
  @type param_pagination :: pagination() | string_keyed_pagination() | nil
  @type optional_changeset :: Ecto.Changeset.t() | nil
  @type t :: %__MODULE__{
    repo: repo(),
    base_query: query(),
    params: params(),
    param_types: param_types(),
    filters: filters(),
    filter_functions: filter_functions(),
    pagination: optional_pagination(),
    changeset: optional_changeset()
  }
  defguard is_module(m) when is_atom(m)
  defguard is_repo(r) when is_module(r)
  defguard is_query(_q) when true # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  defguard is_field(x) when is_atom(x)
  defguard is_params(p) when is_map(p)
  defguard is_param_types(p) when is_map(p) and map_size(p) > 0
  defguard is_filter_value(_x) when true
  defguard is_filter_function(f) when is_function(f, 2)
  defguard is_pagination(p) when is_nil(p) or (is_map(p) and map_size(p) == 2)
  defguard is_page(n) when is_integer(n) and n > 0
  defguard is_page_size(n) when is_integer(n) and n > 0

  @enforce_keys [:repo, :base_query, :params, :param_types]
  defstruct [
    repo: nil,
    base_query: nil,
    params: nil,
    param_types: nil,
    filters: %{},
    filter_functions: %{},
    pagination: nil,
    changeset: nil
  ]

  @spec default_pagination() :: pagination()
  def default_pagination(), do: @default_pagination

  @spec new(repo(), query(), params(), param_types()) :: t()
  def new(repo, base_query, params, param_types)
      when is_repo(repo) and is_query(base_query) and is_params(params)
      and is_param_types(param_types) do
    %__MODULE__{
      repo: repo,
      base_query: base_query,
      params: params,
      param_types: Map.merge(param_types, @special_param_types)
    }
    |> cast_params()
    |> extract_filters()
    |> maybe_extract_pagination()
  end

  @spec cast_params(t()) :: t()
  defp cast_params(%__MODULE__{params: params, param_types: param_types} = qb)
       when is_params(params) and is_param_types(param_types) do
    %__MODULE__{qb |
      changeset: Ecto.Changeset.cast({%{}, param_types}, params, Map.keys(param_types))
    }
  end

  @spec extract_filters(t()) :: t()
  defp extract_filters(%__MODULE__{changeset: %Ecto.Changeset{valid?: true} = cs, params: params} = qb) do
    filters =
      params
      |> Map.drop(@special_parameters)
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

  @spec maybe_extract_pagination(t()) :: t()
  defp maybe_extract_pagination(%__MODULE__{changeset: %Ecto.Changeset{valid?: true} = cs, params: params} = qb) do
    pagination =
      params
      |> Map.take(@pagination_parameters)
      |> Enum.map(fn {key, _} ->
        k = String.to_atom(key)
        {k, Ecto.Changeset.get_change(cs, k)}
      end)
      |> Map.new()

    %__MODULE__{qb |
      pagination: pagination
    }
  end

  defp maybe_extract_pagination(%__MODULE__{changeset: %Ecto.Changeset{valid?: false}} = qb) do
    qb
  end

  @spec clear_pagination(t()) :: t()
  def clear_pagination(%__MODULE__{} = qb) do
    put_pagination(qb, nil)
  end

  @spec put_pagination(t(), optional_pagination()) :: t()
  def put_pagination(%__MODULE__{} = qb, nil) do
    %__MODULE__{qb |
      pagination: nil
    }
  end

  def put_pagination(%__MODULE__{} = qb, %{page: page, page_size: page_size})
      when is_page(page) and is_page_size(page_size) do
    %__MODULE__{qb |
      pagination: %{page: page, page_size: page_size}
    }
  end

  def put_pagination(%__MODULE__{} = qb, %{page: page, page_size: page_size})
      when is_page(page) and is_page_size(page_size) do
    %__MODULE__{qb |
      pagination: %{page: page, page_size: page_size}
    }
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

  @spec fetch(t()) :: term()
  def fetch(%__MODULE__{repo: repo, pagination: nil} = qb) do
    qb
    |> __MODULE__.query()
    |> repo.all()
  end

  def fetch(%__MODULE__{repo: repo, pagination: %{page: page, page_size: page_size} = pagination} = qb)
      when is_page(page) and is_page_size(page_size) do
    qb
    |> __MODULE__.query()
    |> repo.paginate(pagination)
  end
end
