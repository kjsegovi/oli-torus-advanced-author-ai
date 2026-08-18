defmodule Oli.Repo.Migrations.EnforceOpenstaxV6Cutover do
  use Ecto.Migration

  @moduledoc """
  Retains the historical migration timestamp without imposing a database-wide
  cutover on persisted OpenStax imports.

  New runs enforce the current source and plan contracts in application
  changesets. The later preservation migration owns the permissive database
  constraints needed by legacy rows.
  """

  def change do
    :ok
  end
end
