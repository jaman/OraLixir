defmodule OraLixir.Connection do
	@moduledoc false
  
	@dpiMajorVersion 3
	@dpiMinorVersion 0
  
	use DBConnection
  
	defstruct [:oranifNode, :context, :conn]
	
	defmacrop oranif(slave, api, args) do
	  quote do
		try do
		  case unquote(slave) do
			nil -> Kernel.apply(:dpi, unquote(api), unquote(args))
			_ -> :rpc.call(unquote(slave), :dpi, unquote(api), unquote(args))
		  end
		rescue
		  e in ErlangError ->
			{:error, file, line, original} = e.original
			{:error, %{
			  reason: original,
			  oranifFile: file,
			  oranifLine: line,
			  api: unquote(api),
			  args: unquote(args),
			  node: unquote(slave)
			}}
		end
	  end
	end
  
	@impl true
	def checkin(s) do
	  {:ok, s}
	end
  
	@impl true
	def checkout(s) do
	  {:ok, s}
	end
	
	@impl true
	def connect(opts) do 
	  ora = %OraLixir.Connection{}
	
	  case Keyword.fetch(opts, :slave) do
		{:ok, slave} -> :dpi.load slave
		:error -> :dpi.load_unsafe
	  end
	  |>
	  case do
		:ok -> create_context_connection(ora, opts)
		slave when is_atom(slave) ->
		  create_context_connection(%{ora | oranifNode: slave}, opts)
		error -> {:error, error}
	  end
	end
  
	@impl true
	def disconnect(_err, ora) do
	  # IO.inspect ora
	  if ora.conn != nil, do: oranif(ora.oranifNode, :conn_close, [ora.conn, [], ""])
	  if ora.context != nil, do: oranif(ora.oranifNode, :context_destroy, [ora.context])
	  if ora.oranifNode != node(), do: :dpi.unload ora.oranifNode
	  :ok
	end
  
	@impl true
	def handle_begin(_opts, s) do
	  {:ok, :handle_begin, s}
	end
  
	@impl true
	def handle_close(_query, _opts, state) do
	  {:ok, :handle_close, state}
	end
  
	@impl true
	def handle_commit(_opts, state) do
	  {:ok, :handle_commit, state}
	end
  
	@impl true
	def handle_deallocate(_query, _cursor, _opts, state) do
	  {:ok, :handle_deallocate, state}
	end
	
	@impl true
	def handle_prepare(
	  %OraLixir.Query{query_str: queryStr} = query, _opts,
	  %OraLixir.Connection{conn: conn, oranifNode: slave} = state
	) do
	  case oranif(slave, :conn_prepareStmt, [conn, false, queryStr, <<>>]) do
		statement when is_reference(statement) ->
		  info = oranif(slave, :stmt_getInfo, [statement])
		  query = %{query | statement: statement, info: info}
		  {:ok, query, state}
      {:error, error} -> {:error, oranif_error(error), state}
	  end
	end
  
	@impl true
	def handle_execute(
	  %OraLixir.Query{statement: statement} = query, _params, _opts,
	  %OraLixir.Connection{oranifNode: slave} = state
	) when is_reference(statement)
	do
	  case oranif(slave, :stmt_execute, [statement, []]) do
            numberOfColumns when is_integer(numberOfColumns) ->
              return = execute_query(numberOfColumns, query, state)
              oranif(slave, :stmt_close, [statement, ""])
              return
            {:error, error} -> {:error, oranif_error(error), state}
	  end
	end

	@impl true
	def handle_declare(
    %OraLixir.Query{statement: statement} = query,
    _params, _opts,
    %OraLixir.Connection{oranifNode: slave} = state
	) do
	  case oranif(slave, :stmt_execute, [statement, []]) do
		numberOfColumns when is_integer(numberOfColumns) ->
		  query = %{query | numCols: numberOfColumns}
		  {:ok, query, statement, state}
      {:error, error} -> {:error, oranif_error(error), state}
	  end
	end
  
	@impl true
	def handle_fetch(
	  %OraLixir.Query{numCols: numberOfColumns}, statement, _opts, %OraLixir.Connection{oranifNode: slave} = state
	) do
	  case oranif(slave, :stmt_fetch, [statement]) do
		%{found: true} ->          
			{:cont, fetch_row(numberOfColumns, slave, statement, []), state}
		%{found: false} ->
			{:halt, :halt, state}
      {:error, error} -> {:error, oranif_error(error), state}
	  end
	end
  
	@impl true
	def handle_rollback(
	  _opts,
	  %OraLixir.Connection{conn: conn, oranifNode: slave} = state
	) do
	  case oranif(slave, :conn_rollback, [conn]) do
		:ok -> {:ok, :ok, state}
		error -> {:disconnect, error, state}
	  end
	  {:ok, :handle_rollback, state}
	end
  
	@impl true
	def handle_status(_opts, state) do
	  {:idle, state}
	  # TODO
	  # https://hexdocs.pm/db_connection/DBConnection.html#c:handle_status/2
	end
  
	@impl true
	def ping(%OraLixir.Connection{conn: conn, oranifNode: slave} = state) do
	  case oranif(slave, :conn_ping, [conn]) do
		:ok -> {:ok, state}
		error -> {:disconnect, error, state}
	  end
	end
  
	defp create_context_connection(ora, opts) do
	  username = Keyword.get(opts, :username, "scott")
	  password = Keyword.get(opts, :password, "tiger")
  
	  connectString = case Keyword.fetch(opts, :connectString) do
		{:ok, connStr} -> connStr
		:error ->
		  port = Keyword.get(opts, :port, 1521)
		  host = Keyword.get(opts, :hostname, "127.0.0.1")
		  service_name = Keyword.get(opts, :service_name, "XE")
		  """
		  (DESCRIPTION=(ADDRESS_LIST=(ADDRESS=(PROTOCOL=TCP)(HOST=#{host})
		  (PORT=#{port})))(CONNECT_DATA=(SERVER=dedicated)
		  (SERVICE_NAME=#{service_name})))
		  """
	  end
  
	  commonParams = Keyword.get(opts, :commonParams, %{})
	  createParams = Keyword.get(opts, :createParams, %{})
  
	  oranif(
		ora.oranifNode, :context_create, [@dpiMajorVersion, @dpiMinorVersion]
	  ) |>
	  case do
		{:error, reason} -> {:error, reason}
		context ->
		  oranif(
			ora.oranifNode, :conn_create,
			[
			  context, username, password, connectString, commonParams,
			  createParams
			]
		  ) |>
		  case do
			{:error, reason} -> {:error, reason}
			conn ->
			  %{ora | context: context, conn: conn}
		  end
	  end |>
	  case do
		{:error, reason} ->
		  if ora.conn != nil, do: oranif(ora.oranifNode, :conn_close, [ora.conn, [], ""])
		  if ora.context != nil, do: oranif(ora.oranifNode, :context_destroy, [ora.context])
		  if ora.oranifNode != node(), do: :dpi.unload ora.oranifNode
		  {:error, reason}
		newora -> {:ok, newora}
	  end
	end
  
	defp fetch_all(slave, statement, numberOfColumns) do
	  case oranif(slave, :stmt_fetch, [statement]) do
		%{found: false} -> []
		%{found: true} ->
		  [fetch_row(numberOfColumns, slave, statement, [])
		   | fetch_all(slave, statement, numberOfColumns)]
	  end
	end
  
	defp fetch_row(0, _slave, _statement, row), do: row
	defp fetch_row(colIdx, slave, statement, row) do
	  %{data: data} = oranif(slave, :stmt_getQueryValue, [statement, colIdx])
	  value = oranif(slave, :data_get, [data])
	  oranif(slave, :data_release, [data])
	  fetch_row(colIdx - 1, slave, statement, [value | row])
	end
  
  defp execute_query(
    numberOfColumns,
    %OraLixir.Query{statement: statement, info: %{:isQuery => true}} = query,
    %OraLixir.Connection{oranifNode: slave} = state
  ) when numberOfColumns > 0 do
    columns = for idx <- 1..numberOfColumns do
			case oranif(slave, :stmt_getQueryInfo, [statement, idx]) do
      col when is_map(col) -> col
      error -> raise error
			end
    end
    rows = fetch_all(slave, statement, numberOfColumns)
    result = %OraLixir.Result{columns: columns, rows: rows}
    {:ok, %{query | numCols: numberOfColumns}, result, state}
  end

  defp execute_query(
    0,
    %OraLixir.Query{info: %{:isQuery => false}} = query,
    state
  ) do
    {:ok, %{query | numCols: 0}, :ok, state}
  end

  defp oranif_error(%{:reason => %{:message => message}} = error) do
    %OraLixir.Error{message: message, details: error}
  end

  end
