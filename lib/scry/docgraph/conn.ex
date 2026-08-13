defmodule Scry.DocGraph.Conn do
  @moduledoc """
  The combined document tree + graph adjacency `Scry.DocGraph.Executor.
  run/3` reads from -- a reference structure, not a real backing adapter
  (the same "why no `scry_engine_*` package this round" reasoning `Scry.
  Document.Conn`'s/`Scry.Graph.Conn`'s own moduledocs already give).

  Two parts:

    * `data` -- the exact `%{[String.t(), ...] => [row]}` shape `Scry.
      Document.Conn`'s own `data` *and* `Scry.Graph.Conn`'s own `nodes`
      already share (confirmed directly, not assumed -- both packages'
      own `Conn` moduledocs independently describe the identical shape).
      One space serves both roles at once here: a key's own segments
      are tree position (`Scry.Document.Conn`'s own convention, needed
      for `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS`) *and* every row in it
      is a potential graph node (`Scry.Graph.Conn`'s own convention,
      needed for `VIA`/`PATH`) -- there is no second, separate `nodes`
      map, since a document row and a graph node were never two
      different kinds of thing to begin with, just two vocabularies for
      addressing the same stored rows.
    * `edges` -- the exact `%{{id, edge_name} => [id, ...]}` shape
      `Scry.Graph.Conn`'s own `edges` already has, unchanged.

  **Unlike `Scry.Graph.Conn`, not every row needs a string `"id"`
  field** -- only ones that actually participate in a `VIA` traversal
  (as a start node or an edge target) do. `Scry.DocGraph.Executor`'s own
  id index is built by *skipping* any row with no `"id"` (or a non-string
  one), a deliberate widening from `Scry.Graph.Conn`'s own stricter
  `Map.fetch!/2` (which requires every node, store-wide, to have one) --
  a document row with no graph role at all is a real, common shape here
  in a way it never is in a pure `scry_graph` store.
  """

  @typedoc "Keyed by a document's own tree position -- segment order encodes nesting."
  @type data :: %{optional([String.t(), ...]) => [Scry.Core.EngineBehaviour.row()]}

  @typedoc "Outgoing adjacency: `{from_id, edge_name}` -> every reachable `to_id` one hop away."
  @type edges :: %{optional({String.t(), String.t()}) => [String.t()]}

  @type t :: %__MODULE__{data: data(), edges: edges()}

  defstruct data: %{}, edges: %{}

  @doc "Builds a `Conn` from plain `data`/`edges` maps -- both empty by default."
  @spec new(data(), edges()) :: t()
  def new(data \\ %{}, edges \\ %{}) when is_map(data) and is_map(edges) do
    %__MODULE__{data: data, edges: edges}
  end
end
