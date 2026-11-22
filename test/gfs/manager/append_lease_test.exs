defmodule Gfs.Manager.AppendLeaseTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Gfs.Manager.Metadata
  alias Gfs.Manager.Repo
  alias Gfs.Schema
  alias Gfs.TestRuntime

  setup do
    # Repo is started in test_helper.exs (tests run via `mix test --no-start`)
    {:ok, sim} = TestRuntime.start_link(%{})
    # 3 fake chunkservers in :pg + Repo rows
    seed_chunkservers()
    %{sim: sim, runtime: sim.runtime}
  end

  test "issue -> commit -> expire -> re-issue", %{sim: sim, runtime: runtime} do
    path = "/logs/a.txt"
    {:ok, _} = Metadata.ensure_file(path)

    t0 = TestRuntime.now(sim)
    {:ok, lease} = Metadata.acquire_append_lease(path, runtime)
    assert lease.expires_at == DateTime.add(t0, 60, :second)

    :ok =
      Metadata.commit_append(lease.lease_id, lease.chunk.uniq_id, 128, lease.primary.id, runtime)

    assert get_last_chunk(path).end_byte == 127

    # Advance past TTL: row still exists, so the commit is rejected as it is expired
    TestRuntime.advance(sim, 61)

    assert {:error, :lease_expired} =
             Metadata.commit_append(
               lease.lease_id,
               lease.chunk.uniq_id,
               10,
               lease.primary.id,
               runtime
             )

    # re-issue rotates the lease row and bumps the chunk version
    {:ok, lease2} = Metadata.acquire_append_lease(path, runtime)
    assert lease2.chunk.version == lease.chunk.version + 1
    assert lease2.lease_id != lease.lease_id
  end

  defp seed_chunkservers do
    for i <- 1..3 do
      node =
        Repo.insert!(%Schema.Node{
          identifier: "cs#{i}@localhost",
          role: "chunkserver",
          http_port: 0,
          alive: true
        })

      Repo.insert!(%Schema.ChunkServer{
        node_id: node.id,
        uniq_id: "cs#{i}",
        role: "chunkserver"
      })
    end
  end

  defp get_last_chunk(path) do
    Repo.one(
      from(
        c in Schema.Chunk,
        join: f in Schema.File,
        on: c.file_id == f.id,
        where: f.path == ^path,
        order_by: [desc: c.start_byte],
        limit: 1
      )
    )
  end
end
