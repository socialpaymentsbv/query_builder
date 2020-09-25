<!-- MDOC !-->

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

In the above examples, the library user specifies a focused function that
takes a query and returns a new query based on the search criteria.
`QueryBuilder` handles parameter validation based on specified types,
takes the function to use it later if the search parameter is specified,
also, fetches the result with or without pagination (based on parameters).

The parameters resemble Phoenix parameters, but `QueryBuilder` does not depend on Phoenix.
The param map is anything that can be turned into an `Changeset` for validation.
That means `QueryBuilder` is compatible with Phoenix but can be used without it.

### Usage guidelines

`QueryBuilder` is based on functions instead of modules.
In smaller projects, it can be used directly where needed, e.g. in Phoenix controllers.
However, we've found it beneficial to use it in a separate module for each schema.

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

If you need to debug the builder, you can do it by inspecting fields or piping `QueryBuilder` struct to `IO.inspect`

    iex> user_query_builder = QueryBuilder.new(Repo, User, %{"search" => "José"}, %{search: :string})
    iex> user_query_builder.filters
    %{search: "José"}
    iex> user_query_builder.params
    %{"search" => "José"}

The struct presents validated params for easy debugging.

### Validation

Before building queries, it is beneficial to validate incoming params.
`QueryBuilder.new` requires passing param types. See `Changeset.cast/4` for examples of schemaless changesets.

If your use-case requires additional validations,
you can pass an additional validator as the fifth parameter to `QueryBuilder.new/5`
`t:filter_validator/0` takes `Changeset` right after initial cast as an argument and should also return the changeset after applying validations.

### Strings vs Atoms

Only initial param list allows string keys.
`QueryBuilder` uses `Changeset` internally so all filter and order functions expect the keys to be atoms.

### Default params

Both for filtering and ordering, it is possible to modify the initial params.
There is a family of functions starting with `put_`, `put_default` and `clear_`.
All those functions expect atom keys as indicated in the previous section.

`put_*` functions modify the param unconditionally setting it to the new value.
`put_default_*` functions set the param only if it is not present.
It is convenient for initial page loads.

    UserQueryBuilder.new(%{"search" => "José"})
    |> QueryBuilder.put_default_pagination(%{page: 1})

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

    iex> QueryBuilder.new(Repo, User, %{"sort" => [%{"id" => "asc"}, %{"updated_at" => "desc"}]}, %{}).sort
    [asc: :id, desc: :updated_at]


### Errors

If the parameters don't match specified types, we get errors inside changeset.

    iex> QueryBuilder.new(Repo, User, %{"sort" => [%{"id" => "asc", "updated_at" => "desc"}]}, %{}).changeset.errors
    [sort: {"Sort clause must be a map %{\"field\" => \"direction\"}, got: {[\"id\", \"updated_at\"], [\"asc\", \"desc\"]}", []}]
<!-- MDOC !-->
