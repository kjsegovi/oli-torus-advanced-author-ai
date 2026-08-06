defmodule Oli.OpenStax.CourseImport.Enrichment.Sandbox.CapiBridge do
  @moduledoc """
  Injects the system-owned, typed CAPI bridge used by generated simulations.

  Generated code never receives Torus context or credentials and may not call
  `postMessage` directly. When an approved manifest declares typed inputs or
  outputs, the generated document must load this reserved bridge before any
  generated script. The sandbox supplies the exact bridge implementation and
  excludes only that byte-for-byte implementation from its direct
  `postMessage` prohibition.
  """

  alias Oli.OpenStax.CourseImport.GeneratedSimulation

  @bridge_path "torus-capi-bridge.js"

  @spec bridge_path() :: String.t()
  def bridge_path, do: @bridge_path

  @spec prepare(%{String.t() => binary()}, term()) ::
          {:ok, %{String.t() => binary()}, map()} | {:error, term()}
  def prepare(files, manifest) when is_map(files) do
    with false <- Map.has_key?(files, @bridge_path),
         {:ok, normalized} <- GeneratedSimulation.normalize_capi_manifest(manifest),
         :ok <- validate_bridge_reference(files, normalized) do
      prepared =
        if declarations?(normalized) do
          Map.put(files, @bridge_path, bridge_source(normalized))
        else
          files
        end

      {:ok, prepared, wire_manifest(normalized)}
    else
      true -> {:error, :reserved_capi_bridge_file}
      {:error, _} = error -> error
    end
  end

  def prepare(_files, _manifest), do: {:error, :invalid_bundle_files}

  @spec trusted_file?(String.t(), binary(), map()) :: boolean()
  def trusted_file?(@bridge_path, contents, normalized_manifest) when is_binary(contents) do
    with {:ok, normalized} <-
           GeneratedSimulation.normalize_capi_manifest(normalized_manifest) do
      declarations?(normalized) and contents == bridge_source(normalized)
    else
      _ -> false
    end
  end

  def trusted_file?(_path, _contents, _manifest), do: false

  defp validate_bridge_reference(files, normalized) do
    {script_nodes, direct_document_scripts} =
      files
      |> Map.get("index.html", "")
      |> Floki.parse_document()
      |> case do
        {:ok, document} ->
          {Floki.find(document, "script"), Floki.find(document, "head > script, body > script")}

        _ ->
          {[], []}
      end

    bridge_count =
      Enum.count(script_nodes, fn script ->
        script |> Floki.attribute("src") |> List.first() == @bridge_path
      end)

    cond do
      declarations?(normalized) and
          (bridge_count != 1 or
             not canonical_bridge_script?(List.first(script_nodes)) or
             not Enum.any?(direct_document_scripts, &canonical_bridge_script?/1)) ->
        {:error, :trusted_capi_bridge_missing}

      not declarations?(normalized) and bridge_count > 0 ->
        {:error, :undeclared_capi_bridge}

      true ->
        :ok
    end
  end

  # The system-owned bridge must execute synchronously before any generated
  # script. Requiring one exact classic-script tag prevents a generator from
  # neutralizing or reordering it with type, async, defer, or module attributes.
  defp canonical_bridge_script?({"script", attributes, _children} = script) do
    attributes == [{"src", @bridge_path}] and String.trim(Floki.text(script)) == ""
  end

  defp canonical_bridge_script?(_script), do: false

  defp declarations?(normalized) do
    normalized.inputs != [] or normalized.outputs != []
  end

  defp wire_manifest(normalized) do
    %{
      "inputs" => Enum.map(normalized.inputs, & &1.declaration),
      "outputs" => Enum.map(normalized.outputs, & &1.declaration)
    }
  end

  defp bridge_contract(normalized) do
    %{
      "inputs" => declaration_contract(normalized.inputs),
      "outputs" => declaration_contract(normalized.outputs)
    }
  end

  defp declaration_contract(items) do
    Map.new(items, fn item ->
      declaration = item.declaration

      {item.key,
       %{
         "type" => declaration["type"],
         "typeCode" => item.config_data["type"],
         "allowedValues" => declaration["allowedValues"] || []
       }}
    end)
  end

  defp bridge_source(normalized) do
    contract = normalized |> bridge_contract() |> Jason.encode!()

    """
    (() => {
      'use strict';
      const HANDSHAKE_REQUEST = 1;
      const HANDSHAKE_RESPONSE = 2;
      const ON_READY = 3;
      const VALUE_CHANGE = 4;
      const contract = Object.freeze(#{contract});
      const listeners = Object.create(null);
      const random = new Uint32Array(4);
      crypto.getRandomValues(random);
      const requestToken = Array.from(random, (value) => value.toString(16)).join('-');
      let authToken = '';
      let ready = false;
      let handshakeTimer;

      const declarationFor = (direction, key) =>
        Object.prototype.hasOwnProperty.call(contract[direction], key)
          ? contract[direction][key]
          : null;

      const bounded = (value) => {
        try {
          const encoded = JSON.stringify(value);
          return typeof encoded === 'string' && encoded.length <= 16384;
        } catch (_error) {
          return false;
        }
      };

      const validValue = (declaration, value) => {
        if (!declaration || !bounded(value)) return false;
        switch (declaration.type) {
          case 'number': return typeof value === 'number' && Number.isFinite(value);
          case 'string':
          case 'math_expr': return typeof value === 'string';
          case 'boolean': return typeof value === 'boolean';
          case 'enum': return typeof value === 'string' && declaration.allowedValues.includes(value);
          case 'array':
          case 'array_point': return Array.isArray(value) && value.length <= 256;
          default: return false;
        }
      };

      const send = (type, values, includeAuth = true) => {
        const message = {
          handshake: {
            requestToken,
            ...(includeAuth ? { authToken } : {})
          },
          type,
          values
        };
        parent.postMessage(JSON.stringify(message), '*');
      };

      const requestHandshake = () => send(HANDSHAKE_REQUEST, {}, false);

      const api = Object.freeze({
        emit(key, value) {
          const declaration = declarationFor('outputs', key);
          if (!ready || !validValue(declaration, value)) return false;
          send(VALUE_CHANGE, { [key]: { type: declaration.typeCode, value } });
          return true;
        },
        onInput(key, callback) {
          if (!declarationFor('inputs', key) || typeof callback !== 'function') return () => {};
          if (!listeners[key]) listeners[key] = new Set();
          listeners[key].add(callback);
          return () => listeners[key].delete(callback);
        },
        isReady() { return ready; }
      });

      Object.defineProperty(window, 'TorusCapi', {
        value: api,
        writable: false,
        configurable: false,
        enumerable: true
      });

      window.addEventListener('message', (event) => {
        if (event.source !== parent || typeof event.data !== 'string' || event.data.length > 64000) return;
        let message;
        try { message = JSON.parse(event.data); } catch (_error) { return; }
        if (!message || message.handshake?.requestToken !== requestToken) return;

        if (message.type === HANDSHAKE_RESPONSE && typeof message.handshake.authToken === 'string') {
          authToken = message.handshake.authToken;
          ready = true;
          window.clearInterval(handshakeTimer);
          send(ON_READY, {});
          window.dispatchEvent(new Event('torus-capi-ready'));
          return;
        }

        if (message.type !== VALUE_CHANGE || message.handshake?.authToken !== authToken) return;
        Object.entries(message.values || {}).forEach(([key, variable]) => {
          const declaration = declarationFor('inputs', key);
          if (!declaration || !variable || variable.type !== declaration.typeCode ||
              !validValue(declaration, variable.value)) return;
          (listeners[key] || []).forEach((callback) => callback(variable.value));
        });
      });

      handshakeTimer = window.setInterval(requestHandshake, 100);
      requestHandshake();
    })();
    """
  end
end
