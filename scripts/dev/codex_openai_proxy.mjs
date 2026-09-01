/*
 * Loopback-only Codex bridge for local Torus proof-of-concept imports.
 *
 * Run:
 *   OPENSTAX_CODEX_POC_ENABLED=true node scripts/dev/codex_openai_proxy.mjs
 *
 * The bridge deliberately uses ChatGPT-authenticated `codex exec`; it never
 * accepts an OpenAI API key and never logs prompts, model output, or credentials.
 */

import crypto from "node:crypto";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import { constants as fsConstants, promises as fs } from "node:fs";
import { fileURLToPath } from "node:url";

const HOST = "127.0.0.1";
const PORT = positiveInteger(process.env.PORT, 4001);
const CODEX_BIN = process.env.CODEX_BIN || "codex";
const CODEX_PROXY_TOKEN = process.env.CODEX_PROXY_TOKEN || "";
const CODEX_PROXY_TOKEN_DIGEST = crypto
  .createHash("sha256")
  .update(CODEX_PROXY_TOKEN)
  .digest();
const EXECUTION_TIMEOUT_MS = positiveInteger(
  process.env.CODEX_PROXY_TIMEOUT_MS,
  300_000,
);
const LOGIN_TIMEOUT_MS = positiveInteger(
  process.env.CODEX_PROXY_LOGIN_TIMEOUT_MS,
  5_000,
);
const READINESS_CACHE_TTL_MS = Math.min(
  positiveInteger(process.env.CODEX_PROXY_HEALTH_CACHE_TTL_MS, 2_000),
  60_000,
);
const MAX_REQUEST_BYTES = positiveInteger(
  process.env.CODEX_PROXY_MAX_REQUEST_BYTES,
  2_000_000,
);
const KILL_GRACE_MS = positiveInteger(
  process.env.CODEX_PROXY_KILL_GRACE_MS,
  2_000,
);
const MAX_PROCESS_OUTPUT_BYTES = positiveInteger(
  process.env.CODEX_PROXY_MAX_PROCESS_OUTPUT_BYTES,
  64_000,
);
const MAX_RESULT_BYTES = positiveInteger(
  process.env.CODEX_PROXY_MAX_RESULT_BYTES,
  2_000_000,
);
const MAX_QUEUED_REQUESTS = positiveInteger(
  process.env.CODEX_PROXY_MAX_QUEUED_REQUESTS,
  2,
);
const QUEUE_TIMEOUT_MS = positiveInteger(
  process.env.CODEX_PROXY_QUEUE_TIMEOUT_MS,
  15_000,
);
const DEFAULT_MODEL = process.env.CODEX_MODEL || "gpt-5.6-terra";
const ALLOWED_MODELS = new Set([
  "gpt-5.6-terra",
  "gpt-5.6-sol",
  "gpt-5.6-luna",
]);
const PASSTHROUGH_ENV = [
  "PATH",
  "HOME",
  "CODEX_HOME",
  "TMPDIR",
  "LANG",
  "LC_ALL",
  "SSL_CERT_FILE",
  "SSL_CERT_DIR",
  "HTTP_PROXY",
  "HTTPS_PROXY",
  "NO_PROXY",
];

class ExecutionQueue {
  constructor({ maxQueued, timeoutMs }) {
    this.active = false;
    this.entries = [];
    this.maxQueued = maxQueued;
    this.timeoutMs = timeoutMs;
  }

  run(task, { signal } = {}) {
    if (signal?.aborted) {
      return Promise.reject(new BridgeError("request_cancelled", 499));
    }

    return new Promise((resolve, reject) => {
      const entry = {
        abort: null,
        reject,
        resolve,
        settled: false,
        signal,
        task,
        timer: null,
      };
      entry.abort = () => {
        if (entry.settled) return;
        entry.settled = true;
        this.remove(entry);
        reject(new BridgeError("request_cancelled", 499));
      };

      if (this.active) {
        if (this.entries.length >= this.maxQueued) {
          entry.settled = true;
          reject(new BridgeError("bridge_busy", 503));
          return;
        }
        signal?.addEventListener("abort", entry.abort, { once: true });
        entry.timer = setTimeout(() => {
          if (entry.settled) return;
          entry.settled = true;
          this.remove(entry);
          reject(new BridgeError("queue_timeout", 503));
        }, this.timeoutMs);
        this.entries.push(entry);
      } else {
        this.start(entry);
      }
    });
  }

  remove(entry) {
    const index = this.entries.indexOf(entry);
    if (index >= 0) this.entries.splice(index, 1);
    clearTimeout(entry.timer);
    entry.signal?.removeEventListener("abort", entry.abort);
  }

  start(entry) {
    this.active = true;
    this.remove(entry);
    Promise.resolve()
      .then(entry.task)
      .then(
        (value) => {
          if (entry.settled) return;
          entry.settled = true;
          entry.resolve(value);
        },
        (error) => {
          if (entry.settled) return;
          entry.settled = true;
          entry.reject(error);
        },
      )
      .finally(() => {
        this.active = false;
        const next = this.entries.shift();
        if (next) this.start(next);
      });
  }
}

class BridgeError extends Error {
  constructor(code, status = 500) {
    super(code);
    this.code = code;
    this.status = status;
  }
}

function isLoopbackHostname(hostname) {
  return ["127.0.0.1", "localhost", "[::1]"].includes(hostname.toLowerCase());
}

function validHost(host) {
  if (typeof host !== "string") return false;
  try {
    const parsed = new URL(`http://${host}`);
    return (
      isLoopbackHostname(parsed.hostname) &&
      parsed.username === "" &&
      parsed.password === "" &&
      parsed.pathname === "/" &&
      parsed.search === "" &&
      parsed.hash === ""
    );
  } catch {
    return false;
  }
}

function validOrigin(origin) {
  if (origin === undefined) return true;
  if (typeof origin !== "string") return false;
  try {
    const parsed = new URL(origin);
    return (
      ["http:", "https:"].includes(parsed.protocol) &&
      isLoopbackHostname(parsed.hostname) &&
      parsed.origin === origin
    );
  } catch {
    return false;
  }
}

function validBearerToken(authorization) {
  if (typeof authorization !== "string" || !authorization.startsWith("Bearer ")) {
    return false;
  }

  const supplied = crypto
    .createHash("sha256")
    .update(authorization.slice("Bearer ".length))
    .digest();
  return crypto.timingSafeEqual(CODEX_PROXY_TOKEN_DIGEST, supplied);
}

function positiveInteger(value, fallback) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function canWrite(res) {
  return !res.destroyed && !res.writableEnded;
}

function writeJson(res, status, body) {
  if (!canWrite(res)) return;
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function startSse(res) {
  if (!canWrite(res)) return false;
  res.writeHead(200, {
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
    "content-type": "text/event-stream",
  });
  return true;
}

function writeSse(res, payload) {
  if (canWrite(res)) res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

function finishSse(res) {
  if (!canWrite(res)) return;
  res.write("data: [DONE]\n\n");
  res.end();
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let bytes = 0;
    let settled = false;

    req.on("data", (chunk) => {
      if (settled) return;

      bytes += chunk.length;
      if (bytes > MAX_REQUEST_BYTES) {
        settled = true;
        reject(new BridgeError("request_too_large", 413));
        req.resume();
        return;
      }

      chunks.push(chunk);
    });

    req.on("end", () => {
      if (!settled) resolve(Buffer.concat(chunks).toString("utf8"));
    });
    req.on("error", (error) => {
      if (!settled) reject(error);
    });
  });
}

async function parseJsonBody(req) {
  let body;
  try {
    body = JSON.parse(await readBody(req));
  } catch (error) {
    if (error instanceof BridgeError) throw error;
    throw new BridgeError("invalid_json", 400);
  }

  if (!body || typeof body !== "object" || Array.isArray(body)) {
    throw new BridgeError("invalid_json", 400);
  }
  return body;
}

function validateCompletionBody(body) {
  if (!Array.isArray(body.messages)) {
    throw new BridgeError("invalid_completion_request", 400);
  }
  if (body.tools !== undefined && !Array.isArray(body.tools)) {
    throw new BridgeError("invalid_completion_request", 400);
  }
  return body;
}

function normalizeTools(body) {
  if (Array.isArray(body.tools)) {
    return body.tools
      .filter((tool) => tool?.type === "function" && tool.function?.name)
      .map((tool) => tool.function);
  }

  return Array.isArray(body.functions)
    ? body.functions.filter((fn) => fn?.name)
    : [];
}

function schemaAcceptsNull(schema) {
  if (!schema || typeof schema !== "object") return false;
  if (schema.type === "null") return true;
  if (Array.isArray(schema.type) && schema.type.includes("null")) return true;
  return Array.isArray(schema.anyOf) && schema.anyOf.some(schemaAcceptsNull);
}

function asNullableSchema(schema) {
  return schemaAcceptsNull(schema)
    ? schema
    : { anyOf: [schema, { type: "null" }] };
}

function normalizeSchema(schema) {
  if (Array.isArray(schema)) return schema.map(normalizeSchema);
  if (!schema || typeof schema !== "object") return schema;

  const normalized = Object.fromEntries(
    Object.entries(schema).map(([key, value]) => [key, normalizeSchema(value)]),
  );

  if (normalized.type === "object") {
    const properties = normalized.properties || {};
    const originallyRequired = new Set(
      Array.isArray(normalized.required) ? normalized.required : [],
    );
    const strictProperties = Object.fromEntries(
      Object.entries(properties).map(([key, value]) => [
        key,
        originallyRequired.has(key) ? value : asNullableSchema(value),
      ]),
    );

    return {
      ...normalized,
      additionalProperties: false,
      properties: strictProperties,
      required: Object.keys(strictProperties),
    };
  }

  return normalized;
}

function messageSchema() {
  return {
    additionalProperties: false,
    properties: {
      arguments: { type: "null" },
      content: { type: "string" },
      name: { type: "null" },
      type: { const: "message", type: "string" },
    },
    required: ["type", "name", "arguments", "content"],
    type: "object",
  };
}

function functionCallSchema(tool) {
  return {
    additionalProperties: false,
    properties: {
      arguments: normalizeSchema(
        tool.parameters || { type: "object", properties: {} },
      ),
      content: { type: "null" },
      name: { const: tool.name, type: "string" },
      type: { const: "function_call", type: "string" },
    },
    required: ["type", "name", "arguments", "content"],
    type: "object",
  };
}

function buildOutputSchema(tools = []) {
  if (!tools.length) return messageSchema();
  return { anyOf: [messageSchema(), ...tools.map(functionCallSchema)] };
}

function buildPrompt({ messages, tools }) {
  return [
    "Act as a stateless OpenAI-compatible completion backend.",
    "Do not use shell, filesystem, app, plugin, skill, subagent, or unrelated tools.",
    "Web search is unavailable for this request.",
    "Return exactly one JSON object matching the supplied output schema.",
    "Use a function_call result only when the conversation requires one of the supplied functions.",
    "Always include type, name, arguments, and content; set unused keys to null.",
    "Preserve the meaning of tool_call_id and tool result history in the conversation.",
    "",
    `Functions: ${JSON.stringify(tools)}`,
    `Conversation: ${JSON.stringify(messages)}`,
  ].join("\n");
}

function buildResearchSchema() {
  return {
    additionalProperties: false,
    properties: {
      claims: {
        items: {
          additionalProperties: false,
          properties: {
            citation_urls: {
              items: { type: "string" },
              minItems: 1,
              type: "array",
            },
            paraphrase: { type: "string" },
          },
          required: ["paraphrase", "citation_urls"],
          type: "object",
        },
        minItems: 1,
        type: "array",
      },
      retrieved_sources: {
        items: {
          additionalProperties: false,
          properties: { title: { type: "string" }, url: { type: "string" } },
          required: ["url", "title"],
          type: "object",
        },
        minItems: 2,
        type: "array",
      },
      search_count: { maximum: 4, minimum: 1, type: "integer" },
    },
    required: ["retrieved_sources", "claims", "search_count"],
    type: "object",
  };
}

function buildResearchPrompt(prompt, allowedDomains) {
  return [
    "Research the educational simulation evidence request below using live web search.",
    "Do not use shell, filesystem, app, plugin, skill, subagent, or unrelated tools.",
    `Only consult these domains and their subdomains: ${allowedDomains.join(", ")}.`,
    "Use at most four search actions and consult at most twelve sources.",
    "Return claim paraphrases, never copied passages. Every citation URL must be in retrieved_sources.",
    "Return exactly one JSON object matching the supplied output schema.",
    "",
    prompt,
  ].join("\n");
}

function actualModel(requested) {
  const stripped = String(requested || DEFAULT_MODEL).replace(
    /^codex-proxy\//,
    "",
  );
  if (!ALLOWED_MODELS.has(stripped))
    throw new BridgeError("unsupported_model", 400);
  return stripped;
}

function filteredEnvironment() {
  return Object.fromEntries(
    PASSTHROUGH_ENV.flatMap((name) =>
      process.env[name] ? [[name, process.env[name]]] : [],
    ),
  );
}

function disabledToolArgs() {
  return [
    "--disable",
    "shell_tool",
    "--disable",
    "unified_exec",
    "--disable",
    "apps",
    "--disable",
    "plugins",
    "--disable",
    "browser_use",
    "--disable",
    "computer_use",
    "--disable",
    "image_generation",
    "--disable",
    "multi_agent",
    "--disable",
    "workspace_dependencies",
  ];
}

function codexArgs({
  allowedDomains = [],
  model,
  outputPath,
  research,
  schemaPath,
}) {
  const args = [
    "exec",
    "--ephemeral",
    "--ignore-user-config",
    "--ignore-rules",
    "--skip-git-repo-check",
    "--sandbox",
    "read-only",
    "--json",
    "--color",
    "never",
    "--model",
    model,
    "-c",
    'forced_login_method="chatgpt"',
    "-c",
    `web_search="${research ? "live" : "disabled"}"`,
    ...disabledToolArgs(),
    "--output-schema",
    schemaPath,
    "--output-last-message",
    outputPath,
    "-",
  ];

  if (research) {
    args.splice(
      args.length - 5,
      0,
      "-c",
      `tools.web_search={allowed_domains=${JSON.stringify(allowedDomains)}}`,
    );
  }

  return args;
}

function appendBounded(current, chunk, limit) {
  const next = Buffer.concat([current, chunk]);
  return next.length > limit ? next.subarray(next.length - limit) : next;
}

function runProcess(args, { cwd, input = "", signal, timeoutMs }) {
  if (signal?.aborted) {
    return Promise.reject(new BridgeError("request_cancelled", 499));
  }

  return new Promise((resolve, reject) => {
    const child = spawn(CODEX_BIN, args, {
      cwd,
      env: filteredEnvironment(),
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = Buffer.alloc(0);
    let stderr = Buffer.alloc(0);
    let settled = false;
    let terminationReason = null;
    let inputFailed = false;
    let killTimer;

    const finish = (error, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearTimeout(killTimer);
      signal?.removeEventListener("abort", abort);
      if (error) reject(error);
      else resolve(result);
    };

    const terminate = (reason) => {
      if (settled || terminationReason) return;
      terminationReason = reason;
      child.kill("SIGTERM");
      killTimer = setTimeout(() => child.kill("SIGKILL"), KILL_GRACE_MS);
      killTimer.unref();
    };
    const abort = () => terminate("abort");
    signal?.addEventListener("abort", abort, { once: true });

    const timer = setTimeout(() => terminate("timeout"), timeoutMs);

    child.stdout.on("data", (chunk) => {
      stdout = appendBounded(stdout, chunk, MAX_PROCESS_OUTPUT_BYTES);
    });
    child.stderr.on("data", (chunk) => {
      stderr = appendBounded(stderr, chunk, MAX_PROCESS_OUTPUT_BYTES);
    });
    child.stdin.on("error", () => {
      inputFailed = true;
      child.kill("SIGTERM");
    });
    child.on("error", (error) => {
      const bridgeError =
        error?.code === "ENOENT"
          ? new BridgeError("codex_missing", 503)
          : new BridgeError("codex_execution_failed", 502);
      finish(bridgeError);
    });
    child.on("close", (code, childSignal) => {
      if (terminationReason === "abort") {
        finish(new BridgeError("request_cancelled", 499));
        return;
      }
      if (terminationReason === "timeout") {
        finish(new BridgeError("execution_timeout", 504));
        return;
      }
      if (inputFailed || code !== 0 || childSignal) {
        finish(new BridgeError("codex_execution_failed", 502));
        return;
      }

      finish(null, {
        stderr: stderr.toString("utf8"),
        stdout: stdout.toString("utf8"),
      });
    });

    if (signal?.aborted) abort();
    if (terminationReason !== "abort") child.stdin.end(input);
  });
}

function parseUsage(jsonl) {
  let usage = {};

  for (const line of jsonl.split(/\r?\n/)) {
    if (!line.trim()) continue;

    try {
      const event = JSON.parse(line);
      if (event.type === "turn.completed" && event.usage) usage = event.usage;
    } catch {
      // Non-JSON diagnostic output is ignored and never logged.
    }
  }

  const promptTokens = Number(usage.input_tokens || 0);
  const completionTokens = Number(usage.output_tokens || 0);
  return {
    completion_tokens: completionTokens,
    prompt_tokens: promptTokens,
    prompt_tokens_details: {
      cached_tokens: Number(usage.cached_input_tokens || 0),
    },
    total_tokens: promptTokens + completionTokens,
  };
}

async function readCodexOutput(outputPath) {
  let output;
  try {
    output = await fs.open(
      outputPath,
      fsConstants.O_RDONLY | fsConstants.O_NOFOLLOW | fsConstants.O_NONBLOCK,
    );
  } catch (error) {
    if (error?.code === "ENOENT") {
      throw new BridgeError("codex_output_missing", 502);
    }
    throw new BridgeError("invalid_codex_output", 502);
  }

  try {
    const outputStat = await output.stat();
    if (!outputStat.isFile()) {
      throw new BridgeError("invalid_codex_output", 502);
    }
    if (outputStat.size > MAX_RESULT_BYTES) {
      throw new BridgeError("codex_output_too_large", 502);
    }

    const chunks = [];
    let bytes = 0;
    while (bytes <= MAX_RESULT_BYTES) {
      const capacity = Math.min(64_000, MAX_RESULT_BYTES - bytes + 1);
      const chunk = Buffer.allocUnsafe(capacity);
      const { bytesRead } = await output.read(chunk, 0, capacity, bytes);
      if (bytesRead === 0) break;
      chunks.push(chunk.subarray(0, bytesRead));
      bytes += bytesRead;
    }
    if (bytes > MAX_RESULT_BYTES) {
      throw new BridgeError("codex_output_too_large", 502);
    }
    return Buffer.concat(chunks, bytes).toString("utf8");
  } catch (error) {
    if (error instanceof BridgeError) throw error;
    throw new BridgeError("invalid_codex_output", 502);
  } finally {
    await output.close();
  }
}

async function executeCodex({
  allowedDomains = [],
  model,
  prompt,
  research = false,
  schema,
  signal,
}) {
  const selectedModel = actualModel(model);
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "torus-codex-poc-"));
  const schemaPath = path.join(tmpDir, "schema.json");
  const outputPath = path.join(tmpDir, "output.json");

  try {
    await fs.writeFile(schemaPath, JSON.stringify(schema), {
      encoding: "utf8",
      mode: 0o600,
    });
    const processResult = await runProcess(
      codexArgs({
        allowedDomains,
        model: selectedModel,
        outputPath,
        research,
        schemaPath,
      }),
      {
        cwd: tmpDir,
        input: prompt,
        signal,
        timeoutMs: EXECUTION_TIMEOUT_MS,
      },
    );
    const result = JSON.parse(await readCodexOutput(outputPath));
    return {
      model: selectedModel,
      result,
      usage: parseUsage(processResult.stdout),
    };
  } catch (error) {
    if (error instanceof SyntaxError)
      throw new BridgeError("invalid_codex_output", 502);
    throw error;
  } finally {
    await fs.rm(tmpDir, { force: true, recursive: true });
  }
}

function completionId() {
  return `chatcmpl_${crypto.randomUUID().replaceAll("-", "")}`;
}

function nowSeconds() {
  return Math.floor(Date.now() / 1000);
}

function stripNullObjectFields(value) {
  if (Array.isArray(value)) return value.map(stripNullObjectFields);
  if (!value || typeof value !== "object") return value;

  return Object.fromEntries(
    Object.entries(value)
      .filter(([, nested]) => nested !== null)
      .map(([key, nested]) => [key, stripNullObjectFields(nested)]),
  );
}

function firstJsonObject(text) {
  const start = text.indexOf("{");
  if (start < 0) return null;

  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let index = start; index < text.length; index += 1) {
    const character = text[index];

    if (inString) {
      if (escaped) escaped = false;
      else if (character === "\\") escaped = true;
      else if (character === '"') inString = false;
      continue;
    }

    if (character === '"') inString = true;
    else if (character === "{") depth += 1;
    else if (character === "}") {
      depth -= 1;
      if (depth === 0) return text.slice(start, index + 1);
    }
  }

  return null;
}

function normalizeMessageContent(content, depth = 0) {
  if (typeof content !== "string") return content ?? "";
  if (depth >= 4) return content;

  const trimmed = content.trim();
  let objectText = trimmed;
  let parsed;

  try {
    parsed = JSON.parse(trimmed);
  } catch {
    if (!trimmed.startsWith("{")) return content;
    objectText = firstJsonObject(trimmed);
    if (!objectText) return content;

    try {
      parsed = JSON.parse(objectText);
    } catch {
      return content;
    }
  }

  if (parsed?.type === "message" && typeof parsed.content === "string") {
    return normalizeMessageContent(parsed.content, depth + 1);
  }

  return objectText;
}

function validateChatResult(result, tools) {
  if (!result || typeof result !== "object" || Array.isArray(result)) {
    throw new BridgeError("invalid_codex_output", 502);
  }

  if (result.type === "message" && typeof result.content === "string") {
    return result;
  }

  const offered = new Set(tools.map((tool) => tool.name));
  if (
    result.type === "function_call" &&
    offered.has(result.name) &&
    result.arguments &&
    typeof result.arguments === "object" &&
    !Array.isArray(result.arguments)
  ) {
    return result;
  }

  throw new BridgeError("invalid_codex_output", 502);
}

function asChatCompletion(result, requestedModel, usage, modernTools) {
  const base = {
    created: nowSeconds(),
    id: completionId(),
    model: requestedModel,
    object: "chat.completion",
    usage,
  };

  if (result.type === "function_call") {
    const callId =
      result.call_id || `call_${crypto.randomUUID().replaceAll("-", "")}`;
    const fn = {
      arguments: JSON.stringify(stripNullObjectFields(result.arguments || {})),
      name: result.name,
    };

    if (modernTools) {
      return {
        ...base,
        choices: [
          {
            finish_reason: "tool_calls",
            index: 0,
            message: {
              content: null,
              role: "assistant",
              tool_calls: [{ function: fn, id: callId, type: "function" }],
            },
          },
        ],
      };
    }

    return {
      ...base,
      choices: [
        {
          finish_reason: "function_call",
          index: 0,
          message: { content: null, function_call: fn, role: "assistant" },
        },
      ],
    };
  }

  return {
    ...base,
    choices: [
      {
        finish_reason: "stop",
        index: 0,
        message: {
          content: normalizeMessageContent(result.content),
          role: "assistant",
        },
      },
    ],
  };
}

function streamChatCompletion(res, response) {
  startSse(res);
  const choice = response.choices[0];
  const delta = { ...choice.message };

  if (Array.isArray(delta.tool_calls)) {
    delta.tool_calls = delta.tool_calls.map((call, index) => ({ ...call, index }));
  }

  writeSse(res, {
    choices: [{ delta, index: 0 }],
    created: response.created,
    id: response.id,
    model: response.model,
    object: "chat.completion.chunk",
  });
  writeSse(res, {
    choices: [{ delta: {}, finish_reason: choice.finish_reason, index: 0 }],
    created: response.created,
    id: response.id,
    model: response.model,
    object: "chat.completion.chunk",
    usage: response.usage,
  });
  finishSse(res);
}

async function loginReadiness() {
  const tmpDir = await fs.mkdtemp(
    path.join(os.tmpdir(), "torus-codex-health-"),
  );

  try {
    const result = await runProcess(["login", "status"], {
      cwd: tmpDir,
      timeoutMs: LOGIN_TIMEOUT_MS,
    });
    const status = `${result.stdout}\n${result.stderr}`;

    if (/Logged in using ChatGPT/i.test(status)) {
      return { auth_method: "chatgpt", code: "ready", ok: true };
    }
    if (/API key/i.test(status)) {
      return { code: "api_key_authenticated", ok: false };
    }
    return { code: "not_authenticated", ok: false };
  } catch (error) {
    if (error?.code === "codex_missing")
      return { code: "codex_missing", ok: false };
    if (error?.code === "execution_timeout")
      return { code: "login_status_timeout", ok: false };
    return { code: "not_authenticated", ok: false };
  } finally {
    await fs.rm(tmpDir, { force: true, recursive: true });
  }
}

function validateResearchBody(body) {
  const domains = Array.isArray(body.allowed_domains)
    ? body.allowed_domains
        .filter((domain) => /^[a-z0-9.-]+$/i.test(domain))
        .slice(0, 100)
    : [];
  if (!body.prompt || typeof body.prompt !== "string" || domains.length === 0) {
    throw new BridgeError("invalid_research_request", 400);
  }
  return domains;
}

function logMetadata(id, metadata) {
  console.log(
    JSON.stringify({
      at: new Date().toISOString(),
      id,
      service: "torus-codex-poc",
      ...metadata,
    }),
  );
}

export function createServer() {
  const executionQueue = new ExecutionQueue({
    maxQueued: MAX_QUEUED_REQUESTS,
    timeoutMs: QUEUE_TIMEOUT_MS,
  });
  let readinessCache = null;
  let readinessInFlight = null;
  const readiness = () => {
    if (readinessCache && Date.now() < readinessCache.expiresAt) {
      return Promise.resolve(readinessCache.status);
    }
    if (!readinessInFlight) {
      readinessInFlight = loginReadiness()
        .then((status) => {
          readinessCache = {
            expiresAt: Date.now() + READINESS_CACHE_TTL_MS,
            status,
          };
          return status;
        })
        .finally(() => {
          readinessInFlight = null;
        });
    }
    return readinessInFlight;
  };

  return http.createServer(async (req, res) => {
    const id = crypto.randomUUID().slice(0, 8);
    const startedAt = Date.now();
    const controller = new AbortController();
    const abortRequest = () => controller.abort();
    const abortClosedResponse = () => {
      if (!res.writableEnded) controller.abort();
    };
    req.once("aborted", abortRequest);
    res.once("close", abortClosedResponse);

    try {
      const protectedRoute =
        (req.method === "GET" && req.url === "/health") ||
        (req.method === "POST" &&
          ["/v1/chat/completions", "/v1/codex/research"].includes(req.url));
      if (protectedRoute && CODEX_PROXY_TOKEN.trim() === "") {
        throw new BridgeError("proxy_token_unconfigured", 503);
      }
      if (protectedRoute && !validBearerToken(req.headers.authorization)) {
        throw new BridgeError("unauthorized", 401);
      }
      if (
        protectedRoute &&
        (!validHost(req.headers.host) || !validOrigin(req.headers.origin))
      ) {
        throw new BridgeError("forbidden", 403);
      }
      if (
        protectedRoute &&
        req.method === "POST" &&
        req.headers["content-type"]?.split(";", 1)[0].trim().toLowerCase() !==
          "application/json"
      ) {
        throw new BridgeError("unsupported_media_type", 415);
      }

      if (req.method === "GET" && req.url === "/health") {
        const status = await readiness();
        writeJson(res, status.ok ? 200 : 503, status);
        logMetadata(id, {
          code: status.code,
          duration_ms: Date.now() - startedAt,
          route: "health",
        });
        return;
      }

      if (
        req.method !== "POST" ||
        !["/v1/chat/completions", "/v1/codex/research"].includes(req.url)
      ) {
        writeJson(res, 404, {
          error: { code: "not_found", type: "bridge_error" },
        });
        return;
      }

      const body = await parseJsonBody(req);

      if (req.url === "/v1/codex/research") {
        const allowedDomains = validateResearchBody(body);
        const execution = await executionQueue.run(
          () =>
            executeCodex({
              allowedDomains,
              model: body.model,
              prompt: buildResearchPrompt(body.prompt, allowedDomains),
              research: true,
              schema: buildResearchSchema(),
              signal: controller.signal,
            }),
          { signal: controller.signal },
        );
        writeJson(res, 200, {
          ...execution.result,
          billing_source: "chatgpt_plan",
          model: execution.model,
          provider: "codex_cli",
          usage: execution.usage,
        });
        logMetadata(id, {
          duration_ms: Date.now() - startedAt,
          model: execution.model,
          route: "research",
          source_count: execution.result.retrieved_sources?.length || 0,
          status: 200,
        });
        return;
      }

      validateCompletionBody(body);
      const tools = normalizeTools(body);
      const messages = body.messages;
      const execution = await executionQueue.run(
        () =>
          executeCodex({
            model: body.model,
            prompt: buildPrompt({ messages, tools }),
            schema: buildOutputSchema(tools),
            signal: controller.signal,
          }),
        { signal: controller.signal },
      );
      const response = asChatCompletion(
        validateChatResult(execution.result, tools),
        body.model || `codex-proxy/${execution.model}`,
        execution.usage,
        Array.isArray(body.tools),
      );

      if (body.stream === true) streamChatCompletion(res, response);
      else writeJson(res, 200, response);

      logMetadata(id, {
        duration_ms: Date.now() - startedAt,
        message_count: messages.length,
        model: execution.model,
        route: "chat_completions",
        status: 200,
        tool_count: tools.length,
      });
    } catch (error) {
      const status = error instanceof BridgeError ? error.status : 500;
      const code = error instanceof BridgeError ? error.code : "bridge_failed";
      const body = { error: { code, type: "bridge_error" } };
      writeJson(res, status, body);
      logMetadata(id, { code, duration_ms: Date.now() - startedAt, status });
    } finally {
      req.removeListener("aborted", abortRequest);
      res.removeListener("close", abortClosedResponse);
    }
  });
}

export {
  asChatCompletion,
  buildOutputSchema,
  buildPrompt,
  buildResearchPrompt,
  codexArgs,
  ExecutionQueue,
  parseUsage,
  validateChatResult,
};

const isMain =
  process.argv[1] &&
  path.resolve(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  const server = createServer();
  server.listen(PORT, HOST, () => {
    console.log(`torus-codex-poc listening on http://${HOST}:${PORT}`);
  });
}
