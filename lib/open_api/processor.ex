defmodule OpenAPI.Processor do
  @moduledoc """
  Phase two of code generation

  The **process** phase begins with a decoded API description from the **read** phase. It may
  represent the contents of one or more files, including one or more root descriptions if
  supplemental files were used.

  This library takes an "operation first" mindset when processing the description. Schemas are
  ignored until they are referenced by an operation (ex. as a response body). It is the job of
  this phase to observe all of the operations and their referenced schemas, process them into
  data structures more relevant to code generation, and prepare the data for rendering.

  ## Customization

  At several points during code generation, it may be useful to customize the behaviour of the
  processor. For this purpose, this module is a Behaviour with most of its critical logic
  implemented as optional callbacks.
  """
  alias OpenAPI.Processor.Operation
  alias OpenAPI.Processor.Operation.Param
  alias OpenAPI.Processor.Schema
  alias OpenAPI.Processor.Schema.Field
  alias OpenAPI.Processor.State
  alias OpenAPI.Processor.Type
  alias OpenAPI.Spec
  alias OpenAPI.Spec.Path.Operation, as: OperationSpec
  alias OpenAPI.Spec.Schema, as: SchemaSpec

  @doc """
  Run the processing phase of the code generator

  This functions is used by the main `OpenAPI` module. It is unlikely that you will call this
  function directly, unless you are reimplementing one of the core functions. If this happens,
  please share your use-case with the maintainers; a plugin might be warranted.
  """
  @spec run(OpenAPI.State.t()) :: OpenAPI.State.t()
  def run(state) do
    state
    |> State.new()
    |> collect_operations_and_schemas()
    |> process_schemas()
    |> Map.get(:schemas_by_ref)

    # |> IO.inspect(pretty: true, syntax_colors: IO.ANSI.syntax_colors())

    state
  end

  #
  # Integration
  #

  defmacro __using__(_opts) do
    quote do
      defdelegate ignore_operation?(state, operation), to: OpenAPI.Processor
      defdelegate ignore_schema?(state, schema), to: OpenAPI.Processor
      defdelegate operation_docstring(state, operation_spec, params), to: OpenAPI.Processor
      defdelegate operation_function_name(state, operation_spec), to: OpenAPI.Processor
      defdelegate operation_module_names(state, operation_spec), to: OpenAPI.Processor
      defdelegate operation_request_body(state, operation_spec), to: OpenAPI.Processor
      defdelegate operation_request_method(state, operation_spec), to: OpenAPI.Processor
      defdelegate operation_response_body(state, operation_spec), to: OpenAPI.Processor
      defdelegate schema_module_and_type(state, schema_spec), to: OpenAPI.Processor

      defoverridable ignore_operation?: 2,
                     ignore_schema?: 2,
                     operation_docstring: 3,
                     operation_function_name: 2,
                     operation_module_names: 2,
                     operation_request_body: 2,
                     operation_request_method: 2,
                     operation_response_body: 2,
                     schema_module_and_type: 2
    end
  end

  #
  # Callbacks
  #

  @optional_callbacks ignore_operation?: 2,
                      ignore_schema?: 2,
                      operation_docstring: 3,
                      operation_function_name: 2,
                      operation_module_names: 2,
                      operation_request_body: 2,
                      operation_request_method: 2,
                      operation_response_body: 2,
                      schema_module_and_type: 2

  @doc """
  Whether to render the given operation in the generated code

  If this function returns `true`, the operation will not appear in the generated code.

  See `OpenAPI.Processor.ignore_operation?/2` for the default implementation.
  """
  @callback ignore_operation?(State.t(), OperationSpec.t()) :: boolean

  @doc """
  Whether to render the given schema in the generated code

  If this function returns `true`, the schema will not appear in the generated code (unless it
  returns `false` when presented in another context) and a plain `map` will be used as its type.

  See `OpenAPI.Processor.ignore_schema?/2` for the default implementation.
  """
  @callback ignore_schema?(State.t(), SchemaSpec.t()) :: boolean

  @doc """
  Construct a docstring for the given operation

  This function accepts the operation spec as well as a list of the **processed** query params
  associated with the operation.

  See `OpenAPI.Processor.Operation.docstring/2` for the default implementation.
  """
  @callback operation_docstring(State.t(), OperationSpec.t(), [Param.t()]) :: String.t()

  @doc """
  Choose the name of the client function for the given operation

  This function accepts the operation spec and chooses a name for the client function that will
  be generated. The name must be unique within its module (see `c:operation_module_name/1`).

  See `OpenAPI.Processor.Naming.operation_function/2` for the default implementation.
  """
  @callback operation_function_name(State.t(), OperationSpec.t()) :: atom

  @doc """
  Choose the names of the client function modules for the given operation

  Each operation may have multiple client functions in different modules. This function accepts
  the operation spec and returns a list of all of its operation modules.

  See `OpenAPI.Processor.Naming.operation_modules/2` for the default implementation.
  """
  @callback operation_module_names(State.t(), OperationSpec.t()) :: [module]

  @doc """
  Collect a list of request content types and their associated schemas

  This function accepts the operation spec and returns a list of tuples containing the content
  type (ex. "application/json") and the schema associated with that type.

  See `OpenAPI.Processor.Operation.request_body/1` for the default implementation.
  """
  @callback operation_request_body(State.t(), OperationSpec.t()) ::
              Operation.request_body_unprocessed()

  @doc """
  Choose and cast the request method for the given operation

  This function accepts the operation spec and must return the (lowercase) atom representing the
  HTTP method.

  See `OpenAPI.Processor.Operation.request_method/1` for the default implementation.
  """
  @callback operation_request_method(State.t(), OperationSpec.t()) :: Operation.method()

  @doc """
  Collect a list of response status codes and their associated schemas

  This function accepts the operation spec and returns a list of tuples containing the status
  codes (ex. `200` or `:default`) and a list of tuples with the possible content types and the
  schema associated with that code and type.

  See `OpenAPI.Processor.Operation.response_body/1` for the default implementation.
  """
  @callback operation_response_body(State.t(), OperationSpec.t()) ::
              Operation.response_body_unprocessed()

  @doc """
  Choose the name of the module and type for the given schema

  Each module may contain multiple schemas with distinct types. By convention, the default
  type (used for single-schema modules) is `:t`, as in `MySchema.t()`. Additional schemas in the
  same module may represent variations on the default type, such as a `User.public()` schema
  containing a reduced set of fields from `User.t()`.

  See `OpenAPI.Processor.Naming.schema_module_and_type/2` for the default implementation.
  """
  @callback schema_module_and_type(State.t(), SchemaSpec.t()) :: {module, atom}

  #
  # Default Implementations
  #

  defdelegate ignore_operation?(state, operation_spec), to: OpenAPI.Processor.Ignore
  defdelegate ignore_schema?(state, schema_spec), to: OpenAPI.Processor.Ignore

  defdelegate operation_docstring(state, operation_spec, params),
    to: OpenAPI.Processor.Operation,
    as: :docstring

  defdelegate operation_function_name(state, operation_spec),
    to: OpenAPI.Processor.Naming,
    as: :operation_function

  defdelegate operation_module_names(state, operation_spec),
    to: OpenAPI.Processor.Naming,
    as: :operation_modules

  defdelegate operation_request_body(state, operation_spec),
    to: OpenAPI.Processor.Operation,
    as: :request_body

  defdelegate operation_request_method(state, operation_spec),
    to: OpenAPI.Processor.Operation,
    as: :request_method

  defdelegate operation_response_body(state, operation_spec),
    to: OpenAPI.Processor.Operation,
    as: :response_body

  defdelegate schema_module_and_type(state, schema_spec),
    to: OpenAPI.Processor.Naming,
    as: :schema_module_and_type

  #
  # Helpers
  #

  @methods [:get, :put, :post, :delete, :options, :head, :patch, :trace]

  @spec collect_operations_and_schemas(State.t()) :: State.t()
  defp collect_operations_and_schemas(state) do
    %State{implementation: implementation, spec: %Spec{paths: paths}} = state

    for {_path, item} <- paths,
        method <- @methods,
        operation_spec = Map.get(item, method),
        not implementation.ignore_operation?(state, operation_spec),
        reduce: state do
      state ->
        process_operation(state, operation_spec)
    end
  end

  @spec process_operation(State.t(), OperationSpec.t()) :: State.t()
  defp process_operation(state, operation_spec) do
    %State{implementation: implementation} = state

    %OperationSpec{
      "$oag_path": request_path,
      "$oag_path_parameters": params_from_path,
      parameters: params_from_operation
    } = operation_spec

    all_params = Enum.map(params_from_path ++ params_from_operation, &Param.from_spec/1)
    path_params = Enum.filter(all_params, &(&1.location == :path))
    query_params = Enum.filter(all_params, &(&1.location == :query))

    docstring = implementation.operation_docstring(state, operation_spec, query_params)
    module_names = implementation.operation_module_names(state, operation_spec)
    request_method = implementation.operation_request_method(state, operation_spec)

    for module_name <- module_names, reduce: state do
      state ->
        function_name = implementation.operation_function_name(state, operation_spec)

        {state, request_body} =
          implementation.operation_request_body(state, operation_spec)
          |> process_request_body(state, module_name, function_name)

        {state, response_body} =
          implementation.operation_response_body(state, operation_spec)
          |> process_response_body(state, module_name, function_name)

        operation = %Operation{
          docstring: docstring,
          function_name: function_name,
          module_name: module_name,
          request_body: request_body,
          request_method: request_method,
          request_path: request_path,
          request_path_parameters: path_params,
          request_query_parameters: query_params,
          responses: response_body
        }

        %State{state | operations: [operation | state.operations]}
    end
  end

  @spec process_request_body(Operation.request_body_unprocessed(), State.t(), String.t(), atom) ::
          {State.t(), Operation.request_body()}
  defp process_request_body(request_body, state, op_module_name, op_function_name) do
    request_body
    |> Enum.sort_by(fn {content_type, _schema} -> content_type end, :desc)
    |> Enum.reduce({state, []}, fn {content_type, schema_spec}, {state, request_body} ->
      context = {:request, op_module_name, op_function_name, content_type}
      schema_spec = %SchemaSpec{schema_spec | "$oag_schema_context": context}

      {state, schema_type} = Type.from_schema(state, schema_spec)
      {state, [{content_type, schema_type} | request_body]}
    end)
  end

  @spec process_response_body(Operation.response_body_unprocessed(), State.t(), String.t(), atom) ::
          {State.t(), Operation.response_body()}
  defp process_response_body(response_body, state, op_module_name, op_function_name) do
    response_body
    |> Enum.sort_by(fn {status_code, _schema} -> status_code end, :desc)
    |> Enum.reduce({state, []}, fn {status_code, schema_specs}, {state, response_body} ->
      {state, schema_types} =
        schema_specs
        |> Enum.reverse()
        |> Enum.reduce({state, []}, fn {content_type, schema_spec}, {state, schema_types} ->
          context = {:response, op_module_name, op_function_name, status_code, content_type}
          schema_spec = %SchemaSpec{schema_spec | "$oag_schema_context": context}

          {state, schema_type} = Type.from_schema(state, schema_spec)
          {state, [{content_type, schema_type} | schema_types]}
        end)

      {state, [{status_code, schema_types} | response_body]}
    end)
  end

  @spec process_schemas(State.t()) :: State.t()
  defp process_schemas(state) do
    for {ref, schema_spec} <- state.schema_specs_by_ref, reduce: state do
      state -> process_schema(state, ref, schema_spec)
    end
  end

  @spec process_schema(State.t(), reference, SchemaSpec.t()) :: State.t()
  defp process_schema(state, ref, schema_spec) do
    %State{implementation: implementation, schemas_by_ref: schemas_by_ref} = state

    cond do
      Map.has_key?(schemas_by_ref, ref) ->
        state

      implementation.ignore_schema?(state, schema_spec) ->
        schema = %Schema{
          fields: [],
          module_name: nil,
          type_name: :map
        }

        schemas_by_ref = Map.put(state.schemas_by_ref, ref, schema)
        %State{state | schemas_by_ref: schemas_by_ref}

      :else ->
        {state, fields} = process_schema_fields(state, schema_spec)
        {module_name, type_name} = implementation.schema_module_and_type(state, schema_spec)

        schema = %Schema{
          fields: fields,
          module_name: module_name,
          type_name: type_name
        }

        schemas_by_ref = Map.put(state.schemas_by_ref, ref, schema)
        %State{state | schemas_by_ref: schemas_by_ref}
    end
  end

  @spec process_schema_fields(State.t(), SchemaSpec.t()) :: {State.t(), [Field.t()]}
  def process_schema_fields(state, %SchemaSpec{properties: properties, required: required}) do
    for {field_name, %SchemaSpec{nullable: nullable?} = field_spec} <- properties,
        reduce: {state, []} do
      {state, fields} ->
        required? = is_list(required) and field_name in required

        {state, type} =
          case Type.from_schema(state, field_spec) do
            {state, ref} when is_reference(ref) -> {process_schema(state, ref, field_spec), ref}
            {state, type} -> {state, type}
          end

        field = %Field{
          name: field_name,
          nullable: nullable?,
          private: false,
          required: required?,
          type: type
        }

        {state, [field | fields]}
    end
  end
end
