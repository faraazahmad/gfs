defmodule Gfs.Manager.Repo.Migrations.AddPathUniqIndexToFiles do
  use Ecto.Migration

  def change do
    create unique_index(:file, [:path], name: :unique_file_path_index)
  end
end
