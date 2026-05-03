defmodule Gfs.Manager.Task.ExpireLeases do
  use GenServer
  import Ecto.Query

  alias Gfs.Manager.Repo
  alias Gfs.Schema.Lease

  @interval_ms 5_000

  def start_link(_args) do
    GenServer.start_link(__MODULE__, %{}, name: __MODULE__)
  end

  @impl true
  def init(state) do
    schedule()
    {:ok, state}
  end

  @impl true
  def handle_info(:expire_leases, state) do
    now = DateTime.utc_now()

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
    {:noreply, state}
  end

  defp schedule do
    Process.send_after(self(), :expire_leases, @interval_ms)
  end
end
