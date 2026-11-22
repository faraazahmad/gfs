defmodule Gfs.MixProject do
  use Mix.Project

  def project do
    [
      app: :gfs,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: aliases()
    ]
  end
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]
  defp aliases, do: [test: "test --no-start"]

  def nodes do
    []
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      env: [nodes: nodes(), manager_node: nil],
      extra_applications: [:logger],
      mod: {Gfs.App, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ecto, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17.2"},
      {:bandit, "~> 1.5"},
      {:ex_ulid, "~> 0.1.0"},
      {:jason, "~> 1.4"},
      {:httpoison, "~> 2.2"}
    ]
  end
end
