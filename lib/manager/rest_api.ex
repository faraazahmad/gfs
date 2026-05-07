defmodule Gfs.Manager.RestApi do
  @moduledoc """
  External HTTP edge for the manager.

  This module is intentionally thin: every route delegates to
  `Gfs.Manager.Metadata`, which is also reachable directly from BEAM
  callers (chunkservers via `:erpc`). All business logic lives there.
  """

  use Plug.Router

  alias Gfs.Manager.Metadata
  alias Gfs.Manager.Repo
  alias Gfs.Schema

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
    chunk_servers = Repo.all(Schema.ChunkServer)
    send_json(conn, 200, chunk_servers)
  end

  get "/node/:id" do
    node_id = conn.params["id"]
    node = Repo.get(Schema.Node, node_id)
    send_json(conn, 200, node)
  end

  get "/files" do
    files = Repo.all(Schema.File)
    send_json(conn, 200, files)
  end

  post "/file/:encoded_file_path" do
    with {:ok, file_path} <- decode_file_path(conn.params["encoded_file_path"]),
         {:ok, %{file_id: _, chunk_uniq_id: _} = result} <- Metadata.ensure_file(file_path) do
      send_json(conn, 200, result)
    else
      :error ->
        send_json(conn, 400, %{error: "invalid_path"})

      {:error, :no_alive_replicas} ->
        send_json(conn, 503, %{error: "no_alive_replicas"})

      {:error, reason} ->
        send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  get "/file/:encoded_file_path/lease" do
    with {:ok, file_path} <- decode_file_path(conn.params["encoded_file_path"]),
         {:ok, response} <- Metadata.acquire_append_lease(file_path) do
      send_json(conn, 200, response)
    else
      :error -> send_json(conn, 400, %{error: "invalid_path"})
      {:error, :file_not_found} -> send_json(conn, 404, %{error: "file_not_found"})
      {:error, :chunk_not_found} -> send_json(conn, 404, %{error: "chunk_not_found"})
      {:error, :no_alive_replicas} -> send_json(conn, 503, %{error: "no_alive_replicas"})
      {:error, :conflict} -> send_json(conn, 409, %{error: "conflict"})
    end
  end

  # TODO: can be simplified
  post "/file/:encoded_file_path/chunk/:bytes_to_write" do
    with {:ok, file_path} <- decode_file_path(conn.params["encoded_file_path"]),
         {:ok, byte_count} <- parse_byte_count(conn.params["bytes_to_write"]),
         {:ok, _ensured} <- Metadata.ensure_file(file_path),
         {:ok, result} <- Metadata.acquire_writable_chunk(file_path, byte_count) do
      send_json(conn, 200, result)
    else
      :error -> send_json(conn, 400, %{error: "invalid_path"})
      {:error, :invalid_byte_count} -> send_json(conn, 400, %{error: "invalid_byte_count"})
      {:error, :bytes_too_large} -> send_json(conn, 413, %{error: "bytes_too_large"})
      {:error, :file_not_found} -> send_json(conn, 404, %{error: "file_not_found"})
      {:error, :no_alive_replicas} -> send_json(conn, 503, %{error: "no_alive_replicas"})
      {:error, reason} -> send_json(conn, 500, %{error: inspect(reason)})
    end
  end

  post "/lease/:lease_id/renew" do
    lease_id = conn.params["lease_id"]
    primary_id = conn.params["primary_chunk_server_id"]

    case Metadata.renew_lease(lease_id, primary_id) do
      {:ok, body} -> send_json(conn, 200, body)
      {:error, :lease_not_active} -> send_json(conn, 409, %{error: "lease_not_active"})
    end
  end

  post "/lease/:lease_id/commit" do
    lease_id = conn.params["lease_id"]
    chunk_uniq_id = conn.params["chunk_uniq_id"]
    bytes_appended = conn.params["bytes_appended"]
    primary_id = conn.params["primary_chunk_server_id"]

    case Metadata.commit_append(lease_id, chunk_uniq_id, bytes_appended, primary_id) do
      :ok -> send_json(conn, 200, %{ok: true})
      {:error, :lease_not_found} -> send_json(conn, 409, %{error: "lease_not_found"})
      {:error, :lease_expired} -> send_json(conn, 409, %{error: "lease_expired"})
    end
  end

  get "/file/:encoded_file_path/chunks" do
    with {:ok, file_path} <- decode_file_path(conn.params["encoded_file_path"]),
         %Schema.File{} = file <- Repo.get_by(Schema.File, path: file_path) do
      import Ecto.Query
      chunks = Repo.all(from(c in Schema.Chunk, where: c.file_id == ^file.id))
      send_json(conn, 200, chunks)
    else
      :error -> send_json(conn, 400, %{error: "invalid_path"})
      nil -> send_json(conn, 404, %{error: "file_not_found"})
    end
  end

  get "/file/:encoded_file_path/chunks/last" do
    import Ecto.Query

    with {:ok, file_path} <- decode_file_path(conn.params["encoded_file_path"]) do
      chunk_query =
        from(c in Schema.Chunk,
          join: f in Schema.File,
          on: c.file_id == f.id,
          where: f.path == ^file_path,
          order_by: [desc: c.updated_at],
          limit: 1
        )

      send_json(conn, 200, Repo.one(chunk_query))
    else
      :error -> send_json(conn, 400, %{error: "invalid_path"})
    end
  end

  match _ do
    send_resp(conn, 404, "not_found")
  end

  ## Helpers ##

  defp decode_file_path(encoded) when is_binary(encoded) do
    case Base.decode16(encoded) do
      {:ok, raw} -> {:ok, to_string(raw)}
      :error -> :error
    end
  end

  defp decode_file_path(_), do: :error

  defp parse_byte_count(value) when is_integer(value) and value >= 0, do: {:ok, value}

  defp parse_byte_count(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :invalid_byte_count}
    end
  end

  defp parse_byte_count(_), do: {:error, :invalid_byte_count}

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
