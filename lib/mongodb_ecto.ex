defmodule MongodbEcto do
  @behaviour Ecto.Adapter
  @behaviour Ecto.Adapter.Storage
  # FIXME remove tranaction - we shouldn't need it
  @behaviour Ecto.Adapter.Transaction

  alias MongodbEcto.Bson
  alias MongodbEcto.Query

  ## Adapter

  defmacro __before_compile__(env) do
    quote do
      def __worker__ do
        unquote(env.module).Worker
      end
    end
  end

  def start_link(repo, opts) do
    pid = Process.whereis(repo.__worker__)

    if is_nil(pid) or not Process.alive?(pid) do
      opts
      |> prepare_opts(repo)
      |> :mc_worker.start_link
    else
      {:error, {:already_started, pid}}
    end
  end

  def stop(repo) do
    :mc_worker.disconnect(repo.__worker__)
  end

  def all(repo, query, params, _opts) do
    {collection, selector, projector, skip, batch_size} = Query.all(query, params)

    cursor = :mongo.find(repo.__worker__, collection,
                         Bson.to_bson(selector), Bson.to_bson(projector),
                         skip, batch_size)
    documents = :mc_cursor.rest(cursor)
    :mc_cursor.close(cursor)

    documents
    |> Enum.map(&Bson.from_bson/1)
    |> Enum.map(&process_document(&1, query.select.fields, query.from))
  end

  def process_document(document, fields, {source, model}) do
    Enum.map(fields, fn
      {:&, _, [0]} ->
        row = model.__schema__(:fields)
              |> Enum.map(&Map.get(document, &1))
              |> List.to_tuple
        model.__schema__(:load, source, 0, row)
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
  def insert(repo, source, params, [pk | _] = returning, _opts) do
    result = do_insert(repo, source, params, pk) |> Bson.from_bson(pk)

    {:ok, Enum.map(returning, &{&1, Map.get(result, &1)})}
  end

  defp do_insert(repo, source, params, pk \\ :id) do
    :mongo.insert(repo.__worker__, source, Bson.to_bson(params, pk))
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
    {:ok, conn} = opts |> prepare_opts |> :mc_worker.start_link
    reply = :mongo.command(conn, command)
    :ok = :mc_worker.disconnect(conn)
    case reply do
      {true, resp} -> {:ok, resp}
      {false, err} -> {:error, err}
    end
  end

  defp prepare_opts(opts) do
    opts
    |> Keyword.take([:database, :r_mode, :w_mode, :timeout,
                     :port, :hostname, :username, :password])
    |> Enum.map(fn
      {:hostname, hostname} -> {:host, to_erl(hostname)}
      {:username, username} -> {:login, to_erl(username)}
      {:database, database} -> {:database, to_string(database)}
      {key, value} when is_binary(value) -> {key, to_erl(value)}
      other -> other
    end)
  end
  defp prepare_opts(opts, repo) do
    opts
    |> prepare_opts
    |> Keyword.put(:register, repo.__worker__)
  end

  defp to_erl(nil), do: :undefined
  defp to_erl(string) when is_binary(string), do: to_char_list(string)
  defp to_erl(other), do: other
end
