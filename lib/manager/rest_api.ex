import Ecto.Query

defmodule Gfs.Manager.RestApi do
  use Plug.Router

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
    chunk_servers = Gfs.Manager.Repo.all(Gfs.Schema.Node)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(chunk_servers))
  end

  get "/files" do
    send_resp(conn, 300, "Not Implemented")
  end

  get "/file/:file_name/chunks" do
    file_name = conn.params.file_name
    file = Gfs.Manager.Repo.get_by(Gfs.Schema.File, name: file_name)
    query = from chunk in Gfs.Schema.Chunk, where: chunk.file_id == ^file.id
    chunks = Gfs.Manager.Repo.all(query)
    send_resp(conn, 200, Jason.encode!(chunks))
  end

  get "/file/:encoded_file_path/write/chunkservers" do
    params = conn.query_params
    file_path = :binary.decode_hex(encoded_file_path)
    file = Gfs.Manager.Repo.get_by(Gfs.Schema.File, path: file_path)

    if not is_nil(file) do
        query = from chunk in Gfs.Schema.Chunk,
                where: chunk.file == ^file and
                        chunk.start_byte == ^params.start_byte and
                        chunk.end_byte == ^params.end_byte,
                join: cs in Gfs.Schema.ChunkServer, on: cs.id == chunk.chunk_server_id,
                limit: @replication_limit
        chunks = Gfs.Manager.Repo.all(query)
        send_resp(conn, 200, Jason.encode!(chunks))
    else
        # Create file entry in DB
        {:ok, _file} = Gfs.Manager.Repo.insert(%Gfs.Schema.File{ path: file_path })
        # Given @replication_limit: Get available chunk servers and create chunk entries
        send_resp(conn, 200, "")
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
