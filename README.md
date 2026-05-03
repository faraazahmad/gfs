# Gfs

**TODO: Add description**

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `gfs` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:gfs, "~> 0.1.0"}
  ]
end
```

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/gfs>.

## Get Started

You can run the server in either `manager` or `chunkserver` mode by:

```bash
mix run --no-halt -- <MODE>
```

Where `<MODE>` is either `manager` or `chunkserver`.

or run using `iex` with:

```bash
 iex --cookie <COOKIE> --sname <shortname> -S mix run -- <MODE>
```
Where:
* `<shortname>` is any name you want to give to the node
* `<COOKIE>` is string to be used as cookie. It needs to be the same between 2 nodes for them to find and connect with
each other.

## Debug cluster (1 manager + 3 chunkservers)

To bring up a local debug cluster of 1 manager and 3 chunkservers, each in its
own `iex` session split across 4 tmux panes, run:

```bash
make debug          # start (or restart) the debug session
make debug-stop     # kill the debug session
make debug-clean    # wipe per-node SQLite DBs and start fresh
```

This requires [tmux](https://github.com/tmux/tmux). Each chunkserver gets its
own SQLite file under `~/.gfs/database/debug/` (overridable via
`GFS_DB_ROOT`). The cookie defaults to `gfsdev` (override with `GFS_COOKIE`).
