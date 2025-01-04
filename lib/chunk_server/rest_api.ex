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
    send_resp(conn, 300, "Not Implemented")
  end

  match _ do
    send_resp(conn, 404, "not_found")
  end
end
