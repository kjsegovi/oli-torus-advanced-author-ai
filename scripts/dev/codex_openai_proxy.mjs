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
import { promises as fs } from "node:fs";
import { fileURLToPath } from "node:url";

const HOST = "127.0.0.1";
const PORT = positiveInteger(process.env.PORT, 4001);
const CODEX_BIN = process.env.CODEX_BIN || "codex";
const EXECUTION_TIMEOUT_MS = positiveInteger(
  process.env.CODEX_PROXY_TIMEOUT_MS,
  300_000,
);
const LOGIN_TIMEOUT_MS = positiveInteger(
  process.env.CODEX_PROXY_LOGIN_TIMEOUT_MS,
  5_000,
);
const MAX_REQUEST_BYTES = positiveInteger(
  process.env.CODEX_PROXY_MAX_REQUEST_BYTES,
  2_000_000,
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

let executionTail = Promise.resolve();

class BridgeError extends Error {
  constructor(code, status = 500, details) {
    super(code);
    this.code = code;
    this.status = status;
    this.details = details;
  }
}

function positiveInteger(value, fallback) {
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

function writeJson(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function startSse(res) {
  res.writeHead(200, {
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
    "content-type": "text/event-stream",
  });
}

function writeSse(res, payload) {
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

function finishSse(res) {
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
      content: { type: "string" },
      type: { const: "message", type: "string" },
    },
    required: ["type", "content"],
    type: "object",
  };
}

function buildOutputSchema(tools = []) {
  if (!tools.length) return messageSchema();

  const argumentSchemas = tools.map((tool) =>
    normalizeSchema(tool.parameters || { type: "object", properties: {} }),
  );

  return {
    additionalProperties: false,
    properties: {
      arguments: {
        anyOf: [
          ...(argumentSchemas.length === 1
            ? argumentSchemas
            : [{ anyOf: argumentSchemas }]),
          { type: "null" },
        ],
      },
      content: { type: ["string", "null"] },
      name: {
        anyOf: [
          { enum: tools.map((tool) => tool.name), type: "string" },
          { type: "null" },
        ],
      },
      type: { enum: ["message", "function_call"], type: "string" },
    },
    required: ["type", "name", "arguments", "content"],
    type: "object",
  };
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

function runProcess(args, { cwd, input = "", timeoutMs }) {
  return new Promise((resolve, reject) => {
    const child = spawn(CODEX_BIN, args, {
      cwd,
      env: filteredEnvironment(),
      stdio: ["pipe", "pipe", "pipe"],
    });
    const stdout = [];
    const stderr = [];
    let timedOut = false;

    const timer = setTimeout(() => {
      timedOut = true;
      child.kill("SIGTERM");
      setTimeout(() => child.kill("SIGKILL"), 2_000).unref();
    }, timeoutMs);

    child.stdout.on("data", (chunk) => stdout.push(chunk));
    child.stderr.on("data", (chunk) => stderr.push(chunk));
    child.on("error", (error) => {
      clearTimeout(timer);
      reject(error);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (timedOut) return reject(new BridgeError("execution_timeout", 504));

      const stderrText = Buffer.concat(stderr).toString("utf8");
      const stdoutText = Buffer.concat(stdout).toString("utf8");
      if (code !== 0) {
        return reject(
          new BridgeError("codex_execution_failed", 502, {
            exit_code: code,
            stderr: stderrText.slice(-2000),
            stdout: stdoutText.slice(-4000),
          }),
        );
      }

      resolve({
        stderr: stderrText,
        stdout: stdoutText,
      });
    });

    child.stdin.end(input);
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

async function executeCodex({
  allowedDomains = [],
  model,
  prompt,
  research = false,
  schema,
}) {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "torus-codex-poc-"));
  const schemaPath = path.join(tmpDir, "schema.json");
  const outputPath = path.join(tmpDir, "output.json");
  const selectedModel = actualModel(model);

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
      { cwd: tmpDir, input: prompt, timeoutMs: EXECUTION_TIMEOUT_MS },
    );
    const result = JSON.parse(await fs.readFile(outputPath, "utf8"));
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

function serialExecution(task) {
  const next = executionTail.then(task, task);
  executionTail = next.catch(() => undefined);
  return next;
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

function unwrapNestedMessageContent(content) {
  if (typeof content !== "string") return content ?? "";

  const trimmed = content.trim();
  let parsed;

  try {
    parsed = JSON.parse(trimmed);
  } catch {
    const objectText = firstJsonObject(trimmed);
    if (!objectText) return content;

    try {
      parsed = JSON.parse(objectText);
    } catch {
      return content;
    }
  }

  return parsed?.type === "message" && typeof parsed.content === "string"
    ? parsed.content
    : content;
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
          content: unwrapNestedMessageContent(result.content),
          role: "assistant",
        },
      },
    ],
  };
}

function streamChatCompletion(res, response) {
  startSse(res);
  const choice = response.choices[0];
  writeSse(res, {
    choices: [{ delta: choice.message, index: 0 }],
    created: response.created,
    id: response.id,
    model: response.model,
    object: "chat.completion.chunk",
  });
  writeSse(res, {
    choices: [{ finish_reason: choice.finish_reason, index: 0 }],
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
    if (error?.code === "ENOENT") return { code: "codex_missing", ok: false };
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
  return http.createServer(async (req, res) => {
    const id = crypto.randomUUID().slice(0, 8);
    const startedAt = Date.now();

    try {
      if (req.method === "GET" && req.url === "/health") {
        const status = await loginReadiness();
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

      const body = JSON.parse(await readBody(req));

      if (req.url === "/v1/codex/research") {
        const allowedDomains = validateResearchBody(body);
        const execution = await serialExecution(() =>
          executeCodex({
            allowedDomains,
            model: body.model,
            prompt: buildResearchPrompt(body.prompt, allowedDomains),
            research: true,
            schema: buildResearchSchema(),
          }),
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

      const tools = normalizeTools(body);
      const messages = Array.isArray(body.messages) ? body.messages : [];
      const execution = await serialExecution(() =>
        executeCodex({
          model: body.model,
          prompt: buildPrompt({ messages, tools }),
          schema: buildOutputSchema(tools),
        }),
      );
      const response = asChatCompletion(
        execution.result,
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
      if (error instanceof BridgeError && error.details) {
        body.error.details = error.details;
      }
      writeJson(res, status, body);
      logMetadata(id, { code, duration_ms: Date.now() - startedAt, status });
    }
  });
}

export {
  asChatCompletion,
  buildOutputSchema,
  buildPrompt,
  buildResearchPrompt,
  codexArgs,
  parseUsage,
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
