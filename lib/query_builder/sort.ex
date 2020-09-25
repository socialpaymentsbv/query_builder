defmodule QueryBuilder.Sort do
  alias Ecto.Changeset
  @moduledoc false

  @sort_key :sort
  @sort_direction_atoms ~w(asc asc_nulls_first asc_nulls_last desc desc_nulls_first desc_nulls_last)a
  @sort_direction_strings Enum.map(@sort_direction_atoms, &Atom.to_string/1)

  defguard is_sort_direction(x) when x in @sort_direction_atoms
  defguard is_sort_function(f) when is_function(f, 2)

  @spec validate_sort_clauses(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  def validate_sort_clauses(%Ecto.Changeset{} = cs, sort) when is_list(sort) do
    validation_result =
      Enum.reduce_while(sort, :ok, fn sort_clause, _ ->
        case validate_sort_clause(sort_clause) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case validation_result do
      {:error, reason} -> Changeset.add_error(cs, @sort_key, reason)
      :ok -> Changeset.put_change(cs, @sort_key, sort)
    end
  end

  defp validate_sort_clause({direction, field})
  when direction in @sort_direction_atoms and is_atom(field) do
    :ok
  end
  defp validate_sort_clause(other), do: {:error, "Sort clause must be a tuple {direction, field}, got: #{inspect(other)}"}

  @spec cast_sort_clauses(Ecto.Changeset.t(), term()) :: Ecto.Changeset.t()
  def cast_sort_clauses(%Ecto.Changeset{} = cs, sort) do
    case parse_sort_clauses(sort) do
      {:error, reason} -> Changeset.add_error(cs, @sort_key, reason)
      sort_clauses when is_list(sort_clauses) -> Changeset.put_change(cs, @sort_key, sort_clauses)
    end
  end

  defp parse_sort_clauses(sort_clauses) when is_list(sort_clauses) do
    parsed_sort_clauses =
      sort_clauses
      |> Enum.reduce_while([], fn sort_clause, acc ->
        case parse_sort_clause(sort_clause) do
          {:ok, parsed_sort_clause} -> {:cont, [parsed_sort_clause | acc]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case parsed_sort_clauses do
      {:error, reason} -> {:error, reason}
      list -> Enum.reverse(list)
    end
  end

  defp parse_sort_clauses(nil), do: []

  defp parse_sort_clauses(sort_clauses) do
    {:error, "Sort clauses must be a list of maps like [%{\"field\" => \"direction\"}], got: #{inspect(sort_clauses)}"}
  end

  defp parse_sort_clause(%{} = sort_clause) do
    case {Map.keys(sort_clause), Map.values(sort_clause)} do
      {[field], [direction]} when direction in @sort_direction_strings->
        {:ok, {String.to_existing_atom(direction), String.to_existing_atom(field)}}
      other ->
        sort_clause_error(other)
    end
  end

  defp parse_sort_clause(sort_clause), do: sort_clause_error(sort_clause)

  defp sort_clause_error(sort_clause) do
    {:error, "Sort clause must be a map %{\"field\" => \"direction\"}, got: #{inspect(sort_clause)}"}
  end
end
