defmodule Gfs.Manager.Task.ExpireLeases do
  use GenServer
  import Ecto.Query

  alias Gfs.Manager.Repo
  alias Gfs.Schema.Lease

  @interval_ms 5_000

  def start_link(runtime) do
    GenServer.start_link(__MODULE__, runtime, name: __MODULE__)
  end

  @impl true
  def init(runtime) do
    schedule()
    {:ok, runtime}
  end

  @impl true
  def handle_info(:expire_leases, runtime) do
    now = Gfs.Runtime.now(runtime)

    {count, _} =
      Repo.delete_all(
        from(l in Lease,
          where: l.expires_at <= ^now or not is_nil(l.revoked_at)
        )
      )

    if count > 0 do
      IO.puts("ExpireLeases: removed #{count} expired/revoked leases")
    end

    schedule()
    {:noreply, runtime}
  end

  defp schedule do
    Process.send_after(self(), :expire_leases, @interval_ms)
  end
end
