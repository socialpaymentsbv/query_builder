defmodule QB do
  @moduledoc ~S"""
  `QB` reduces boilerplate needed to translate parameters into queries.

  ### What problem does `QB` solve?

  While writing CRUD applications we discovered we are performing the same tasks repeatedly for each search form:
  a) validate incoming parameters
  b) write functions that translate parameters into composable queries
  c) compose those functions using `Enum.reduce/3`
  d) write a conditional expression to use `Repo.all/2` or `Repo.paginate/2`

  `QB` handles validation, composition and pagination, and requires only
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
    |> QB.new(User, %{"search" => "José"}, %{search: :string})
    |> QB.put_filter_function(:search, &filter_users_by_search/2)
    |> QB.fetch
  ```

  In above examples the library user specifies a focused function that
  takes query and returns a new query based on the search criteria.
  `QB` handles parameter validation based on specified types,
  takes the function to later use it if search parameter is specified,
  and fetches the result with or without pagination (based on parameters).

  The parameters resemble Phoenix parameters but `QB` does not depend on Phoenix.
  The param map is anything that can be turned into an `Ecto.Changeset` for validation.
  That means `QB` is compatible with Phoenix but can be used without it.

  ### Usage guidelines

  `QB` is based on functions instead of modules.
  In smaller projects it can be used directly where needed e.g. in Phoenix controllers.
  However, we've found it beneficial to use it in a separate module for each schema.

  ```
  defmodule UserQueryBuilder do
    alias User
    @param_types %{search: :string}

    def new(params) do
      Repo
      |> QB.new(base_query(), params, @param_types)
      |> QB.put_filter_function(:search, &filter_users_by_search/2)
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
  |> QB.fetch()
  ```

  In this way, we can reuse the same filter functions in different places,
  e.g. in UI and JSON API.
  The `UserQueryBuilder.new/1` function is an entry point returning `QB` struct.
  In case our UI and API differs slightly, we can define multiple entry points that allow different params or have slightly different filter functions.

  Note that `base_query/0` can use joins and later filter functions
  may use all the bindings.

  ### Comparison with other libraries

  There is another library that servers similar purpose called `Ecto.Rummage`.
  `QB` uses functions instead of modules.
  `Ecto.Rummage` uses hooks which are modules implementing specific behaviour.
  Hooks give more safety but we've found functions easier to use.

  `Rummage` provides default hooks that can turn some params into queries automatically.
  E.g. params that match names of fields can become `WHERE field = value`.
  We've found it confusing for queries with joins and multiple bindings,
  so `QB` forces writing filter functions explicitly.

  At present we support one way to paginate but that may be subject to change.

  ### Debugging

  If you need to debug the builder, you can do it by piping to `IO.inspect`

  ```
  Repo
  |> QB.new(User, %{"search" => "José"}, %{search: :string})
  |> IO.inspect
  ```

  The struct presents validated params for easy debugging.
  """

  import Ecto.Query

  @default_pagination %{page: 1, page_size: 50}

  @pagination_param_types %{page: :integer, page_size: :integer}
  @page_parameter "page"
  @page_size_parameter "page_size"
  @page_key :page
  @page_size_key :page_size
  @pagination_parameters [@page_parameter, @page_size_parameter]

  @sort_param_types %{sort: {:array, {:map, :string}}}
  @sort_key :sort
  @sort_parameter "sort"
  @sort_parameters [@sort_parameter]
  @sort_direction_atoms ~w(asc asc_nulls_first asc_nulls_last desc desc_nulls_first desc_nulls_last)a
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

  defguard is_module(m) when is_atom(m)
  defguard is_repo(r) when is_module(r)

  # we cannot check more strictly since there is no way to check if a struct implements the `Ecto.Queryable` protocol.
  defguard is_query(_q) when true
  defguard is_field(x) when is_atom(x)
  defguard is_params(p) when is_map(p)
  defguard is_param_types(p) when is_map(p)
  defguard is_filter_value(_x) when true
  defguard is_filter_function(f) when is_function(f, 2)
  defguard is_filter_validator(f) when is_function(f, 1)
  defguard is_pagination(p) when is_nil(p) or (is_map(p) and map_size(p) == 2)
  defguard is_page(n) when is_integer(n) and n > 0
  defguard is_page_size(n) when is_integer(n) and n > 0
  defguard is_sort_direction(x) when x in @sort_direction_atoms

  @enforce_keys [:repo, :base_query, :params, :param_types]
  defstruct repo: nil,
            base_query: nil,
            params: %{},
            param_types: %{},
            filters: %{},
            filter_functions: %{},
            pagination: %{},
            sort: [],
            changeset: nil

  @spec default_pagination() :: pagination()
  def default_pagination(), do: @default_pagination

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
  def put_params(%__MODULE__{param_types: param_types} = qb, params, filter_validator \\ & &1)
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
      qb
      | params: params,
        changeset: modified_cs,
        filters: Ecto.Changeset.apply_changes(modified_cs)
    }
    |> cast_filters()
    |> cast_pagination()
    |> cast_sort()
  end

  @spec cast_filters(t()) :: t()
  defp cast_filters(
         %__MODULE__{changeset: %Ecto.Changeset{valid?: true} = cs, params: params} = qb
       ) do
    filters =
      params
      |> Map.drop(@special_parameters)
      |> Enum.map(fn {key, _} ->
        k = if is_binary(key), do: String.to_atom(key), else: key
        {k, Ecto.Changeset.get_change(cs, k)}
      end)
      |> Map.new()

    %__MODULE__{qb | filters: filters}
  end

  defp cast_filters(%__MODULE__{changeset: %Ecto.Changeset{valid?: false}} = qb) do
    qb
  end

  @spec cast_pagination(t()) :: t()
  defp cast_pagination(
         %__MODULE__{changeset: %Ecto.Changeset{valid?: true} = cs, params: params} = qb
       ) do
    pagination =
      params
      |> Map.take(@pagination_parameters)
      |> Enum.map(fn {key, _} ->
        k = String.to_atom(key)
        {k, Ecto.Changeset.get_change(cs, k)}
      end)
      |> Map.new()

    %__MODULE__{qb | pagination: pagination}
  end

  defp cast_pagination(%__MODULE__{changeset: %Ecto.Changeset{valid?: false}} = qb) do
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
        index: idx_not_map,
        clause: :not_a_map
      )
    else
      # Check if there is even one sort clause that's not a single-keyed map.
      idx_not_one_key_map = Enum.find_index(sort, &(map_size(&1) != 1))

      if not is_nil(idx_not_one_key_map) do
        Ecto.Changeset.add_error(
          cs,
          @sort_key,
          "clause #{idx_not_one_key_map} is not a one-key map",
          index: idx_not_one_key_map,
          clause: :not_a_one_key_map
        )
      else
        # Check if there are sort direction clauses that are not in the
        # expected list of valid values by Ecto.
        idx_invalid_direction =
          Enum.find_index(sort, fn clause ->
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
            "clause #{idx_invalid_direction} sorting direction is not one of: #{
              Enum.join(@sort_direction_strings, ", ")
            }",
            index: idx_invalid_direction,
            clause: :invalid_direction
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
    Ecto.Changeset.add_error(cs, @sort_key, "must be a list of sort clauses", clauses: :not_a_list)
  end

  @spec cast_sort(t()) :: t()
  defp cast_sort(%__MODULE__{changeset: %Ecto.Changeset{} = cs, params: %{"sort" => sort}} = qb) do
    modified_cs = cast_sort_clauses(cs, sort)

    %__MODULE__{
      qb
      | changeset: modified_cs,
        sort: Ecto.Changeset.get_change(modified_cs, @sort_key) || []
    }
  end

  defp cast_sort(%__MODULE__{} = qb), do: qb

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

  @spec validate_sort(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  defp validate_sort(%Ecto.Changeset{} = cs, sort)
       when is_list(sort) do
    idx_invalid_direction =
      Enum.find_index(sort, fn {direction, _field} ->
        direction not in @sort_direction_atoms
      end)

    if not is_nil(idx_invalid_direction) do
      Ecto.Changeset.add_error(
        cs,
        @sort_key,
        "clause #{idx_invalid_direction} sorting direction is not one of: #{
          Enum.join(@sort_direction_strings, ", ")
        }",
        index: idx_invalid_direction,
        clause: :invalid_direction
      )
    else
      idx_invalid_field =
        Enum.find_index(sort, fn {_direction, field} ->
          not (is_binary(field) or is_atom(field))
        end)

      if not is_nil(idx_invalid_field) do
        Ecto.Changeset.add_error(
          cs,
          @sort_key,
          "clause #{idx_invalid_field} sorting field is not a string or atom",
          index: idx_invalid_field,
          clause: :invalid_field
        )
      else
        cs
      end
    end
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
  def put_sort(%__MODULE__{changeset: %Ecto.Changeset{} = cs} = qb, sort) do
    original_cs = %Ecto.Changeset{cs | errors: List.keydelete(cs.errors, @sort_key, 0)}
    errors_before = length(original_cs.errors)
    modified_cs = validate_sort(original_cs, sort)
    errors_after = length(modified_cs.errors)

    if errors_before == errors_after do
      %__MODULE__{
        qb
        | sort: sort,
          changeset: Ecto.Changeset.put_change(modified_cs, @sort_key, sort)
      }
    else
      %__MODULE__{qb | changeset: modified_cs}
    end
  end

  @spec clear_sort(t()) :: t()
  def clear_sort(%__MODULE__{changeset: %Ecto.Changeset{} = cs} = qb) do
    %__MODULE__{qb | sort: [], changeset: Ecto.Changeset.delete_change(cs, @sort_key)}
  end

  @spec remove_sort(t(), field()) :: t()
  def remove_sort(%__MODULE__{sort: sort} = qb, field)
      when is_field(field) do
    param_sort = List.keydelete(sort, field, 1)
    put_sort(qb, param_sort)
  end

  @spec add_sort(t(), field(), sort_direction()) :: t()
  def add_sort(%__MODULE__{sort: sort} = qb, field, direction)
      when is_field(field) and is_sort_direction(direction) do
    param_sort = sort ++ [{direction, field}]
    put_sort(qb, param_sort)
  end

  @spec put_default_sort(t(), term()) :: t()
  def put_default_sort(%__MODULE__{sort: []} = qb, param_sort) do
    put_sort(qb, param_sort)
  end

  def put_default_sort(%__MODULE__{sort: _current_sort} = qb, _param_sort) do
    qb
  end

  def merge_default_sort(%__MODULE__{sort: sort} = qb, param_sort) do
    modified_sort = keyword_merge_without_overwriting(sort, param_sort)
    put_sort(qb, modified_sort)
  end

  @spec clear_pagination(t()) :: t()
  def clear_pagination(%__MODULE__{} = qb) do
    put_pagination(qb, %{})
  end

  @spec put_pagination(t(), optional_pagination()) :: t()
  def put_pagination(%__MODULE__{changeset: %Ecto.Changeset{} = cs} = qb, empty_pagination)
      when empty_pagination == %{} do
    modified_cs =
      cs
      |> Ecto.Changeset.delete_change(@page_key)
      |> Ecto.Changeset.delete_change(@page_size_key)

    %__MODULE__{qb | pagination: %{}, changeset: modified_cs}
  end

  def put_pagination(%__MODULE__{changeset: %Ecto.Changeset{} = cs} = qb, %{
        page: page,
        page_size: page_size
      })
      when is_page(page) and is_page_size(page_size) do
    modified_cs =
      cs
      |> Ecto.Changeset.put_change(@page_key, page)
      |> Ecto.Changeset.put_change(@page_size_key, page_size)

    %__MODULE__{qb | pagination: %{page: page, page_size: page_size}, changeset: modified_cs}
  end

  @spec put_default_pagination(t(), optional_pagination()) :: t()
  def put_default_pagination(
        %__MODULE__{pagination: pagination} = qb,
        %{page: page, page_size: page_size} = param_pagination
      )
      when is_page(page) and is_page_size(page_size) do
    modified_pagination = Map.merge(param_pagination, pagination)
    put_pagination(qb, modified_pagination)
  end

  @spec put_default_filters(t(), params()) :: t()
  def put_default_filters(%__MODULE__{filters: filters} = qb, %{} = param_filters) do
    modified_filters = Map.merge(param_filters, filters)
    put_params(qb, modified_filters)
  end

  @spec put_filters(t(), filters()) :: t()
  def put_filters(%__MODULE__{filters: filters} = qb, %{} = param_filters) do
    modified_filters = Map.merge(filters, param_filters)
    put_params(qb, modified_filters)
  end

  @spec put_filter_function(t(), field(), filter_fun()) :: t()
  def put_filter_function(%__MODULE__{filter_functions: filter_functions} = qb, field, filter_fun)
      when is_field(field) and is_filter_function(filter_fun) do
    %__MODULE__{qb | filter_functions: Map.put(filter_functions, field, filter_fun)}
  end

  @spec remove_filter_function(t(), field()) :: t()
  def remove_filter_function(%__MODULE__{filter_functions: filter_functions} = qb, field)
      when is_field(field) do
    %__MODULE__{qb | filter_functions: Map.drop(filter_functions, [field])}
  end

  @spec query(t()) :: query()
  def query(
        %__MODULE__{base_query: base_query, filter_functions: filter_functions, sort: sort} = qb
      ) do
    q =
      Enum.reduce(filter_functions, base_query, fn {field, filter_fun}, acc_query ->
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

  def fetch(
        %__MODULE__{repo: repo, pagination: %{page: page, page_size: page_size} = pagination} = qb
      )
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
