defmodule QueryBuilderTest do
  use ExUnit.Case
  doctest QueryBuilder

  alias QueryBuilder.{Repo, User}

  import Ecto.Query

  @valid_sort [%{"birthdate" => "desc"}, %{"inserted_at" => "asc"}]

  @valid_params %{
    "search" => "clubcollect",
    "adult" => "true",
    "sort" => @valid_sort,
    "page" => "1",
    "page_size" => "1"
  }
  @valid_params_without_pagination %{
    "search" => "clubcollect",
    "adult" => "true",
    "sort" => @valid_sort
  }
  @valid_params_without_sort %{
    "search" => "clubcollect",
    "adult" => "true",
    "page" => "1",
    "page_size" => "1"
  }
  @valid_params_with_unexpected_fields %{
    "search" => "abc",
    "adult" => "false",
    "unexpected" => "2"
  }
  @valid_param_types %{search: :string, adult: :boolean}
  @valid_param_keys Map.keys(@valid_param_types)
  @default_pagination %{page: 1, page_size: 100}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    {:ok, birthdate1, 0} = DateTime.from_iso8601("1990-01-01T23:50:07Z")
    {:ok, birthdate2, 0} = DateTime.from_iso8601("2019-01-01T23:50:07Z")

    adult_user = %User{email: "adult@clubcollect.com", name: "adult", birthdate: birthdate1}

    juvenile_user = %User{
      email: "juvenile@clubcollect.com",
      name: "juvenile",
      birthdate: birthdate2
    }

    {:ok, inserted_adult_user} = Repo.insert(adult_user)
    {:ok, inserted_juvenile_user} = Repo.insert(juvenile_user)

    [adult_user: inserted_adult_user, juvenile_user: inserted_juvenile_user]
  end

  defp filter_users_by_search(query, search) do
    db_search = "%#{search}%"

    from(u in query,
      where: ilike(u.name, ^db_search) or ilike(u.email, ^db_search)
    )
  end

  defp filter_users_by_adult(query, true) do
    from(u in query,
      where: fragment("date_part('years', age(now(), ?)) > 18", u.birthdate)
    )
  end

  defp filter_users_by_adult(query, false), do: query

  defp sort_by_birthdate(query, sort_direction) do
    from(u in query, order_by: [{^sort_direction, u.birthdate}])
  end

  defp sort_by_inserted_at(query, sort_direction) do
    from(u in query, order_by: [{^sort_direction, u.inserted_at}])
  end

  defp verify_filter_params(changeset) do
    changeset
    |> Ecto.Changeset.validate_length(:search, min: 2)
  end

  test "create with valid params and valid types, including pagination and sorting" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_filter_function(:search, &filter_users_by_search/2)
      |> QueryBuilder.put_filter_function(:adult, &filter_users_by_adult/2)

    assert Repo === query_builder.repo
    assert User === query_builder.base_query
    assert match?(%Ecto.Changeset{valid?: true, errors: []}, query_builder.changeset)
    assert @valid_params === query_builder.params
    assert @valid_param_types === Map.take(query_builder.param_types, @valid_param_keys)

    assert match?(
             %{search: fun_c, adult: fun_a} when is_function(fun_c, 2) and is_function(fun_a, 2),
             query_builder.filter_functions
           )

    assert %{search: "clubcollect", adult: true} === query_builder.filters
    assert "clubcollect" === Ecto.Changeset.get_change(query_builder.changeset, :search)
    assert true === Ecto.Changeset.get_change(query_builder.changeset, :adult)
    assert %{page: 1, page_size: 1} === query_builder.pagination
    assert [desc: :birthdate, asc: :inserted_at] === query_builder.sort

    expected_query =
      from(
        u in User,
        where: fragment("date_part('years', age(now(), ?)) > 18", u.birthdate),
        where: ilike(u.name, ^"%clubcollect%") or ilike(u.email, ^"%clubcollect%"),
        order_by: [desc: u.birthdate],
        order_by: [asc: u.inserted_at]
      )

    assert inspect(expected_query) == inspect(QueryBuilder.query(query_builder))
  end

  test "create with valid params and valid types, without pagination" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params_without_pagination, @valid_param_types)

    assert %{} === query_builder.pagination
  end

  test "create with valid params with unexpected fields" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params_with_unexpected_fields, @valid_param_types)
      |> QueryBuilder.put_filter_function(:search, &filter_users_by_search/2)

    expected_query =
      from(
        u in User,
        where: ilike(u.name, ^"%abc%") or ilike(u.email, ^"%abc%")
      )

    assert inspect(expected_query) == inspect(QueryBuilder.query(query_builder))
  end

  test "fetching correct records from database through an Ecto Repo", %{adult_user: expected_user} do
    fetched_users =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_filter_function(:search, &filter_users_by_search/2)
      |> QueryBuilder.put_filter_function(:adult, &filter_users_by_adult/2)
      |> QueryBuilder.query()
      |> Repo.all()

    assert fetched_users == [expected_user]
  end

  test "fetching correct records from database through the fetch function", %{
    adult_user: expected_user
  } do
    fetched_users =
      QueryBuilder.new(
        Repo,
        User,
        Map.drop(@valid_params, ["page", "page_size"]),
        @valid_param_types
      )
      |> QueryBuilder.put_filter_function(:search, &filter_users_by_search/2)
      |> QueryBuilder.put_filter_function(:adult, &filter_users_by_adult/2)
      |> QueryBuilder.fetch()

    assert fetched_users == [expected_user]
  end

  test "database pagination works", %{adult_user: expected_user} do
    fetched_users =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_filter_function(:search, &filter_users_by_search/2)
      |> QueryBuilder.put_filter_function(:adult, &filter_users_by_adult/2)
      |> QueryBuilder.fetch()

    assert match?(%Scrivener.Page{}, fetched_users)
    assert fetched_users.entries == [expected_user]
  end

  test "setting pagination works" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params_without_pagination, @valid_param_types)
      |> QueryBuilder.put_pagination(%{page: 3, page_size: 20})

    assert %{page: 3, page_size: 20} === query_builder.pagination
    assert 3 === Ecto.Changeset.get_change(query_builder.changeset, :page)
    assert 20 === Ecto.Changeset.get_change(query_builder.changeset, :page_size)
  end

  test "default pagination is correct when no user pagination is supplied" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params_without_pagination, @valid_param_types)
      |> QueryBuilder.put_default_pagination(@default_pagination)

    dp = @default_pagination

    assert dp == query_builder.pagination
    assert dp.page === Ecto.Changeset.get_change(query_builder.changeset, :page)
    assert dp.page_size === Ecto.Changeset.get_change(query_builder.changeset, :page_size)
  end

  test "default pagination is not applied when a user pagination is supplied" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params_without_pagination, @valid_param_types)
      |> QueryBuilder.put_pagination(%{page: 3, page_size: 20})
      |> QueryBuilder.put_default_pagination(@default_pagination)

    assert %{page: 3, page_size: 20} === query_builder.pagination
    assert 3 === Ecto.Changeset.get_change(query_builder.changeset, :page)
    assert 20 === Ecto.Changeset.get_change(query_builder.changeset, :page_size)
  end

  test "explicit changing of pagination overwrites initial parameters" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_pagination(%{page: 3, page_size: 20})

    assert %{page: 3, page_size: 20} === query_builder.pagination
    assert 3 === Ecto.Changeset.get_change(query_builder.changeset, :page)
    assert 20 === Ecto.Changeset.get_change(query_builder.changeset, :page_size)
  end

  test "default filters are correct when no user filters are supplied" do
    query_builder =
      QueryBuilder.new(Repo, User, %{}, @valid_param_types)
      |> QueryBuilder.put_default_filters(%{search: "huh?", adult: false})

    assert %{search: "huh?", adult: false} === query_builder.filters
    assert "huh?" === Ecto.Changeset.get_change(query_builder.changeset, :search)
    assert false === Ecto.Changeset.get_change(query_builder.changeset, :adult)
  end

  test "default filters are not applied when user filters are supplied" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_default_filters(%{search: "huh?", adult: false})

    assert %{search: "clubcollect", adult: true} === query_builder.filters
    assert "clubcollect" === Ecto.Changeset.get_change(query_builder.changeset, :search)
    assert true === Ecto.Changeset.get_change(query_builder.changeset, :adult)
  end

  test "explicitly set filters override defaults" do
    query_builder =
      QueryBuilder.new(Repo, User, %{}, @valid_param_types)
      |> QueryBuilder.put_default_filters(%{search: "huh?", adult: false})
      |> QueryBuilder.put_filters(%{search: "custom", adult: true})

    assert %{search: "custom", adult: true} === query_builder.filters
    assert "custom" === Ecto.Changeset.get_change(query_builder.changeset, :search)
    assert true === Ecto.Changeset.get_change(query_builder.changeset, :adult)
  end

  test "explicitly set filters override initial parameters" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_filters(%{search: "huh?", adult: false})

    assert %{search: "huh?", adult: false} === query_builder.filters
    assert "huh?" === Ecto.Changeset.get_change(query_builder.changeset, :search)
    assert false === Ecto.Changeset.get_change(query_builder.changeset, :adult)
  end

  test "passing sort clauses that are not a list is reported" do
    err =
      QueryBuilder.new(Repo, User, %{"search" => "abc", "sort" => {false, 1}}, @valid_param_types)
      |> QueryBuilder.get_error(:sort)

    assert match?({_msg, [clauses: :not_a_list]}, err)
  end

  test "passing sort clauses that are not all maps is reported" do
    err =
      QueryBuilder.new(
        Repo,
        User,
        %{
          "search" => "abc",
          "sort" => [false, %{"birthdate" => "desc!"}, %{"inserted_at" => "asc"}]
        },
        @valid_param_types
      )
      |> QueryBuilder.get_error(:sort)

    assert match?({_msg, [index: 0, clause: :not_a_map]}, err)
  end

  test "passing sort clauses that are not all one-key maps is reported" do
    err =
      QueryBuilder.new(
        Repo,
        User,
        %{"search" => "abc", "sort" => [%{"birthdate" => "desc", "inserted_at" => "asc"}]},
        @valid_param_types
      )
      |> QueryBuilder.get_error(:sort)

    assert match?({_msg, [index: 0, clause: :not_a_one_key_map]}, err)
  end

  test "passing sort clauses that have invalid sort directions is reported" do
    err =
      QueryBuilder.new(
        Repo,
        User,
        %{"search" => "abc", "sort" => [%{"birthdate" => "desc"}, %{"inserted_at" => "asc!"}]},
        @valid_param_types
      )
      |> QueryBuilder.get_error(:sort)

    assert match?({_msg, [index: 1, clause: :invalid_direction]}, err)
  end

  test "passing valid params without sort works" do
    query_builder = QueryBuilder.new(Repo, User, @valid_params_without_sort, @valid_param_types)
    assert query_builder.sort === []
  end

  test "trying to change sort with non-list is reported" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_sort(:whatever)

    assert match?(
             {_msg, [clauses: :not_a_list]},
             QueryBuilder.get_error(query_builder, :sort)
           )
  end

  test "trying to change sort with invalid direction is reported" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_sort(unknown: :inserted_at)

    assert match?(
             {_msg, [index: 0, clause: :invalid_direction]},
             QueryBuilder.get_error(query_builder, :sort)
           )
  end

  test "trying to change sort with invalid field is reported" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_sort(asc: 123)

    assert match?(
             {_msg, [index: 0, clause: :invalid_field]},
             QueryBuilder.get_error(query_builder, :sort)
           )
  end

  test "changing to a valid sort works" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_sort(asc: :id)

    assert [asc: :id] === query_builder.sort
    assert [asc: :id] === Ecto.Changeset.get_change(query_builder.changeset, :sort)
  end

  test "adding sort field works" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.add_sort(:id, :desc)

    assert [desc: :birthdate, asc: :inserted_at, desc: :id] === query_builder.sort

    assert [desc: :birthdate, asc: :inserted_at, desc: :id] ===
             Ecto.Changeset.get_change(query_builder.changeset, :sort)
  end

  test "default sort does not override parameter sort if they pertain to the same fields" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_default_sort(asc: :birthdate, desc: :inserted_at)

    assert [desc: :birthdate, asc: :inserted_at] === query_builder.sort

    assert [desc: :birthdate, asc: :inserted_at] ===
             Ecto.Changeset.get_change(query_builder.changeset, :sort)
  end

  test "default sort does not override parameter sort even if they pertain to different fields" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.put_default_sort(asc: :email)

    assert [desc: :birthdate, asc: :inserted_at] === query_builder.sort

    assert [desc: :birthdate, asc: :inserted_at] ===
             Ecto.Changeset.get_change(query_builder.changeset, :sort)
  end

  test "default sort gets merged with parameter sort if they pertain to different fields" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params, @valid_param_types)
      |> QueryBuilder.merge_default_sort(asc: :id, desc: :updated_at)

    assert [desc: :birthdate, asc: :inserted_at, asc: :id, desc: :updated_at] ===
             query_builder.sort

    assert [desc: :birthdate, asc: :inserted_at, asc: :id, desc: :updated_at] ===
             Ecto.Changeset.get_change(query_builder.changeset, :sort)
  end

  test "default sort gets unconditionally applied if parameters contained no sort" do
    query_builder =
      QueryBuilder.new(Repo, User, @valid_params_without_sort, @valid_param_types)
      |> QueryBuilder.put_default_sort(asc: :id, desc: :updated_at)

    assert [asc: :id, desc: :updated_at] === query_builder.sort

    assert [asc: :id, desc: :updated_at] ===
             Ecto.Changeset.get_change(query_builder.changeset, :sort)
  end

  test "reports errors from custom validations" do
    err =
      QueryBuilder.new(
        Repo,
        User,
        %{"search" => "a"},
        @valid_param_types,
        &verify_filter_params/1
      )
      |> QueryBuilder.get_error(:search)

    assert match?({_msg, [count: 2, validation: :length, kind: :min, type: :string]}, err)
  end
end
