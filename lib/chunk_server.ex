defmodule Gfs.ChunkServer do
  use GenServer

  def start_link(arg) when is_map(arg) do
    GenServer.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(arg) do
    {:ok, arg}
  end

  @impl true
  def handle_call({:read, file_path}, _from, record) do
    {:reply, record, Map.get(record, file_path, [])}
  end

  @impl true
  def handle_call({:append, chunk_id, content}, _from, record) do
    chunk_file_path = Path.expand("~/.gfs/chunk_server/chunks/#{chunk_id}")
    file_content = case File.read(chunk_file_path) do
      {:ok, binary_content} -> binary_content
      {:error, _} -> nil
    end

    reply = case File.write(chunk_file_path, "#{file_content}#{content}") do
      :ok ->
        {:reply, record, :ok}
      {:error, error} ->
        {:reply, record, :error, error}
    end

    reply
  end
end
