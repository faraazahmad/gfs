defmodule Gfs.ChunkServer.Data do
  @moduledoc """
  Transport-neutral data-plane for the chunkserver.

  Functions here are designed to be invoked either directly inside the
  chunkserver (e.g. from a Plug handler when the client uploads via
  HTTP) or remotely from another chunkserver via `:erpc.call/4`.

  None of these functions go through a registered GenServer mailbox,
  which is intentional: the payload is up to 64 MiB and head-of-line
  blocking on a shared mailbox would be catastrophic. Per-lease serial
  numbers are pulled from `Gfs.ChunkServer.Serials` (an ETS counter),
  not from a GenServer.
  """

  require Logger

  @chunk_size 64 * 1024 * 1024
  @replica_timeout 15_000
  @commit_timeout 5_000

  @type lease :: %{
          required(:lease_id) => binary(),
          required(:chunk) => %{
            required(:uniq_id) => binary(),
            required(:version) => integer(),
            optional(any()) => any()
          },
          required(:primary) => map(),
          required(:secondaries) => [map()],
          required(:manager_node) => node()
        }

  @doc """
  Append a payload as the primary replica:

  1. Append locally.
  2. Fan out the same payload to every secondary in parallel.
  3. Ask the manager to commit the new byte range.

  Returns `:ok` on success or `{:error, reason}`.
  """
  @spec append_primary(lease(), binary()) ::
          {:ok, %{serial_no: pos_integer(), bytes_appended: non_neg_integer()}}
          | {:error,
             :chunk_full
             | :lease_expired
             | {:replication_failed, term()}
             | {:commit_failed, term()}
             | term()}
  def append_primary(lease, payload) when is_binary(payload) do
    serial_no = Gfs.ChunkServer.Serials.next(lease.lease_id)
    chunk_id = lease.chunk.uniq_id

    with :ok <- append_local(chunk_id, payload),
         :ok <-
           replicate_parallel(
             lease.secondaries,
             chunk_id,
             lease.lease_id,
             lease.chunk.version,
             serial_no,
             payload
           ),
         :ok <-
           commit_to_manager(
             lease.manager_node,
             lease.lease_id,
             chunk_id,
             byte_size(payload),
             lease.primary.id
           ) do
      {:ok, %{serial_no: serial_no, bytes_appended: byte_size(payload)}}
    end
  end

  @doc """
  Apply a payload as a secondary replica.

  Used remotely by the primary chunkserver via `:erpc.call/4`.
  """
  @spec apply_replica(binary(), binary(), integer(), pos_integer(), binary()) ::
          :ok | {:error, :chunk_full | term()}
  def apply_replica(chunk_id, _lease_id, _version, _serial_no, payload)
      when is_binary(payload) do
    append_local(chunk_id, payload)
  end

  @doc "Read a whole chunk's contents from local disk."
  @spec read_chunk(binary()) :: {:ok, binary()} | {:error, term()}
  def read_chunk(chunk_id) do
    File.read(chunk_path(chunk_id))
  end

  ## Helpers ##

  defp chunk_path(chunk_id) do
    Path.join([Gfs.ChunkServer.Control.root_dir(), "chunks", chunk_id])
  end

  defp append_local(chunk_id, payload) do
    path = chunk_path(chunk_id)
    File.mkdir_p!(Path.dirname(path))
    IO.puts(path)

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

  defp replicate_parallel([], _chunk_id, _lease_id, _version, _serial_no, _payload), do: :ok

  defp replicate_parallel(secondaries, chunk_id, lease_id, version, serial_no, payload) do
    secondaries
    |> Task.async_stream(
      fn replica ->
        try do
          :erpc.call(
            replica.node,
            Gfs.ChunkServer.Data,
            :apply_replica,
            [chunk_id, lease_id, version, serial_no, payload],
            @replica_timeout
          )
        catch
          kind, reason ->
            IO.puts("Error replicating to #{replica.node}")
            IO.inspect(reason)
            {:error, {kind, reason}}
        end
      end,
      ordered: false,
      timeout: @replica_timeout + 1_000,
      max_concurrency: max(length(secondaries), 1),
      on_timeout: :kill_task
    )
    |> Enum.reduce_while(:ok, fn
      {:ok, :ok}, _ -> {:cont, :ok}
      {:ok, {:error, reason}}, _ -> {:halt, {:error, {:replication_failed, reason}}}
      {:exit, reason}, _ -> {:halt, {:error, {:replication_failed, reason}}}
      other, _ -> {:halt, {:error, {:replication_failed, other}}}
    end)
  end

  defp commit_to_manager(manager_node, lease_id, chunk_id, bytes, primary_id) do
    try do
      case :erpc.call(
             manager_node,
             Gfs.Manager.Metadata,
             :commit_append,
             [lease_id, chunk_id, bytes, primary_id],
             @commit_timeout
           ) do
        :ok ->
          :ok

        {:error, reason} ->
          {:error, {:commit_failed, reason}}
      end
    catch
      kind, reason -> {:error, {:commit_failed, {kind, reason}}}
    end
  end
end
