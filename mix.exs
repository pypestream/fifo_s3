defmodule Prime.Mixfile do
  use Mix.Project

  def project do
    [apps_path: "apps",
      build_embedded: Mix.env == :prod,
      start_permanent: Mix.env == :prod,
      deps: deps()]
  end

  defp deps do
    [{:common, path: "../../../../../apps/common/"},
    {:poolboy, git: "https://github.com/devinus/poolboy.git", tag: "1.5.1"},
    {:base16, git: "https://github.com/goj/base16.git", tag: "1.0.0"}
    ]
  end

end
