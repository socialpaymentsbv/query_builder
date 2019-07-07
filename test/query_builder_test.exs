defmodule QueryBuilderTest do
  use ExUnit.Case
  doctest QueryBuilder

  alias QB.{Repo, User}
  alias QueryBuilder, as: QB

  import Ecto.Query

  @valid_params %{"search" => "clubcollect", "adult" => "true", "sort" => "inserted_at:desc", "page" => "1", "page_size" => "50"}
  @valid_param_types %{search: :string, adult: :boolean}
  @invalid_params %{"search" => 1.17, "adult" => 9, "sort" => "inserted_at:desc", "page" => "1", "page_size" => "50"}

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

  test "create with valid params and valid types" do
    qb =
      QB.new(Repo, User, @valid_params, @valid_param_types)
      |> QB.add_filter_function(:search, &filter_users_by_search/2)
      |> QB.add_filter_function(:adult, &filter_users_by_adult/2)

    assert qb.repo === Repo
    assert qb.base_query === User
    assert qb.params === @valid_params
    assert qb.param_types === @valid_param_types
    assert match?(%{search: [fun_c], adult: [fun_a]} when is_function(fun_c, 2) and is_function(fun_a, 2), qb.filter_functions)
    assert %{search: "clubcollect", adult: true} === qb.filters

    expected_query =
      from(
        u in User,
        where: fragment("date_part('years', age(now(), ?)) > 18", u.birthdate),
        where: ilike(u.name, ^"%clubcollect%") or ilike(u.email, ^"%clubcollect%")
      )
    assert inspect(expected_query) == inspect(QB.query(qb))
  end

  test "create with invalid params and valid types" do
    qb = QB.new(Repo, User, @invalid_params, @valid_param_types)
    assert QB.invalid?(qb, :search)
    assert QB.invalid?(qb, :adult)
  end

  # test "query() returns a query from applied params", %{adult_user: user} do
  #   query =
  #     %{"criteria" => "ad", "adult" => "true"}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.query()

  #   assert [user] == Repo.all(query)
  # end

  # test "entries() return a list of entries", %{adult_user: user} do
  #   users =
  #     %{"criteria" => "ad", "adult" => "true"}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.entries()

  #   assert users == [user]
  # end

  # test "ordering works", %{adult_user: adult_user, juvenile_user: juvenile_user} do
  #   users =
  #     %{"order_by" => "birthdate:asc"}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.entries()

  #   assert users == [adult_user, juvenile_user]
  # end

  # test "pagination works", %{adult_user: adult_user} do
  #   users =
  #     %{"order_by" => "birthdate:asc", "page_size" => "1", "page" => "1"}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.entries()

  #   assert %Scrivener.Page{} = users
  #   assert users.entries == [adult_user]
  # end

  # test "default pagination sets page_size to 50" do
  #   query_builder =
  #     %{"order_by" => "birthdate:asc"}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.default_pagination()

  #   assert query_builder.pagination.page_size == 50
  # end

  # test "default pagination does not overwrite one from params" do
  #   query_builder =
  #     %{"order_by" => "birthdate:asc", "page" => 1, "page_size" => 20}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.default_pagination()

  #   assert query_builder.pagination.page_size == 20
  # end

  # test "paginate overwrites params" do
  #   query_builder =
  #     %{"order_by" => "birthdate:asc", "page" => 1, "page_size" => 20}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.paginate(%{"page" => 2, "page_size" => 30})

  #   assert query_builder.pagination["page_size"] == 30
  # end

  # test "default filter does not overwrite params" do
  #   query_builder =
  #     %{"criteria" => "a"}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.default_filter(%{criteria: "b", adult: true})

  #   assert query_builder.filters.criteria == "a"
  #   assert query_builder.filters.adult == true
  # end

  # test "filter overwrites params" do
  #   query_builder =
  #     %{"criteria" => "a"}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.filter(%{criteria: "b", adult: true})

  #   assert query_builder.filters.criteria == "b"
  #   assert query_builder.filters.adult == true
  # end

  # test "raises custom error for unknown keys" do
  #   assert_raise(QueryBuilder.UnknownFilter, fn ->
  #     %{}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.filter(%{wat: "?"})
  #     |> QueryBuilder.query()
  #   end)
  # end

  # test "ignores unknown param filtered by validation" do
  #   users =
  #     %{"WAT?" => "strange_value"}
  #     |> UserQueryBuilder.from_params()
  #     |> QueryBuilder.entries()

  #   assert [%User{}, %User{}] = users
  # end
end
