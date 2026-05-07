# GFS: Migrating from REST/HTTP to BEAM-Native Distribution

This document describes a phased migration plan to move the internal
("east‑west") communication of the GFS clone away from REST/HTTP and onto
BEAM-native distribution primitives (`Node`, `:pg`, `:erpc`,
`Process.monitor`, `:net_kernel.monitor_nodes`), while keeping HTTP as the
external ("north‑south") boundary for clients.

It captures both the *why* (trade‑offs) and the *how* (concrete API sketches,
phase boundaries, risks, and code shapes).

---

## 1. Background — what we have today

Two OTP applications:

- [`gfs`](file:///Users/faraaz/oss/gfs) — runs in either `manager` or
  `chunkserver` mode, dispatched by [`lib/app.ex`](file:///Users/faraaz/oss/gfs/lib/app.ex).
- [`gfs_client`](file:///Users/faraaz/oss/gfs_client) — a thin HTTPoison-based
  client library, see [`lib/gfs/client.ex`](file:///Users/faraaz/oss/gfs_client/lib/gfs/client.ex).

### Manager process tree
[`lib/manager/app.ex`](file:///Users/faraaz/oss/gfs/lib/manager/app.ex) starts:

- `Gfs.Manager.Repo` — SQLite via Ecto
- `{Bandit, plug: Gfs.Manager.RestApi}` — HTTP on port 4000
  ([`lib/manager/rest_api.ex`](file:///Users/faraaz/oss/gfs/lib/manager/rest_api.ex))
- `Gfs.Manager.Task.MonitorNodes`
  ([`lib/manager/tasks/monitor_nodes.ex`](file:///Users/faraaz/oss/gfs/lib/manager/tasks/monitor_nodes.ex))
- `Gfs.Manager.Task.ExpireLeases`
  ([`lib/manager/tasks/expire_leases.ex`](file:///Users/faraaz/oss/gfs/lib/manager/tasks/expire_leases.ex))

### ChunkServer process tree
[`lib/chunk_server/app.ex`](file:///Users/faraaz/oss/gfs/lib/chunk_server/app.ex) starts:

- `Gfs.ChunkServer.Repo` — SQLite via Ecto
- `Gfs.ChunkServer.Genserver` — currently only holds a per‑lease serial counter
  ([`lib/chunk_server/genserver.ex`](file:///Users/faraaz/oss/gfs/lib/chunk_server/genserver.ex))
- `{Bandit, plug: Gfs.ChunkServer.RestApi, port: <random>}`
  ([`lib/chunk_server/rest_api.ex`](file:///Users/faraaz/oss/gfs/lib/chunk_server/rest_api.ex))
- `Gfs.ChunkServer.Task.MonitorNodes`
  ([`lib/chunk_server/tasks/monitor_nodes.ex`](file:///Users/faraaz/oss/gfs/lib/chunk_server/tasks/monitor_nodes.ex))

### Data flow today

```diagram
╭────────────╮  HTTP/JSON   ╭──────────╮
│ gfs_client │─────────────▶│ Manager  │  (lease)
╰────┬───────╯              ╰──────────╯
     │ HTTP/JSON (base64)
     ▼
╭────────────╮  HTTP/JSON   ╭────────────╮
│  Primary   │─────────────▶│ Secondary  │
│ ChunkSrv   │              │ ChunkSrv   │
╰─────┬──────╯              ╰────────────╯
      │ HTTP/JSON (commit)
      ▼
   Manager
```

Notable properties:

- Replication payload is base64‑encoded JSON: a 64 MiB chunk inflates to
  ~86 MiB, requiring `length: 128 * 1024 * 1024` on the chunkserver Plug parser.
- ChunkServers pick an ephemeral HTTP port at boot
  ([`get_free_port/0`](file:///Users/faraaz/oss/gfs/lib/chunk_server/app.ex#L25-L31)),
  so the Manager has to re‑discover it each time via a single BEAM call:
  `GenServer.call({:chunkserver, node}, :manager_connect)`
  ([`refresh_node_http_port/1`](file:///Users/faraaz/oss/gfs/lib/manager/tasks/monitor_nodes.ex#L86-L108)).
- The only existing BEAM-native call in the system is that one port-discovery
  RPC. *Everything else* is HTTP.

---

## 2. Why migrate?

### 2.1 Pros of the current REST/HTTP architecture

- **Good external boundary.** Any non-BEAM client (Go, Python, curl) can talk
  to it.
- **Operationally familiar.** Easy to inspect, replay, log.
- **Security boundary is clean.** Clients do *not* need the Erlang cookie or
  cluster membership.
- **Transport decoupled.** Chunkservers can be replaced as long as routes
  remain stable.

### 2.2 Cons of the current architecture

- **Expensive payload encoding.** Base64 + JSON for 64 MiB blobs forces a
  128 MiB Plug body limit. CPU and memory are wasted on encode/decode.
- **Stale ephemeral ports.** Every chunkserver reboot invalidates manager DB
  state until the manager re-runs its port refresh.
- **Sequential replication.** [`replicate_to_secondaries/6`](file:///Users/faraaz/oss/gfs/lib/chunk_server/rest_api.ex#L145-L170)
  uses `Enum.reduce_while`, replicating one secondary at a time.
- **Transport-coupled logic.** Lease issuance and metadata writes live
  *inside* Plug handlers in [`rest_api.ex`](file:///Users/faraaz/oss/gfs/lib/manager/rest_api.ex),
  making them hard to call from anywhere else.
- **Weaker failure model.** HTTP 500/502 timeouts hide what BEAM already gives
  you for free: `:nodedown`, `:DOWN`, `:noproc`, `:timeout`.
- **Per-hop overhead.** Plug parsing + HTTPoison client + Bandit server, all
  inside a *trusted* cluster.

### 2.3 Pros of BEAM-native intra-cluster transport

- **No JSON/base64 inflation** for cluster-internal messages.
- **Eliminates the ephemeral-port problem** — internal addressing uses
  `node()` + named process or pid, not host:port.
- **Native failure detection.** `:net_kernel.monitor_nodes/1`,
  `Process.monitor/1`, `:erpc` errors are first-class.
- **Lower CPU per request.** Skip Plug + HTTP entirely for east-west traffic.
- **Cleaner control plane.** Lease/commit/renew become normal function calls.

### 2.4 Cons of BEAM-native architecture

- **Distributed Erlang is a trusted-cluster protocol.** The cookie *is* your
  auth: anyone with it is "inside the cluster".
- **Non-BEAM clients lose direct access.** You need to keep an HTTP edge or
  rebuild a different external API.
- **Binaries are still copied per destination node.** BEAM distribution
  serializes binaries; you save the JSON/base64 overhead, not the network
  copy itself.
- **Single-mailbox hotspots are catastrophic.** A naive
  `GenServer.call(:chunkserver, {:append, 64MiB_binary})` will block the
  whole process behind one giant message.
- **LAN-oriented.** Distributed Erlang is awkward across NAT, WAN, or
  zero-trust boundaries.
- **Cookie auth is coarse.** No per-client roles, no scoped tokens.

---

## 3. Target architecture

> **Rule of thumb:** *East-west = BEAM. North-south = HTTP.*

```diagram
╭────────────╮   HTTP/JSON     ╭────────────────────╮
│ gfs_client │────────────────▶│ Manager (Bandit)   │  ← edge stays HTTP
╰────────────╯                 ╰─────────┬──────────╯
                                         │  :erpc / :pg
                                         ▼
                              ╭──────────────────────╮
                              │   Gfs.Manager.       │
                              │   Metadata service   │
                              ╰──────────┬───────────╯
                                         │ :erpc (commit, renew)
                                         ▲
                                         │
        :erpc (apply_replica) ╭──────────┴──────────╮
   ╭────────────────────────▶ │   Primary ChunkSrv  │
   │                          ╰──────────┬──────────╯
   ▼                                     │ local FS append
╭────────────╮                           ▼
│ Secondary  │                    ~/.gfs/chunks/<id>
│ ChunkSrv   │
╰────────────╯
```

Key choices:

- **Manager remains the single metadata authority.** No multi-master, no
  consensus layer required for this rewrite.
- **`:pg` is the chunkserver registry.** No DB-stored host/port for internal
  addressing.
- **`:erpc` is the internal RPC.** Prefer it over `:rpc` for the hot path.
- **`Task.async_stream` for fan-out replication.** Parallelism with
  bounded concurrency and explicit timeouts.
- **HTTP persists at the edge** for the client API and for human/operator
  debugging.
- **`gfs_client` stays HTTP by default.** Don't widen the cookie's blast
  radius.

---

## 4. Concrete API sketches

### 4.1 Transport-neutral services

```elixir
defmodule Gfs.Manager.Metadata do
  @spec ensure_file(binary()) :: {:ok, file_id :: term()} | {:error, term()}
  def ensure_file(path)

  @spec acquire_append_lease(binary()) ::
          {:ok,
           %{
             lease_id: binary(),
             expires_at: DateTime.t(),
             chunk: %{uniq_id: binary(), version: integer(),
                      start_byte: integer(), end_byte: integer()},
             primary: replica_ref(),
             secondaries: [replica_ref()]
           }}
          | {:error, :file_not_found | :invalid_path | :conflict | :no_alive_replicas}
  def acquire_append_lease(path)

  @spec allocate_next_chunk(binary()) ::
          {:ok, %{chunk: map(), replicas: [replica_ref()]}} | {:error, term()}
  def allocate_next_chunk(path)

  @spec renew_lease(binary(), integer()) ::
          {:ok, %{lease_id: binary(), expires_at: DateTime.t()}} | {:error, :lease_not_active}
  def renew_lease(lease_id, primary_chunk_server_id)

  @spec commit_append(binary(), binary(), non_neg_integer(), integer()) ::
          :ok | {:error, :lease_not_found | :lease_expired}
  def commit_append(lease_id, chunk_uniq_id, bytes_appended, primary_chunk_server_id)
end
```

```elixir
defmodule Gfs.ChunkServer.Control do
  use GenServer

  # only small messages here
  def describe(pid),         do: GenServer.call(pid, :describe)
  def next_serial(pid, lid), do: GenServer.call(pid, {:next_serial, lid})
end
```

```elixir
defmodule Gfs.ChunkServer.Data do
  @spec append_primary(map(), binary()) ::
          :ok | {:error, :chunk_full | :lease_expired
                | :replication_failed | :commit_failed}
  def append_primary(lease, payload)

  @spec apply_replica(binary(), binary(), integer(), integer(), binary()) ::
          :ok | {:error, :chunk_full | :lease_expired | :out_of_order}
  def apply_replica(chunk_id, lease_id, version, serial_no, payload)

  @spec read_chunk(binary()) :: {:ok, binary()} | {:error, term()}
  def read_chunk(chunk_id)
end
```

### 4.2 Route → BEAM mapping

| Current HTTP route | Replace with |
|---|---|
| `GET /chunk_servers` | `:pg.get_members(:gfs_chunkservers)` + `Control.describe/1` |
| `POST /file/:encoded_path` | `Gfs.Manager.Metadata.ensure_file/1` |
| `GET /file/:encoded_path/lease` | `Gfs.Manager.Metadata.acquire_append_lease/1` |
| `POST /file/:encoded_path/chunk` | `Gfs.Manager.Metadata.allocate_next_chunk/1` |
| `POST /lease/:lease_id/renew` | `Gfs.Manager.Metadata.renew_lease/2` |
| `POST /lease/:lease_id/commit` | `Gfs.Manager.Metadata.commit_append/4` |
| `PUT /append/chunk/:chunk_id` | `:erpc.call(primary_node, Gfs.ChunkServer.Data, :append_primary, [lease, payload])` |
| `PUT /replicate/chunk/:chunk_id` | `:erpc.call(secondary_node, Gfs.ChunkServer.Data, :apply_replica, [chunk_id, lease_id, version, serial_no, payload])` |

### 4.3 Discovery via `:pg` (replaces stale-port DB lookups)

On chunkserver boot:

```elixir
def init(state) do
  :ok = :pg.join(:gfs_chunkservers, self())
  {:ok, state}
end
```

On manager:

```elixir
def list_chunkservers do
  :pg.get_members(:gfs_chunkservers)
  |> Enum.map(&Gfs.ChunkServer.Control.describe/1)
end
```

Use:

- `Node.connect/1` only for bootstrap.
- `:pg` for membership.
- `Process.monitor/1` for chunkserver process liveness.
- `:net_kernel.monitor_nodes(true)` for node liveness.
- **Prefer `:erpc` over `:rpc`** for the hot path.
- Avoid `:global` here — too coarse, unnecessary.

### 4.4 Replication without a single-mailbox hotspot

```elixir
def append_primary(lease, payload) do
  serial_no = Gfs.ChunkServer.Serials.next(lease.lease_id)   # ETS counter

  with :ok <- append_local(lease.chunk.uniq_id, payload),
       :ok <- replicate_parallel(lease.secondaries, lease, serial_no, payload),
       :ok <- :erpc.call(lease.manager.node,
                         Gfs.Manager.Metadata, :commit_append,
                         [lease.lease_id, lease.chunk.uniq_id,
                          byte_size(payload), lease.primary.id]) do
    :ok
  end
end

defp replicate_parallel(secondaries, lease, serial_no, payload) do
  secondaries
  |> Task.async_stream(
    fn replica ->
      :erpc.call(
        replica.node,
        Gfs.ChunkServer.Data,
        :apply_replica,
        [lease.chunk.uniq_id, lease.lease_id,
         lease.chunk.version, serial_no, payload],
        15_000
      )
    end,
    ordered: false,
    timeout: 15_000,
    max_concurrency: length(secondaries)
  )
  |> Enum.reduce_while(:ok, fn
    {:ok, :ok}, _ -> {:cont, :ok}
    other,     _ -> {:halt, {:error, {:replication_failed, other}}}
  end)
end
```

The 64 MiB payload is the *function argument* — not a `GenServer.call` to a
single registered process — so there is no head-of-line blocking on a shared
mailbox. The serial counter lives in ETS (`:update_counter`) so the data path
never funnels through one `Control` GenServer.

---

## 5. Phased migration plan

### Phase 0 — Extract logic from Plug routers
**Effort: M (1–3h). Risk: low.**

1. Create `Gfs.Manager.Metadata`, `Gfs.ChunkServer.Data`,
   `Gfs.ChunkServer.Control`.
2. Move all current Plug-handler logic into them; have the Plug routes
   delegate.
3. Fix correctness bugs in the existing monitors before depending on them:
   - Both `MonitorNodes` use a single `receive` block — they handle exactly
     one `:nodeup`/`:nodedown` event then exit. Convert each to a looping
     `GenServer` (or `receive` loop) that keeps consuming events.
   - The chunkserver's `:nodedown` handler currently passes `true` to
     `update_node_status/2`, marking the node alive when it just went down.
     Pass `false`.
   - `Gfs.Manager.RestApi.create_new_file_chunk/2` inserts a chunk row with no
     replica selection — it diverges from the chunk allocation done at file
     creation. Unify both paths through `Metadata.allocate_next_chunk/1`.
4. Add tests against `Gfs.Manager.Metadata` directly (no HTTP).

**Why first:** one canonical implementation per operation, callable from
both HTTP handlers and BEAM remote callers, is the prerequisite for every
subsequent phase.

### Phase 1 — Replace chunkserver discovery with `:pg`
**Effort: M (1–3h). Risk: low.**

1. Each chunkserver joins `:gfs_chunkservers` from its `Control` GenServer.
2. Manager replaces SQL/HTTP-port discovery with `:pg.get_members/1` +
   `Control.describe/1`.
3. Internal addressing is now `{node(), chunk_server_id}` — no stale ports.
4. `Process.monitor/1` each discovered control pid; treat `:DOWN` as
   "chunkserver gone".
5. Keep `Node.connect/1` only for bootstrap-from-config.

**Wins:** the manager's `refresh_node_http_port/1` dance disappears for
internal traffic, and `GET /chunk_servers` is no longer needed internally.

### Phase 2 — Move control plane to `:erpc`
**Effort: M (1–3h). Risk: medium.**

Replace these chunkserver→manager HTTP calls:

- `POST /lease/:id/commit` → `:erpc.call(manager_node, Metadata, :commit_append, [...])`
- `POST /lease/:id/renew` → `:erpc.call(manager_node, Metadata, :renew_lease, [...])`

HTTP routes still exist for external clients but call the same
`Gfs.Manager.Metadata` functions. Add `:erpc` timeouts and explicit error
mapping (`{:erpc, :timeout}` → `{:error, :transient}` etc.).

### Phase 3 — Move data plane to `:erpc`
**Effort: L (1–2 days). Risk: medium.**

1. Implement `Gfs.ChunkServer.Data.append_primary/2` and `apply_replica/5`.
2. Primary does: local append → parallel `Task.async_stream` of `:erpc.call`
   to each secondary → `:erpc.call` to manager for commit.
3. Move serial-number generation to ETS (`:ets.update_counter/3`) so it never
   sits in the same mailbox as a 64 MiB payload.
4. Add backpressure:
   - `max_concurrency` in `Task.async_stream`.
   - A semaphore (e.g. counter ETS or a small `:counters` array) to cap
     in-flight appends per chunkserver; return `{:error, :overloaded}` when
     saturated.
5. Delete the chunkserver Bandit instance (or keep it gated behind a config
   flag for debugging).

**Hard rule for this phase:** never add a code path of the form
`GenServer.call(:chunkserver, {:append, big_binary})`. The whole point is
to avoid funneling 64 MiB through a single mailbox.

### Phase 4 — Decide the client boundary
**Effort: S–M.**

Recommended default: **keep `gfs_client` on HTTP.**

- Keep manager Bandit running for control operations.
- If you keep direct client→chunkserver upload, replace base64 JSON with
  `application/octet-stream` (raw binary body) — that alone removes the
  inflation.
- Provide `Gfs.Client.Beam` only for *trusted internal Elixir services*. For
  those, lease responses can return `node()` + chunkserver pid/id instead of
  HTTP host/port, and the client does its own `:erpc.call`.

If and only if every future client is a trusted BEAM app (e.g. all consumers
are internal Elixir services on the same VPC):

- Remove chunkserver Bandit entirely.
- Make manager BEAM-callable too (`Gfs.Manager.Metadata` exposed via `:erpc`).
- The HTTP edge becomes optional/admin-only.

---

## 6. Trade-offs and guardrails

- **Network copies still happen.** Distributed Erlang serializes and copies
  binaries across nodes. BEAM-native saves base64/JSON/Plug overhead, *not*
  network bandwidth.
- **Avoid hot mailboxes.** Don't push large payloads through a registered
  GenServer. Keep large data flowing through plain function calls (which is
  what `:erpc.call` becomes on the receiver side: a fresh process executes
  the call).
- **Prefer `:erpc` over `:rpc`.** `:rpc` runs everything through a single
  `:rex` server on the remote node — exactly the bottleneck you don't want.
  `:erpc` spawns per-call.
- **Cookie = trust.** Any node with the cookie can call any function on any
  other node. Don't extend that trust to clients.
- **Don't proxy chunk data through the manager.** That centralizes bandwidth
  and memory at the worst place.
- **If HTTP stays externally, give chunkservers stable configured ports.**
  Random ephemeral ports are only acceptable when chunkservers are
  BEAM-internal.
- **Fix monitoring before depending on it.** The current one-shot `receive`
  tasks are too fragile for a real distributed system.
- **Unify chunk allocation semantics** before migration; do not carry
  inconsistent paths forward.

---

## 7. When to consider a fuller redesign

Move beyond this plan only if one of these becomes true:

- All clients are trusted Elixir/Erlang services on a private network.
- You need much higher append concurrency on the same chunk with strict
  ordering guarantees.
- You need to span multiple subnets / WAN / zero-trust links.
- The single manager becomes a bottleneck and you need metadata HA or
  partition tolerance.

In that world you'd add things like:

- `Gfs.Client.Beam` as the default client.
- Per-chunk append worker keyed by `{chunk_id, lease_id}` for strict
  in-order replication under concurrency.
- A consensus layer (Raft/`ra`, or `mnesia` with care) for manager HA.

But none of those are required to get the big wins in this document.

---

## 8. Summary

- **Pain points today** are stale ephemeral ports, base64+JSON inflation, and
  Plug/HTTPoison overhead on a trusted internal data path.
- **The fix** is to keep HTTP at the *edge* (the client boundary), and move
  every internal control- and data-plane interaction to BEAM primitives:
  `:pg` for discovery, `Process.monitor` for liveness, `:erpc` for calls,
  `Task.async_stream` for fan-out replication, ETS for serial counters.
- **Don't make the client a BEAM node by default.** That gives every client
  the cluster cookie — too much trust for a thin upload library.
- **Phase the work**: extract logic → discovery → control plane → data plane
  → decide on client. Each phase is independently shippable.

The end-state is a system where `mix.exs` still depends on `:bandit` for the
edge, but every internal hop is just a function call across nodes — with the
failure model, performance, and correctness BEAM was designed for.
