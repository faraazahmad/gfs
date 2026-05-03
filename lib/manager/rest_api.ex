defmodule Gfs.Manager.RestApi do
  use Plug.Router
  alias Gfs.Manager.Repo
  alias Gfs.Schema
  import Ecto.Query

  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  @replication_limit 3
  # GFS-style: writes proceed as long as at least one replica is alive.
  # Falling below @replication_limit (but >= @min_replicas_for_write) only
  # signals that the master should schedule background re-replication; it
  # must not block writes. Hard-failing every lease just because one of three
  # chunkservers is momentarily down means a single crash takes the whole
  # cluster offline for writes.
  @min_replicas_for_write 1
  @lease_ttl_seconds 60

  get "/" do
    send_resp(conn, 200, "OK")
  end

  get "/chunk_servers" do
    chunk_servers =
      Gfs.Manager.Repo.all(Gfs.Schema.ChunkServer)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(chunk_servers))
  end

  get "/node/:id" do
    node_id = conn.params["id"]

    node =
      Gfs.Manager.Repo.get(Gfs.Schema.Node, node_id)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(node))
  end

  get "/files" do
    files = Gfs.Manager.Repo.all(Gfs.Schema.File)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(files))
  end

  def handle_file_creation(conn, file_path, _chunk_servers) when file_path == "" do
    send_resp(conn, 500, "Route not implemented")
  end

  def handle_file_creation(conn, _file_path, chunk_servers) when chunk_servers.length == 0 do
    send_resp(conn, 500, "No chunk servers found.")
  end

  def handle_file_creation(conn, file_path, chunk_servers) do
    file =
      case Gfs.Manager.Repo.get_by(Gfs.Schema.File, path: file_path) do
        nil ->
          Gfs.Manager.Repo.insert!(%Gfs.Schema.File{path: file_path})

        found_file ->
          found_file
      end

    primary_cs_index =
      chunk_servers
      |> length
      |> :rand.uniform()

    chunk_uniq_id = ExULID.ULID.generate()

    chunk_servers
    |> Enum.with_index()
    |> Enum.each(fn {cs, index} ->
      # TODO: Update :ets storage with primary, secondary and lease data

      Gfs.Manager.Repo.insert!(%Gfs.Schema.Chunk{
        chunk_server_id: cs.id,
        file_id: file.id,
        start_byte: 0,
        end_byte: -1,
        uniq_id: chunk_uniq_id,
        version: 0
      })
    end)

    chunk_server_uniq_ids = Enum.map(chunk_servers, fn cs -> cs.uniq_id end)
    send_resp(conn, 200, Jason.encode!(chunk_server_uniq_ids))
  end

  @doc """
    Client →  Master: "I want to write to chunk X
    Master →  Client: "Primary is replica A, secondaries are B and C. Here's the lease."

    1. Client pushes data to ALL replicas (pipelined over the network)
    2. Client sends WRITE REQUEST to Primary
    3. Primary assigns a serial number to the mutation, applies it locally
    4. Primary forwards the write (with serial number) to all secondaries
    5. Secondaries apply in the same serial order, reply "done" to Primary
    6. Primary replies SUCCESS to client
       (if any secondary fails → client retries) 
  """
  get "/file/:encoded_file_path/lease" do
    with {:ok, ctx} <- load_lease_context(conn.params["encoded_file_path"]),
         {:ok, {lease, chunk}} <- get_or_issue_lease(ctx) do
      IO.inspect(ctx.replicas, label: "replicas")
      send_json(conn, 200, build_lease_response(lease, chunk, ctx.replicas))
    else
      {:error, status, body} -> send_json(conn, status, body)
    end
  end

  post "/lease/:lease_id/renew" do
    lease_id = conn.params["lease_id"]
    primary_id = conn.params["primary_chunk_server_id"]
    now = DateTime.utc_now()
    new_expires_at = DateTime.add(now, @lease_ttl_seconds, :second)

    {count, _} =
      Repo.update_all(
        from(l in Schema.Lease,
          where:
            l.lease_id == ^lease_id and
              l.primary_chunk_server_id == ^primary_id and
              is_nil(l.revoked_at) and
              l.expires_at > ^now
        ),
        set: [expires_at: new_expires_at, updated_at: now]
      )

    case count do
      1 ->
        send_json(conn, 200, %{lease_id: lease_id, expires_at: new_expires_at})

      _ ->
        send_json(conn, 409, %{error: "lease_not_active"})
    end
  end

  post "/lease/:lease_id/commit" do
    lease_id = conn.params["lease_id"]
    chunk_uniq_id = conn.params["chunk_uniq_id"]
    bytes_appended = conn.params["bytes_appended"]
    primary_id = conn.params["primary_chunk_server_id"]
    now = DateTime.utc_now()

    lease =
      Repo.one(
        from(l in Schema.Lease,
          where:
            l.lease_id == ^lease_id and
              l.chunk_uniq_id == ^chunk_uniq_id and
              l.primary_chunk_server_id == ^primary_id and
              is_nil(l.revoked_at)
        )
      )

    cond do
      is_nil(lease) ->
        send_json(conn, 409, %{error: "lease_not_found"})

      DateTime.compare(lease.expires_at, now) != :gt ->
        send_json(conn, 409, %{error: "lease_expired"})

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

        send_json(conn, 200, %{ok: true})
    end
  end

  post "/file/:encoded_file_path" do
    # Get all chunkservers on alive nodes
    cs_query =
      from(cs in Gfs.Schema.ChunkServer,
        join: n in Gfs.Schema.Node,
        on: cs.node_id == n.id,
        left_join: c in Gfs.Schema.Chunk,
        on: c.chunk_server_id == cs.id,
        where: n.alive == true,
        group_by: cs.id,
        order_by: [asc: count(c.id)],
        limit: @replication_limit,
        select: cs
      )

    chunk_servers = Gfs.Manager.Repo.all(cs_query)

    encoded_file_path = conn.params["encoded_file_path"]

    file_path =
      case Base.decode16(encoded_file_path) do
        {:ok, charlist} ->
          to_string(charlist)

        _ ->
          ""
      end

    handle_file_creation(conn, file_path, chunk_servers)
  end

  get "/file/:encoded_file_path/chunks" do
    encoded_file_path = conn.params["encoded_file_path"]

    file_path =
      case Base.decode16(encoded_file_path) do
        {:ok, charlist} ->
          to_string(charlist)

        _ ->
          ""
      end

    file = Gfs.Manager.Repo.get_by(Gfs.Schema.File, path: file_path)
    query = from(chunk in Gfs.Schema.Chunk, where: chunk.file_id == ^file.id)
    chunks = Gfs.Manager.Repo.all(query)
    send_resp(conn, 200, Jason.encode!(chunks))
  end

  def create_new_file_chunk(conn, file_record) do
    start_byte =
      case Gfs.Manager.Repo.one(
             from(chunk in Gfs.Schema.Chunk,
               where: chunk.file_id == ^file_record.id,
               order_by: [desc: chunk.start_byte],
               limit: 1
             )
           ) do
        nil ->
          0

        chunk ->
          chunk.end_byte + 1
      end

    case Gfs.Manager.Repo.insert(%Gfs.Schema.Chunk{
           file_id: file_record.id,
           start_byte: start_byte,
           end_byte: start_byte
         }) do
      {:ok, chunk} ->
        send_resp(conn, 200, Jason.encode!(chunk))

      {:error, error} ->
        send_resp(conn, 500, Jason.encode!(error.reason))
    end
  end

  post "/file/:encoded_file_path/chunk" do
    encoded_file_path = conn.params["encoded_file_path"]
    file_path = Base.decode16!(encoded_file_path)

    file =
      case Repo.get_by(Schema.File, path: file_path) do
        nil -> %Schema.File{path: file_path}
        object -> object
      end
      |> Schema.File.changeset(%{})
      |> Repo.insert_or_update!()

    create_new_file_chunk(conn, file)
  end

  get "/file/:encoded_file_path/chunks/last" do
    encoded_file_path = conn.params["encoded_file_path"]

    case Base.decode16(encoded_file_path) do
      {:ok, charlist} ->
        file_path = to_string(charlist)
        # file_record = Gfs.Manager.Repo.get_by(Gfs.Schema.File, path: file_path)
        # last_chunk = Gfs.Manager.Repo.get_by(Gfs.Schema.Chunk, file_id: file_record.id)
        # send_resp(conn, 200, Jason.encode!(last_chunk))

        chunk_query =
          from(
            chunk in Gfs.Schema.Chunk,
            join: file in Gfs.Schema.File,
            on: chunk.file_id == file.id,
            where: file.path == ^file_path,
            order_by: [desc: chunk.updated_at],
            limit: 1
          )

        last_chunk = Gfs.Manager.Repo.one(chunk_query)
        send_resp(conn, 200, Jason.encode!(last_chunk))

      _ ->
        send_resp(conn, 404, nil)
    end

    # case Repo.get_by(Schema.Node, identifier: node) do
    #   nil -> %Schema.Node{identifier: node}
    #   object -> object
    # end
    # |> Schema.Node.changeset(%{alive: alive})
    # |> Repo.insert_or_update()
  end

  get "/file/:encoded_file_path/:chunk_id/chunkservers" do
    encoded_file_path = conn.params["encoded_file_path"]
    encoded_chunk_id = conn.params["chunk_id"]

    file_path = Base.decode16!(encoded_file_path)
    chunk_id = Base.decode16!(encoded_chunk_id)
    IO.puts("#{chunk_id}")
    [_path, byte_range | _] = String.split(chunk_id, ":", [])
    [start_byte, end_byte | _] = String.split(byte_range, ",", [])
    file = Gfs.Manager.Repo.get_by(Gfs.Schema.File, path: file_path)

    if not is_nil(file) do
      chunk_query =
        from(chunk in Gfs.Schema.Chunk,
          where:
            chunk.file_id == ^file.id and
              chunk.start_byte == ^start_byte and
              chunk.end_byte == ^end_byte,
          select: chunk.id
        )

      chunk_ids = Gfs.Manager.Repo.all(chunk_query)

      cs_query =
        from(chunk_server in Gfs.Schema.ChunkServer,
          join: node in Gfs.Schema.Node,
          on: node.id == chunk_server.node_id,
          where: chunk_server.id in ^chunk_ids and node.alive == true
        )

      chunk_servers = Gfs.Manager.Repo.all(cs_query)

      if length(chunk_servers) < @replication_limit do
        # create_chunks(
        #   file_path,
        #   params["start_byte"],
        #   params["end_byte"],
        #   @replication_limit - length(chunk_servers)
        # )
      end

      send_resp(conn, 200, Jason.encode!(chunk_servers))
    else
      # Create file entry in DB and return 3 (replication no.) chunkservers
      result =
        Gfs.Manager.Repo.insert(%Gfs.Schema.File{
          path: file_path,
          updated_at: DateTime.truncate(DateTime.utc_now(), :microsecond)
        })

      case result do
        {:error, reason} -> send_resp(conn, 500, reason)
      end

      cs_query =
        from(chunk_server in Gfs.Schema.ChunkServer,
          join: node in Gfs.Schema.Node,
          on: node.id == chunk_server.node_id,
          where: node.alive == true,
          limit: 3
        )

      # Given @replication_limit: Get available chunk servers and create chunk entries
      chunkservers = Gfs.Manager.Repo.all(cs_query)
      send_resp(conn, 200, Jason.encode!(chunkservers))
    end
  end

  match _ do
    send_resp(conn, 404, "not_found")
  end

  defp decode_file_path(encoded) when is_binary(encoded) do
    case Base.decode16(encoded) do
      {:ok, raw} -> {:ok, to_string(raw)}
      :error -> :error
    end
  end

  defp decode_file_path(_), do: :error

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  # Step 1: validate path and load file, last chunk, and alive replicas.
  defp load_lease_context(encoded_path) do
    with {:ok, file_path} <- decode_file_path(encoded_path),
         %Schema.File{} = file <- Repo.get_by(Schema.File, path: file_path),
         %Schema.Chunk{} = chunk <- last_chunk_for_file(file.id),
         replicas when length(replicas) >= @min_replicas_for_write <-
           alive_replicas(chunk.uniq_id) do
      if length(replicas) < @replication_limit do
        IO.puts(
          "load_lease_context: chunk #{chunk.uniq_id} is under-replicated " <>
            "(#{length(replicas)}/#{@replication_limit}); proceeding with write"
        )

        # TODO: signal background re-replication for chunk.uniq_id here.
      end

      {:ok, %{file: file, chunk: chunk, replicas: replicas}}
    else
      :error ->
        {:error, 400, %{error: "invalid_path"}}

      nil ->
        {:error, 404, %{error: "file_not_found"}}

      :no_chunk ->
        {:error, 404, %{error: "chunk_not_found"}}

      replicas when is_list(replicas) and length(replicas) < @min_replicas_for_write ->
        {:error, 503, %{error: "no_alive_replicas"}}
    end
  end

  # Step 2: reuse an active lease or issue a new one inside a transaction.
  defp get_or_issue_lease(%{file: file, chunk: chunk, replicas: replicas}) do
    case Repo.transaction(fn ->
           now = DateTime.utc_now()

           case active_lease(chunk.uniq_id, now) do
             %Schema.Lease{} = existing -> {existing, chunk}
             nil -> issue_lease(file, chunk, replicas, now)
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, :conflict} -> {:error, 409, %{error: "conflict"}}
    end
  end

  # Step 3: shape the JSON body, splitting replicas into primary + secondaries.
  defp build_lease_response(lease, chunk, replicas) do
    primary_id = lease.primary_chunk_server_id
    primary = Enum.find(replicas, &(&1.chunk_server.id == primary_id))
    secondaries = Enum.reject(replicas, &(&1.chunk_server.id == primary_id))

    %{
      lease_id: lease.lease_id,
      expires_at: lease.expires_at,
      chunk: %{
        uniq_id: chunk.uniq_id,
        version: lease.chunk_version,
        start_byte: chunk.start_byte,
        end_byte: chunk.end_byte
      },
      primary: format_replica(primary),
      secondaries: Enum.map(secondaries, &format_replica/1)
    }
  end

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

  defp format_replica(%{chunk_server: cs, node: n}) do
    %{
      id: cs.id,
      uniq_id: cs.uniq_id,
      http_port: n.http_port,
      identifier: n.identifier,
      host: host_for_http(n.identifier)
    }
  end

  # The BEAM node identifier (e.g. "chunk1@MacBookPro") is fine for distributed
  # Erlang (which uses EPMD), but its host portion is usually not DNS-resolvable
  # over plain HTTP and causes :nxdomain when the client / peer chunkserver
  # tries to PUT/POST. This deployment is single-host, so always advertise
  # "localhost" for the HTTP endpoint.
  defp host_for_http(_identifier), do: "localhost"
end
