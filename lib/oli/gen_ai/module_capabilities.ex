defmodule Oli.GenAI.ModuleCapabilities do
  @moduledoc false

  @spec supports?(module(), atom(), non_neg_integer()) :: boolean()
  def supports?(module, function, arity) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> function_exported?(module, function, arity)
      {:error, _reason} -> false
    end
  end
end
