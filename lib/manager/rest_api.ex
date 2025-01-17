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

  match _ do
    send_resp(conn, 404, "not_found")
  end
end
