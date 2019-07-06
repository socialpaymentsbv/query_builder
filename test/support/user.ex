defmodule QB.User do
  use Ecto.Schema

  schema "users" do
    field(:email, :string)
    field(:name, :string)
    field(:birthdate, :utc_datetime)

    timestamps()
  end
end
