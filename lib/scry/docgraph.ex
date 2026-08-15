defmodule Scry.DocGraph do
  @moduledoc """
  The `document` + `graph` composite kind for Scry --
  `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS` alongside
  `VIA`/`PATH`, in the same query body, each
  independently nestable inside any of the others.

  **A real fused executor, not a thin delegate** -- unlike `scry_reltime`/
  `scry_reldoc` (`relational` is a degenerate kind with no grammar/
  execution vocabulary of its own, so those two packages are pure
  delegation), `document` and `graph` are each real, independent kinds
  that both bypass `Scry.Core.EngineBehaviour` with their own bespoke,
  whole-space-needing executors, each recognizing only its *own*
  `{:variant, ...}` tags. Composing them for real needs a genuinely new
  dispatcher -- `Scry.DocGraph.Executor` -- not a delegation to either
  one alone. See that module's own moduledoc for the full mechanics.

  `parse/1` uses `Scry.DocGraph.Grammar.Compiled` -- checked-in,
  pre-generated from core folded with *both* `scry_document`'s and
  `scry_graph`'s own grammar fragments (`Scry.DocGraph.Grammar`'s own
  moduledoc has the full composition story; this package contributes no
  fragment of its own). A query using `DEEP` resolves into `query.
  variant.select_ep1a` (the bare atom `:deep`); `PARENT { ... }`/
  `SIBLINGS { ... }`/`ANCESTORS { ... }`/`VIA <edge> [...] { ... }`/a
  bare `PATH` all resolve into `{:variant, ...}`-tagged body items
  inside `query.select` (core's own `body_item` handler wraps every
  `body_item_ep1` contribution automatically). Neither construct is
  executed by `parse/1` itself -- see `Scry.DocGraph.Executor.run/3` for
  that.
  """

  alias Scry.Core.{CombinedQuery, Query}

  @doc """
  Parses `source` (Scry query text) into a `%Scry.Core.Query{}` (or a
  `%Scry.Core.CombinedQuery{}`, per `Scry.Core.parse/1`'s own combinator
  handling).
  """
  @spec parse(String.t()) :: {:ok, Query.t() | CombinedQuery.t()} | {:error, term()}
  def parse(source) when is_binary(source) do
    Scry.DocGraph.Grammar.Compiled.run(source, nil)
  end
end
