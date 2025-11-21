defmodule Gfs.Manager.RestApi do
  alias Bandit.WebSocket.Frame.Binary
  use Plug.Router
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
    send_resp(conn, 400, "Invalid file path.")
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

    Enum.each(chunk_servers, fn cs ->
      IO.puts(cs.id)

      Gfs.Manager.Repo.insert!(%Gfs.Schema.Chunk{
        chunk_server_id: cs.id,
        file_id: file.id,
        start_byte: 0,
        end_byte: 0,
        uniq_id: ExULID.ULID.generate(),
        version: 0
      })
    end)

    chunk_server_uniq_ids = Enum.map(chunk_servers, fn cs -> cs.uniq_id end)
    send_resp(conn, 200, Jason.encode!(chunk_server_uniq_ids))
  end

  post "/file/:encoded_file_path" do
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
      case Base.decode64(encoded_file_path) do
        {:ok, charlist} ->
          to_string(charlist)

        _ ->
          ""
      end

    handle_file_creation(conn, file_path, chunk_servers)
  end

  get "/file/:file_name/chunks" do
    file_name = conn.params.file_name
    file = Gfs.Manager.Repo.get_by(Gfs.Schema.File, name: file_name)
    query = from(chunk in Gfs.Schema.Chunk, where: chunk.file_id == ^file.id)
    chunks = Gfs.Manager.Repo.all(query)
    send_resp(conn, 200, Jason.encode!(chunks))
  end

  get "/file/:encoded_file_path/:chunk_id/chunkservers" do
    params = conn.query_params
    file_path = :base64.decode_to_string(encoded_file_path)
    file = Gfs.Manager.Repo.get_by(Gfs.Schema.File, path: file_path)

    if not is_nil(file) do
      chunk_query =
        from(chunk in Gfs.Schema.Chunk,
          where:
            chunk.file_id == ^file.id and
              chunk.start_byte == ^params["start_byte"] and
              chunk.end_byte == ^params["end_byte"],
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
          updated_at: DateTime.truncate(DateTime.utc_now(), :second)
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

  post "/file/chunk" do
    IO.puts("started POST file chunk")
    # Get following data from req body: content, start_byte, end_byte
    # case read_body(conn, length: 70 * 1024 * 1024, read_timeout: 30_000) do
    #   {:ok, _body, conn} -> send_resp(conn, 200, "OK")
    #   {:error, error } -> IO.puts(error)
    #   _ -> send_resp(conn, 200, "ok")
    # end

    case Plug.Conn.read_body(conn, length: 70 * 1024 * 1024) do
      {:ok, body, conn} ->
        # Process the body
        IO.inspect(body)
        send_resp(conn, 200, "ok")

      {:more, chunk, conn} ->
        # Process the chunk and continue reading
        IO.inspect(chunk)
        send_resp(conn, 200, "ok")

      # Continue reading the rest of the body

      {:error, reason} ->
        # Handle the error
        IO.inspect(reason)
    end
  end

  match _ do
    send_resp(conn, 404, "not_found")
  end
end
