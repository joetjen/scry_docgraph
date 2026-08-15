# Scry.DocGraph

The `document` + `graph` composite kind for Scry -- `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS`
alongside `VIA`/`PATH`, in the same query body, each independently
nestable inside any of the others.

**A real fused executor, not a thin delegate** -- unlike `scry_reltime`/`scry_reldoc`
(`relational` is a degenerate kind with no grammar/execution vocabulary of its own, so
those two packages are pure delegation to a single underlying kind's own executor),
`document` and `graph` are each real, independent kinds that both bypass
`Scry.Core.EngineBehaviour` with their own bespoke, whole-space-needing executors, each
recognizing only its own `{:variant, ...}` tags. Composing them for real needs a
genuinely new dispatcher -- `Scry.DocGraph.Executor` -- which is what this package is.
See `Scry.DocGraph.Executor`'s own moduledoc for the full mechanics, including how
`PARENT`/`SIBLINGS`/`ANCESTORS` and `VIA`/`PATH` compose in both directions (a `VIA`
hop landing back in the document tree via `PARENT`, and vice versa), and the stated
scope decision for what happens to a bare `PATH` written inside a `PARENT`/`SIBLINGS`/
`ANCESTORS` body with no intervening `VIA` of its own.

`Scry.DocGraph.Conn` combines `scry_document`'s own `%{[String.t(), ...] => [row]}`
document tree and `scry_graph`'s own `{id, edge_name} => [id, ...]}` adjacency into one
`data`/`edges` struct -- one row space serves both a document position and a potential
graph node at once, rather than two separate stores (`Scry.DocGraph.Conn`'s own
moduledoc has the full reasoning, including a deliberate widening from `scry_graph`'s
own stricter "every row must have an id" requirement).

This package contributes no grammar fragment of its own -- `Scry.DocGraph.Grammar`
folds `scry_core`'s grammar with *both* `scry_document`'s and `scry_graph`'s own
`priv/grammar.aether` fragments (`Scry.Core.GrammarCompose.merge/2`'s own
union-not-collision semantics for extension-point rules is what makes this produce one
real grammar, not a collision).
