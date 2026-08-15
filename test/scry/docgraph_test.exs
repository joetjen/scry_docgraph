defmodule Scry.DocGraphTest do
  @moduledoc """
  The real proof this composite needs a fused executor, unlike `scry_reltime`/
  `scry_reldoc`: `DEEP`/`PARENT`/`SIBLINGS`/`ANCESTORS`
  composed with `VIA`/`PATH` *and* a correlated
  nested `SELECT`, in the same query body, each independently nestable
  inside any of the others -- executed end to end against a real
  `Scry.DocGraph.Conn`, not just asserted from either single-kind
  package's own worked examples.
  """

  use ExUnit.Case, async: true

  alias Scry.Core.Cursor
  alias Scry.DocGraph.Conn

  # A small org chart: a document tree (`company` is the parent of
  # `company.people`) whose people rows are *also* graph nodes, chained
  # by a "knows" edge -- exactly the "one space serves both roles"
  # design `Scry.DocGraph.Conn`'s own moduledoc describes. `reviews` is
  # an ordinary flat source with no document-tree nesting of its own,
  # correlated to a person's own "id" the same way any ordinary
  # relational nested SELECT correlates to an outer row's own field.
  @document %{
    ["company"] => [%{"name" => "Acme"}],
    ["company", "people"] => [
      %{"id" => "1", "name" => "Alice"},
      %{"id" => "2", "name" => "Bob"},
      %{"id" => "3", "name" => "Carol"}
    ]
  }

  @reviews [
    %{"person_id" => "1", "score" => 9},
    %{"person_id" => "2", "score" => 7}
  ]

  @edges %{
    {"1", "knows"} => ["2"],
    {"2", "knows"} => ["3"]
  }

  defp conn do
    Conn.new(Map.put(@document, ["reviews"], @reviews), @edges)
  end

  test "PARENT, VIA, and a correlated nested SELECT compose in the same body" do
    {:ok, query} =
      Scry.DocGraph.parse("""
      SELECT company.people ORDER BY id {
        name,
        PARENT { name },
        VIA knows { name },
        SELECT reviews WHERE person_id = people.id { score }
      }
      """)

    assert {:ok, cursor} = Scry.DocGraph.Executor.run(query, conn())
    rows = Cursor.to_list(cursor)

    assert rows == [
             %{
               "name" => "Alice",
               "parent" => %{"name" => "Acme"},
               "via" => [%{"name" => "Bob"}],
               "reviews" => [%{"score" => 9}]
             },
             %{
               "name" => "Bob",
               "parent" => %{"name" => "Acme"},
               "via" => [%{"name" => "Carol"}],
               "reviews" => [%{"score" => 7}]
             },
             %{
               "name" => "Carol",
               "parent" => %{"name" => "Acme"},
               "via" => [],
               "reviews" => []
             }
           ]
  end

  test "a VIA hop's own inner body can nest PARENT -- a graph traversal landing back in the document tree" do
    {:ok, query} =
      Scry.DocGraph.parse("""
      SELECT company.people ORDER BY id {
        name,
        VIA knows { name, PARENT { name } }
      }
      """)

    assert {:ok, cursor} = Scry.DocGraph.Executor.run(query, conn())
    rows = Cursor.to_list(cursor)

    assert [alice, bob, _carol] = rows
    assert alice["via"] == [%{"name" => "Bob", "parent" => %{"name" => "Acme"}}]
    assert bob["via"] == [%{"name" => "Carol", "parent" => %{"name" => "Acme"}}]
  end

  test "PATH resolves the full traversal, ids included, inside a VIA body" do
    {:ok, query} =
      Scry.DocGraph.parse("""
      SELECT company.people WHERE id = "1" {
        name,
        VIA knows HOPS 1-2 { name, PATH }
      }
      """)

    assert {:ok, cursor} = Scry.DocGraph.Executor.run(query, conn())
    assert [%{"name" => "Alice", "via" => via}] = Cursor.to_list(cursor)

    assert Enum.map(via, & &1["name"]) |> Enum.sort() == ["Bob", "Carol"]

    bob_hop = Enum.find(via, &(&1["name"] == "Bob"))
    assert Enum.map(bob_hop["path"], & &1["id"]) == ["1", "2"]

    carol_hop = Enum.find(via, &(&1["name"] == "Carol"))
    assert Enum.map(carol_hop["path"], & &1["id"]) == ["1", "2", "3"]
  end

  test "a bare PATH inside a PARENT nested inside a VIA is a clear error, not a stale path" do
    {:ok, query} =
      Scry.DocGraph.parse("""
      SELECT company.people WHERE id = "1" {
        VIA knows { PARENT { PATH } }
      }
      """)

    assert Scry.DocGraph.Executor.run(query, conn()) ==
             {:error, {:unsupported, :path_outside_via}}
  end

  test "DEEP resolves a source across every matching key, unaffected by VIA/PARENT alongside it" do
    {:ok, query} =
      Scry.DocGraph.parse("""
      SELECT people DEEP ORDER BY id {
        name,
        PARENT { name }
      }
      """)

    assert {:ok, cursor} = Scry.DocGraph.Executor.run(query, conn())

    assert Cursor.to_list(cursor) == [
             %{"name" => "Alice", "parent" => %{"name" => "Acme"}},
             %{"name" => "Bob", "parent" => %{"name" => "Acme"}},
             %{"name" => "Carol", "parent" => %{"name" => "Acme"}}
           ]
  end

  test "GROUP BY alongside any special item is declined explicitly" do
    {:ok, query} =
      Scry.DocGraph.parse("""
      SELECT company.people GROUP BY id {
        id,
        VIA knows { name }
      }
      """)

    assert Scry.DocGraph.Executor.run(query, conn()) ==
             {:error, {:unsupported, :special_item_with_group_by}}
  end

  test "an ordinary query with no pseudo-construct at all still works, unaffected" do
    {:ok, query} = Scry.DocGraph.parse("SELECT company.people ORDER BY id { name }")
    assert {:ok, cursor} = Scry.DocGraph.Executor.run(query, conn())

    assert Cursor.to_list(cursor) == [
             %{"name" => "Alice"},
             %{"name" => "Bob"},
             %{"name" => "Carol"}
           ]
  end
end
