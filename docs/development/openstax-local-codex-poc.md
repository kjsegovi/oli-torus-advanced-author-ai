# OpenStax local Codex POC

This development-only option runs AI steps in an OpenStax import through a
loopback Codex bridge. It uses the local Codex installation's ChatGPT-authenticated
allowance. The usage ledger still records tokens, while the API cost guard attributes
zero API dollars to `codex-proxy/*` calls. This does not mean the calls are free.

The selected backend is locked when the import run is created. Retries, lesson
regeneration, simulation research, simulation specification, artifact generation, and
criticism keep using that backend. There is no API fallback.

## Local setup

1. Install Codex and authenticate using ChatGPT:

   ```bash
   codex login
   codex login status
   ```

   The status must say `Logged in using ChatGPT`. API-key authentication is rejected by
   the bridge. See the official [Codex authentication documentation](https://learn.chatgpt.com/docs/auth).

2. Apply migrations:

   ```bash
   mix ecto.migrate
   ```

3. Create one runtime-only bridge token and pass the same value to both processes:

   ```bash
   export CODEX_PROXY_TOKEN="<bridge-token-placeholder>"
   export OPENSTAX_CODEX_PROXY_TOKEN="$CODEX_PROXY_TOKEN"
   ```

   `CODEX_PROXY_TOKEN` is mandatory for protected bridge routes. It must be supplied at
   runtime and must not be committed, persisted in project configuration, or printed in
   logs. `OPENSTAX_CODEX_PROXY_TOKEN` is the matching application-side runtime setting.
   This bridge token is only a local shared secret; it is not an OpenAI API key and not an OAuth credential.

4. Start the loopback bridge in its own terminal:

   ```bash
   CODEX_PROXY_TOKEN="$CODEX_PROXY_TOKEN" node scripts/dev/codex_openai_proxy.mjs
   ```

   The bridge binds to `localhost`, uses the supported default model
   `codex-proxy/gpt-5.6-terra`, runs one request at a time, and admits only a short,
   bounded queue. Executions use ephemeral, read-only non-interactive Codex runs. See
   the official [non-interactive mode documentation](https://learn.chatgpt.com/docs/non-interactive-mode).

5. Start Phoenix with the POC option and matching runtime token:

   ```bash
   OPENSTAX_CODEX_POC_ENABLED=true \
   OPENSTAX_CODEX_PROXY_TOKEN="$OPENSTAX_CODEX_PROXY_TOKEN" \
   mix phx.server
   ```

   To prove the selected path does not depend on API credentials, omit `OPENAI_API_KEY`
   from that Phoenix process. Existing API-backed imports still require their normal API
   configuration.

6. Verify readiness:

   ```bash
   curl --fail http://localhost:4001/health
   ```

   A ready response has `"ok":true` and `"auth_method":"chatgpt"`. The import form then
   enables **Local Codex (POC)**. Readiness is checked again when the form is submitted.

## Bridge boundaries and protocol limits

- `POST /v1/chat/completions` supports modern `tools`/`tool_calls`, tool-call IDs,
  multi-turn tool-result history, and the legacy `functions` response used by older DOT
  callers.
- Ordinary completions disable web search. `POST /v1/codex/research` enables live web
  search only for the server-provided simulation domain allowlist.
- Requests run in isolated temporary directories with user/project rules ignored, a
  read-only sandbox, filtered child environments, execution timeouts, request-size
  limits, and metadata-only logs.
- The configured bridge URL must resolve to `localhost`, `127.0.0.1`, or `::1`.
- The execution queue is serialized and bounded: one request runs at a time, queued
  work has a short limit, and excess work receives a typed `bridge_busy` error.
- A disconnected client cancels its request. Queue expiry and cancellation are
  reported as typed errors, and all bridge errors are sanitized before they leave the
  process; subprocess output, prompts, tokens, and filesystem details are not exposed.
- SSE responses are buffered rather than token-live. Request, process-output, result,
  and response buffers are size-limited, so over-limit output fails with a typed,
  sanitized error instead of being streamed without bounds.
- The client receive timeout is 310 seconds, leaving headroom above the bridge's
  300-second execution limit.

Remote hosting, shared authentication, multiple Codex users, production deployment,
and automatic failover to usage-billed APIs are intentionally out of scope.

## Deterministic verification

Run the syntax check and deterministic Node 22 protocol suite without credentials or
network calls:

```bash
node --check scripts/dev/codex_openai_proxy.mjs
node --test scripts/dev/codex_openai_proxy.test.mjs
```

The same deterministic command is the CI contract:

```bash
node --test scripts/dev/codex_openai_proxy.test.mjs
```

CI does not set `OPENSTAX_REAL_CODEX_SMOKE`, `CODEX_PROXY_TOKEN`, or
`OPENSTAX_CODEX_PROXY_TOKEN`.

## Optional real smoke test

After deterministic tests pass, start the bridge and run one small import with Local
Codex selected. Confirm the run screen shows the locked backend, the usage events record
`codex_cli` and `chatgpt_plan`, and no request reaches an external API endpoint. This
consumes ChatGPT Codex allowance and is intentionally excluded from normal CI.

The bridge also has an opt-in one-call smoke test:

```bash
OPENSTAX_REAL_CODEX_SMOKE=1 node --test scripts/dev/codex_openai_proxy.test.mjs
```
