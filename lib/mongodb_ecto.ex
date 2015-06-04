defmodule MongodbEcto do
  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Storage

  alias MongodbEcto.Bson
  alias MongodbEcto.Query
  alias MongodbEcto.ObjectID
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
    %{binary_id: ObjectID}
  end

  defp with_conn(repo, fun) do
    {pool, timeout} = repo.__pool__

    worker = :poolboy.checkout(pool, true, timeout)
    try do
      {module, conn} = Worker.ask!(worker, timeout)
      fun.(module, conn)
    after
      :ok = :poolboy.checkin(pool, worker)
    end
  end

  def all(repo, query, params, _opts) do
    {collection, model, selector, projector, skip, batch_size} = Query.all(query, params)
    pk = primary_key(model)

    selector = Bson.to_bson(selector, pk)
    projector = Bson.to_bson(projector, pk)

    fields = query.select.fields
    from = query.from
    id_types = id_types(repo)
    params = List.to_tuple(params)

    with_conn(repo, fn module, conn ->
      module.all(conn, collection, selector, projector, skip, batch_size)
    end)
    |> Enum.map(&Bson.from_bson(&1, pk))
    |> Enum.map(&process_document(&1, fields, from, id_types, params))
  end


  def update_all(repo, query, values, params, _opts) do
    {collection, model, selector, command} = Query.update_all(query, values, params)
    pk = primary_key(model)

    selector = Bson.to_bson(selector, pk)
    command  = Bson.to_bson(command, pk)

    with_conn(repo, fn module, conn ->
      module.update_all(conn, collection, selector, command)
    end)
  end

  def delete_all(repo, query, params, _opts) do
    {collection, model, selector} = Query.delete_all(query, params)
    pk = primary_key(model)

    selector = Bson.to_bson(selector, pk)

    with_conn(repo, fn module, conn ->
      module.delete_all(conn, collection, selector)
    end)
  end

  def insert(_repo, source, _params, {key, :id, _}, _returning, _opts) do
    raise ArgumentError, "MongoDB adapter does not support :id field type in models. " <>
                         "The #{inspect key} field in #{inspect source} is tagged as such."
  end

  def insert(_repo, source, _params, _autogen, [_] = returning, _opts) do
    raise ArgumentError,
      "MongoDB adapter does not support :read_after_writes in models. " <>
      "The following fields in #{inspect source} are tagged as such: #{inspect returning}"
  end

  def insert(repo, source, params, nil, [], _opts) do
    do_insert(repo, source, params, nil)
    {:ok, []}
  end

  def insert(repo, source, params, {pk, :binary_id, nil}, [], _opts) do
    result = do_insert(repo, source, params, pk) |> Bson.from_bson(pk)

    {:ok, [{pk, Map.fetch!(result, pk)}]}
  end

  def insert(repo, source, params, {pk, :binary_id, _value}, [], _opts) do
    do_insert(repo, source, params, pk)
    {:ok, []}
  end

  def update(_repo, source, _fields, _filter, _autogen, [_] = returning, _opts) do
    raise ArgumentError,
      "MongoDB adapter does not support :read_after_writes in models. " <>
      "The following fields in #{inspect source} are tagged as such: #{inspect returning}"
  end

  def update(repo, source, fields, filter, {pk, :binary_id, _value}, [], _opts) do
    {collection, selector, command} = Query.update(source, fields, filter)

    selector = Bson.to_bson(selector, pk)
    command  = Bson.to_bson(command, pk)

    with_conn(repo, fn module, conn ->
      module.update(conn, collection, selector, command)
    end)

    {:ok, []}
  end

  def delete(repo, source, filter, {pk, :binary_id, _value}, _opts) do
    {collection, selector} = Query.delete(source, filter)

    selector = Bson.to_bson(selector, pk)

    with_conn(repo, fn module, conn ->
      module.delete(conn, collection, selector)
    end)

    {:ok, []}
  end

  def primary_key(nil), do: nil
  def primary_key(model) do
    case model.__schema__(:primary_key) do
      [pk] -> pk
      _    -> :id
    end
  end

  defp do_insert(repo, source, params, pk) do
    document =
      params
      |> Enum.filter(fn
        {_key, %Ecto.Query.Tagged{value: nil}} -> false
        {_key, nil} -> false
        _ -> true
      end)
      |> Bson.to_bson(pk)

    with_conn(repo, fn module, conn ->
      module.insert(conn, source, document)
    end)
  end

  def process_document(document, fields, {source, model}, id_types, params) do
    Enum.map(fields, fn
      {:&, _, [0]} ->
        row = model.__schema__(:fields)
              |> Enum.map(&Map.get(document, &1, nil))
              |> List.to_tuple
        model.__schema__(:load, source, 0, row, id_types)
      {{:., _, [{:&, _, [0]}, field]}, _, []} ->
        Map.get(document, field)
      %Ecto.Query.Tagged{value: {:^, _, [idx]}} ->
        # I really don't like it, but I don't know what else to do. I cant pass
        # literal selects to the db...
        case elem(params, idx) do
          %Ecto.Query.Tagged{value: value} -> value
          value -> value
        end
      value ->
        value
    end)
  end

  ## Storage

  # Noop for MongoDB, as any databases and collections are created as needed.
  def storage_up(_opts) do
    :ok
  end

  def storage_down(opts) do
    command(opts, %{dropDatabase: 1})
  end

  ## Other

  defp command(opts, command) do
    command = Bson.to_bson(command, nil)

    {:ok, conn} = Connection.connect(opts)
    reply = Connection.command(conn, command)
    :ok = Connection.disconnect(conn)

    reply
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
