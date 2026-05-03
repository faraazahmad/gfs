defmodule Gfs.ChunkServer.RestApi do
  use Plug.Router

  # 64 MiB, matching Gfs.Client's piece size and the canonical GFS chunk size.
  @chunk_size 64 * 1024 * 1024
  @manager_base_url "http://localhost:4000"
  @json_headers [{"Content-Type", "application/json"}]

  plug(Plug.Logger)

  # Append payloads are base64-encoded JSON bodies of up to one chunk
  # (64 MiB raw -> ~86 MiB encoded), so we have to lift Plug's default
  # 8 MB body limit.
  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: 128 * 1024 * 1024,
    read_length: 1_000_000,
    read_timeout: 30_000
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

  put "/append/chunk/:chunk_id" do
    lease_id = conn.body_params["lease_id"]
    primary_id = conn.body_params["primary_chunk_server_id"]
    secondaries = conn.body_params["secondaries"] || []
    encoded_content = conn.body_params["content"]

    case Base.decode64(encoded_content || "") do
      {:ok, payload} ->
        {:ok, serial_no} = Gfs.ChunkServer.Genserver.next_serial(lease_id)

        with :ok <- append_local(chunk_id, payload),
             :ok <- replicate_to_secondaries(chunk_id, payload, lease_id, serial_no, primary_id, secondaries),
             :ok <- commit_to_manager(chunk_id, lease_id, byte_size(payload), primary_id) do
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, Jason.encode!(%{ok: true, serial_no: serial_no, bytes_appended: byte_size(payload)}))
        else
          {:error, :chunk_full} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(422, Jason.encode!(%{error: "chunk_full"}))

          {:error, :lease_expired} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(409, Jason.encode!(%{error: "lease_expired"}))

          {:error, {:replication_failed, reason}} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(502, Jason.encode!(%{error: "replication_failed", reason: inspect(reason)}))

          {:error, {:commit_failed, reason}} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(502, Jason.encode!(%{error: "commit_failed", reason: inspect(reason)}))

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(500, Jason.encode!(%{error: inspect(reason)}))
        end

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "bad_content"}))
    end
  end

  put "/replicate/chunk/:chunk_id" do
    serial_no = conn.body_params["serial_no"]
    encoded_content = conn.body_params["content"]

    case Base.decode64(encoded_content || "") do
      {:ok, payload} ->
        case append_local(chunk_id, payload) do
          :ok ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(%{ok: true, serial_no: serial_no}))

          {:error, :chunk_full} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(422, Jason.encode!(%{error: "chunk_full"}))

          {:error, reason} ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(500, Jason.encode!(%{error: inspect(reason)}))
        end

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, Jason.encode!(%{error: "bad_content"}))
    end
  end

  match _ do
    send_resp(conn, 404, "not_found")
  end

  defp chunk_path(chunk_id) do
    Path.expand("~/.gfs/chunk_server/chunks/#{chunk_id}")
  end

  defp append_local(chunk_id, payload) do
    path = chunk_path(chunk_id)
    File.mkdir_p!(Path.dirname(path))

    current_size =
      case File.stat(path) do
        {:ok, %{size: size}} -> size
        {:error, _} -> 0
      end

    if current_size + byte_size(payload) > @chunk_size do
      {:error, :chunk_full}
    else
      File.write(path, payload, [:append, :binary])
    end
  end

  defp replicate_to_secondaries(chunk_id, payload, lease_id, serial_no, primary_id, secondaries) do
    body =
      Jason.encode!(%{
        lease_id: lease_id,
        primary_chunk_server_id: primary_id,
        serial_no: serial_no,
        content: Base.encode64(payload)
      })

    Enum.reduce_while(secondaries, :ok, fn s, _acc ->
      port = Map.fetch!(s, "http_port")
      host = Map.get(s, "host", "localhost")
      url = "http://#{host}:#{port}/replicate/chunk/#{chunk_id}"

      case HTTPoison.put(url, body, @json_headers) do
        {:ok, %HTTPoison.Response{status_code: 200}} ->
          {:cont, :ok}

        {:ok, %HTTPoison.Response{status_code: status}} ->
          {:halt, {:error, {:replication_failed, {:status, status}}}}

        {:error, reason} ->
          {:halt, {:error, {:replication_failed, reason}}}
      end
    end)
  end

  defp commit_to_manager(chunk_id, lease_id, bytes, primary_id) do
    body =
      Jason.encode!(%{
        chunk_uniq_id: chunk_id,
        bytes_appended: bytes,
        primary_chunk_server_id: primary_id
      })

    url = "#{@manager_base_url}/lease/#{lease_id}/commit"

    case HTTPoison.post(url, body, @json_headers) do
      {:ok, %HTTPoison.Response{status_code: 200}} -> :ok
      {:ok, %HTTPoison.Response{status_code: 409}} -> {:error, :lease_expired}
      {:ok, %HTTPoison.Response{status_code: status}} -> {:error, {:commit_failed, {:status, status}}}
      {:error, reason} -> {:error, {:commit_failed, reason}}
    end
  end
end
