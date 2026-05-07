defmodule Gfs.Manager.Metadata do
  @moduledoc """
  Transport-neutral metadata service.

  Holds *all* business logic for the manager — lease issuance, commit,
  renew, file creation, chunk allocation. Both the HTTP edge
  (`Gfs.Manager.RestApi`) and BEAM-internal callers (chunkservers via
  `:erpc.call/4`) call into this module so there is exactly one
  implementation per operation.
  """

  import Ecto.Query

  alias Gfs.Manager.Repo
  alias Gfs.Schema

  @replication_limit 3
  @min_replicas_for_write 1
  @lease_ttl_seconds 60
  @chunk_size 64 * 1024 * 1024

  @type replica_ref :: %{
          id: integer(),
          uniq_id: binary(),
          node: node(),
          # http_port + host kept for backward-compat with the existing
          # HTTP-based gfs_client; for east-west traffic we only use :node.
          http_port: integer() | nil,
          host: binary()
        }

  @type lease_response :: %{
          lease_id: binary(),
          expires_at: DateTime.t(),
          chunk: %{
            uniq_id: binary(),
            version: integer(),
            start_byte: integer(),
            end_byte: integer()
          },
          primary: replica_ref(),
          secondaries: [replica_ref()],
          manager_node: node()
        }

  ## Public API ##

  @doc """
  Make sure a `Gfs.Schema.File` exists for `path` and that there is at
  least one chunk allocated for it. Returns the file id.

  This is the unified entry point for "I want to write to a file"
  """
  @spec ensure_file(binary()) ::
          {:ok, %{file_id: integer(), chunk_uniq_id: binary()}}
          | {:error, :invalid_path | :no_alive_replicas | term()}
  def ensure_file(path) when is_binary(path) and path != "" do
    case Repo.get_by(Schema.File, path: path) do
      nil ->
        # If file not found, create file and first chunk with replicas
        with {:ok, replicas} <- pick_replicas_for_new_chunk() do
          Repo.transaction(fn ->
            file = Repo.insert!(%Schema.File{path: path})
            chunk_uniq_id = insert_chunk_row(file.id, 0, replicas)
            %{file_id: file.id, chunk_uniq_id: chunk_uniq_id}
          end)
        end

      # Else if file record is found, return file id and latest chunk uid
      file ->
        case last_chunk_for_file(file.id) do
          :no_chunk ->
            with {:ok, replicas} <- pick_replicas_for_new_chunk() do
              chunk_uniq_id = insert_chunk_row(file.id, 0, replicas)
              {:ok, %{file_id: file.id, chunk_uniq_id: chunk_uniq_id}}
            end

          %Schema.Chunk{uniq_id: uid} ->
            {:ok, %{file_id: file.id, chunk_uniq_id: uid}}
        end
    end
  end

  def ensure_file(_), do: {:error, :invalid_path}

  @doc """
  Hand the caller a chunk it can append `byte_count` bytes to.

  If the file's current last chunk still has at least `byte_count`
  bytes of free capacity (chunk capacity = `@chunk_size`), that chunk
  is returned unchanged together with its currently-alive replicas.
  Otherwise — or if the file has no chunk yet — a brand-new chunk is
  allocated on freshly picked replicas (the `@replication_limit`
  chunkservers with the fewest chunks currently assigned) and
  returned.
  """
  @spec acquire_writable_chunk(binary(), non_neg_integer()) ::
          {:ok, %{chunk: map(), replicas: [replica_ref()]}}
          | {:error,
             :file_not_found
             | :invalid_path
             | :bytes_too_large
             | :no_alive_replicas
             | term()}
  def acquire_writable_chunk(path, byte_count)
      when is_binary(path) and is_integer(byte_count) and byte_count >= 0 do
    cond do
      byte_count > @chunk_size ->
        {:error, :bytes_too_large}

      true ->
        case Repo.get_by(Schema.File, path: path) do
          nil ->
            {:error, :file_not_found}

          file ->
            case last_chunk_for_file(file.id) do
              :no_chunk ->
                allocate_new_chunk(file, 0)

              %Schema.Chunk{} = chunk ->
                used = chunk.end_byte - chunk.start_byte + 1
                remaining = @chunk_size - used

                if remaining >= byte_count do
                  replicas = alive_replicas(chunk.uniq_id)

                  {:ok,
                   %{
                     chunk: %{
                       uniq_id: chunk.uniq_id,
                       version: chunk.version,
                       start_byte: chunk.start_byte,
                       end_byte: chunk.end_byte,
                       file_id: file.id
                     },
                     replicas: Enum.map(replicas, &format_replica/1)
                   }}
                else
                  allocate_new_chunk(file, chunk.end_byte + 1)
                end
            end
        end
    end
  end

  def acquire_writable_chunk(_, _), do: {:error, :invalid_path}

  defp allocate_new_chunk(file, start_byte) do
    with {:ok, replicas} <- pick_replicas_for_new_chunk() do
      chunk_uniq_id = insert_chunk_row(file.id, start_byte, replicas)

      {:ok,
       %{
         chunk: %{
           uniq_id: chunk_uniq_id,
           version: 0,
           start_byte: start_byte,
           end_byte: start_byte - 1,
           file_id: file.id
         },
         replicas: Enum.map(replicas, &format_replica/1)
       }}
    end
  end

  @doc """
  Get an existing active lease for the file's last chunk, or issue a
  new one.
  """
  @spec acquire_append_lease(binary()) ::
          {:ok, lease_response()}
          | {:error,
             :file_not_found
             | :chunk_not_found
             | :invalid_path
             | :conflict
             | :no_alive_replicas}
  def acquire_append_lease(path) when is_binary(path) do
    with %Schema.File{} = file <- Repo.get_by(Schema.File, path: path) || :file_not_found,
         %Schema.Chunk{} = chunk <- last_chunk_for_file(file.id),
         replicas when length(replicas) >= @min_replicas_for_write <-
           alive_replicas(chunk.uniq_id) do
      maybe_warn_under_replicated(chunk.uniq_id, replicas)
      get_or_issue_lease(%{file: file, chunk: chunk, replicas: replicas})
    else
      :file_not_found -> {:error, :file_not_found}
      :no_chunk -> {:error, :chunk_not_found}
      replicas when is_list(replicas) -> {:error, :no_alive_replicas}
    end
  end

  @doc "Renew an active lease."
  @spec renew_lease(binary(), integer()) ::
          {:ok, %{lease_id: binary(), expires_at: DateTime.t()}}
          | {:error, :lease_not_active}
  def renew_lease(lease_id, primary_chunk_server_id) do
    now = DateTime.utc_now()
    new_expires_at = DateTime.add(now, @lease_ttl_seconds, :second)

    {count, _} =
      Repo.update_all(
        from(l in Schema.Lease,
          where:
            l.lease_id == ^lease_id and
              l.primary_chunk_server_id == ^primary_chunk_server_id and
              is_nil(l.revoked_at) and
              l.expires_at > ^now
        ),
        set: [expires_at: new_expires_at, updated_at: now]
      )

    case count do
      1 -> {:ok, %{lease_id: lease_id, expires_at: new_expires_at}}
      _ -> {:error, :lease_not_active}
    end
  end

  @doc """
  Commit an append: extend `chunk.end_byte` by `bytes_appended` and
  bump the file's `updated_at`.
  """
  @spec commit_append(binary(), binary(), non_neg_integer(), integer()) ::
          :ok | {:error, :lease_not_found | :lease_expired}
  def commit_append(lease_id, chunk_uniq_id, bytes_appended, primary_chunk_server_id) do
    now = DateTime.utc_now()

    lease =
      Repo.one(
        from(l in Schema.Lease,
          where:
            l.lease_id == ^lease_id and
              l.chunk_uniq_id == ^chunk_uniq_id and
              l.primary_chunk_server_id == ^primary_chunk_server_id and
              is_nil(l.revoked_at)
        )
      )

    cond do
      is_nil(lease) ->
        {:error, :lease_not_found}

      DateTime.compare(lease.expires_at, now) != :gt ->
        {:error, :lease_expired}

      true ->
        Repo.update_all(
          from(c in Schema.Chunk, where: c.uniq_id == ^chunk_uniq_id),
          inc: [end_byte: bytes_appended],
          set: [updated_at: now]
        )

        Repo.update_all(
          from(f in Schema.File, where: f.id == ^lease.file_id),
          set: [updated_at: now]
        )

        :ok
    end
  end

  @doc """
  Discover currently alive chunkservers via `:pg`.

  Returns a list of `%{node, uniq_id, pid}` for every chunkserver that
  is currently a member of the `:gfs_chunkservers` group.

  This replaces the old "JOIN node ON node.alive = true" SQL discovery,
  which depended on stale ephemeral HTTP ports written to SQLite.
  """
  @spec list_chunkservers() :: [%{node: node(), uniq_id: binary(), pid: pid()}]
  def list_chunkservers do
    Gfs.ChunkServer.Control.list_pids()
    |> Task.async_stream(
      fn pid ->
        case Gfs.ChunkServer.Control.describe(pid) do
          {:ok, info} -> info
          {:error, _} -> nil
        end
      end,
      ordered: false,
      timeout: 5_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, nil} -> []
      {:ok, info} -> [info]
      _ -> []
    end)
  end

  ## Internal: replica selection ##

  defp pick_replicas_for_new_chunk do
    cs_query =
      from(cs in Schema.ChunkServer,
        join: n in Schema.Node,
        on: cs.node_id == n.id,
        left_join: c in Schema.Chunk,
        on: c.chunk_server_id == cs.id,
        where: n.alive == true,
        group_by: cs.id,
        order_by: [asc: count(c.id)],
        limit: @replication_limit,
        select: %{chunk_server: cs, node: n}
      )

    case Repo.all(cs_query) do
      [] -> {:error, :no_alive_replicas}
      list -> {:ok, list}
    end
  end

  defp insert_chunk_row(file_id, start_byte, replicas) do
    chunk_uniq_id = ExULID.ULID.generate()

    Enum.each(replicas, fn %{chunk_server: cs} ->
      Repo.insert!(%Schema.Chunk{
        chunk_server_id: cs.id,
        file_id: file_id,
        start_byte: start_byte,
        end_byte: start_byte - 1,
        uniq_id: chunk_uniq_id,
        version: 0
      })
    end)

    chunk_uniq_id
  end

  ## Internal: lease lifecycle ##

  defp last_chunk_for_file(file_id) do
    query =
      from(c in Schema.Chunk,
        where: c.file_id == ^file_id,
        order_by: [desc: c.start_byte],
        limit: 1
      )

    case Repo.one(query) do
      nil -> :no_chunk
      chunk -> chunk
    end
  end

  defp alive_replicas(chunk_uniq_id) do
    query =
      from(c in Schema.Chunk,
        join: cs in Schema.ChunkServer,
        on: cs.id == c.chunk_server_id,
        join: n in Schema.Node,
        on: n.id == cs.node_id,
        where: c.uniq_id == ^chunk_uniq_id and n.alive == true,
        select: %{chunk_server: cs, node: n}
      )

    Repo.all(query)
  end

  defp maybe_warn_under_replicated(chunk_uniq_id, replicas) do
    if length(replicas) < @replication_limit do
      IO.puts(
        "Metadata: chunk #{chunk_uniq_id} is under-replicated " <>
          "(#{length(replicas)}/#{@replication_limit}); proceeding with write"
      )
    end

    :ok
  end

  defp get_or_issue_lease(%{file: file, chunk: chunk, replicas: replicas}) do
    result =
      Repo.transaction(fn ->
        now = DateTime.utc_now()

        case active_lease(chunk.uniq_id, now) do
          %Schema.Lease{} = existing -> {existing, chunk}
          nil -> issue_lease(file, chunk, replicas, now)
        end
      end)

    case result do
      {:ok, {lease, chunk}} -> {:ok, build_lease_response(lease, chunk, replicas)}
      {:error, :conflict} -> {:error, :conflict}
      {:error, other} -> {:error, other}
    end
  end

  defp active_lease(chunk_uniq_id, now) do
    Repo.one(
      from(l in Schema.Lease,
        where:
          l.chunk_uniq_id == ^chunk_uniq_id and
            is_nil(l.revoked_at) and
            l.expires_at > ^now
      )
    )
  end

  defp issue_lease(file, chunk, replicas, now) do
    primary = Enum.random(replicas).chunk_server
    new_version = chunk.version + 1
    expires_at = DateTime.add(now, @lease_ttl_seconds, :second)

    Repo.update_all(
      from(c in Schema.Chunk, where: c.uniq_id == ^chunk.uniq_id),
      set: [version: new_version, updated_at: now]
    )

    updated_chunk = %{chunk | version: new_version}

    existing_expired =
      Repo.one(from(l in Schema.Lease, where: l.chunk_uniq_id == ^chunk.uniq_id))

    lease_id = ExULID.ULID.generate()

    cond do
      not is_nil(existing_expired) ->
        {count, _} =
          Repo.update_all(
            from(l in Schema.Lease,
              where:
                l.id == ^existing_expired.id and
                  (l.expires_at <= ^now or not is_nil(l.revoked_at))
            ),
            set: [
              lease_id: lease_id,
              chunk_version: new_version,
              expires_at: expires_at,
              revoked_at: nil,
              file_id: file.id,
              primary_chunk_server_id: primary.id,
              updated_at: now
            ]
          )

        if count == 1 do
          {%{
             existing_expired
             | lease_id: lease_id,
               chunk_version: new_version,
               expires_at: expires_at,
               revoked_at: nil,
               file_id: file.id,
               primary_chunk_server_id: primary.id
           }, updated_chunk}
        else
          Repo.rollback(:conflict)
        end

      true ->
        case Repo.insert(%Schema.Lease{
               lease_id: lease_id,
               chunk_uniq_id: chunk.uniq_id,
               chunk_version: new_version,
               expires_at: expires_at,
               file_id: file.id,
               primary_chunk_server_id: primary.id
             }) do
          {:ok, lease} -> {lease, updated_chunk}
          {:error, _} -> Repo.rollback(:conflict)
        end
    end
  end

  defp build_lease_response(lease, chunk, replicas) do
    primary_id = lease.primary_chunk_server_id
    primary_record = Enum.find(replicas, &(&1.chunk_server.id == primary_id))
    secondary_records = Enum.reject(replicas, &(&1.chunk_server.id == primary_id))

    %{
      lease_id: lease.lease_id,
      expires_at: lease.expires_at,
      chunk: %{
        uniq_id: chunk.uniq_id,
        version: lease.chunk_version,
        start_byte: chunk.start_byte,
        end_byte: chunk.end_byte
      },
      primary: format_replica(primary_record),
      secondaries: Enum.map(secondary_records, &format_replica/1),
      manager_node: Atom.to_string(node())
    }
  end

  defp format_replica(%{chunk_server: cs, node: n}) do
    %{
      id: cs.id,
      uniq_id: cs.uniq_id,
      http_port: n.http_port,
      identifier: n.identifier,
      node: n.identifier,
      host: host_for_http(n.identifier)
    }
  end

  defp host_for_http(_identifier), do: "localhost"
end
