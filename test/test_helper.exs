ExUnit.start()
{:ok, _} = Application.ensure_all_started(:ecto_sqlite3)  # <-- starts ecto, telemetry, db_connection, exqlite
{:ok, _} = Gfs.Manager.Repo.start_link()
Ecto.Migrator.run(Gfs.Manager.Repo, :up, all: true)
