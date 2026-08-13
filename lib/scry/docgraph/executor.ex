defmodule Scry.DocGraph.Executor do
  @moduledoc """
  Runs a parsed docgraph query against a `Scry.DocGraph.Conn.t()` --
  interprets `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS` (lang_spec.md §8.3)
  *and* `VIA`/`PATH` (lang_spec.md §8.1) in the same query body, each
  independently nestable inside any of the others.

  **Why this needs a genuinely new dispatcher, not a delegation to
  `Scry.Document.Executor` or `Scry.Graph.Executor` alone.** Both of
  those already bypass `Scry.Core.EngineBehaviour` for the identical
  reason (`Scry.Document.Executor`'s own moduledoc has the full "why
  this can't be a pure AST-rewrite-then-delegate pass" story: `DEEP`/
  `PARENT`/`SIBLINGS`/`ANCESTORS`/`VIA`/`PATH` all need access to the
  *whole* stored space, not just the rows behind one already-resolved
  source) -- but each one's own `special_items?/1`/`project_body/...`
  recognizes only its *own* `{:variant, ...}` tags, so handing a query
  combining `PARENT` with `VIA` to either one alone crashes the same way
  a nested `SELECT` alone used to (`Scry.Core.QueryOps.
  resolve_correlated_nested/5`'s own moduledoc has that story). Unlike
  `scry_reltime`/`scry_reldoc` (`relational` is a *degenerate* kind
  contributing nothing syntactically, so a thin delegate is
  correct there), `document` and `graph` are each real, independent
  kinds -- composing them for real means one dispatcher that recognizes
  *both* vocabularies at once, which is what this module is.

  **Concretely, reusing every mechanic `Scry.Document.Executor`/`Scry.
  Graph.Executor` already established, fused into one:**

    * Source resolution (`DEEP` included) is `Scry.Document.Executor`'s
      own -- `Scry.Graph.Conn`'s own `nodes` and `Scry.Document.Conn`'s
      own `data` already share the identical `%{[String.t(), ...] =>
      [row]}` shape (`Scry.DocGraph.Conn`'s own moduledoc has the full
      "why one space, not two" reasoning), so `Scry.DocGraph.Conn.t()`'s
      own `data` field serves as both at once.
    * An `"id"`-keyed index (`Scry.Graph.Executor`'s own `build_id_index/1`,
      widened here to *skip* any row with no `"id"` rather than crash --
      `Scry.DocGraph.Conn`'s own moduledoc explains why that widening is
      correct for a composite store) is built once per query whenever
      any special item is present, the same "build once, not per-row"
      shape `Scry.Graph.Executor` already has, letting `VIA` reach any
      target node regardless of which document key it lives under.
    * `PARENT`/`SIBLINGS`/`ANCESTORS` resolve relative to a row's own
      document *key* (`Scry.Document.Executor`'s own recursive
      `project_body`/`resolve_pseudo_field` mechanics, unchanged);
      `VIA`/`PATH` resolve relative to a row's own `"id"` and the
      current traversal's own accumulated `path_rows` (`Scry.Graph.
      Executor`'s own `resolve_via`/`add_path` mechanics, unchanged).
      **Both a document key *and* a `path_rows` accumulator are threaded
      through every recursive `project_body` call together** -- the one
      genuinely new piece this fusion needs, since `Scry.Graph.Conn`'s
      own `id_index` value (`{source, row}`) already carries a
      traversal target's own document key for free (`source` there
      *is* a document key, `Scry.DocGraph.Conn`'s own one-space design),
      so recursing from a `VIA` hop into a nested `PARENT`/`SIBLINGS`/
      `ANCESTORS` -- or vice versa -- is a real, tested composition, not
      a hypothetical one.
    * **Nesting one pseudo-construct inside another wraps, it doesn't
      flatten** -- the same rule `Scry.Document.Executor`'s own
      moduledoc already states, unchanged, now covering `VIA`/`PATH` too.
    * **`path_rows` resets to `nil` when recursing into a `PARENT`/
      `SIBLINGS`/`ANCESTORS` body** -- a genuine, stated scope decision,
      not an oversight: those three jump to an entirely different
      document position, so the enclosing `VIA`'s own traversal no
      longer describes "how we got here." A bare `PATH` immediately
      inside such a body is therefore `{:error, {:unsupported,
      :path_outside_via}}`, the same error it already is anywhere
      outside a `VIA` at all -- consistent, not a special case. A `VIA`
      nested *inside* a `PARENT`/`SIBLINGS`/`ANCESTORS` body starts its
      own, fresh `path_rows` regardless (`resolve_via/8` always computes
      one from scratch), so this only affects a bare `PATH` written
      directly inside a `PARENT`/`SIBLINGS`/`ANCESTORS` body with no
      intervening `VIA` of its own.
    * A nested `%Scry.Core.Query{}` body item resolves via `Scry.Core.
      QueryOps.resolve_correlated_nested/5`, `fetch_fn` recursing into
      this module's own `run/3` -- identical to `Scry.Document.
      Executor`'s/`Scry.Graph.Executor`'s own fix, and the same `own_name`
      ("always the *original, top-level* query's own source, last
      segment only") scope limit both of those already state applies
      here unchanged.
    * **Scope limit, stated rather than silently unsupported**: any
      special item (`PARENT`/`SIBLINGS`/`ANCESTORS`/`VIA`/`PATH`/a
      nested `SELECT`) alongside `GROUP BY` returns `{:error,
      {:unsupported, :special_item_with_group_by}}` -- a fresh atom
      name (this is new code, not a modification of either single-kind
      package's own pre-existing atom, so there's nothing to preserve
      by reusing theirs), the same underlying reasoning both already
      state: an aggregated/grouped result no longer corresponds to one
      specific node. `%Scry.Core.CombinedQuery{}` is `{:error,
      {:unsupported, :combined_query}}`, not the focal capability.
    * Ordinary `WHERE`/`ORDER BY`/`LIMIT`/`OFFSET`/plain-field
      projection delegate to `Scry.Core.QueryOps.run_flat/3`, exactly
      like both single-kind executors already do.
  """

  alias Scry.Core.{Cursor, Query, QueryOps}
  alias Scry.DocGraph.Conn

  @docgraph_key_field "__scry_docgraph_key__"
  @path_marker_field "__scry_docgraph_path__"

  @doc """
  Runs `query` against `conn`, returning a lazy `Scry.Core.Cursor.t()`
  -- the same widened contract every other kind's own `Executor.run/3,4,5`
  already has.
  """
  @spec run(Query.t() | Scry.Core.CombinedQuery.t(), Conn.t(), map()) ::
          {:ok, Cursor.t()} | {:error, term()}
  def run(query, conn, params \\ %{})

  def run(%Scry.Core.CombinedQuery{}, %Conn{}, _params) do
    {:error, {:unsupported, :combined_query}}
  end

  def run(%Query{} = query, %Conn{data: document} = conn, params) do
    with {:ok, matches} <- resolve_source(document, query.source, deep?(query)) do
      if special_items?(query.select) do
        with :ok <- validate_no_grouping(query),
             {:ok, ordered} <- order_and_limit(matches, query, params) do
          own_name = List.last(query.source)
          id_index = build_id_index(document)

          case project_all(ordered, query.select, id_index, conn, own_name, params) do
            {:ok, rows} -> {:ok, Cursor.new(rows)}
            {:error, _reason} = error -> error
          end
        end
      else
        # Neither a PARENT/SIBLINGS/ANCESTORS/VIA/PATH pseudo-construct
        # nor a nested SELECT anywhere in this query's own top-level
        # select -- nothing docgraph-specific to do. Delegating
        # wholesale, unmodified query included, is the correctness-
        # critical path here (GROUP BY/aggregation needs `run_flat/3` to
        # see every row belonging to a group at once), the same
        # reasoning `Scry.Document.Executor`'s/`Scry.Graph.Executor`'s
        # own identical fast paths already state.
        rows = Enum.map(matches, fn {_key, row} -> row end)

        with {:ok, enumerable} <- QueryOps.run_flat(rows, query, params) do
          {:ok, Cursor.new(enumerable)}
        end
      end
    end
  end

  defp special_items?(body_items) do
    Enum.any?(body_items, fn
      {:variant, {kind, _body}} when kind in [:parent, :siblings, :ancestors] -> true
      {:variant, {:via, _edge, _opts, _body}} -> true
      {:variant, :path} -> true
      %Query{} -> true
      _other -> false
    end)
  end

  defp deep?(%Query{variant: %{select_ep1a: :deep}}), do: true
  defp deep?(_query), do: false

  defp validate_no_grouping(%Query{group_bys: []}), do: :ok
  defp validate_no_grouping(_query), do: {:error, {:unsupported, :special_item_with_group_by}}

  defp resolve_source(document, source, false) do
    case Map.fetch(document, source) do
      {:ok, rows} -> {:ok, Enum.map(rows, &{source, &1})}
      :error -> {:error, {:query_error, {:no_such_source, source}}}
    end
  end

  defp resolve_source(document, source, true) do
    matches =
      document
      |> Enum.filter(fn {key, _rows} -> deep_match?(key, source) end)
      |> Enum.sort_by(fn {key, _rows} -> key end)
      |> Enum.flat_map(fn {key, rows} -> Enum.map(rows, &{key, &1}) end)

    {:ok, matches}
  end

  defp deep_match?(key, [only]), do: List.last(key) == only

  defp deep_match?(key, source) do
    List.first(key) == List.first(source) and List.last(key) == List.last(source)
  end

  # `"id"`-keyed reverse index -- widened from `Scry.Graph.Executor`'s
  # own `build_id_index/1` (`Map.fetch!/2`, crashing on any id-less
  # row) to *skip* rows with no string `"id"` instead: `Scry.DocGraph.
  # Conn`'s own moduledoc states this is correct here, since not every
  # document row in a composite store has (or needs) a graph role.
  defp build_id_index(document) do
    for {key, rows} <- document,
        row <- rows,
        id = Map.get(row, "id"),
        is_binary(id),
        into: %{} do
      {id, {key, row}}
    end
  end

  # Threads a unique, synthetic per-row index through `run_flat/3` (not
  # the document key itself -- two distinct matched rows can legitimately
  # share the same key) so the post-filter/order/limit survivor list can
  # be mapped back to its own original `{key, row}` pair. Identical to
  # `Scry.Document.Executor`'s own `order_and_limit/3`.
  defp order_and_limit(matches, query, params) do
    indexed = Enum.with_index(matches)
    lookup = Map.new(indexed, fn {{key, row}, idx} -> {idx, {key, row}} end)

    tagged_rows =
      Enum.map(indexed, fn {{_key, row}, idx} -> Map.put(row, @docgraph_key_field, idx) end)

    marker_query = %{query | select: [{:field, [@docgraph_key_field]}]}

    with {:ok, marker_rows} <- QueryOps.run_flat(tagged_rows, marker_query, params) do
      ordered =
        marker_rows
        |> Enum.to_list()
        |> Enum.map(fn %{@docgraph_key_field => idx} -> Map.fetch!(lookup, idx) end)

      {:ok, ordered}
    end
  end

  defp project_all(ordered, select, id_index, conn, own_name, params) do
    ordered
    |> Enum.map(fn {key, row} ->
      project_body(key, row, select, id_index, conn.edges, nil, conn, own_name, params)
    end)
    |> Enum.split_with(&match?({:error, _}, &1))
    |> case do
      {[], oks} -> {:ok, Enum.map(oks, fn {:ok, row} -> row end)}
      {[first_error | _], _rows} -> first_error
    end
  end

  # Projects one already-resolved `{key, row}` (or `{end_key, end_row}`
  # reached via a `VIA` hop) against `body`. Splits `body` into ordinary
  # fields, a nested `%Scry.Core.Query{}` (Scry's own `JOIN` equivalent),
  # `PARENT`/`SIBLINGS`/`ANCESTORS`, `VIA`, and a bare `PATH`, and
  # resolves each independently before merging into one map -- this
  # module's own moduledoc has the full "why both `key` and `path_rows`
  # thread through every recursive call together" reasoning.
  defp project_body(key, row, body, id_index, edges, path_rows, conn, own_name, params) do
    {flat_select, nested_items, pseudo_items, via_items, has_path?} = partition_body(body)

    with {:ok, base} <- project_ordinary(row, flat_select, params),
         {:ok, with_nested} <- add_nested_results(base, nested_items, row, conn, own_name, params),
         {:ok, with_path} <- add_path(with_nested, has_path?, path_rows),
         {:ok, with_pseudo} <-
           add_pseudo_results(
             with_path,
             pseudo_items,
             key,
             id_index,
             edges,
             conn,
             own_name,
             params
           ) do
      add_via_results(with_pseudo, via_items, row, id_index, edges, conn, own_name, params)
    end
  end

  defp partition_body(body_items) do
    {flat, nested, pseudo, vias, has_path?} =
      Enum.reduce(body_items, {[], [], [], [], false}, fn item,
                                                          {flat, nested, pseudo, vias, has_path?} ->
        case item do
          %Query{} = q ->
            {flat, [q | nested], pseudo, vias, has_path?}

          {:variant, {kind, item_body}} when kind in [:parent, :siblings, :ancestors] ->
            {flat, nested, [{Atom.to_string(kind), kind, item_body} | pseudo], vias, has_path?}

          {:variant, {:via, edge, opts, inner}} ->
            {flat, nested, pseudo, [{edge, opts, inner} | vias], has_path?}

          {:variant, :path} ->
            {flat, nested, pseudo, vias, true}

          other ->
            {[other | flat], nested, pseudo, vias, has_path?}
        end
      end)

    {Enum.reverse(flat), Enum.reverse(nested), Enum.reverse(pseudo), Enum.reverse(vias),
     has_path?}
  end

  defp add_nested_results(base, [], _row, _conn, _own_name, _params), do: {:ok, base}

  defp add_nested_results(base, nested_items, row, conn, own_name, params) do
    Enum.reduce_while(nested_items, {:ok, base}, fn nested, {:ok, acc} ->
      fetch_fn = fn q, p ->
        with {:ok, cursor} <- run(q, conn, p) do
          {:ok, Cursor.to_list(cursor)}
        end
      end

      case QueryOps.resolve_correlated_nested(nested, row, own_name, params, fetch_fn) do
        {:ok, rows} -> {:cont, {:ok, Map.put(acc, List.last(nested.source), rows)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp add_path(base, false, _path_rows), do: {:ok, base}
  defp add_path(_base, true, nil), do: {:error, {:unsupported, :path_outside_via}}
  defp add_path(base, true, path_rows), do: {:ok, Map.put(base, "path", path_rows)}

  defp project_ordinary(_row, [], _params), do: {:ok, %{}}

  # The `QueryOps.run_flat/3` call just below is `.dialyzer_ignore.exs`'s
  # own `:call` entry -- a confirmed dialyzer false positive (verified
  # this exact struct literal round-trips correctly at runtime), see
  # that file's own comment for the full explanation. Mirrors `Scry.
  # Document.Executor`'s/`Scry.Graph.Executor`'s own identical function.
  defp project_ordinary(row, select, params) do
    flat_query = %Query{
      source: nil,
      wheres: [],
      group_bys: [],
      group_mode: :plain,
      havings: [],
      distinct: false,
      order_bys: [],
      limit: nil,
      offset: nil,
      required: false,
      select: select,
      variant: %{},
      with_bindings: %{},
      type_decls: %{}
    }

    case QueryOps.run_flat([row], flat_query, params) do
      {:ok, enumerable} ->
        case Enum.to_list(enumerable) do
          [projected] -> {:ok, projected}
          [] -> {:ok, %{}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  # `resolve_pseudo_field/8`/`project_first/7` return `{:ok, value} |
  # {:error, reason}`, not a bare value the way `Scry.Document.Executor`'s
  # own identically-named functions do -- a real difference forced by
  # this fusion: a `PARENT`/`SIBLINGS`/`ANCESTORS` body can now itself
  # contain a `VIA`/`PATH` (a bare `PATH` with no enclosing `VIA` of its
  # own is a real error, `add_path/3`'s own `:path_outside_via` case),
  # so an error raised deep inside one of these bodies has to propagate
  # all the way back out through `project_body/9`, not crash a hardcoded
  # `{:ok, projected} = project_body(...)` match the way the single-kind
  # package's own (VIA/PATH-free) version safely could.
  defp add_pseudo_results(base, [], _key, _id_index, _edges, _conn, _own_name, _params),
    do: {:ok, base}

  defp add_pseudo_results(base, pseudo_items, key, id_index, edges, conn, own_name, params) do
    Enum.reduce_while(pseudo_items, {:ok, base}, fn {output_key, kind, nested_body}, {:ok, acc} ->
      case resolve_pseudo_field(kind, nested_body, key, id_index, edges, conn, own_name, params) do
        {:ok, value} -> {:cont, {:ok, Map.put(acc, output_key, value)}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp resolve_pseudo_field(:parent, body, key, id_index, edges, conn, own_name, params) do
    case parent_key(key) do
      nil -> {:ok, nil}
      parent_key -> project_first(parent_key, body, id_index, edges, conn, own_name, params)
    end
  end

  defp resolve_pseudo_field(:siblings, body, key, id_index, edges, conn, own_name, params) do
    parent = parent_key(key)

    siblings =
      conn.data
      |> Enum.filter(fn {k, _rows} -> k != key and parent_key(k) == parent end)
      |> Enum.sort_by(fn {k, _rows} -> k end)
      |> Enum.flat_map(fn {sibling_key, rows} -> Enum.map(rows, &{sibling_key, &1}) end)

    Enum.reduce_while(siblings, {:ok, []}, fn {sibling_key, row}, {:ok, acc} ->
      case project_body(sibling_key, row, body, id_index, edges, nil, conn, own_name, params) do
        {:ok, projected} -> {:cont, {:ok, [projected | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = err -> err
    end
  end

  defp resolve_pseudo_field(:ancestors, body, key, id_index, edges, conn, own_name, params) do
    Enum.reduce_while(ancestor_keys(key), {:ok, []}, fn ancestor_key, {:ok, acc} ->
      case project_first(ancestor_key, body, id_index, edges, conn, own_name, params) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      {:error, _} = err -> err
    end
  end

  defp project_first(key, body, id_index, edges, conn, own_name, params) do
    case Map.fetch(conn.data, key) do
      {:ok, [row | _rest]} ->
        project_body(key, row, body, id_index, edges, nil, conn, own_name, params)

      _absent ->
        {:ok, nil}
    end
  end

  defp parent_key([_single]), do: nil
  defp parent_key(key), do: Enum.drop(key, -1)

  defp ancestor_keys(key) when length(key) <= 1, do: []
  defp ancestor_keys(key), do: for(i <- (length(key) - 1)..1//-1, do: Enum.take(key, i))

  defp add_via_results(base, [], _row, _id_index, _edges, _conn, _own_name, _params),
    do: {:ok, base}

  defp add_via_results(base, [{edge, opts, inner}], row, id_index, edges, conn, own_name, params) do
    with {:ok, results} <-
           resolve_via(row, edge, opts, inner, id_index, edges, conn, own_name, params) do
      {:ok, Map.put(base, "via", results)}
    end
  end

  defp add_via_results(base, via_items, row, id_index, edges, conn, own_name, params) do
    via_items
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, base}, fn {{edge, opts, inner}, idx}, {:ok, acc} ->
      case resolve_via(row, edge, opts, inner, id_index, edges, conn, own_name, params) do
        {:ok, results} -> {:cont, {:ok, Map.put(acc, "via_#{idx}", results)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp resolve_via(row, edge, opts, inner_body, id_index, edges, conn, own_name, params) do
    with {:ok, start_id} <- fetch_id(row) do
      edge_name = Enum.join(edge, ".")
      {from, to} = opts.hops || {1, 1}
      adjacency = if opts.backward, do: incoming_adjacency(edges), else: edges
      all_paths = enumerate_paths(adjacency, edge_name, start_id, from, to)
      candidate_paths = if opts.shortest, do: keep_shortest(all_paths), else: all_paths

      with {:ok, ordered_paths} <- filter_and_order_paths(candidate_paths, opts, id_index, params) do
        projected =
          Enum.map(ordered_paths, fn path_ids ->
            path_rows = Enum.map(path_ids, fn id -> elem(Map.fetch!(id_index, id), 1) end)
            {end_key, end_row} = Map.fetch!(id_index, List.last(path_ids))

            project_body(
              end_key,
              end_row,
              inner_body,
              id_index,
              edges,
              path_rows,
              conn,
              own_name,
              params
            )
          end)

        case Enum.split_with(projected, &match?({:error, _}, &1)) do
          {[], oks} ->
            rows = Enum.map(oks, fn {:ok, r} -> r end)
            rows = if opts.distinct, do: Enum.uniq(rows), else: rows
            rows = rows |> maybe_drop(opts.offset) |> maybe_take(opts.limit)
            {:ok, rows}

          {[first_error | _], _rows} ->
            first_error
        end
      end
    end
  end

  defp fetch_id(row) do
    case Map.fetch(row, "id") do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:unsupported, :node_missing_id}}
    end
  end

  # Every simple path (no revisiting a node within the same path) of
  # depth in [min_hops, max_hops]. Identical to `Scry.Graph.Executor`'s
  # own `enumerate_paths/5`/`collect_paths/7`.
  defp enumerate_paths(adjacency, edge, start_id, min_hops, max_hops) do
    collect_paths(adjacency, edge, [start_id], 0, min_hops, max_hops, [])
  end

  defp collect_paths(adjacency, edge, path, depth, min_hops, max_hops, acc) do
    acc = if depth >= min_hops, do: [Enum.reverse(path) | acc], else: acc

    if depth >= max_hops do
      acc
    else
      current = hd(path)
      neighbors = Map.get(adjacency, {current, edge}, [])

      Enum.reduce(neighbors, acc, fn neighbor, acc2 ->
        if neighbor in path do
          acc2
        else
          collect_paths(adjacency, edge, [neighbor | path], depth + 1, min_hops, max_hops, acc2)
        end
      end)
    end
  end

  defp keep_shortest(paths) do
    paths
    |> Enum.group_by(&List.last/1)
    |> Enum.flat_map(fn {_end_id, group} ->
      min_len = group |> Enum.map(&length/1) |> Enum.min()
      Enum.filter(group, &(length(&1) == min_len))
    end)
  end

  defp incoming_adjacency(edges) do
    Enum.reduce(edges, %{}, fn {{from_id, edge}, to_ids}, acc ->
      Enum.reduce(to_ids, acc, fn to_id, acc2 ->
        Map.update(acc2, {to_id, edge}, [from_id], &[from_id | &1])
      end)
    end)
  end

  # `WHERE`/`ORDER BY` only -- evaluated against each candidate path's
  # own raw end-node row, via the same synthetic-marker technique
  # `order_and_limit/3` above uses. Identical to `Scry.Graph.Executor`'s
  # own `filter_and_order_paths/4`.
  defp filter_and_order_paths(paths, opts, id_index, params) do
    indexed = Enum.with_index(paths)
    lookup = Map.new(indexed, fn {path, idx} -> {idx, path} end)

    tagged_rows =
      Enum.map(indexed, fn {path, idx} ->
        end_id = List.last(path)
        {_key, end_row} = Map.fetch!(id_index, end_id)
        Map.put(end_row, @path_marker_field, idx)
      end)

    query = %Query{
      source: nil,
      wheres: if(opts.where, do: [opts.where], else: []),
      group_bys: [],
      group_mode: :plain,
      havings: [],
      distinct: false,
      order_bys: opts.order_bys,
      limit: nil,
      offset: nil,
      required: false,
      select: [{:field, [@path_marker_field]}],
      variant: %{},
      with_bindings: %{},
      type_decls: %{}
    }

    with {:ok, enumerable} <- QueryOps.run_flat(tagged_rows, query, params) do
      ordered =
        enumerable
        |> Enum.to_list()
        |> Enum.map(fn %{@path_marker_field => idx} -> Map.fetch!(lookup, idx) end)

      {:ok, ordered}
    end
  end

  defp maybe_drop(rows, nil), do: rows
  defp maybe_drop(rows, n), do: Enum.drop(rows, n)

  defp maybe_take(rows, nil), do: rows
  defp maybe_take(rows, n), do: Enum.take(rows, n)
end
