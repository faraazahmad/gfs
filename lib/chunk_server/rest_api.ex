defmodule Gfs.ChunkServer.RestApi do
  use Plug.Router

  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, "OK")
  end

  get "/chunk/:chunk_id" do
    chunk_file_path = Path.expand("~/.gfs/chunk_server/chunks/#{chunk_id}")
    file_content = case File.read(chunk_file_path) do
      {:ok, content} -> content
      {:error, error} -> error
    end

    send_resp(conn, 200, Jason.encode!(file_content))
  end

  put "append/chunk/:chunk_id" do
    content = conn.body.content
    chunk_file_path = Path.expand("~/.gfs/chunk_server/chunks/#{chunk_id}")

    reply = File.write(chunk_file_path, content, [:append])
    send_resp(conn, 200, Jason.encode!(reply))
  end

  match _ do
    send_resp(conn, 404, "not_found")
  end
end
