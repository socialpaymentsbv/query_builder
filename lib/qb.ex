defmodule QB do
  @moduledoc """
  TODO
  """

  import Ecto.Query

  @default_pagination %{page: 1, page_size: 50}

  @pagination_param_types %{page: :integer, page_size: :integer}
  @page_parameter "page"
  @page_size_parameter "page_size"
  @pagination_parameters [@page_parameter, @page_size_parameter]

  @sort_param_types %{sort: {:array, {:map, :string}}}
  @sort_key :sort
  @sort_parameter "sort"
  @sort_parameters [@sort_parameter]
  @sort_direction_strings ~w(asc asc_nulls_first asc_nulls_last desc desc_nulls_first desc_nulls_last)

  @special_parameters @pagination_parameters ++ @sort_parameters
  @special_param_types Map.merge(@pagination_param_types, @sort_param_types)

  @type repo :: Ecto.Repo.t()
  # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  @type query :: term()
  @type field :: atom()
  @type params :: %{required(String.t()) => term()}
  @type param_type :: term()
  @type param_types :: %{required(field()) => param_type()}
  @type filter_value :: term()
  @type filter_fun :: (query(), term() -> query())
  @type filters :: %{required(field()) => filter_value()}
  @type filter_functions :: %{required(field()) => filter_fun()}
  @type page :: pos_integer()
  @type page_size :: pos_integer()
  @type pagination :: %{page: page(), page_size: page_size()}
  @type optional_pagination :: pagination() | %{}
  @type sort_direction :: :asc | :asc_nulls_first | :asc_nulls_last | :desc | :desc_nulls_first | :desc_nulls_last
  @type sort_clause :: {field(), sort_direction()}
  @type sort :: [sort_clause()]
  # really ugly but we cannot specify a map with string keys as we can with the atom keys.
  @type optional_changeset :: Ecto.Changeset.t() | nil
  @type t :: %__MODULE__{
    repo: repo(),
    base_query: query(),
    params: params(),
    param_types: param_types(),
    filters: filters(),
    filter_functions: filter_functions(),
    pagination: optional_pagination(),
    sort: sort(),
    changeset: optional_changeset()
  }
  @type validator :: (Ecto.Changeset.t() -> Ecto.Changeset.t())

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
    params: %{},
    param_types: %{},
    filters: %{},
    filter_functions: %{},
    pagination: %{},
    sort: [],
    changeset: nil
  ]

  @spec default_pagination() :: pagination()
  def default_pagination(), do: @default_pagination

  @spec new(repo(), query(), params(), param_types(), validator()) :: t()
  def new(repo, base_query, params, param_types, validator \\ &(&1))
      when is_repo(repo) and is_query(base_query) and is_params(params)
      and is_param_types(param_types) do
    %__MODULE__{
      repo: repo,
      base_query: base_query,
      params: params,
      param_types: Map.merge(param_types, @special_param_types)
    }
    |> cast_params(validator)
    |> extract_filters()
    |> maybe_extract_pagination()
    |> cast_sort()
  end

  @spec cast_params(t(), validator()) :: t()
  defp cast_params(%__MODULE__{params: params, param_types: param_types} = qb, validator)
       when is_params(params) and is_param_types(param_types) do
    changeset =
      {%{}, param_types}
      |> Ecto.Changeset.cast(Map.drop(params, @sort_parameters), Map.keys(param_types))
      |> validator.()
    %__MODULE__{qb |
      changeset: changeset
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

  @spec cast_sort_clauses(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  defp cast_sort_clauses(%Ecto.Changeset{} = cs, sort)
       when is_list(sort) do
    # Check if there is even one sort clause that's not a map.
    idx_not_map = Enum.find_index(sort, &(not is_map(&1)))
    if not is_nil(idx_not_map) do
      Ecto.Changeset.add_error(
        cs,
        @sort_key,
        "clause #{idx_not_map} is not a map",
        [index: idx_not_map, clause: :not_a_map]
      )
    else
      # Check if there is even one sort clause that's not a single-keyed map.
      idx_not_one_key_map = Enum.find_index(sort, &(map_size(&1) != 1))
      if not is_nil(idx_not_one_key_map) do
        Ecto.Changeset.add_error(
          cs,
          @sort_key,
          "clause #{idx_not_one_key_map} is not a one-key map",
          [index: idx_not_one_key_map, clause: :not_a_one_key_map]
        )
      else
        # Check if there are sort direction clauses that are not in the
        # expected list of valid values by Ecto.
        idx_invalid_direction = Enum.find_index(sort, fn(clause) ->
          {_field, direction} =
            clause
            |> Map.to_list()
            |> hd()

          direction not in @sort_direction_strings
        end)

        if not is_nil(idx_invalid_direction) do
          Ecto.Changeset.add_error(
            cs,
            @sort_key,
            "clause #{idx_invalid_direction} sorting direction is not one of: #{Enum.join(@sort_direction_strings, ", ")}",
            [index: idx_invalid_direction, clause: :invalid_direction]
          )
        else
          # If the shape of the sort clauses is correct, add the changes
          # to the changeset programmatically (no further validation).
          sort_clauses =
            sort
            |> Enum.map(&(&1 |> Map.to_list() |> hd()))
            |> Enum.map(fn {k, v} -> {String.to_atom(v), String.to_atom(k)} end)

          Ecto.Changeset.put_change(cs, @sort_key, sort_clauses)
        end
      end
    end
  end

  defp cast_sort_clauses(%Ecto.Changeset{} = cs, _) do
    Ecto.Changeset.add_error(cs, @sort_key, "must be a list of sort clauses", [clauses: :not_a_list])
  end

  @spec cast_sort(t()) :: t()
  defp cast_sort(%__MODULE__{changeset: %Ecto.Changeset{} = cs, params: %{"sort" => sort}} = qb) do
    modified_cs = cast_sort_clauses(cs, sort)
    %__MODULE__{qb |
      changeset: modified_cs,
      sort: Ecto.Changeset.get_change(modified_cs, @sort_key) || []
    }
  end

  defp cast_sort(%__MODULE__{} = qb), do: qb

  @spec remove_pagination(t()) :: t()
  def remove_pagination(%__MODULE__{} = qb) do
    put_pagination(qb, %{})
  end

  @spec put_pagination(t(), optional_pagination()) :: t()
  def put_pagination(%__MODULE__{} = qb, empty_pagination)
      when empty_pagination == %{} do
    %__MODULE__{qb |
      pagination: %{}
    }
  end

  def put_pagination(%__MODULE__{} = qb, %{page: page, page_size: page_size})
      when is_page(page) and is_page_size(page_size) do
    %__MODULE__{qb |
      pagination: %{page: page, page_size: page_size}
    }
  end

  @spec maybe_put_default_pagination(t(), optional_pagination()) :: t()
  def maybe_put_default_pagination(%__MODULE__{pagination: pagination} = qb, %{page: page, page_size: page_size} = param_pagination)
      when is_page(page) and is_page_size(page_size) do
    %__MODULE__{qb |
      pagination: Map.merge(param_pagination, pagination)
    }
  end

  @spec maybe_put_default_filters(t(), params()) :: t()
  def maybe_put_default_filters(%__MODULE__{filters: filters} = qb, %{} = param_filters) do
    %__MODULE__{qb |
      filters: Map.merge(param_filters, filters)
    }
  end

  @spec put_filters(t(), filters()) :: t()
  def put_filters(%__MODULE__{filters: filters} = qb, %{} = param_filters) do
    %__MODULE__{qb |
      filters: Map.merge(filters, param_filters)
    }
  end

  @spec put_filter_function(t(), field(), filter_fun()) :: t()
  def put_filter_function(%__MODULE__{filter_functions: filter_functions} = qb, field, filter_fun)
      when is_field(field) and is_filter_function(filter_fun) do
    %__MODULE__{qb |
      filter_functions: Map.put(filter_functions, field, filter_fun)
    }
  end

  @spec remove_filter_function(t(), field()) :: t()
  def remove_filter_function(%__MODULE__{filter_functions: filter_functions} = qb, field)
      when is_field(field) do
    %__MODULE__{qb |
      filter_functions: Map.drop(filter_functions, [field])
    }
  end

  @spec query(t()) :: query()
  def query(%__MODULE__{base_query: base_query, filter_functions: filter_functions, sort: sort} = qb) do
    q = Enum.reduce(filter_functions, base_query, fn {field, filter_fun}, acc_query ->
      filter_fun.(acc_query, qb.filters[field])
    end)

    if sort !== [] do
      order_by(q, [_], ^sort)
    else
      q
    end
  end

  @spec fetch(t()) :: term()
  def fetch(%__MODULE__{repo: repo, pagination: empty_pagination} = qb)
      when empty_pagination == %{} do
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

  def has_errors?(%__MODULE__{changeset: %Ecto.Changeset{} = cs}) do
    cs.valid? and cs.errors === []
  end

  def has_error?(%__MODULE__{changeset: %Ecto.Changeset{errors: errors}}, field)
      when is_field(field) do
    Keyword.has_key?(errors, field)
  end

  def get_error(%__MODULE__{changeset: %Ecto.Changeset{errors: errors}}, field)
      when is_field(field) do
    Keyword.get(errors, field)
  end
end
