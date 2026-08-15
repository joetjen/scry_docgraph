defmodule Scry.DocGraph.Grammar do
  @moduledoc """
  Composes core's own grammar with *both* `scry_document`'s and
  `scry_graph`'s own `priv/grammar.aether` fragments -- folded twice
  (`Scry.Core.GrammarCompose.merge/2`'s own moduledoc documents exactly
  this: "to compose more than one fragment, fold this over a list").

  **This package contributes no grammar fragment of its own.** Unlike
  `scry_document`/`scry_graph`, there is no `priv/grammar.aether` here
  -- `relational`/`document`/`graph` between them already cover every
  syntactic extension this composite needs (`select_ep1a` for `DEEP`,
  `body_item_ep1` for `PARENT`/`SIBLINGS`/`ANCESTORS`/`VIA`/`PATH`), and
  `Scry.Core.GrammarCompose`'s own union-not-collision semantics for
  extension-point rules (its own moduledoc: "an extension point is not
  'exactly one fragment may define this rule'") is exactly what makes
  folding both fragments into one grammar produce a single, real
  `body_item_ep1` `Choice` over all five alternatives (`parent_field`/
  `siblings_field`/`ancestors_field`/`via_item`/`path_item`) rather than
  a collision -- confirmed directly by reading `merge/2`'s own
  `union_rule/2`, not assumed.

  **Not** the production parse path -- `Scry.DocGraph.parse/1` calls the
  checked-in, pre-generated `Scry.DocGraph.Grammar.Compiled` (`priv/gen/
  generate_compiled_grammar.exs` is its generator, run by hand; never
  hand-edit the generated file). `compile/0` here stays, for the same
  reasons `scry_document`'s/`scry_graph`'s own identical functions do:
  the generator script itself needs the merged-but-unanalyzed grammar,
  and it's a cheap, direct way to test the merge/composition mechanics
  themselves without round-tripping through codegen.

  Uses `:code.priv_dir/1` (via `Scry.Document.Grammar.grammar_path/0`/
  `Scry.Graph.Grammar.grammar_path/0`, both already public for exactly
  this reuse), not a path relative to the current working directory --
  resolves correctly both from this package's own test suite and from a
  downstream adapter depending on this package as an ordinary compiled
  dependency.
  """

  # See Scry.Core.Grammar's own identical `@compile {:no_warn_undefined,
  # ...}` comment for the full reasoning -- `Aether.Parser.parse/2`/
  # `Grammar.Analysis.run/1` are genuinely undefined when this module
  # compiles as a dependency of a package that never declares `ichor`
  # itself, and neither is ever actually called by such a consumer.
  @compile {:no_warn_undefined, {Aether.Parser, :parse, 2}}
  @compile {:no_warn_undefined, {Grammar.Analysis, :run, 1}}

  # See Scry.Core.Grammar's own identical attribute/comment for why this
  # is registered rather than a bare module attribute, and why the
  # Sobelow skip below is justified the same way theirs is.
  Module.register_attribute(__MODULE__, :sobelow_skip, persist: true)

  @doc """
  Parses `scry_document`'s and `scry_graph`'s own fragments, folds both
  into core's own unanalyzed grammar in turn, and runs `Grammar.
  Analysis` on the merged result.
  """
  @sobelow_skip ["Traversal.FileModule"]
  @spec compile() :: {:ok, Aether.Grammar.t()} | {:error, term()}
  def compile do
    doc_path = Scry.Document.Grammar.grammar_path()
    graph_path = Scry.Graph.Grammar.grammar_path()

    with {:ok, doc_source} <- File.read(doc_path),
         {:ok, doc_fragment} <- Aether.Parser.parse(doc_source, doc_path),
         {:ok, graph_source} <- File.read(graph_path),
         {:ok, graph_fragment} <- Aether.Parser.parse(graph_source, graph_path),
         {:ok, core} <- Scry.Core.Grammar.compile_unanalyzed(),
         {:ok, with_document} <- Scry.Core.GrammarCompose.merge(core, doc_fragment),
         {:ok, merged} <- Scry.Core.GrammarCompose.merge(with_document, graph_fragment) do
      Grammar.Analysis.run(merged)
    end
  end
end
