defmodule QueryBuilder do
  alias QueryBuilder.Sort
  import Sort, only: [is_sort_direction: 1, is_sort_function: 1]

  @moduledoc ~S"""
  `QueryBuilder` reduces boilerplate needed to translate parameters into queries.

  ### What problem does `QueryBuilder` solve?

  While writing CRUD applications, we discovered we are performing the same tasks repeatedly for each search form:
  - validate incoming parameters
  - write functions that translate parameters into composable queries
  - compose those functions using `Enum.reduce/3`
  - write a conditional expression to use `Repo.all/2` or `Repo.paginate/2`

  `QueryBuilder` handles validation, composition and pagination, and requires only
  specifying how to translate parameters into queries.

  Example:

  ```
  defp filter_users_by_search(query, search) do
    db_search = "%#{search}%"
    from(u in query,
      where: ilike(u.name, ^db_search) or ilike(u.email, ^db_search)
    )
  end

  users =
    Repo
    |> QueryBuilder.new(User, %{"search" => "José"}, %{search: :string})
    |> QueryBuilder.put_filter_function(:search, &filter_users_by_search/2)
    |> QueryBuilder.fetch
  ```

  In the above examples, the library user specifies a focused function that
  takes a query and returns a new query based on the search criteria.
  `QueryBuilder` handles parameter validation based on specified types,
  takes the function to use it later if the search parameter is specified,
  also, fetches the result with or without pagination (based on parameters).

  The parameters resemble Phoenix parameters, but `QueryBuilder` does not depend on Phoenix.
  The param map is anything that can be turned into an `Ecto.Changeset` for validation.
  That means `QueryBuilder` is compatible with Phoenix but can be used without it.

  ### Usage guidelines

  `QueryBuilder` is based on functions instead of modules.
  In smaller projects, it can be used directly where needed, e.g. in Phoenix controllers.
  However, we've found it beneficial to use it in a separate module for each schema.

  ```
  defmodule UserQueryBuilder do
    alias User
    @param_types %{search: :string}

    def new(params) do
      Repo
      |> QueryBuilder.new(base_query(), params, @param_types)
      |> QueryBuilder.put_filter_function(:search, &filter_users_by_search/2)
    end

    defp filter_users_by_search(query, search) do
      db_search = "%#{search}%"
      from(u in query,
        where: ilike(u.name, ^db_search) or ilike(u.email, ^db_search)
      )
    end

    defp base_query(), do: User
  end

  UserQueryBuilder.new(%{"search" => "José"})
  |> QueryBuilder.fetch()
  ```

  In this way, we can reuse the same filter functions in different places,
  e.g. in UI and JSON API.
  The `UserQueryBuilder.new/1` function is an entry point returning `QueryBuilder` struct.
  In case our UI and API differs slightly, we can define multiple entry points that allow different params or have slightly different filter functions.

  Note that `base_query/0` can use joins and later filter functions
  may use all the bindings.

  ### Comparison with other libraries

  There is another library that serves similar purpose called `Ecto.Rummage`.
  `QueryBuilder` uses functions instead of modules.
  `Ecto.Rummage` uses hooks, which are modules implementing specific behaviour.
  Hooks give more safety, but we've found functions more natural to use.

  `Rummage` provides default hooks that can turn some params into queries automatically.
  E.g. params that match names of fields can become `WHERE field = value`.
  We've found it confusing for queries with joins and multiple bindings,
  so `QueryBuilder` forces writing filter functions explicitly.

  At present, we support one way to paginate, but that may be subject to change.

  ### Debugging

  If you need to debug the builder, you can do it by piping to `IO.inspect`

  ```
  Repo
  |> QueryBuilder.new(User, %{"search" => "José"}, %{search: :string})
  |> IO.inspect
  ```

  The struct presents validated params for easy debugging.

  ### Validation

  Before building queries, it is beneficial to validate incoming params.
  `QueryBuilder.new` requires passing param types. See `Ecto.Changeset.cast/4` for examples of schemaless changesets.

  If your use-case requires additional validations,
  you can pass an additional validator as the fifth parameter to `QueryBuilder.new/5`
  `t:filter_validator/0` takes `Ecto.Changeset` right after initial cast as an argument and should also return the changeset after applying validations.

  ### Strings vs Atoms

  Only initial param list allows string keys.
  `QueryBuilder` uses `Ecto.Changeset` internally so all filter and order functions expect the keys to be atoms.

  ### Default params

  Both for filtering and ordering, it is possible to modify the initial params.
  There is a family of functions starting with `put_`, `put_default` and `clear_`.
  All those functions expect atom keys as indicated in the previous section.

  `put_*` functions modify the param unconditionally setting it to the new value.
  `put_default_*` functions set the param only if it is not present.
  It is convenient for initial page loads.

  ```
  UserQueryBuilder.new(%{"search" => "José"})
  |> QueryBuilder.put_default_pagination(%{page: 1})
  ```

  This way, on initial load, when "page" is not set, it defaults to `1`.
  Later on, when the user goes to the next page, the params will be:
  `%{"search" => "José", "page" => 2}`,
  the call to `put_default_pagination` will have no effect
  because defaults don't overwrite parameter values.

  If you really want to overwrite the param, you can use `QueryBuilder.put_pagination/2`

  ### Filtering

  Filtering requires adding search param to `param_types` (without that step changeset ignores the param),
  and writing a function that handles the query.
  See the example at the top of the docs.

  ### Pagination

  Functions for setting, clearing and default pagination are similar
  to those used for filtering.
  The main differences are:
  - you don't have to specify `page` or `page_number` types in `QueryBuilder.new/4`
  - you don't specify function modifying `query`.

  ### Sorting

  Sorting is different from filtering and pagination because,
  it uses a list instead of a map. `QueryBuilder.put_sort(query_builder, [asc: :id, desc: :updated_at])`
  We can't use a map here because order matters.

  ```
  query_builder = QueryBuilder.new(Repo, User, %{"sort" => [asc: :id, desc: :updated_at]})
  ```
  """

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
  @type filter_validator :: (Ecto.Changeset.t() -> Ecto.Changeset.t())
  @type filters :: %{required(field()) => filter_value()}
  @type filter_functions :: %{required(field()) => filter_fun()}
  @type page :: pos_integer()
  @type page_size :: pos_integer()
  @type pagination :: %{page: page(), page_size: page_size()}
  @type optional_pagination :: pagination() | %{}
  @type sort_direction ::
          :asc | :asc_nulls_first | :asc_nulls_last | :desc | :desc_nulls_first | :desc_nulls_last
  @type sort_clause :: {field(), sort_direction()}
  @type sort :: [sort_clause()]
  @type sort_fun :: (query(), sort_direction() -> query())
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
      Ecto.Changeset.cast(
        {%{}, param_types},
        params,
        Map.keys(param_types)
      )
      |> filter_validator.()

    %__MODULE__{
      query_builder
      | params: params,
        changeset: modified_cs,
        filters: Ecto.Changeset.apply_changes(modified_cs)
    }
    |> cast_filters()
    |> cast_pagination()
    |> cast_sort()
  end

  @spec cast_filters(t()) :: t()
  defp cast_filters(%__MODULE__{changeset: %Ecto.Changeset{valid?: true} = cs} = query_builder) do
    filters =
      cs.changes
      |> Map.drop(@special_parameters)

    %__MODULE__{query_builder | filters: filters}
  end

  defp cast_filters(%__MODULE__{changeset: %Ecto.Changeset{valid?: false}} = query_builder) do
    query_builder
  end

  @spec cast_pagination(t()) :: t()
  defp cast_pagination(%__MODULE__{changeset: %Ecto.Changeset{valid?: true} = cs} = query_builder) do
    pagination =
      cs.changes
      |> Map.take(@pagination_keys)

    %__MODULE__{query_builder | pagination: pagination}
  end

  defp cast_pagination(%__MODULE__{changeset: %Ecto.Changeset{valid?: false}} = query_builder) do
    query_builder
  end

  @spec cast_sort(t()) :: t()
  defp cast_sort(
         %__MODULE__{changeset: %Ecto.Changeset{} = cs, params: %{"sort" => sort}} = query_builder
       ) do
    modified_cs = Sort.cast_sort_clauses(cs, sort)

    %__MODULE__{
      query_builder
      | changeset: modified_cs,
        sort: Ecto.Changeset.get_change(modified_cs, @sort_key) || []
    }
  end

  defp cast_sort(%__MODULE__{} = query_builder), do: query_builder

  @spec validate_sort(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  defp validate_sort(%Ecto.Changeset{} = cs, sort)
       when is_list(sort) do
    Sort.validate_sort_clauses(cs, sort)
  end

  defp validate_sort(%Ecto.Changeset{} = cs, _) do
    Ecto.Changeset.add_error(
      cs,
      @sort_key,
      "must be a list of sort clauses",
      clauses: :not_a_list
    )
  end

  @spec put_sort(t(), term()) :: t()
  def put_sort(%__MODULE__{changeset: %Ecto.Changeset{} = cs} = query_builder, sort) do
    original_cs = %Ecto.Changeset{cs | errors: List.keydelete(cs.errors, @sort_key, 0)}
    errors_before = length(original_cs.errors)
    modified_cs = validate_sort(original_cs, sort)
    errors_after = length(modified_cs.errors)

    if errors_before == errors_after do
      %__MODULE__{
        query_builder
        | sort: sort,
          changeset: Ecto.Changeset.put_change(modified_cs, @sort_key, sort)
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

  @spec put_pagination(t(), optional_pagination()) :: t()
  def put_pagination(
        %__MODULE__{changeset: %Ecto.Changeset{} = cs} = query_builder,
        empty_pagination
      )
      when empty_pagination == %{} do
    modified_cs =
      cs
      |> Ecto.Changeset.delete_change(@page_key)
      |> Ecto.Changeset.delete_change(@page_size_key)

    %__MODULE__{query_builder | pagination: %{}, changeset: modified_cs}
  end

  def put_pagination(%__MODULE__{changeset: %Ecto.Changeset{} = cs} = query_builder, %{
        page: page,
        page_size: page_size
      })
      when is_page(page) and is_page_size(page_size) do
    modified_cs =
      cs
      |> Ecto.Changeset.put_change(@page_key, page)
      |> Ecto.Changeset.put_change(@page_size_key, page_size)

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
  def put_default_filters(%__MODULE__{filters: filters} = query_builder, %{} = param_filters) do
    modified_filters = Map.merge(param_filters, filters)
    put_params(query_builder, modified_filters)
  end

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
    %__MODULE__{query_builder | filter_functions: Map.put(filter_functions, field, filter_fun)}
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
      order_fun = Map.get(sort_functions, field, &noop/2)
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
        %__MODULE__{repo: repo, pagination: %{page: page, page_size: page_size} = pagination} =
          query_builder
      )
      when is_page(page) and is_page_size(page_size) do
    query_builder
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
