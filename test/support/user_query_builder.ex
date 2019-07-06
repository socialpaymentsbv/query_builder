defmodule UserQueryBuilder do
  import Ecto.Query
  alias QB.User

  def from_params(params) do
    filter_param_types = %{criteria: :string, adult: :boolean}

    params
    |> QueryBuilder.from_params(filter_param_types)
    |> QueryBuilder.set_repo(QB.Repo)
    |> QueryBuilder.set_base_query(base_query())
    |> QueryBuilder.set_filter_function(&apply_filter_term_to_query/3)
    |> QueryBuilder.set_sort_function(&apply_sort_term_to_query/3)
  end

  defp base_query() do
    User
  end

  defp apply_filter_term_to_query(query, :criteria, criteria) do
    db_criteria = "%#{criteria}%"

    from(u in query,
      where: ilike(u.name, ^db_criteria) or ilike(u.email, ^db_criteria)
    )
  end

  defp apply_filter_term_to_query(query, :adult, true) do
    from(u in query,
      where: fragment("date_part('years', age(now(), ?)) > 18", u.birthdate)
    )
  end

  defp apply_filter_term_to_query(query, :adult, _) do
    query
  end

  defp apply_sort_term_to_query(query, :birthdate, direction) do
    from(u in query,
      order_by: [{^direction, u.birthdate}]
    )
  end
end
