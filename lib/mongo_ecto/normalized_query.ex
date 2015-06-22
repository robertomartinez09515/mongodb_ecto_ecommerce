defmodule Mongo.Ecto.NormalizedQuery do
  @moduledoc false

  defmodule ReadQuery do
    @moduledoc false

    defstruct params: {}, from: {nil, nil, nil}, query: %{}, projection: %{},
              fields: [], opts: []
  end

  defmodule WriteQuery do
    @moduledoc false

    defstruct coll: nil, query: %{}, command: %{}, opts: []
  end

  alias Mongo.Ecto.Encoder
  alias Ecto.Query

  defmacrop is_op(op) do
    quote do
      is_atom(unquote(op)) and unquote(op) != :^
    end
  end

  def all(%Query{} = original, params) do
    check_query(original)

    params     = List.to_tuple(params)
    from       = from(original)
    query      = query_order(original, params, from)
    projection = projection(original, from)
    fields     = fields(original, params)
    opts       = opts(:all, original)

    %ReadQuery{params: params, from: from, query: query, projection: projection,
               fields: fields, opts: opts}
  end

  def update_all(%Query{} = original, values, params) do
    check_query(original)

    params  = List.to_tuple(params)
    from    = from(original)
    coll    = coll(from)
    query   = query(original, params, from)
    command = command(:update, values, params, from)
    opts    = opts(:update_all, original)

    %WriteQuery{coll: coll, query: query, command: command, opts: opts}
  end

  def update(coll, values, filter, pk) do
    command = command(:update, values, pk)
    query   = query(filter, pk)

    %WriteQuery{coll: coll, query: query, command: command}
  end

  def delete_all(%Query{} = original, params) do
    check_query(original)

    params = List.to_tuple(params)
    from   = from(original)
    coll   = coll(from)
    query  = query(original, params, from)
    opts   = opts(:delete_all, original)

    %WriteQuery{coll: coll, query: query, opts: opts}
  end

  def delete(coll, filter, pk) do
    query = query(filter, pk)

    %WriteQuery{coll: coll, query: query}
  end

  def insert(coll, document, pk) do
    command = command(:insert, document, pk)

    %WriteQuery{coll: coll, command: command}
  end

  defp from(%Query{from: {coll, model}}) do
    {coll, model, primary_key(model)}
  end

  defp query_order(original, params, from) do
    query = query(original, params, from)
    order = order(original, from)
    query_order(query, order)
  end

  defp query_order(query, order) when order == %{},
    do: query
  defp query_order(query, order),
    do: %{"$query": query, "$orderby": order}

  defp projection(%Query{select: nil}, _from),
    do: %{}
  defp projection(%Query{select: %Query.SelectExpr{fields: [{:&, _, [0]}]}}, _from),
    do: %{}
  defp projection(%Query{select: %Query.SelectExpr{fields: fields}} = query,
                  {_coll, model, pk}) do
    Enum.flat_map(fields, fn
      {:&, _, [0]} ->
        model.__schema__(:fields)
      {{:., _, [{:&, _, [0]}, field]}, _, []} when field == pk ->
        [:_id]
      {{:., _, [{:&, _, [0]}, field]}, _, []} ->
        [field]
      {op, _, _} when is_op(op) ->
        error(query, "select clause")
      _value ->
        # We skip all values and then add them when constructing return result
        []
    end)
    |> Enum.map(&{&1, true})
  end

  defp fields(%Query{select: nil}, _params),
    do: []
  defp fields(%Query{select: %Query.SelectExpr{fields: fields}} = query, params) do
    Enum.map(fields, fn
      %Query.Tagged{value: {:^, _, [idx]}} ->
        params |> elem(idx) |> value(params, query, "select clause")
      value ->
        value
    end)
  end

  defp opts(:all, query),
    do: [num_return: num_return(query), num_skip: num_skip(query)]
  defp opts(:update_all, _query),
    do: [multi: true]
  defp opts(:delete_all, _query),
    do: [multi: true]

  defp num_skip(%Query{offset: offset}), do: offset_limit(offset)

  defp num_return(%Query{limit: limit}), do: offset_limit(limit)

  defp coll({coll, _model, _pk}), do: coll

  defp query(%Query{wheres: wheres} = query, params, {_coll, _model, pk}) do
    Enum.into(wheres, %{}, fn %Query.QueryExpr{expr: expr} ->
      pair(expr, params, pk, query, "where clause")
    end)
  end
  defp query(filter, pk) do
    case Encoder.encode_document(filter, pk) do
      {:ok, document} -> document
      {:error, _expr}  ->
        error("where clause")
    end
  end

  defp order(%Query{order_bys: order_bys} = query, {_coll, _model, pk}) do
    order_bys
    |> Enum.flat_map(fn %Query.QueryExpr{expr: expr} -> expr end)
    |> Enum.into(%{}, &order_by_expr(&1, pk, query))
  end

  defp command(:update, values, params, {_coll, _model, pk}) do
    updates =
      case Encoder.encode_document(values, params, pk) do
        {:ok, document} -> Enum.into(document, %{})
        {:error, _expr}  ->
          error("update command")
      end

    ["$set": updates]
  end
  defp command(:update, values, pk) do
    updates =
      case Encoder.encode_document(values, pk) do
        {:ok, document} -> Enum.into(document, %{})
        {:error, _expr}  ->
          error("update command")
      end

    ["$set": updates]
  end
  defp command(:insert, document, pk) do
    case Encoder.encode_document(document, pk) do
      {:ok, document} -> document
      {:error, _expr}  ->
        error("insert command")
    end
  end

  defp offset_limit(nil),
    do: 0
  defp offset_limit(%Query.QueryExpr{expr: int}) when is_integer(int),
    do: int

  defp primary_key(nil),
    do: nil
  defp primary_key(model) do
    case model.__schema__(:primary_key) do
      []   -> nil
      [pk] -> pk
      keys ->
        raise ArgumentError, "MongoDB adapter does not support multiple primary keys " <>
          "and #{inspect keys} were defined in #{inspect model}."
    end
  end

  defp order_by_expr({:asc,  expr}, pk, query),
    do: {field(expr, pk, query, "order clause"),  1}
  defp order_by_expr({:desc, expr}, pk, query),
    do: {field(expr, pk, query, "order clause"), -1}

  defp check_query(query) do
    check(query.distinct, nil, query, "MongoDB adapter does not support distinct clauses")
    check(query.lock,     nil, query, "MongoDB adapter does not support locking")
    check(query.joins,     [], query, "MongoDB adapter does not support join clauses")
    check(query.group_bys, [], query, "MongoDB adapter does not support group_by clauses")
    check(query.havings,   [], query, "MongoDB adapter does not support having clauses")
  end

  defp check(expr, expr, _, _),
    do: nil
  defp check(_, _, query, message),
    do: raise(Ecto.QueryError, query: query, message: message)

  defp value(expr, params, query, place) do
    case Encoder.encode_value(expr, params) do
      {:ok, value}   -> value
      {:error, _expr} -> error(query, place)
    end
  end

  defp field({{:., _, [{:&, _, [0]}, pk]}, _, []}, pk, _query, _place),
    do: :_id
  defp field({{:., _, [{:&, _, [0]}, field]}, _, []}, _pk, _query, _place),
    do: field
  defp field(_expr, _pk, query, place),
    do: error(query, place)

  binary_ops =
    [>: :"$gt", >=: :"$gte", <: :"$lt", <=: :"$lte", !=: :"$ne", in: :"$in"]
  bool_ops =
    [and: :"$and", or: :"$or"]

  @binary_ops Keyword.keys(binary_ops)
  @bool_ops Keyword.keys(bool_ops)

  Enum.map(binary_ops, fn {op, mongo_op} ->
    defp binary_op(unquote(op)), do: unquote(mongo_op)
  end)

  Enum.map(bool_ops, fn {op, mongo_op} ->
    defp bool_op(unquote(op)), do: unquote(mongo_op)
  end)

  defp mapped_pair_or_value({op, _, _} = tuple, params, pk, query, place) when is_op(op) do
    {key, value} = pair(tuple, params, pk, query, place)
    Map.put(%{}, key, value)
  end
  defp mapped_pair_or_value(value, params, _pk, query, place) do
    value(value, params, query, place)
  end

  defp pair({op, _, args}, params, pk, query, place) when op in @bool_ops do
    args = Enum.map(args, &mapped_pair_or_value(&1, params, pk, query, place))
    {bool_op(op), args}
  end
  defp pair({:in, _, [left, {:^, _, [ix, len]}]}, params, pk, query, place) do
    args =
      ix..ix+len-1
      |> Enum.map(&elem(params, &1))
      |> Enum.map(&value(&1, params, query, place))

    {field(left, pk, query, place), %{"$in": args}}
  end
  defp pair({:is_nil, _, [expr]}, _, pk, query, place) do
    {field(expr, pk, query, place), nil}
  end
  defp pair({:==, _, [left, right]}, params, pk, query, place) do
    {field(left, pk, query, place), value(right, params, query, place)}
  end
  defp pair({op, _, [left, right]}, params, pk, query, place) when op in @binary_ops do
    value = Map.put(%{}, binary_op(op), value(right, params, query, place))
    {field(left, pk, query, place), value}
  end
  defp pair({:not, _, [{:in, _, [left, {:^, _, [ix, len]}]}]}, params, pk, query, place) do
    args =
      ix..ix+len-1
      |> Enum.map(&elem(params, &1))
      |> Enum.map(&value(&1, params, query, place))

    {field(left, pk, query, place), %{"$nin": args}}
  end
  defp pair({:not, _, [{:in, _, [left, right]}]}, params, pk, query, place) do
    {field(left, pk, query, place), %{"$nin": value(right, params, query, place)}}
  end
  defp pair({:not, _, [{:is_nil, _, [expr]}]}, _, pk, query, place) do
    {field(expr, pk, query, place), %{"$neq": nil}}
  end
  defp pair({:not, _, [{:==, _, [left, right]}]}, params, pk, query, place) do
    {field(left, pk, query, place), %{"$neq": value(right, params, query, place)}}
  end
  defp pair({:not, _, [expr]}, params, pk, query, place) do
    {key, value} = pair(expr, params, pk, query, place)
    {:"$not", Map.put(%{}, key, value)}
  end
  defp pair({:^, _, _} = expr, params, _pk, query, place) do
    case value(expr, params, query, place) do
      %BSON.JavaScript{} = js ->
        {:"$where", js}
      _value ->
        error(query, place)
    end
  end
  defp pair(_expr, _params, _pk, query, place) do
    # Pair is used only in where clauses
    error(query, place)
  end

  defp error(query, place) do
    raise Ecto.QueryError, query: query,
      message: "Invalid expression for MongoDB adapter in #{place}"
  end
  defp error(place) do
    raise ArgumentError, "Invalid expression for MongoDB adapter in #{place}"
  end
end
