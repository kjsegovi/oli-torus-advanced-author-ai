import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { promises as fs } from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

import {
  asChatCompletion,
  buildOutputSchema,
  buildPrompt,
  buildResearchPrompt,
  codexArgs,
  parseUsage,
} from "./codex_openai_proxy.mjs";

const tool = {
  name: "review_openstax_questions",
  description: "Review questions",
  parameters: {
    type: "object",
    properties: { candidate: { type: "string" } },
    required: ["candidate"],
  },
};

const bridgePath = fileURLToPath(
  new URL("./codex_openai_proxy.mjs", import.meta.url),
);

async function unusedPort() {
  const server = net.createServer();
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const { port } = server.address();
  await new Promise((resolve) => server.close(resolve));
  return port;
}

async function fakeCodex(tmpDir, { auth = "chatgpt", delayMs = 0 } = {}) {
  const executable = path.join(tmpDir, "fake-codex");
  const capturePath = path.join(tmpDir, "capture.jsonl");
  const authText =
    auth === "chatgpt"
      ? "Logged in using ChatGPT"
      : "Logged in using an API key";

  const source = `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
if (args[0] === 'login') { console.log(${JSON.stringify(authText)}); process.exit(0); }
let prompt = '';
process.stdin.on('data', (chunk) => { prompt += chunk.toString(); });
process.stdin.on('end', () => {
  setTimeout(() => {
    const outputIndex = args.indexOf('--output-last-message');
    const outputPath = args[outputIndex + 1];
    const research = prompt.includes('Research the educational simulation evidence request');
    const result = research
      ? {
          retrieved_sources: [
            { url: 'https://www.nist.gov/a', title: 'NIST A' },
            { url: 'https://pubchem.ncbi.nlm.nih.gov/b', title: 'PubChem B' }
          ],
          claims: [
            { paraphrase: 'A grounded claim.', citation_urls: ['https://www.nist.gov/a'] },
            { paraphrase: 'A second claim.', citation_urls: ['https://pubchem.ncbi.nlm.nih.gov/b'] }
          ],
          search_count: 2
        }
      : prompt.includes('review_openstax_questions')
        ? { type: 'function_call', name: 'review_openstax_questions', arguments: { candidate: 'v2' } }
        : { type: 'message', content: 'ok' };
    fs.appendFileSync(${JSON.stringify(capturePath)}, JSON.stringify({ args, prompt }) + '\\n');
    fs.writeFileSync(outputPath, JSON.stringify(result));
    console.log(JSON.stringify({
      type: 'turn.completed',
      usage: { input_tokens: 120, cached_input_tokens: 20, output_tokens: 30 }
    }));
  }, ${delayMs});
});
`;

  await fs.writeFile(executable, source, { mode: 0o700 });
  return { capturePath, executable };
}

async function startBridge(t, options = {}) {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "codex-bridge-test-"));
  const fake = await fakeCodex(tmpDir, options);
  const port = await unusedPort();
  const child = spawn(process.execPath, [bridgePath], {
    env: {
      ...process.env,
      CODEX_BIN: fake.executable,
      CODEX_PROXY_MAX_REQUEST_BYTES: String(options.maxBytes || 100_000),
      CODEX_PROXY_TIMEOUT_MS: String(options.timeoutMs || 2_000),
      PORT: String(port),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  await new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("bridge startup timed out")),
      5_000,
    );
    child.stdout.on("data", (chunk) => {
      if (chunk.toString().includes("listening on")) {
        clearTimeout(timer);
        resolve();
      }
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`bridge exited during startup: ${code}`));
    });
  });

  t.after(async () => {
    child.kill("SIGTERM");
    await fs.rm(tmpDir, { force: true, recursive: true });
  });

  return { baseUrl: `http://127.0.0.1:${port}`, capturePath: fake.capturePath };
}

async function startRealBridge(t) {
  const port = await unusedPort();
  const child = spawn(process.execPath, [bridgePath], {
    env: {
      ...process.env,
      CODEX_BIN: process.env.CODEX_BIN || "codex",
      PORT: String(port),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });

  await new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error("real bridge startup timed out")),
      5_000,
    );
    child.stdout.on("data", (chunk) => {
      if (chunk.toString().includes("listening on")) {
        clearTimeout(timer);
        resolve();
      }
    });
    child.once("exit", (code) => {
      clearTimeout(timer);
      reject(new Error(`real bridge exited during startup: ${code}`));
    });
  });

  t.after(() => child.kill("SIGTERM"));
  return `http://127.0.0.1:${port}`;
}

test("modern and legacy tool-call responses retain IDs and arguments", () => {
  const result = {
    type: "function_call",
    name: tool.name,
    arguments: { candidate: "v2" },
    call_id: "call_preserved",
  };
  const usage = { prompt_tokens: 10, completion_tokens: 4, total_tokens: 14 };

  const modern = asChatCompletion(
    result,
    "codex-proxy/gpt-5.6-sol",
    usage,
    true,
  );
  assert.equal(modern.choices[0].finish_reason, "tool_calls");
  assert.equal(modern.choices[0].message.tool_calls[0].id, "call_preserved");
  assert.equal(
    modern.choices[0].message.tool_calls[0].function.name,
    tool.name,
  );
  assert.deepEqual(
    JSON.parse(modern.choices[0].message.tool_calls[0].function.arguments),
    result.arguments,
  );

  const legacy = asChatCompletion(
    result,
    "codex-proxy/gpt-5.6-sol",
    usage,
    false,
  );
  assert.equal(legacy.choices[0].finish_reason, "function_call");
  assert.equal(legacy.choices[0].message.function_call.name, tool.name);
});

test("nested message envelopes with trailing Codex text are unwrapped", () => {
  const nested = {
    type: "message",
    name: null,
    arguments: null,
    content: JSON.stringify({
      patch: [{ op: "add", path: "/sections/0", value: {} }],
    }),
  };
  const result = {
    type: "message",
    content: `${JSON.stringify(nested)} trailing malformed Codex event text`,
  };

  const completion = asChatCompletion(
    result,
    "codex-proxy/gpt-5.6-sol",
    {},
    false,
  );

  assert.deepEqual(JSON.parse(completion.choices[0].message.content), {
    patch: [{ op: "add", path: "/sections/0", value: {} }],
  });
});

test("the structured schema binds each tool name to its own argument contract", () => {
  const schema = buildOutputSchema([tool]);

  assert.deepEqual(schema.properties.name.anyOf[0].enum, [tool.name]);
  assert.deepEqual(schema.properties.arguments.anyOf[0].required, [
    "candidate",
  ]);
  assert.equal(
    schema.properties.arguments.anyOf[0].additionalProperties,
    false,
  );
  assert.deepEqual(schema.required, ["type", "name", "arguments", "content"]);
});

test("optional tool fields become required nullable fields for Codex strict schemas", () => {
  const schema = buildOutputSchema([
    {
      name: "submit",
      parameters: {
        type: "object",
        required: ["candidate"],
        properties: {
          candidate: { type: "string" },
          feedback: {
            type: "object",
            properties: {
              hint: { type: "string" },
            },
          },
        },
      },
    },
  ]);

  const args = schema.properties.arguments.anyOf[0];
  assert.deepEqual(args.required.sort(), ["candidate", "feedback"]);
  assert.deepEqual(args.properties.feedback.anyOf[1], { type: "null" });

  const feedback = args.properties.feedback.anyOf[0];
  assert.deepEqual(feedback.required, ["hint"]);
  assert.deepEqual(feedback.properties.hint.anyOf[1], { type: "null" });
});

test("null placeholders from strict schemas are omitted from returned tool arguments", () => {
  const result = {
    type: "function_call",
    name: tool.name,
    arguments: {
      candidate: "v2",
      optional_note: null,
      nested: { keep: "yes", omit: null },
    },
  };

  const completion = asChatCompletion(
    result,
    "codex-proxy/gpt-5.6-sol",
    {},
    true,
  );
  const args = JSON.parse(
    completion.choices[0].message.tool_calls[0].function.arguments,
  );

  assert.deepEqual(args, { candidate: "v2", nested: { keep: "yes" } });
});

test("multi-turn modern tool-result history is serialized without dropping IDs", () => {
  const messages = [
    { role: "user", content: "Review this." },
    {
      role: "assistant",
      content: null,
      tool_calls: [
        {
          id: "call_history",
          type: "function",
          function: { name: tool.name, arguments: '{"candidate":"v1"}' },
        },
      ],
    },
    { role: "tool", tool_call_id: "call_history", content: '{"valid":true}' },
  ];

  const prompt = buildPrompt({ messages, tools: [tool] });
  assert.match(prompt, /call_history/);
  assert.match(prompt, /tool_call_id/);
  assert.match(prompt, /review_openstax_questions/);
});

test("usage events become OpenAI-compatible token accounting", () => {
  const usage = parseUsage(
    [
      JSON.stringify({ type: "thread.started" }),
      JSON.stringify({
        type: "turn.completed",
        usage: {
          input_tokens: 120,
          cached_input_tokens: 40,
          output_tokens: 30,
        },
      }),
    ].join("\n"),
  );

  assert.deepEqual(usage, {
    prompt_tokens: 120,
    completion_tokens: 30,
    total_tokens: 150,
    prompt_tokens_details: { cached_tokens: 40 },
  });
});

test("ordinary and research executions have distinct web-search configuration", () => {
  const common = {
    model: "gpt-5.6-terra",
    outputPath: "/tmp/output.json",
    schemaPath: "/tmp/schema.json",
  };
  const ordinary = codexArgs({ ...common, research: false });
  const research = codexArgs({
    ...common,
    research: true,
    allowedDomains: ["nist.gov", "pubchem.ncbi.nlm.nih.gov"],
  });

  assert.ok(ordinary.includes("--ephemeral"));
  assert.ok(ordinary.includes("--ignore-user-config"));
  assert.ok(ordinary.includes("--ignore-rules"));
  assert.ok(ordinary.includes("read-only"));
  assert.ok(ordinary.includes('web_search="disabled"'));
  assert.ok(research.includes('web_search="live"'));
  assert.ok(research.some((value) => value.includes("allowed_domains")));

  const prompt = buildResearchPrompt("research contract", ["nist.gov"]);
  assert.match(prompt, /Only consult these domains.*nist\.gov/);
  assert.match(prompt, /at most four search actions/i);
});

test("a fake Codex executable verifies readiness, modern history, research, and usage", async (t) => {
  const bridge = await startBridge(t);

  const health = await fetch(`${bridge.baseUrl}/health`);
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), {
    auth_method: "chatgpt",
    code: "ready",
    ok: true,
  });

  const completion = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "codex-proxy/gpt-5.6-sol",
      tools: [{ type: "function", function: tool }],
      messages: [
        {
          role: "assistant",
          tool_calls: [{ id: "call_history", type: "function" }],
        },
        {
          role: "tool",
          tool_call_id: "call_history",
          content: '{"valid":true}',
        },
      ],
    }),
  });
  assert.equal(completion.status, 200);
  const completionBody = await completion.json();
  assert.equal(completionBody.choices[0].finish_reason, "tool_calls");
  assert.equal(completionBody.usage.prompt_tokens, 120);
  assert.equal(completionBody.usage.prompt_tokens_details.cached_tokens, 20);

  const research = await fetch(`${bridge.baseUrl}/v1/codex/research`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "codex-proxy/gpt-5.6-terra",
      prompt: "research contract",
      allowed_domains: ["nist.gov", "pubchem.ncbi.nlm.nih.gov"],
    }),
  });
  assert.equal(research.status, 200);
  const researchBody = await research.json();
  assert.equal(researchBody.provider, "codex_cli");
  assert.equal(researchBody.billing_source, "chatgpt_plan");
  assert.equal(researchBody.retrieved_sources.length, 2);

  const captures = (await fs.readFile(bridge.capturePath, "utf8"))
    .trim()
    .split("\n")
    .map(JSON.parse);
  assert.match(captures[0].prompt, /call_history/);
  assert.ok(captures[0].args.includes('web_search="disabled"'));
  assert.ok(captures[1].args.includes('web_search="live"'));
  assert.ok(
    captures[1].args.some((value) => value.includes("allowed_domains")),
  );
});

test("health rejects API-key authentication", async (t) => {
  const bridge = await startBridge(t, { auth: "api_key" });
  const response = await fetch(`${bridge.baseUrl}/health`);

  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    code: "api_key_authenticated",
    ok: false,
  });
});

test("request limits and execution timeouts fail with sanitized bridge codes", async (t) => {
  const limited = await startBridge(t, { maxBytes: 128 });
  const tooLarge = await fetch(`${limited.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      messages: [{ role: "user", content: "x".repeat(500) }],
    }),
  });
  assert.equal(tooLarge.status, 413);
  assert.deepEqual(await tooLarge.json(), {
    error: { code: "request_too_large", type: "bridge_error" },
  });

  const slow = await startBridge(t, { delayMs: 500, timeoutMs: 50 });
  const timeout = await fetch(`${slow.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "codex-proxy/gpt-5.6-terra",
      messages: [{ role: "user", content: "timeout" }],
    }),
  });
  assert.equal(timeout.status, 504);
  assert.deepEqual(await timeout.json(), {
    error: { code: "execution_timeout", type: "bridge_error" },
  });
});

test(
  "opt-in real ChatGPT Codex smoke test",
  { skip: process.env.OPENSTAX_REAL_CODEX_SMOKE !== "1" },
  async (t) => {
    const baseUrl = await startRealBridge(t);
    const health = await fetch(`${baseUrl}/health`);
    assert.equal(health.status, 200);

    const response = await fetch(`${baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({
        model: "codex-proxy/gpt-5.6-luna",
        messages: [
          { role: "system", content: "Reply exactly with the word ready." },
          { role: "user", content: "Check the local Codex bridge." },
        ],
      }),
    });

    assert.equal(response.status, 200);
    const body = await response.json();
    assert.match(body.choices[0].message.content, /ready/i);
    assert.ok(body.usage.total_tokens > 0);
  },
);
