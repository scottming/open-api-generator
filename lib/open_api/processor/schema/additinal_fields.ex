defmodule OpenAPI.Processor.Schema.AdditinalFields do
  alias OpenAPI.Processor.Type

  @type t :: %__MODULE__{type: Type.t()}
  defstruct [:type]
end
