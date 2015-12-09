# System.at_exit fn _ -> Logger.flush end
Logger.configure(level: :info)
ExUnit.start exclude: [:uses_usec, :id_type, :read_after_writes, :sql_fragments, :decimal_type, :invalid_prefix, :transaction, :foreign_key_constraint]

Application.put_env(:ecto, :primary_key_type, :binary_id)

Code.require_file "../deps/ecto/integration_test/support/repo.exs", __DIR__
Code.require_file "../deps/ecto/integration_test/support/models.exs", __DIR__
Code.require_file "../deps/ecto/integration_test/support/migration.exs", __DIR__

# Basic test repo
alias Ecto.Integration.TestRepo

Application.put_env(:ecto, TestRepo,
                    adapter: Mongo.Ecto,
                    url: "ecto://localhost:27017/ecto_test",
                    pool_size: 1)

defmodule Ecto.Integration.TestRepo do
  use Ecto.Integration.Repo, otp_app: :ecto
end

defmodule Ecto.Integration.Case do
  use ExUnit.CaseTemplate

  alias Ecto.Integration.TestRepo

  setup_all do
    :ok
  end

  setup do
    Mongo.Ecto.truncate(TestRepo)
    :ok
  end
end

_   = Ecto.Storage.down(TestRepo)
:ok = Ecto.Storage.up(TestRepo)

{:ok, pid} = TestRepo.start_link
:ok = TestRepo.stop(pid, :infinity)
{:ok, _pid} = TestRepo.start_link

# We capture_io, because of warnings on references
ExUnit.CaptureIO.capture_io fn ->
  :ok = Ecto.Migrator.up(TestRepo, 0, Ecto.Integration.Migration, log: false)
end
