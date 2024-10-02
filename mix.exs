defmodule Gfs.MixProject do
  use Mix.Project

  def project do
    [
      app: :gfs,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def nodes do
    [
      :"alice@Syeds-MacBook-Pro.local",
      :"bob@Syeds-MacBook-Pro.local",
      :"charlie@Syeds-MacBook-Pro.local"
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      env: [nodes: nodes()],
      extra_applications: [:logger],
      mod: {Gfs.Manager.App, []},
      mod: {Gfs.ChunkServer, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17.2"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"}
    ]
  end
end
