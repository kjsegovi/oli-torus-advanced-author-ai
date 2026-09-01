defmodule Oli.GenAI.ModuleCapabilitiesTest do
  use ExUnit.Case, async: false

  alias Oli.GenAI.ModuleCapabilities

  @lazy_fixture Oli.GenAI.ModuleCapabilitiesTest.LazyFixture

  test "loads a module before checking an optional callback" do
    make_reloadable(@lazy_fixture, "metadata(_, _, _) -> ok.")

    refute function_exported?(@lazy_fixture, :metadata, 3)
    assert ModuleCapabilities.supports?(@lazy_fixture, :metadata, 3)
    assert function_exported?(@lazy_fixture, :metadata, 3)
  end

  defp make_reloadable(module, body) do
    directory =
      Path.join(System.tmp_dir!(), "module_capabilities_#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    source_path = Path.join(directory, "fixture.erl")

    File.write!(source_path, """
    -module('#{module}').
    -export([metadata/3]).
    #{body}
    """)

    {:ok, ^module, binary} = :compile.file(String.to_charlist(source_path), [:binary])
    File.write!(Path.join(directory, Atom.to_string(module) <> ".beam"), binary)
    :code.add_patha(String.to_charlist(directory))

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
      :code.del_path(String.to_charlist(directory))
      File.rm_rf!(directory)
    end)
  end
end
