# Changelog

## [Unreleased]

### Added

- The `document` + `graph` composite kind (impl_spec.md §2/§6) -- a real fused executor,
  not a thin delegate: `document` and `graph` are each independent kinds that bypass
  `Scry.Core.EngineBehaviour` with their own bespoke executors, each recognizing only
  its own `{:variant, ...}` tags, so composing `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS`
  with `VIA`/`PATH` in the same query body needed a genuinely new dispatcher
  (`Scry.DocGraph.Executor`), reusing every mechanic `Scry.Document.Executor`/`Scry.
  Graph.Executor` already established (source resolution incl. `DEEP`, the marker-
  per-row ordering technique, `resolve_correlated_nested/5` for a nested `SELECT`) --
  see that module's own moduledoc for the full mechanics.
  Both a document *key* and a `VIA` traversal's own `path_rows` accumulator are threaded
  through every recursive body-projection call together, so a `VIA` hop can land back in
  the document tree via a nested `PARENT`/`SIBLINGS`/`ANCESTORS`, and vice versa -- a
  real, tested composition (`test/scry/docgraph_test.exs`), not a hypothetical one.
  `path_rows` resets to `nil` when recursing into a `PARENT`/`SIBLINGS`/`ANCESTORS` body
  (a stated scope decision, not an oversight): a bare `PATH` written directly inside one
  of those, with no intervening `VIA` of its own, is `{:error, {:unsupported,
  :path_outside_via}}`, the same error it already is anywhere outside a `VIA`.
  Any special construct (`PARENT`/`SIBLINGS`/`ANCESTORS`/`VIA`/`PATH`/a nested `SELECT`)
  alongside `GROUP BY` is `{:error, {:unsupported, :special_item_with_group_by}}` -- a
  fresh atom name, since this is new code with no pre-existing atom of its own to
  preserve, unlike `scry_document`'s/`scry_graph`'s own reused
  `:pseudo_field_with_group_by`/`:via_with_group_by`.
  `Scry.DocGraph.Conn` combines `scry_document`'s own document tree and `scry_graph`'s
  own edge adjacency into one `data`/`edges` struct (one row space serves both roles at
  once, not two separate stores) -- widened from `scry_graph`'s own `Scry.Graph.Conn`
  to *skip* any row with no `"id"` when building the reverse id index, rather than crash,
  since not every document row in a composite store has (or needs) a graph role.
  This package contributes no grammar fragment of its own -- `Scry.DocGraph.Grammar`
  folds core's grammar with *both* `scry_document`'s and `scry_graph`'s own `priv/
  grammar.aether` fragments (`Scry.Core.GrammarCompose.merge/2`'s own
  union-not-collision extension-point semantics is what makes this produce one real
  grammar, not a collision -- confirmed directly, not assumed).
