Logger.configure(level: :info)
ExUnit.start

Code.require_file "../deps/ecto/integration_test/support/repo.exs", __DIR__
Code.require_file "../deps/ecto/integration_test/support/models.exs", __DIR__
Code.require_file "../deps/ecto/integration_test/support/migration.exs", __DIR__

# Basic test repo
alias Ecto.Integration.TestRepo

Application.put_env(:ecto, TestRepo,
  adapter: MongodbEcto,
  url: "ecto://localhost:27017/ecto_test",
  size: 1)

defmodule Ecto.Integration.TestRepo do
  use Ecto.Integration.Repo, otp_app: :ecto
end

defmodule Ecto.Integration.Case do
  use ExUnit.CaseTemplate

  setup_all do
    Ecto.Storage.up(TestRepo)
    on_exit fn -> Ecto.Storage.down(TestRepo) end
    :ok
  end

  setup do
    Ecto.Storage.down(TestRepo)
    Ecto.Storage.up(TestRepo)
    :ok
  end
end

# Load up the repository, start it, and run migrations
_   = Ecto.Storage.down(TestRepo)
:ok = Ecto.Storage.up(TestRepo)

{:ok, _pid} = TestRepo.start_link

# :ok = Ecto.Migrator.up(TestRepo, 0, Ecto.Integration.Migration, log: false)
