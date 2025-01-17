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
    chunk_file_path = Path.expand("~/.gfs/chunk_server/chunks/#{chunk_id}")
    case File.stat(chunk_file_path) do
      {:ok, chunk_file_stat} -> 
        available_space = 64_000 - chunk_file_stat.size
        append_payload(conn, chunk_id, conn.body_params["content"], available_space)
      {:error, error} -> send_resp(conn, 500, Jason.encode!(error))
    end
  end

  defp append_payload(conn, _chunk_id, payload, available_space) when available_space - byte_size(payload) < 0 do
      send_resp(conn, 400, "Chunk size exceeds limit (64KB), aborting append.")
  end

  defp append_payload(conn, chunk_id, payload, available_space) when available_space - byte_size(payload) >= 0 do
    chunk_file_path = Path.expand("~/.gfs/chunk_server/chunks/#{chunk_id}")
    case File.write(chunk_file_path, payload, [:append]) do
      :ok -> send_resp(conn, 200, "Appended chunk #{chunk_id} with #{byte_size(payload) / 1000} KB payload.")
      {:error, error} -> send_resp(conn, 500, Jason.encode!(error))
    end
  end

  match _ do
    send_resp(conn, 404, "not_found")
  end
end
