defmodule Mongo.Ecto do
  @moduledoc """
  Adapter module for MongoDB

  It uses `mongo` for communicating with the database and manages
  a connection pool using `poolboy`.

  ## Features

    * Support for documents with ObjectID as their primary key
    * Support for insert, find, update and delete mongo functions
    * Support for management commands with `command/2`
  """

  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Storage

  alias Mongo.Ecto.NormalizedQuery
  alias Mongo.Ecto.NormalizedQuery.ReadQuery
  alias Mongo.Ecto.Decoder
  alias Mongo.Ecto.ObjectID
  alias Mongo.Ecto.Connection

  alias Ecto.Adapters.Pool

  ## Adapter

  @doc false
  defmacro __before_compile__(env) do
    config =
      env.module
      |> Module.get_attribute(:config)

    timeout = Keyword.get(config, :timeout, 5000)
    pool_mod = Keyword.get(config, :pool, Ecto.Adapters.Poolboy)

    quote do
      def __pool__ do
        {unquote(pool_mod), __MODULE__.Pool, unquote(timeout)}
      end
    end
  end

  @doc false
  def start_link(repo, opts) do
    {:ok, _} = Application.ensure_all_started(:mongodb_ecto)

    {pool_mod, pool, _} = repo.__pool__
    opts = opts
      |> Keyword.put(:timeout, Keyword.get(opts, :connect_timeout, 5000))
      |> Keyword.put(:name, pool)
      |> Keyword.put_new(:size, 10)

    pool_mod.start_link(Connection, opts)
  end

  @doc false
  def stop(repo) do
    {pool_mod, pool, _} = repo.__pool__
    pool_mod.stop(pool)
  end

  @doc false
  def id_types(_repo) do
    %{binary_id: ObjectID}
  end

  defp with_conn(repo, fun) do
    {pool_mod, pool, timeout} = repo.__pool__

    case Pool.run(pool_mod, pool, timeout, &do_with_conn(&1, &2, &3, &4, timeout, fun)) do
      {:ok, :noconnect} ->
        # :noconnect can never be the reason a call fails because
        # it is converted to {:nodedown, node}. This means the exit
        # reason can be easily identified.
        exit({:noconnect, {__MODULE__, :with_conn, [repo, fun]}})
      {:ok, result} ->
        result
      {:error, :noproc} ->
        raise ArgumentError, "repo #{inspect repo} is not started, " <>
                             "please ensure it is part of your supervision tree"
    end
  end

  defp do_with_conn(ref, _mode, _depth, _queue_time, timeout, fun) do
    case Pool.connection(ref) do
      {:ok, {mod, conn}} ->
        Pool.fuse(ref, timeout, fn -> fun.(mod, conn) end)
      {:error, :noconnect} ->
        :noconnect
    end
  end

  @doc false
  def all(repo, query, params, opts) do
    normalized = NormalizedQuery.all(query, params)

    with_conn(repo, fn module, conn ->
      module.all(conn, normalized, opts)
    end)
    |> elem(1)
    |> Enum.map(&process_document(&1, normalized, id_types(repo)))
  end

  @doc false
  def update_all(repo, query, values, params, opts) do
    normalized = NormalizedQuery.update_all(query, values, params)

    with_conn(repo, fn module, conn ->
      module.update_all(conn, normalized, opts)
    end)
  end

  @doc false
  def delete_all(repo, query, params, opts) do
    normalized = NormalizedQuery.delete_all(query, params)

    with_conn(repo, fn module, conn ->
      module.delete_all(conn, normalized, opts)
    end)
  end

  @doc false
  def insert(_repo, source, _params, {key, :id, _}, _returning, _opts) do
    raise ArgumentError, "MongoDB adapter does not support :id field type in models. " <>
                         "The #{inspect key} field in #{inspect source} is tagged as such."
  end

  def insert(_repo, source, _params, _autogen, [_] = returning, _opts) do
    raise ArgumentError,
      "MongoDB adapter does not support :read_after_writes in models. " <>
      "The following fields in #{inspect source} are tagged as such: #{inspect returning}"
  end

  def insert(repo, source, params, nil, [], opts) do
    do_insert(repo, source, params, nil, opts)
  end

  def insert(repo, source, params, {pk, :binary_id, nil}, [], opts) do
    %BSON.ObjectId{value: value} = id = Mongo.IdServer.new
    case do_insert(repo, source, [{pk, id} | params], pk, opts) do
      {:ok, []} -> {:ok, [{pk, value}]}
      other     -> other
    end
  end

  def insert(repo, source, params, {pk, :binary_id, _value}, [], opts) do
    do_insert(repo, source, params, pk, opts)
  end

  defp do_insert(repo, coll, document, pk, opts) do
    normalized = NormalizedQuery.insert(coll, document, pk)

    with_conn(repo, fn module, conn ->
      module.insert(conn, normalized, opts)
    end)
  end

  @doc false
  def update(_repo, source, _fields, _filter, {key, :id, _}, _returning, _opts) do
    raise ArgumentError, "MongoDB adapter does not support :id field type in models. " <>
                         "The #{inspect key} field in #{inspect source} is tagged as such."
  end

  def update(_repo, source, _fields, _filter, _autogen, [_|_] = returning, _opts) do
    raise ArgumentError,
      "MongoDB adapter does not support :read_after_writes in models. " <>
      "The following fields in #{inspect source} are tagged as such: #{inspect returning}"
  end

  def update(repo, source, fields, filter, {pk, :binary_id, _value}, [], opts) do
    normalized = NormalizedQuery.update(source, fields, filter, pk)

    with_conn(repo, fn module, conn ->
      module.update(conn, normalized, opts)
    end)
  end

  @doc false
  def delete(_repo, source, _filter, {key, :id, _}, _opts) do
    raise ArgumentError, "MongoDB adapter does not support :id field type in models. " <>
                         "The #{inspect key} field in #{inspect source} is tagged as such."
  end

  def delete(repo, source, filter, {pk, :binary_id, _value}, opts) do
    normalized = NormalizedQuery.delete(source, filter, pk)

    with_conn(repo, fn module, conn ->
      module.delete(conn, normalized, opts)
    end)
  end

  defp process_document(document, %ReadQuery{fields: fields, pk: pk}, id_types) do
    document = Decoder.decode_document(document, pk)

    Enum.map(fields, fn
      {:document, nil} ->
        document
      {:model, {model, coll}} ->
        row = model.__schema__(:fields)
              |> Enum.map(&Map.get(document, Atom.to_string(&1)))
              |> List.to_tuple
        model.__schema__(:load, coll, 0, row, id_types)
      {:field, field} ->
        Map.get(document, Atom.to_string(field))
      value ->
        Decoder.decode_value(value, pk)
    end)
  end

  ## Storage

  # Noop for MongoDB, as any databases and collections are created as needed.
  @doc false
  def storage_up(_opts) do
    :ok
  end

  @doc false
  def storage_down(opts) do
    with_new_conn(opts, fn conn ->
      command(conn, %{dropDatabase: 1})
    end)
  end

  defp with_new_conn(opts, fun) do
    {:ok, conn} = Connection.connect(opts)
    try do
      fun.(conn)
    after
      :ok = Connection.disconnect(conn)
    end
  end

  ## Mongo specific calls

  @doc """
  Drops all the collections in current database except system ones.

  Especially usefull in testing.
  """
  def truncate(repo) when is_atom(repo) do
    with_new_conn(repo.config, &truncate/1)
  end
  def truncate(conn) when is_pid(conn) do
    conn
    |> list_collections
    |> Enum.reject(&String.starts_with?(&1, "system"))
    |> Enum.flat_map_reduce(:ok, fn collection, :ok ->
      case drop_collection(conn, collection) do
        {:ok, _} -> {[collection], :ok}
        error    -> {[], error}
      end
    end)
    |> case do
         {dropped, :ok} -> {:ok, dropped}
         {dropped, {:error, reason}} -> {:error, {reason, dropped}}
       end
  end

  @doc """
  Runs a command in the database.

  For list of available commands plese see: http://docs.mongodb.org/manual/reference/command/
  """
  def command(repo, command, opts \\ [])
  def command(repo, command, opts) when is_atom(repo) do
    with_new_conn(repo.config, &command(&1, command, opts))
  end
  def command(conn, command, opts) when is_pid(conn) do
    Connection.command(conn, command, opts)
  end

  defp list_collections(conn) when is_pid(conn) do
    query = %ReadQuery{coll: "system.namespaces"}
    {:ok, collections} = Connection.all(conn, query)

    collections
    |> Enum.map(&Map.fetch!(&1, "name"))
    |> Enum.map(fn collection ->
      collection |> String.split(".", parts: 2) |> Enum.at(1)
    end)
    |> Enum.reject(fn
      "system" <> _rest -> true
      collection        -> String.contains?(collection, "$")
    end)
  end

  defp drop_collection(conn, collection) when is_pid(conn) do
    command(conn, %{drop: collection})
  end
end
