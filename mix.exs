defmodule Mongo.Ecto.Mixfile do
  use Mix.Project

  def project do
    [app: :mongodb_ecto,
     version: "0.0.1",
     elixir: "~> 1.0",
     deps: deps,
     test_coverage: [tool: ExCoveralls]]
  end

  def application do
    [applications: [:ecto, :mongodb]]
  end

  defp deps do
    [
      {:mongodb, github: "ericmj/mongodb", ref: "97e96a8de6f549d6fc42fad5666ecb253cdc29bf"},
      {:ecto, github: "elixir-lang/ecto", ref: "49ed0a534f9249b1f0215af7e9642c837ce02214"},
      {:inch_ex, only: :docs},
      {:dialyze, "~> 0.2.0", only: :dev},
      {:excoveralls, "~> 0.3.11", only: :test}
    ]
  end
end
