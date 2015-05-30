defmodule MongodbEcto do
  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Storage
  # FIXME remove tranaction - we shouldn't need it
  @behaviour Ecto.Adapter.Transaction

  alias MongodbEcto.Bson
  alias MongodbEcto.Query
  alias MongodbEcto.Connection
  alias Ecto.Adapters.Worker

  ## Adapter

  defmacro __before_compile__(env) do
    timeout =
      env.module
      |> Module.get_attribute(:config)
      |> Keyword.get(:timeout, 5000)

    quote do
      def __pool__ do
        {__MODULE__.Pool, unquote(timeout)}
      end
    end
  end

  def start_link(repo, opts) do
    {pool_opts, worker_opts} = split_opts(repo, opts)

    :poolboy.start_link(pool_opts, {Connection, worker_opts})
  end

  def stop(repo) do
    repo.__pool__ |> elem(0) |> :poolboy.stop
  end

  def id_types(_repo) do
    %{binary_id: :binary}
  end

  defp with_conn(repo, fun) do
    {pool, timeout} = repo.__pool__

    worker = :poolboy.checkout(pool, true, timeout)
    try do
      {_module, conn} = Worker.ask!(worker, timeout)
      fun.(conn)
    after
      :ok = :poolboy.checkin(pool, worker)
    end
  end

  def all(repo, query, params, _opts) do
    {collection, selector, projector, skip, batch_size} = Query.all(query, params)

    selector = Bson.to_bson(selector)
    projector = Bson.to_bson(projector)

    cursor =
      with_conn(repo, fn conn ->
        :mongo.find(conn, collection, selector, projector, skip, batch_size)
      end)

    documents = :mc_cursor.rest(cursor)
    :mc_cursor.close(cursor)

    documents
    |> Enum.map(&Bson.from_bson/1)
    |> Enum.map(&process_document(&1, query.select.fields, query.from, id_types(repo)))
  end

  def process_document(document, fields, {source, model}, id_types) do
    Enum.map(fields, fn
      {:&, _, [0]} ->
        row = model.__schema__(:fields)
              |> Enum.map(&Map.get(document, &1))
              |> List.to_tuple
        model.__schema__(:load, source, 0, row, id_types)
      {{:., _, [{:&, _, [0]}, field]}, _, []} ->
        Map.get(document, field)
    end)
  end

  def update_all(_repo, _query, _values, _params, _opts) do
    {:error, :not_supported}
  end

  def delete_all(_repo, _query, _params, _opts) do
    {:error, :not_supported}
  end

  def insert(repo, source, params, [], _opts) do
    do_insert(repo, source, params)
    {:ok, []}
  end
  # FIXME do not assume the first returning is the primary key
  def insert(repo, source, params, {pk, :binary_id, nil}, returning, _opts) do
    result = do_insert(repo, source, params, pk) |> Bson.from_bson(pk)

    {:ok, Enum.map(returning, &{&1, Map.get(result, &1)})}
  end

  defp do_insert(repo, source, params, pk \\ :id) do
    document = Bson.to_bson(params, pk)

    with_conn(repo, fn conn ->
      :mongo.insert(conn, source, document)
    end)
  end

  def update(_repo, _source, _fields, _filter, _returning, _opts) do
    {:error, :not_supported}
  end

  def delete(_repo, _source, _filter, _opts) do
    {:error, :not_supported}
  end

  ## Storage

  @doc """
  Noop for MongoDB, as any databases and collections are created as needed.
  """
  def storage_up(_opts) do
    :ok
  end

  def storage_down(opts) do
    command(opts, {:dropDatabase, 1})
  end

  ## Transaction

  # FIXME can we do something better?
  def transaction(_repo, _opts, fun) do
    try do
      {:ok, fun.()}
    catch
      :throw, {:ecto_rollback, value} ->
        {:error, value}
    end
  end

  def rollback(_repo, value) do
    throw {:ecto_rollback, value}
  end

  ## Other

  defp command(opts, command) do
    {:ok, conn} = Connection.connect(opts)
    reply = :mongo.command(conn, command)
    :ok = Connection.disconnect(conn)

    case reply do
      {true, resp} -> {:ok, resp}
      {false, err} -> {:error, err}
    end
  end

  defp split_opts(repo, opts) do
    {pool_name, _} = repo.__pool__

    {pool_opts, worker_opts} = Keyword.split(opts, [:size, :max_overflow])

    pool_opts = pool_opts
      |> Keyword.put_new(:size, 10)
      |> Keyword.put_new(:max_overflow, 0)
      |> Keyword.put(:worker_module, Worker)
      |> Keyword.put(:name, {:local, pool_name})

    worker_opts = worker_opts
      |> Keyword.put(:timeout, Keyword.get(worker_opts, :connect_timeout, 5000))

    {pool_opts, worker_opts}
  end
end
