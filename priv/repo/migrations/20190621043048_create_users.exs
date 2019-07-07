defmodule QB.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add(:email, :string)
      add(:name, :string)
      add(:birthdate, :utc_datetime)

      timestamps()
    end
  end
end
