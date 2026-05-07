defmodule Gfs.ChunkServer.RestApi do
  @moduledoc """
  External  HTTP edge for the chunkserver.

  This route exists so non-BEAM clients  can still upload data 
  over HTTP. Internally the data plane uses BEAM-native primitives
  — `Gfs.ChunkServer.Data` does parallel `:erpc` replication to 
  secondaries and an `:erpc` commit call back to the manager.

  This Plug handler is intentionally thin: it
  parses the request envelope, builds a lease struct, and hands off to
  `Gfs.ChunkServer.Data`. There is no head-of-line blocking on a
  single registered GenServer mailbox.
  """

  use Plug.Router

  # 64 MiB. We continue to accept base64-encoded JSON for backward
  # compat with the existing `gfs_client`; raw binary upload is also
  # supported for the eventual migration off base64.
  @max_body_bytes 128 * 1024 * 1024

  plug(Plug.Logger)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason,
    length: @max_body_bytes,
    read_length: 1_000_000,
    read_timeout: 30_000
  )

  plug(:match)
  plug(:dispatch)

  get "/" do
    send_resp(conn, 200, "OK")
  end

  get "/chunk/:chunk_id" do
    case Gfs.ChunkServer.Data.read_chunk(chunk_id) do
      {:ok, content} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> send_resp(200, content)

      {:error, reason} ->
        send_json(conn, 404, %{error: inspect(reason)})
    end
  end

  put "/append/chunk/:chunk_id" do
    body = conn.body_params

    with {:ok, payload} <- decode_payload(body["content"]),
         {:ok, lease} <- build_lease(chunk_id, body) do
      case Gfs.ChunkServer.Data.append_primary(lease, payload) do
        {:ok, %{serial_no: sn, bytes_appended: bytes}} ->
          send_json(conn, 200, %{ok: true, serial_no: sn, bytes_appended: bytes})

        {:error, :chunk_full} ->
          send_json(conn, 422, %{error: "chunk_full"})

        {:error, :lease_expired} ->
          send_json(conn, 409, %{error: "lease_expired"})

        {:error, {:replication_failed, reason}} ->
          send_json(conn, 502, %{error: "replication_failed", reason: inspect(reason)})

        {:error, {:commit_failed, reason}} ->
          send_json(conn, 502, %{error: "commit_failed", reason: inspect(reason)})

        {:error, reason} ->
          send_json(conn, 500, %{error: inspect(reason)})
      end
    else
      {:error, :bad_content} -> send_json(conn, 400, %{error: "bad_content"})
      {:error, :bad_lease} -> send_json(conn, 400, %{error: "bad_lease"})
    end
  end

  match _ do
    send_resp(conn, 404, "not_found")
  end

  ## Helpers ##

  defp decode_payload(nil), do: {:error, :bad_content}

  defp decode_payload(content) when is_binary(content) do
    case Base.decode64(content) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :bad_content}
    end
  end

  defp decode_payload(_), do: {:error, :bad_content}

  # Reconstruct an internal lease shape from the JSON envelope the
  # client sent. The client previously got this back from
  # `Gfs.Manager.Metadata.acquire_append_lease/1`, so we expect the
  # same fields in stringified form.
  defp build_lease(chunk_id, body) when is_map(body) do
    with lease_id when is_binary(lease_id) <- body["lease_id"],
         primary when is_map(primary) <- body["primary"] || default_primary(body),
         secondaries <- body["secondaries"] || [],
         manager_node when is_binary(manager_node) or is_atom(manager_node) <-
           body["manager_node"] || default_manager_node() do
      lease = %{
        lease_id: lease_id,
        chunk: %{
          uniq_id: chunk_id,
          version: body["chunk_version"] || 0
        },
        primary: normalize_replica(primary),
        secondaries: Enum.map(secondaries, &normalize_replica/1),
        manager_node: to_node(manager_node)
      }

      {:ok, lease}
    else
      _ -> {:error, :bad_lease}
    end
  end

  defp build_lease(_, _), do: {:error, :bad_lease}

  # Older client versions only sent `primary_chunk_server_id`. Build a
  # minimal primary record from that so commit still works.
  defp default_primary(body) do
    case body["primary_chunk_server_id"] do
      nil -> nil
      id -> %{"id" => id, "node" => Atom.to_string(node())}
    end
  end

  defp default_manager_node do
    case Application.get_env(:gfs, :manager_node) do
      nil -> nil
      node -> node
    end
  end

  defp normalize_replica(%{} = m) do
    %{
      id: m["id"] || m[:id],
      uniq_id: m["uniq_id"] || m[:uniq_id],
      node: to_node(m["node"] || m[:node] || m["identifier"] || m[:identifier]),
      http_port: m["http_port"] || m[:http_port],
      host: m["host"] || m[:host]
    }
  end

  defp to_node(nil), do: nil
  defp to_node(n) when is_atom(n), do: n
  defp to_node(n) when is_binary(n), do: String.to_atom(n)

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
