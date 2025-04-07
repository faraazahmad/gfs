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
