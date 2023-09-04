defmodule Foreach.MixProject do
  use Mix.Project

  def project do
    [
      app: :foreach,
      version: "0.1.0",
      elixir: "~> 1.16-dev",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp get_argparser_path() do
    Path.join [System.get_env("HOME"), "Scripts", "argparser"]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:argparser, path: get_argparser_path()}
      # {:dep_from_hexpm, "~> 0.3.0"},
      # {:dep_from_git, git: "https://github.com/elixir-lang/my_dep.git", tag: "0.1.0"}
    ]
  end
end
