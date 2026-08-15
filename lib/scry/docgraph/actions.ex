defmodule Scry.DocGraph.Actions do
  @moduledoc """
  Turns the *merged* (core + `scry_document`'s own fragment + `scry_graph`'s
  own fragment) parse tree into a `%Scry.Core.Query{}`, the exact same
  target `Scry.Core.Actions` produces alone.

  **Owns both fragments' own extra rules directly, rather than
  delegating to `Scry.Document.Actions`/`Scry.Graph.Actions`
  themselves.** Each of those two modules already has its own
  catch-all `handle_rule/3` that delegates to `Scry.Core.Actions` and
  rescues *only* a `FunctionClauseError` raised by `Scry.Core.Actions`
  itself (`delegate_had_no_clause?/2`'s own `e.module == Scry.Core.Actions`
  check) -- chaining through either one first would mean a rule the
  *other* fragment owns (`:via_item` reaching `Scry.Document.Actions`,
  say) raises a `FunctionClauseError` from the wrong module and gets
  mis-handled by the generic `Ichor.Node` fallback instead of that
  rule's own real handler. Owning every extra rule directly in one
  module -- the same delegation-not-composition shape every other
  kind's own `Actions` module already establishes, just combining two
  fragments' worth here instead of one -- sidesteps that entirely.

  `body_item_ep1`'s own merged definition is a five-way `Choice`
  (`parent_field | siblings_field | ancestors_field | via_item |
  path_item`, `Scry.DocGraph.Grammar`'s own moduledoc has the "why this
  union, not a collision" story) -- `body_item_ep1`'s own handler below
  dispatches across all five, each clause identical to its single-kind
  counterpart in `Scry.Document.Actions`/`Scry.Graph.Actions`.

  `body_item`'s own handler, in `Scry.Core.Actions`, already wraps
  whatever `body_item_ep1`'s own handler returns as `{:variant, value}`
  -- confirmed by reading it directly, the same finding `scry_document`'s/
  `scry_graph`'s own identical comments already established. A resolved
  query's own `select` list can therefore contain `{:variant, {:parent,
  body}}`/`{:variant, {:siblings, body}}`/`{:variant, {:ancestors,
  body}}`/`{:variant, {:via, edge, opts, body}}`/`{:variant, :path}`,
  each independently nestable inside any of the others' own bodies (an
  ordinary `body_list` reference, resolved once merged, same as every
  other kind's own pseudo-field/block body) -- `Scry.DocGraph.Executor`
  is what actually interprets these tagged tuples; `Scry.Core.Executor`/
  `Scry.Core.QueryOps` have no notion of any of them.
  """

  @behaviour Ichor.Actions

  alias Ichor.Capture

  @impl true
  def handle_token(name, text, ctx) do
    Scry.Core.Actions.handle_token(name, text, ctx)
  rescue
    e in FunctionClauseError ->
      if delegate_had_no_clause?(e, :handle_token) do
        {:ok, text, ctx}
      else
        reraise e, __STACKTRACE__
      end
  end

  # Bare `DEEP`, EP1(a) header modifier -- owned by
  # `scry_document`'s own fragment only (`scry_graph` contributes no
  # `select_ep1a` fill), identical to `Scry.Document.Actions`'s own
  # handler.
  @impl true
  def handle_rule(:select_ep1a, _captures, ctx), do: {:ok, :deep, ctx}

  # `body_item_ep1 := parent_field | siblings_field | ancestors_field |
  # via_item | path_item` (the merged five-way Choice) -- a bare
  # single-capture alternation, same dispatch-by-sub-capture shape every
  # other kind's own identically-shaped extension point already
  # establishes.
  def handle_rule(:body_item_ep1, %{parent_field: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:body_item_ep1, %{siblings_field: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:body_item_ep1, %{ancestors_field: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:body_item_ep1, %{via_item: cap}, ctx), do: cap.eval.(ctx)
  def handle_rule(:body_item_ep1, %{path_item: cap}, ctx), do: cap.eval.(ctx)

  # `PARENT { <body> }`/`SIBLINGS { <body> }`/`ANCESTORS { <body> }` --
  # identical to `Scry.Document.Actions`'s own handlers.
  def handle_rule(:parent_field, %{inner: inner_cap}, ctx) do
    with {:ok, body, ctx} <- inner_cap.eval.(ctx), do: {:ok, {:parent, body}, ctx}
  end

  def handle_rule(:siblings_field, %{inner: inner_cap}, ctx) do
    with {:ok, body, ctx} <- inner_cap.eval.(ctx), do: {:ok, {:siblings, body}, ctx}
  end

  def handle_rule(:ancestors_field, %{inner: inner_cap}, ctx) do
    with {:ok, body, ctx} <- inner_cap.eval.(ctx), do: {:ok, {:ancestors, body}, ctx}
  end

  # `VIA <edge> [modifiers] { <body> }`/`PATH` -- identical to `Scry.
  # Graph.Actions`'s own handlers.
  def handle_rule(:via_item, captures, ctx) do
    with {:ok, edge, ctx} <- captures.edge.eval.(ctx),
         {:ok, shortest, ctx} <- maybe_eval(captures, :shortest_clause, ctx),
         {:ok, backward, ctx} <- maybe_eval(captures, :backward_clause, ctx),
         {:ok, hops, ctx} <- maybe_eval(captures, :hops_clause, ctx),
         {:ok, where_pred, ctx} <- maybe_eval(captures, :where_clause, ctx),
         {:ok, distinct, ctx} <- maybe_eval(captures, :distinct_clause, ctx),
         {:ok, order_bys, ctx} <- maybe_eval(captures, :order_by_clause, ctx),
         {:ok, limit_and_offset, ctx} <- maybe_eval(captures, :limit_clause, ctx),
         {:ok, body, ctx} <- captures.inner.eval.(ctx) do
      {limit, offset} = if limit_and_offset == :absent, do: {nil, nil}, else: limit_and_offset

      opts = %{
        shortest: shortest != :absent,
        backward: backward != :absent,
        hops: absent_to(nil, hops),
        where: absent_to(nil, where_pred),
        distinct: distinct != :absent,
        order_bys: absent_to([], order_bys),
        limit: limit,
        offset: offset
      }

      {:ok, {:via, edge, opts, body}, ctx}
    end
  end

  def handle_rule(:hops_clause, %{from: from_cap, to: to_cap}, ctx) do
    with {:ok, from, ctx} <- from_cap.eval.(ctx),
         {:ok, to, ctx} <- to_cap.eval.(ctx) do
      {:ok, {from, to}, ctx}
    end
  end

  def handle_rule(:path_item, _captures, ctx), do: {:ok, :path, ctx}

  def handle_rule(rule, captures, ctx) do
    Scry.Core.Actions.handle_rule(rule, captures, ctx)
  rescue
    e in FunctionClauseError ->
      if delegate_had_no_clause?(e, :handle_rule) do
        default_handle_rule(rule, captures, ctx)
      else
        reraise e, __STACKTRACE__
      end
  end

  # Ported from `Scry.Graph.Actions`'s own identical helper -- `Scry.
  # Core.Actions.handle_rule/3` is `defp`-adjacent in spirit but exposed
  # as a plain public function; `maybe_eval/3` itself is genuinely `defp`
  # there, so it isn't reusable directly.
  defp maybe_eval(captures, key, ctx) do
    case Map.fetch(captures, key) do
      {:ok, cap} -> cap.eval.(ctx)
      :error -> {:ok, :absent, ctx}
    end
  end

  defp absent_to(default, :absent), do: default
  defp absent_to(_default, value), do: value

  defp delegate_had_no_clause?(%FunctionClauseError{} = e, expected_function) do
    e.module == Scry.Core.Actions and e.function == expected_function and e.arity == 3
  end

  # `default_handle_rule/3`/`build_node/3`: a direct port of
  # `Ichor.Actions`'s own identically-named private functions
  # (`ichor_runtime`, `lib/ichor/actions.ex`) -- see `Scry.Document.
  # Actions`'s/`Scry.Graph.Actions`'s own identical functions for why a
  # port, not a call, is necessary here.
  defp default_handle_rule(rule_name, captures, ctx) when map_size(captures) == 1 do
    case Map.to_list(captures) do
      [{_name, %Capture{} = cap}] -> cap.eval.(ctx)
      [{_name, list}] when is_list(list) -> build_node(rule_name, captures, ctx)
    end
  end

  defp default_handle_rule(rule_name, captures, ctx), do: build_node(rule_name, captures, ctx)

  defp build_node(rule_name, captures, ctx) do
    with {:ok, resolved, ctx} <- Ichor.Actions.eval_all(captures, ctx) do
      {:ok, %Ichor.Node{rule: rule_name, captures: resolved, span: nil}, ctx}
    end
  end
end
