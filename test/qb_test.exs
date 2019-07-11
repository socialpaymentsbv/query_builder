defmodule QBTest do
  use ExUnit.Case
  doctest QB

  alias QB.{Repo, User}

  import Ecto.Query

  @valid_sort [%{"birthdate" => "desc"}, %{"inserted_at" => "asc"}]

  @valid_params %{"search" => "clubcollect", "adult" => "true", "sort" => @valid_sort, "page" => "1", "page_size" => "1"}
  @valid_params_without_pagination %{"search" => "clubcollect", "adult" => "true", "sort" => @valid_sort}
  @valid_params_with_unexpected_fields %{"search" => "abc", "adult" => "false", "unexpected" => "2"}
  @valid_param_types %{search: :string, adult: :boolean}
  @valid_param_keys Map.keys(@valid_param_types)

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

  test "create with valid params and valid types, including pagination and sorting" do
    qb =
      QB.new(Repo, User, @valid_params, @valid_param_types)
      |> QB.put_filter_function(:search, &filter_users_by_search/2)
      |> QB.put_filter_function(:adult, &filter_users_by_adult/2)

    assert Repo === qb.repo
    assert User === qb.base_query
    assert match?(%Ecto.Changeset{valid?: true, errors: []}, qb.changeset)
    assert @valid_params === qb.params
    assert @valid_param_types === Map.take(qb.param_types, @valid_param_keys)
    assert match?(%{search: fun_c, adult: fun_a} when is_function(fun_c, 2) and is_function(fun_a, 2), qb.filter_functions)
    assert %{search: "clubcollect", adult: true} === qb.filters
    assert %{page: 1, page_size: 1} === qb.pagination
    assert [desc: :birthdate, asc: :inserted_at] === qb.sort

    expected_query =
      from(
        u in User,
        where: fragment("date_part('years', age(now(), ?)) > 18", u.birthdate),
        where: ilike(u.name, ^"%clubcollect%") or ilike(u.email, ^"%clubcollect%"),
        order_by: [desc: u.birthdate, asc: u.inserted_at]
      )
    assert inspect(expected_query) == inspect(QB.query(qb))
  end

  test "create with valid params and valid types, without pagination" do
    qb =
      QB.new(Repo, User, @valid_params_without_pagination, @valid_param_types)

    assert %{} === qb.pagination
  end

  test "create with valid params with unexpected fields" do
    qb =
      QB.new(Repo, User, @valid_params_with_unexpected_fields, @valid_param_types)
      |> QB.put_filter_function(:search, &filter_users_by_search/2)

    expected_query =
      from(
        u in User,
        where: ilike(u.name, ^"%abc%") or ilike(u.email, ^"%abc%")
      )
    assert inspect(expected_query) == inspect(QB.query(qb))
  end

  test "removing filter function works" do
    qb =
      QB.new(Repo, User, @valid_params, @valid_param_types)
      |> QB.put_filter_function(:search, &filter_users_by_search/2)
      |> QB.put_filter_function(:adult, &filter_users_by_adult/2)
      |> QB.remove_filter_function(:search)

    assert match?(%{adult: fun_a} when is_function(fun_a, 2), qb.filter_functions)
  end

  test "fetching correct records from database through an Ecto Repo", %{adult_user: expected_user} do
    fetched_users =
      QB.new(Repo, User, @valid_params, @valid_param_types)
      |> QB.put_filter_function(:search, &filter_users_by_search/2)
      |> QB.put_filter_function(:adult, &filter_users_by_adult/2)
      |> QB.query()
      |> Repo.all()

    assert fetched_users == [expected_user]
  end

  test "fetching correct records from database through the fetch function", %{adult_user: expected_user} do
    fetched_users =
      QB.new(Repo, User, @valid_params, @valid_param_types)
      |> QB.put_filter_function(:search, &filter_users_by_search/2)
      |> QB.put_filter_function(:adult, &filter_users_by_adult/2)
      |> QB.remove_pagination()
      |> QB.fetch()

    assert fetched_users == [expected_user]
  end

  test "database pagination works", %{adult_user: expected_user} do
    fetched_users =
      QB.new(Repo, User, @valid_params, @valid_param_types)
      |> QB.put_filter_function(:search, &filter_users_by_search/2)
      |> QB.put_filter_function(:adult, &filter_users_by_adult/2)
      |> QB.fetch()

    assert match?(%Scrivener.Page{}, fetched_users)
    assert fetched_users.entries == [expected_user]
  end

  test "removing pagination works" do
    qb =
      QB.new(Repo, User, @valid_params, @valid_param_types)
      |> QB.remove_pagination()

    assert %{} === qb.pagination
  end

  test "setting pagination works" do
    qb =
      QB.new(Repo, User, @valid_params_without_pagination, @valid_param_types)
      |> QB.put_pagination(%{page: 3, page_size: 20})

    assert %{page: 3, page_size: 20} === qb.pagination
  end

  test "default pagination is correct when no user pagination is supplied" do
    qb =
      QB.new(Repo, User, @valid_params_without_pagination, @valid_param_types)
      |> QB.maybe_put_default_pagination(QB.default_pagination())

    assert QB.default_pagination() == qb.pagination
  end

  test "default pagination is not applied when a user pagination is supplied" do
    qb =
      QB.new(Repo, User, @valid_params_without_pagination, @valid_param_types)
      |> QB.put_pagination(%{page: 3, page_size: 20})
      |> QB.maybe_put_default_pagination(QB.default_pagination())

    assert %{page: 3, page_size: 20} === qb.pagination
  end

  test "explicit changing of pagination overwrites initial parameters" do
    qb =
      QB.new(Repo, User, @valid_params, @valid_param_types)
      |> QB.put_pagination(%{page: 3, page_size: 20})

    assert %{page: 3, page_size: 20} === qb.pagination
  end

  test "default filters are correct when no user filters are supplied" do
    qb =
      QB.new(Repo, User, %{}, @valid_param_types)
      |> QB.maybe_put_default_filters(%{search: "huh?", adult: false})

    assert %{search: "huh?", adult: false} === qb.filters
  end

  test "default filters are not applied when user filters are supplied" do
    qb =
      QB.new(Repo, User, @valid_params, @valid_param_types)
      |> QB.maybe_put_default_filters(%{search: "huh?", adult: false})

    assert %{search: "clubcollect", adult: true} === qb.filters
  end

  test "explicitly set filters override defaults" do
    qb =
      QB.new(Repo, User, %{}, @valid_param_types)
      |> QB.maybe_put_default_filters(%{search: "huh?", adult: false})
      |> QB.put_filters(%{search: "custom", adult: true})

    assert %{search: "custom", adult: true} === qb.filters
  end

  test "explicitly set filters override initial parameters" do
    qb =
      QB.new(Repo, User, @valid_params, @valid_param_types)
      |> QB.put_filters(%{search: "huh?", adult: false})

    assert %{search: "huh?", adult: false} === qb.filters
  end

  test "passing sort clauses that are not a list is reported" do
    err =
      QB.new(Repo, User, %{"search" => "abc", "sort" => {false, 1}}, @valid_param_types)
      |> QB.get_error(:sort)

    assert match?({_msg, [clauses: :not_a_list]}, err)
  end

  test "passing sort clauses that are not all maps is reported" do
    err =
      QB.new(Repo, User, %{"search" => "abc", "sort" => [false, %{"birthdate" => "desc!"}, %{"inserted_at" => "asc"}]}, @valid_param_types)
      |> QB.get_error(:sort)

    assert match?({_msg, [index: 0, clause: :not_a_map]}, err)
  end

  test "passing sort clauses that are not all one-key maps is reported" do
    err =
      QB.new(Repo, User, %{"search" => "abc", "sort" => [%{"birthdate" => "desc", "inserted_at" => "asc"}]}, @valid_param_types)
      |> QB.get_error(:sort)

    assert match?({_msg, [index: 0, clause: :not_a_one_key_map]}, err)
  end

  test "passing sort clauses that have invalid sort directions is reported" do
    err =
      QB.new(Repo, User, %{"search" => "abc", "sort" => [%{"birthdate" => "desc"}, %{"inserted_at" => "asc!"}]}, @valid_param_types)
      |> QB.get_error(:sort)

    assert match?({_msg, [index: 1, clause: :invalid_direction]}, err)
  end

  test "passing valid params without sort works" do
    qb = QB.new(Repo, User, %{"search" => "abc"}, @valid_param_types)
    assert qb.sort === []
  end
end
