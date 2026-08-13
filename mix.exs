defmodule Scry.DocGraph.MixProject do
  use Mix.Project

  @version "0.1.0"

  # `mix precommit` includes `test` as a step; without this, Mix runs
  # the whole alias chain (including `mix test`) in :dev, and `mix test`
  # itself refuses to run outside :test when invoked as a sub-task
  # rather than the top-level command.
  def cli do
    [preferred_envs: [precommit: :test]]
  end

  def project do
    [
      app: :scry_docgraph,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "Scry.DocGraph",
      docs: docs(),
      aliases: aliases(),
      test_coverage: [tool: ExCoveralls],
      # `:ichor` needs to be listed explicitly here now that it's
      # `runtime: false` (only [:dev, :test]) -- dialyxir's default PLT
      # scan draws on the compiled app's own `:applications` list, which
      # a `runtime: false` dependency is deliberately excluded from, even
      # though it's still genuinely present and compiled in this
      # (`:test`) env, and `Scry.DocGraph.Grammar`/the generator script
      # still reference its types/functions directly. Matches
      # `scry_document`'s/`scry_graph`'s own identical comment.
      dialyzer: [plt_add_apps: [:mix, :ichor], ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      # === SCRY CORE ===
      # A local path dependency, not a Hex version constraint, since
      # scry_core isn't published to Hex yet -- see scry_document's/
      # scry_graph's own identical comment.
      {:scry_core, path: "../scry_core"},

      # === SCRY DOCUMENT / SCRY GRAPH ===
      # Real (not dev/test-only) path dependencies -- this package
      # composes its own grammar by folding *both* of these packages'
      # own `priv/grammar.aether` fragments in with core's (`Scry.
      # DocGraph.Grammar.compile/0`, the generator script), and that's
      # real, public API here (`compile/0` mirrors every other kind's
      # own identically-named function), not a dev/test-only
      # implementation detail. Neither package's own `Executor`/`Conn`
      # is reused, though -- this package's own fused executor and
      # `Scry.DocGraph.Conn` are new, not delegated (see `Scry.DocGraph.
      # Executor`'s own moduledoc for why: composing two bypass-
      # executors that each recognize only their own tags needs a
      # genuinely new dispatcher, unlike `scry_reltime`/`scry_reldoc`).
      {:scry_document, path: "../scry_document"},
      {:scry_graph, path: "../scry_graph"},

      # === ICHOR (grammar compiler) ===
      # Same reasoning as scry_document's/scry_graph's own identical
      # comment: `Scry.DocGraph.parse/1` runs queries through `Scry.
      # DocGraph.Grammar.Compiled`, a checked-in, pre-generated module
      # (`priv/gen/generate_compiled_grammar.exs` is its generator, run
      # by hand). The generated module only calls `ichor_runtime`, never
      # `ichor`.
      {:ichor_runtime, "~> 0.2"},
      {:ichor, "~> 0.2", only: [:dev, :test], runtime: false},

      # === CODE QUALITY & STATIC ANALYSIS ===
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.14", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: [:dev, :test], runtime: false},
      # Credo is invoked via `MIX_ENV=test mix credo`
      # Dialyzer is invoked via `MIX_ENV=test mix dialyzer`
      # Sobelow is invoked via `MIX_ENV=test mix sobelow`
      # Coveralls is invoked via `MIX_ENV=test mix coveralls

      # === TESTING ===
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # === DEVELOPMENT TOOLING ===
      # Mix, and Hex are built-in (no deps needed)
      {:ex_doc, "~> 0.40", only: [:dev], runtime: false}
      # ExDoc is invoked via `MIX_ENV=dev mix docs`
    ]
  end

  # Fast/cheap checks first so a broken commit fails quickly; dialyzer
  # (slowest, especially its first PLT build) runs last.
  defp aliases do
    [
      precommit: [
        "format",
        "compile --warnings-as-errors",
        "credo --strict",
        # `--skip`: honors `@sobelow_skip` annotations on specific
        # functions (AGENTS.md: a low-confidence finding needs a
        # targeted, justified skip, never a blanket suppression) --
        # without this flag Sobelow ignores the annotation entirely and
        # reports the finding anyway. Matches scry_document's/scry_graph's
        # own alias -- this package has the identical `File.read(path)`
        # shape (`Scry.DocGraph.Grammar.compile/0`) that needs it.
        "sobelow --skip",
        "test",
        "dialyzer"
      ]
    ]
  end

  defp description do
    "The document + graph composite kind for Scry (impl_spec.md §2/§6) -- a real fused " <>
      "executor combining DEEP/PARENT/SIBLINGS/ANCESTORS with VIA/PATH in the same query body."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/joetjen/scry_docgraph"},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_url: "https://github.com/joetjen/scry_docgraph",
      source_ref: "v#{@version}",
      extras: extras()
    ]
  end

  defp extras do
    [
      "README.md",
      "CHANGELOG.md",
      "LICENSE"
    ]
  end
end
