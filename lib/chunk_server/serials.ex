defmodule Gfs.ChunkServer.Serials do
  @moduledoc """
  Per-lease serial counter backed by ETS.

  Lives in its own owning process so that the data path (large 64 MiB
  payloads passing through `Gfs.ChunkServer.Data.append_primary/2`) never
  has to send a `GenServer.call/2` to a single registered process to bump
  a counter — everything goes through `:ets.update_counter/3`, which is
  lock-free for distinct keys.

  In the event of requests arriving out of order or a situation where a 
  chunk_server had gone offline, this counter is necessary to restore the
  order of chunks.
  """

  use GenServer

  @table :gfs_chunkserver_serials

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    {:ok, state}
  end

  @doc """
  Atomically increments and returns the next serial number for `lease_id`.
  """
  @spec next(binary()) :: pos_integer()
  def next(lease_id) when is_binary(lease_id) do
    :ets.update_counter(@table, lease_id, {2, 1}, {lease_id, 0})
  end

  @doc "Forget all serials for a finished lease."
  @spec forget(binary()) :: :ok
  def forget(lease_id) when is_binary(lease_id) do
    :ets.delete(@table, lease_id)
    :ok
  end
end
