defmodule Gfs.App do
  use Application

  @impl true
  def start(type, args) do
    runtime = Gfs.Runtime.production()
    case System.argv() do
      ["manager"] ->
        Gfs.Manager.App.start(type, %{runtime: runtime})

      ["chunkserver"] ->
        Gfs.ChunkServer.App.start_link(args, runtime)

      _ ->
        IO.puts("Please specify either 'manager' or 'chunkserver' as an application.")
        System.halt(1)
    end
  end
end
