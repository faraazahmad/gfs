defmodule Gfs.Manager.RestApi do
  use Plug.Router

  plug Plug.Logger
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason

  plug :match
  plug :dispatch

  get "/" do
    send_resp(conn, 200, "OK")
  end

  get "/chunk_servers" do
    chunk_servers = Gfs.Manager.Repo.all(Gfs.Schema.Node)
    # send_resp(conn, 200, chunk_servers)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(chunk_servers))
  end

  match _ do
    send_resp(conn, 404, "not_found")
  end
end
