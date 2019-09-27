defmodule QueryBuilder.SortCaster do
  @moduledoc false

  @sort_key :sort
  @sort_direction_strings ~w(asc asc_nulls_first asc_nulls_last desc desc_nulls_first desc_nulls_last)

  @spec cast_sort_clauses(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  def cast_sort_clauses(%Ecto.Changeset{} = cs, sort)
      when is_list(sort) do
    # Check if there is even one sort clause that's not a map.
    with :ok <- all_sort_clauses_are_maps(sort),
         :ok <- all_sort_clauses_are_one_key_maps(sort),
         :ok <- all_sort_clauses_have_valid_direction(sort) do
      sort_clauses =
        sort
        |> Enum.map(&(&1 |> Map.to_list() |> hd()))
        |> Enum.map(fn {k, v} -> {String.to_atom(v), String.to_atom(k)} end)

      Ecto.Changeset.put_change(cs, @sort_key, sort_clauses)
    else
      {:error, error_key, idx, msg} ->
        Ecto.Changeset.add_error(cs, @sort_key, msg, index: idx, clause: error_key)
    end
  end

  def cast_sort_clauses(%Ecto.Changeset{} = cs, _) do
    Ecto.Changeset.add_error(cs, @sort_key, "must be a list of sort clauses", clauses: :not_a_list)
  end

  defp all_sort_clauses_are_maps(sort) do
    check(sort, &(not is_map(&1)), :not_a_map, "is not a map")
  end

  defp all_sort_clauses_are_one_key_maps(sort) do
    check(sort, &(map_size(&1) != 1), :not_a_one_key_map, "is not a one-key map")
  end

  defp all_sort_clauses_have_valid_direction(sort) do
    msg = "sorting direction is not one of: #{Enum.join(@sort_direction_strings)}"

    sort
    |> extract_directions()
    |> check(&(&1 not in @sort_direction_strings), :invalid_direction, msg)
  end

  defp extract_directions(sort) do
    sort
    |> Enum.map(fn clause -> Map.values(clause) end)
    |> List.flatten()
  end

  defp check(sort, fun, key, msg) do
    idx = Enum.find_index(sort, fun)

    case idx do
      nil -> :ok
      _ -> {:error, key, idx, "clause #{idx} #{msg}"}
    end
  end
end
