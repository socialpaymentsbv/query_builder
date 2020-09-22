defmodule QueryBuilder do
  alias Ecto.Changeset
  alias QueryBuilder.Sort
  import Ecto.Query, only: [from: 2]
  import Sort, only: [is_sort_direction: 1, is_sort_function: 1]

  @external_resource "README.md"
  @moduledoc "README.md"
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  @pagination_param_types %{page: :integer, page_size: :integer}
  @page_key :page
  @page_size_key :page_size
  @pagination_keys Map.keys(@pagination_param_types)

  @sort_key :sort
  @sort_param_types %{sort: {:array, {:map, :string}}}

  @special_parameters [@sort_key | @pagination_keys]
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
  @type filter_validator :: (Changeset.t() -> Changeset.t())
  @type filters :: %{required(field()) => filter_value()}
  @type filter_functions :: %{required(field()) => filter_fun()}
  @type page :: pos_integer()
  @type page_size :: pos_integer()
  @type pagination :: %{page: page(), page_size: page_size()}
  @type optional_pagination :: pagination() | %{}
  @type sort_direction ::
          :asc
          | :asc_nulls_first
          | :asc_nulls_last
          | :desc
          | :desc_nulls_first
          | :desc_nulls_last
  @type sort_clause :: {field(), sort_direction()}
  @type sort :: [sort_clause()]
  @type sort_fun :: (query(), sort_direction() -> query())
  # really ugly but we cannot specify a map with string keys as we can with the atom keys.
  @type optional_changeset :: Changeset.t() | nil
  @type t :: %__MODULE__{
          repo: repo(),
          base_query: query(),
          params: params(),
          param_types: param_types(),
          filters: filters(),
          filter_functions: filter_functions(),
          pagination: optional_pagination(),
          sort: sort(),
          sort_functions: filter_functions(),
          changeset: optional_changeset()
        }

  defguardp is_module(m) when is_atom(m)
  defguardp is_repo(r) when is_module(r)

  # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  defguardp is_query(_q) when true
  defguardp is_field(x) when is_atom(x)
  defguardp is_params(p) when is_map(p)
  defguardp is_param_types(p) when is_map(p)
  defguardp is_filter_function(f) when is_function(f, 2)
  defguardp is_filter_validator(f) when is_function(f, 1)
  defguardp is_page(n) when is_integer(n) and n > 0
  defguardp is_page_size(n) when is_integer(n) and n > 0

  @enforce_keys [:repo, :base_query, :params, :param_types]
  defstruct repo: nil,
            base_query: nil,
            params: %{},
            param_types: %{},
            filters: %{},
            filter_functions: %{},
            pagination: %{},
            sort: [],
            sort_functions: %{},
            changeset: nil

  @doc """
  Creates `QueryBuilder` struct.

      iex> QueryBuilder.new(Repo, User, %{"birthdate" => "1989-02-07"}, %{birthdate: :date}).filters
      %{birthdate: ~D[1989-02-07]}

  It uses `param_types` for casting params to correct data types using `Ecto`
  which means you can use the same Primitive Types as in `Ecto.Schema`

  The optional parameter `filter_validator` allows passing a function performing additional checks on `filters`.

  iex> QueryBuilder.new(Repo, User, %{"birthdate" => "1989-02-07"}, %{birthdate: :date}, fn changeset ->
  ...>   Ecto.Changeset.add_error(changeset, :birthdate, "This validation will always fail")
  ...> end).changeset.errors
  [birthdate: {"This validation will always fail", []}]
  """
  @spec new(repo(), query(), params(), param_types(), filter_validator()) :: t()
  def new(repo, base_query, params, param_types, filter_validator \\ & &1)
      when is_repo(repo) and is_query(base_query) and is_params(params) and
             is_param_types(param_types) and is_filter_validator(filter_validator) do
    %__MODULE__{
      repo: repo,
      base_query: base_query,
      params: params,
      param_types: Map.merge(param_types, @special_param_types)
    }
    |> put_params(params, filter_validator)
  end

  @spec put_params(t(), params(), filter_validator()) :: t()
  defp put_params(
         %__MODULE__{param_types: param_types} = query_builder,
         params,
         filter_validator \\ & &1
       )
       when is_params(params) and is_param_types(param_types) and
              is_filter_validator(filter_validator) do
    modified_cs =
      Changeset.cast(
        {%{}, param_types},
        params,
        Map.keys(param_types)
      )
      |> filter_validator.()

    %__MODULE__{
      query_builder
      | params: params,
        changeset: modified_cs,
        filters: Changeset.apply_changes(modified_cs)
    }
    |> cast_filters()
    |> cast_pagination()
    |> cast_sort()
  end

  @spec cast_filters(t()) :: t()
  defp cast_filters(
         %__MODULE__{changeset: %Changeset{valid?: true} = cs} = query_builder
       ) do
    filters =
      cs.changes
      |> Map.drop(@special_parameters)

    %__MODULE__{query_builder | filters: filters}
  end

  defp cast_filters(%__MODULE__{changeset: %Changeset{valid?: false}} = query_builder) do
    query_builder
  end

  @spec cast_pagination(t()) :: t()
  defp cast_pagination(
         %__MODULE__{changeset: %Changeset{valid?: true} = cs} = query_builder
       ) do
    pagination =
      cs.changes
      |> Map.take(@pagination_keys)

    %__MODULE__{query_builder | pagination: pagination}
  end

  defp cast_pagination(%__MODULE__{changeset: %Changeset{valid?: false}} = query_builder) do
    query_builder
  end

  @spec cast_sort(t()) :: t()
  defp cast_sort(
         %__MODULE__{changeset: %Changeset{} = cs, params: %{"sort" => sort}} =
           query_builder
       ) do
    modified_cs = Sort.cast_sort_clauses(cs, sort)

    %__MODULE__{
      query_builder
      | changeset: modified_cs,
        sort: Changeset.get_change(modified_cs, @sort_key) || []
    }
  end

  defp cast_sort(%__MODULE__{} = query_builder), do: query_builder

  @spec validate_sort(Changeset.t(), term()) :: Changeset.t()
  defp validate_sort(%Changeset{} = cs, sort)
       when is_list(sort) do
    Sort.validate_sort_clauses(cs, sort)
  end

  defp validate_sort(%Changeset{} = cs, _) do
    Changeset.add_error(
      cs,
      @sort_key,
      "must be a list of sort clauses",
      clauses: :not_a_list
    )
  end

  @doc """
  Adds to or overwrites sort set in params.

      iex> qb = QueryBuilder.new(Repo, User, %{"sort" => [%{"name" => "asc"}]}, %{})
      iex> qb.sort
      [asc: :name]
      iex> QueryBuilder.put_sort(qb, [desc: :birthdate]).sort
      [desc: :birthdate]

  IMPORTANT: sort params have the sahpe `[%{"key" => "sort_direction"}, %{"another_key" => "another_sort_direction"}]`
  that later get translated to: `[sort_direction: :key, another_sort_direction: another_key]`.
  We wanted to make the sort compatibile with URL paramaters which don't have keyword lists
  """
  @spec put_sort(t(), term()) :: t()
  def put_sort(%__MODULE__{changeset: %Changeset{} = cs} = query_builder, sort) do
    original_cs = %Changeset{cs | errors: List.keydelete(cs.errors, @sort_key, 0)}
    errors_before = length(original_cs.errors)
    modified_cs = validate_sort(original_cs, sort)
    errors_after = length(modified_cs.errors)

    if errors_before == errors_after do
      %__MODULE__{
        query_builder
        | sort: sort,
          changeset: Changeset.put_change(modified_cs, @sort_key, sort)
      }
    else
      %__MODULE__{query_builder | changeset: modified_cs}
    end
  end

  @spec put_sort_function(t(), field(), sort_fun()) :: t()
  def put_sort_function(
        %__MODULE__{sort_functions: sort_functions} = query_builder,
        field,
        sort_fun
      )
      when is_field(field) and is_sort_function(sort_fun) do
    %__MODULE__{query_builder | sort_functions: Map.put(sort_functions, field, sort_fun)}
  end

  @spec add_sort(t(), field(), sort_direction()) :: t()
  def add_sort(%__MODULE__{sort: sort} = query_builder, field, direction)
      when is_field(field) and is_sort_direction(direction) do
    param_sort = sort ++ [{direction, field}]
    put_sort(query_builder, param_sort)
  end

  @spec put_default_sort(t(), term()) :: t()
  def put_default_sort(%__MODULE__{sort: []} = query_builder, param_sort) do
    put_sort(query_builder, param_sort)
  end

  def put_default_sort(%__MODULE__{sort: _current_sort} = query_builder, _param_sort) do
    query_builder
  end

  def merge_default_sort(%__MODULE__{sort: sort} = query_builder, param_sort) do
    modified_sort = keyword_merge_without_overwriting(sort, param_sort)
    put_sort(query_builder, modified_sort)
  end

  @spec keyword_merge_without_overwriting(keyword, keyword) :: keyword
  defp keyword_merge_without_overwriting(kw0, kw1)
       when is_list(kw0) and is_list(kw1) do
    Enum.reduce(kw1, kw0, fn {v, k}, kw ->
      if List.keymember?(kw, k, 1) do
        kw
      else
        List.keystore(kw, v, 1, {v, k})
      end
    end)
  end

  @doc """
  Adds to or overwrites pagination set in params.

      iex> qb = QueryBuilder.new(Repo, User, %{"pagination" => %{"page" => "1", "page_size" => "10"}}, %{})
      ...> |> QueryBuilder.put_pagination(%{page: 2, page_size: 50})
      iex> qb.pagination
      %{page: 2, page_size: 50}
  """
  @spec put_pagination(t(), optional_pagination()) :: t()
  def put_pagination(
        %__MODULE__{changeset: %Changeset{} = cs} = query_builder,
        empty_pagination
      )
      when empty_pagination == %{} do
    modified_cs =
      cs
      |> Changeset.delete_change(@page_key)
      |> Changeset.delete_change(@page_size_key)

    %__MODULE__{query_builder | pagination: %{}, changeset: modified_cs}
  end

  def put_pagination(%__MODULE__{changeset: %Changeset{} = cs} = query_builder, %{
        page: page,
        page_size: page_size
      })
      when is_page(page) and is_page_size(page_size) do
    modified_cs =
      cs
      |> Changeset.put_change(@page_key, page)
      |> Changeset.put_change(@page_size_key, page_size)

    %__MODULE__{
      query_builder
      | pagination: %{page: page, page_size: page_size},
        changeset: modified_cs
    }
  end

  @spec put_default_pagination(t(), optional_pagination()) :: t()
  def put_default_pagination(
        %__MODULE__{pagination: pagination} = query_builder,
        %{page: page, page_size: page_size} = param_pagination
      )
      when is_page(page) and is_page_size(page_size) do
    modified_pagination = Map.merge(param_pagination, pagination)
    put_pagination(query_builder, modified_pagination)
  end

  @spec put_default_filters(t(), params()) :: t()
  def put_default_filters(
        %__MODULE__{filters: filters} = query_builder,
        %{} = param_filters
      ) do
    modified_filters = Map.merge(param_filters, filters)
    put_params(query_builder, modified_filters)
  end

  @doc """
  Adds to or overwrites filters set in params.

      iex> qb = QueryBuilder.new(Repo, User, %{"search" => "José"}, %{search: :string})
      ...> |> QueryBuilder.put_filters(%{search: "Chris"})
      iex> qb.filters
      %{search: "Chris"}
  """
  @spec put_filters(t(), filters()) :: t()
  def put_filters(%__MODULE__{filters: filters} = query_builder, %{} = param_filters) do
    modified_filters = Map.merge(filters, param_filters)
    put_params(query_builder, modified_filters)
  end

  @spec put_filter_function(t(), field(), filter_fun()) :: t()
  def put_filter_function(
        %__MODULE__{filter_functions: filter_functions} = query_builder,
        field,
        filter_fun
      )
      when is_field(field) and is_filter_function(filter_fun) do
    %__MODULE__{
      query_builder
      | filter_functions: Map.put(filter_functions, field, filter_fun)
    }
  end

  @spec query(t()) :: query()
  def query(%__MODULE__{
        base_query: base_query,
        filter_functions: filter_functions,
        filters: filters,
        sort_functions: sort_functions,
        sort: sort
      }) do
    base_query
    |> reduce_filters(filters, filter_functions)
    |> reduce_sort(sort, sort_functions)
  end

  # reduce_filters and reduce_sort look _almost_ the same, but apart from variable names,
  # there is one significant difference
  # the inner functions have parameters swapped `{field, term}` and `{sort_direction, field}`
  # we wanted to keep sort the same as in Ecto, but it didn't make sense to do the same swap for filters
  defp reduce_filters(base_query, filters, filter_functions) do
    filters
    |> Enum.reduce(base_query, fn {field, term}, acc_query ->
      filter_fun = Map.get(filter_functions, field, &noop/2)
      filter_fun.(acc_query, term)
    end)
  end

  defp reduce_sort(base_query, sort, sort_functions) do
    sort
    |> Enum.reduce(base_query, fn {sort_direction, field}, acc_query ->
      order_fun =
        Map.get(sort_functions, field, fn q, dir ->
          # A default sorting function which assumes ordering only by a singular field.
          sort_clause = [{dir, field}]
          from(x in q, order_by: ^sort_clause)
        end)

      order_fun.(acc_query, sort_direction)
    end)
  end

  defp noop(query, _), do: query

  @spec fetch(t()) :: term()
  def fetch(%__MODULE__{repo: repo, pagination: empty_pagination} = query_builder)
      when empty_pagination == %{} do
    query_builder
    |> __MODULE__.query()
    |> repo.all()
  end

  def fetch(
        %__MODULE__{
          repo: repo,
          pagination: %{page: page, page_size: page_size} = pagination
        } = query_builder
      )
      when is_page(page) and is_page_size(page_size) do
    query_builder
    |> __MODULE__.query()
    |> repo.paginate(pagination)
  end

  def has_errors?(%__MODULE__{changeset: %Changeset{} = cs}) do
    cs.valid? and cs.errors === []
  end

  def has_error?(%__MODULE__{changeset: %Changeset{errors: errors}}, field)
      when is_field(field) do
    Keyword.has_key?(errors, field)
  end

  def get_error(%__MODULE__{changeset: %Changeset{errors: errors}}, field)
      when is_field(field) do
    Keyword.get(errors, field)
  end
end
