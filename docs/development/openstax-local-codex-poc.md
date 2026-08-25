# OpenStax local Codex POC

This development-only option runs every AI step in a new OpenStax import through a
loopback Codex bridge. It uses the developer machine's ChatGPT-authenticated Codex
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

3. Start the loopback bridge in its own terminal:

   ```bash
   node scripts/dev/codex_openai_proxy.mjs
   ```

   The bridge binds to `127.0.0.1:4001`, serializes executions, and uses ephemeral,
   read-only non-interactive Codex runs. See the official
   [non-interactive mode documentation](https://learn.chatgpt.com/docs/non-interactive-mode).

4. Start Phoenix with the POC option enabled:

   ```bash
   OPENSTAX_CODEX_POC_ENABLED=true mix phx.server
   ```

   To prove the selected path does not depend on API credentials, omit
   `OPENAI_API_KEY` from that Phoenix process. Existing API-backed imports still require
   their normal API configuration.

5. Verify readiness:

   ```bash
   curl --fail http://127.0.0.1:4001/health
   ```

   A ready response has `"ok":true` and `"auth_method":"chatgpt"`. The import form then
   enables **Local Codex (POC)**. Readiness is checked again when the form is submitted.

## Bridge boundaries

- `POST /v1/chat/completions` supports modern `tools`/`tool_calls`, tool-call IDs,
  multi-turn tool-result history, and the legacy `functions` response used by older DOT
  callers.
- Ordinary completions disable web search. `POST /v1/codex/research` enables live web
  search only for the server-provided simulation domain allowlist. Codex web-search
  configuration is described in the official
  [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).
- Requests run in isolated temporary directories with user/project rules ignored, a
  read-only sandbox, filtered child environments, execution timeouts, request-size
  limits, and metadata-only logs.
- The configured bridge URL must resolve to `localhost`, `127.0.0.1`, or `::1`.

Remote hosting, shared authentication, multiple Codex users, production deployment,
and automatic failover to usage-billed APIs are intentionally out of scope.

## Optional real smoke test

After the normal test suite passes, start the bridge and run one small import with Local
Codex selected. Confirm the run screen shows the locked backend, the usage events record
`codex_cli` and `chatgpt_plan`, and no request reaches `api.openai.com`. This consumes
ChatGPT Codex allowance and is intentionally excluded from normal CI.

The bridge also has an opt-in one-call smoke test:

```bash
OPENSTAX_REAL_CODEX_SMOKE=1 node --test scripts/dev/codex_openai_proxy.test.mjs
```
