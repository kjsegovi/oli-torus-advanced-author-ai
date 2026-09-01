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
  ExecutionQueue,
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

async function fakeCodex(
  tmpDir,
  { auth = "chatgpt", chatResult, delayMs = 0, mode = "normal" } = {},
) {
  const executable = path.join(tmpDir, "fake-codex");
  const capturePath = path.join(tmpDir, "capture.jsonl");
  const eventPath = path.join(tmpDir, "events.jsonl");
  const authText =
    auth === "chatgpt"
      ? "Logged in using ChatGPT"
      : "Logged in using an API key";

  const source = `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
const mode = ${JSON.stringify(mode)};
const failMarker = ${JSON.stringify(path.join(tmpDir, "fail-first.marker"))};
if (args[0] === 'login') { console.log(${JSON.stringify(authText)}); process.exit(0); }
if (mode === 'immediate-exit') process.exit(17);
if (mode === 'ignore-term') {
  process.on('SIGTERM', () => {});
  process.stdin.resume();
  setInterval(() => {}, 1000);
} else {
  let prompt = '';
  process.stdin.on('data', (chunk) => { prompt += chunk.toString(); });
  process.stdin.on('end', () => {
    fs.appendFileSync(${JSON.stringify(eventPath)}, JSON.stringify({ event: 'start', prompt }) + '\\n');
    process.on('SIGTERM', () => {
      fs.appendFileSync(${JSON.stringify(eventPath)}, JSON.stringify({ event: 'terminated', prompt }) + '\\n');
      process.exit(143);
    });
    if (mode === 'fail-first' && !fs.existsSync(failMarker)) {
      fs.writeFileSync(failMarker, 'failed');
      process.exit(17);
    }
    setTimeout(() => {
      const outputIndex = args.indexOf('--output-last-message');
      const outputPath = args[outputIndex + 1];
      if (mode === 'nonzero-diagnostics') {
        process.stdout.write('STDOUT_FIXTURE_SECRET'.repeat(60_000));
        process.stderr.write('STDERR_FIXTURE_SECRET'.repeat(60_000));
        process.exit(9);
      }
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
        : ${JSON.stringify(chatResult)} || (prompt.includes('review_openstax_questions')
          ? { type: 'function_call', name: 'review_openstax_questions', arguments: { candidate: 'v2' } }
          : { type: 'message', content: 'ok' });
      fs.appendFileSync(${JSON.stringify(capturePath)}, JSON.stringify({ args, prompt }) + '\\n');
      fs.appendFileSync(${JSON.stringify(eventPath)}, JSON.stringify({ event: 'finish', prompt }) + '\\n');
      if (mode === 'missing-output') {
        console.log(JSON.stringify({ type: 'turn.completed', usage: {} }));
        return;
      }
      if (mode === 'malformed-output') fs.writeFileSync(outputPath, '{not-json');
      else if (mode === 'oversized-output') fs.writeFileSync(outputPath, 'x'.repeat(10_000));
      else if (mode === 'symlink-output') {
        const targetPath = outputPath + '.target';
        fs.writeFileSync(targetPath, JSON.stringify(result));
        fs.symlinkSync(targetPath, outputPath);
      } else fs.writeFileSync(outputPath, JSON.stringify(result));
      console.log(JSON.stringify({
        type: 'turn.completed',
        usage: { input_tokens: 120, cached_input_tokens: 20, output_tokens: 30 }
      }));
    }, ${delayMs});
  });
}
`;

  await fs.writeFile(executable, source, { mode: 0o700 });
  return { capturePath, eventPath, executable };
}

async function startBridge(t, options = {}) {
  const tmpDir = await fs.mkdtemp(path.join(os.tmpdir(), "codex-bridge-test-"));
  const fake = await fakeCodex(tmpDir, options);
  const port = await unusedPort();
  const child = spawn(process.execPath, [bridgePath], {
    env: {
      ...process.env,
      CODEX_BIN: options.codexBin || fake.executable,
      CODEX_PROXY_KILL_GRACE_MS: String(options.killGraceMs || 2_000),
      CODEX_PROXY_MAX_PROCESS_OUTPUT_BYTES: String(
        options.maxProcessOutputBytes || 64_000,
      ),
      CODEX_PROXY_MAX_REQUEST_BYTES: String(options.maxBytes || 1_000_000),
      CODEX_PROXY_MAX_QUEUED_REQUESTS: String(options.maxQueued || 2),
      CODEX_PROXY_MAX_RESULT_BYTES: String(options.maxResultBytes || 2_000_000),
      CODEX_PROXY_QUEUE_TIMEOUT_MS: String(options.queueTimeoutMs || 15_000),
      CODEX_PROXY_TIMEOUT_MS: String(options.timeoutMs || 2_000),
      PORT: String(port),
      ...(options.tmpRoot ? { TMPDIR: options.tmpRoot } : {}),
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

  return {
    baseUrl: `http://127.0.0.1:${port}`,
    capturePath: fake.capturePath,
    eventPath: fake.eventPath,
  };
}

async function readEvents(eventPath) {
  try {
    return (await fs.readFile(eventPath, "utf8"))
      .trim()
      .split("\n")
      .filter(Boolean)
      .map(JSON.parse);
  } catch (error) {
    if (error?.code === "ENOENT") return [];
    throw error;
  }
}

async function waitForEvent(eventPath, predicate, timeoutMs = 2_000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const events = await readEvents(eventPath);
    if (events.some(predicate)) return events;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  throw new Error("fake Codex event timed out");
}

function parseSseEvents(text) {
  return text
    .trim()
    .split("\n\n")
    .map((event) => event.replace(/^data: /, ""))
    .map((payload) => (payload === "[DONE]" ? payload : JSON.parse(payload)));
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

test("execution queue runs one task at a time", async () => {
  const queue = new ExecutionQueue({ maxQueued: 2, timeoutMs: 1_000 });
  let releaseFirst;
  const firstGate = new Promise((resolve) => {
    releaseFirst = resolve;
  });
  const events = [];

  const first = queue.run(async () => {
    events.push("first-start");
    await firstGate;
    events.push("first-finish");
  });
  const second = queue.run(async () => {
    events.push("second-start");
  });

  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual(events, ["first-start"]);
  releaseFirst();
  await Promise.all([first, second]);
  assert.deepEqual(events, ["first-start", "first-finish", "second-start"]);
});

test("fake Codex executions are serial within one server", async (t) => {
  const bridge = await startBridge(t, { delayMs: 200 });
  const request = (content) =>
    fetch(`${bridge.baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages: [{ role: "user", content }] }),
    });

  const first = request("serial-first");
  await waitForEvent(
    bridge.eventPath,
    (event) => event.event === "start" && event.prompt.includes("serial-first"),
  );
  const second = request("serial-second");
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(
    (await readEvents(bridge.eventPath)).filter(
      (event) => event.event === "start",
    ).length,
    1,
  );

  assert.equal((await first).status, 200);
  assert.equal((await second).status, 200);
  assert.equal(
    (await readEvents(bridge.eventPath)).filter(
      (event) => event.event === "start",
    ).length,
    2,
  );
});

test("a cancelled queued request never launches Codex", async (t) => {
  const bridge = await startBridge(t, { delayMs: 250 });
  const requestBody = (content) => ({
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", content }] }),
  });

  const first = fetch(
    `${bridge.baseUrl}/v1/chat/completions`,
    requestBody("first-running"),
  );
  await waitForEvent(
    bridge.eventPath,
    (event) => event.event === "start" && event.prompt.includes("first-running"),
  );

  const controller = new AbortController();
  const queued = fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    ...requestBody("second-cancelled"),
    signal: controller.signal,
  });
  await new Promise((resolve) => setTimeout(resolve, 25));
  controller.abort();
  await assert.rejects(queued, { name: "AbortError" });
  assert.equal((await first).status, 200);
  await new Promise((resolve) => setTimeout(resolve, 100));

  const starts = (await readEvents(bridge.eventPath)).filter(
    (event) => event.event === "start",
  );
  assert.equal(starts.length, 1);
});

test("cancelling a running request terminates its Codex child", async (t) => {
  const bridge = await startBridge(t, { delayMs: 1_000 });
  const controller = new AbortController();
  const request = fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      messages: [{ role: "user", content: "cancel-running" }],
    }),
    signal: controller.signal,
  });

  await waitForEvent(
    bridge.eventPath,
    (event) => event.event === "start" && event.prompt.includes("cancel-running"),
  );
  controller.abort();
  await assert.rejects(request, { name: "AbortError" });
  const events = await waitForEvent(
    bridge.eventPath,
    (event) =>
      event.event === "terminated" && event.prompt.includes("cancel-running"),
    500,
  );
  assert.equal(events.filter((event) => event.event === "start").length, 1);
  assert.equal(events.filter((event) => event.event === "terminated").length, 1);

  const recovered = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      messages: [{ role: "user", content: "after-running-cancel" }],
    }),
  });
  assert.equal(recovered.status, 200);
  assert.equal(
    (await readEvents(bridge.eventPath)).filter(
      (event) => event.event === "start",
    ).length,
    2,
  );
});

test("queue capacity overflow returns bridge_busy without launching", async (t) => {
  const bridge = await startBridge(t, { delayMs: 250, maxQueued: 1 });
  const request = (content) =>
    fetch(`${bridge.baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages: [{ role: "user", content }] }),
    });

  const first = request("capacity-first");
  await waitForEvent(
    bridge.eventPath,
    (event) => event.event === "start" && event.prompt.includes("capacity-first"),
  );
  const second = request("capacity-second");
  await new Promise((resolve) => setTimeout(resolve, 25));
  const overflow = await request("capacity-overflow");

  assert.equal(overflow.status, 503);
  assert.deepEqual(await overflow.json(), {
    error: { code: "bridge_busy", type: "bridge_error" },
  });
  assert.equal((await first).status, 200);
  assert.equal((await second).status, 200);
  const starts = (await readEvents(bridge.eventPath)).filter(
    (event) => event.event === "start",
  );
  assert.equal(starts.length, 2);
});

test("queue wait deadline returns queue_timeout without launching", async (t) => {
  const bridge = await startBridge(t, {
    delayMs: 300,
    maxQueued: 1,
    queueTimeoutMs: 50,
  });
  const request = (content) =>
    fetch(`${bridge.baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages: [{ role: "user", content }] }),
    });

  const first = request("timeout-first");
  await waitForEvent(
    bridge.eventPath,
    (event) => event.event === "start" && event.prompt.includes("timeout-first"),
  );
  const timedOut = await request("timeout-queued");

  assert.equal(timedOut.status, 503);
  assert.deepEqual(await timedOut.json(), {
    error: { code: "queue_timeout", type: "bridge_error" },
  });
  assert.equal((await first).status, 200);
  const starts = (await readEvents(bridge.eventPath)).filter(
    (event) => event.event === "start",
  );
  assert.equal(starts.length, 1);
});

test("a later request succeeds after a Codex process failure", async (t) => {
  const bridge = await startBridge(t, { mode: "fail-first" });
  const request = (content) =>
    fetch(`${bridge.baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ messages: [{ role: "user", content }] }),
    });

  const failed = await request("recovery-failure");
  assert.equal(failed.status, 502);
  assert.deepEqual(await failed.json(), {
    error: { code: "codex_execution_failed", type: "bridge_error" },
  });

  const recovered = await request("recovery-success");
  assert.equal(recovered.status, 200);
  assert.equal((await recovered.json()).choices[0].message.content, "ok");
  const starts = (await readEvents(bridge.eventPath)).filter(
    (event) => event.event === "start",
  );
  assert.equal(starts.length, 2);
});

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

test("leading JSON is preserved while trailing Codex chatter is discarded", () => {
  const completion = asChatCompletion(
    { type: "message", content: '{"patch":[]} trailing Codex chatter' },
    "codex-proxy/gpt-5.6-sol",
    {},
    false,
  );

  assert.equal(completion.choices[0].message.content, '{"patch":[]}');
});

test("nested message envelopes unwrap recursively", () => {
  const patch = { patch: [{ op: "replace", path: "/title", value: "v2" }] };
  const inner = { type: "message", content: JSON.stringify(patch) };
  const outer = {
    type: "message",
    content: `${JSON.stringify({ type: "message", content: JSON.stringify(inner) })} trailing text`,
  };

  const completion = asChatCompletion(
    outer,
    "codex-proxy/gpt-5.6-sol",
    {},
    false,
  );

  assert.deepEqual(JSON.parse(completion.choices[0].message.content), patch);
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

test("the structured schema pairs each offered tool with only its argument contract", () => {
  const toolA = tool;
  const toolB = {
    name: "score_openstax_questions",
    parameters: {
      type: "object",
      properties: { score: { type: "integer" } },
      required: ["score"],
    },
  };
  const schema = buildOutputSchema([toolA, toolB]);
  const calls = schema.anyOf.filter(
    (variant) => variant.properties.type.const === "function_call",
  );

  assert.deepEqual(
    calls.map((variant) => variant.properties.name.const),
    [toolA.name, toolB.name],
  );
  assert.deepEqual(calls[0].properties.arguments.required, ["candidate"]);
  assert.deepEqual(calls[1].properties.arguments.required, ["score"]);
});

test("message schema requires null name and arguments", () => {
  const schema = buildOutputSchema([tool]);
  const message = schema.anyOf.find(
    (variant) => variant.properties.type.const === "message",
  );

  assert.deepEqual(message.properties.name, { type: "null" });
  assert.deepEqual(message.properties.arguments, { type: "null" });
  assert.deepEqual(message.required, ["type", "name", "arguments", "content"]);
});

test("the structured schema retains a tool argument contract", () => {
  const schema = buildOutputSchema([tool]);
  const call = schema.anyOf.find(
    (variant) => variant.properties.type.const === "function_call",
  );

  assert.deepEqual(call.properties.name, { const: tool.name, type: "string" });
  assert.deepEqual(call.properties.arguments.required, ["candidate"]);
  assert.equal(call.properties.arguments.additionalProperties, false);
  assert.deepEqual(call.required, ["type", "name", "arguments", "content"]);
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

  const args = schema.anyOf.find(
    (variant) => variant.properties.type.const === "function_call",
  ).properties.arguments;
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

test("an immediate Codex exit contains EPIPE and leaves the proxy healthy", async (t) => {
  const bridge = await startBridge(t, { mode: "immediate-exit" });
  const fixtureSecret = "PROMPT_FIXTURE_SECRET";
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      messages: [
        { role: "user", content: fixtureSecret + "x".repeat(500_000) },
      ],
    }),
  });

  assert.equal(response.status, 502);
  const responseText = await response.text();
  assert.deepEqual(JSON.parse(responseText), {
    error: { code: "codex_execution_failed", type: "bridge_error" },
  });
  assert.doesNotMatch(responseText, new RegExp(fixtureSecret));

  const health = await fetch(`${bridge.baseUrl}/health`);
  assert.equal(health.status, 200);
  assert.equal((await health.json()).code, "ready");
});

test("large subprocess diagnostics are bounded and redacted", async (t) => {
  const bridge = await startBridge(t, {
    maxProcessOutputBytes: 1_024,
    mode: "nonzero-diagnostics",
  });
  const promptSecret = "PROMPT_FIXTURE_SECRET";
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      messages: [{ role: "user", content: promptSecret }],
    }),
  });

  assert.equal(response.status, 502);
  const responseText = await response.text();
  assert.deepEqual(JSON.parse(responseText), {
    error: { code: "codex_execution_failed", type: "bridge_error" },
  });
  for (const secret of [
    promptSecret,
    "STDOUT_FIXTURE_SECRET",
    "STDERR_FIXTURE_SECRET",
  ]) {
    assert.doesNotMatch(responseText, new RegExp(secret));
  }
});

test("a missing Codex executable returns a typed service error", async (t) => {
  const bridge = await startBridge(t, {
    codexBin: path.join(os.tmpdir(), "definitely-missing-codex"),
  });
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", content: "hello" }] }),
  });

  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), {
    error: { code: "codex_missing", type: "bridge_error" },
  });

  const health = await fetch(`${bridge.baseUrl}/health`);
  assert.equal(health.status, 503);
  assert.deepEqual(await health.json(), { code: "codex_missing", ok: false });
});

test("a successful Codex exit without an output file is typed", async (t) => {
  const bridge = await startBridge(t, { mode: "missing-output" });
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", content: "hello" }] }),
  });

  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {
    error: { code: "codex_output_missing", type: "bridge_error" },
  });
});

test("malformed Codex output returns the typed validation error", async (t) => {
  const bridge = await startBridge(t, { mode: "malformed-output" });
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", content: "hello" }] }),
  });

  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {
    error: { code: "invalid_codex_output", type: "bridge_error" },
  });
});

test("oversized Codex output is rejected before it is read", async (t) => {
  const bridge = await startBridge(t, {
    maxResultBytes: 1_024,
    mode: "oversized-output",
  });
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", content: "hello" }] }),
  });

  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {
    error: { code: "codex_output_too_large", type: "bridge_error" },
  });
});

test("Codex output must be a directly opened regular file", async (t) => {
  const bridge = await startBridge(t, { mode: "symlink-output" });
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", content: "hello" }] }),
  });

  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {
    error: { code: "invalid_codex_output", type: "bridge_error" },
  });
});

test("unsupported models are rejected before temporary directory creation", async (t) => {
  const missingTmpRoot = path.join(
    os.tmpdir(),
    `missing-codex-tmp-${process.pid}-${Date.now()}`,
  );
  const bridge = await startBridge(t, { tmpRoot: missingTmpRoot });
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      model: "codex-proxy/unsupported-model",
      messages: [{ role: "user", content: "hello" }],
    }),
  });

  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    error: { code: "unsupported_model", type: "bridge_error" },
  });
  await assert.rejects(fs.stat(missingTmpRoot), { code: "ENOENT" });
});

test("timeout honors the configured kill grace for SIGTERM-resistant children", async (t) => {
  const timeoutMs = 50;
  const killGraceMs = 100;
  const bridge = await startBridge(t, {
    killGraceMs,
    mode: "ignore-term",
    timeoutMs,
  });
  const startedAt = Date.now();
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", content: "timeout" }] }),
  });
  const elapsedMs = Date.now() - startedAt;

  assert.equal(response.status, 504);
  assert.deepEqual(await response.json(), {
    error: { code: "execution_timeout", type: "bridge_error" },
  });
  assert.ok(
    elapsedMs <= timeoutMs + killGraceMs + 500,
    `elapsed ${elapsedMs}ms exceeded timeout plus kill grace`,
  );
});

test("an unknown Codex function call is rejected before formatting", async (t) => {
  const bridge = await startBridge(t, {
    chatResult: {
      type: "function_call",
      name: "unoffered_function",
      arguments: { candidate: "v2" },
    },
  });
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      tools: [{ type: "function", function: tool }],
      messages: [{ role: "user", content: "Review this." }],
    }),
  });

  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {
    error: { code: "invalid_codex_output", type: "bridge_error" },
  });
});

test("a non-object Codex result is rejected before formatting", async (t) => {
  const bridge = await startBridge(t, { chatResult: "not an object" });
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ messages: [{ role: "user", content: "Reply." }] }),
  });

  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), {
    error: { code: "invalid_codex_output", type: "bridge_error" },
  });
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

test("malformed JSON returns a typed client error", async (t) => {
  const bridge = await startBridge(t);
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{not-json",
  });

  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    error: { code: "invalid_json", type: "bridge_error" },
  });
});

test("invalid completion bodies return typed client errors", async (t) => {
  const bridge = await startBridge(t);
  const cases = [
    { name: "null", body: "null", code: "invalid_json" },
    { name: "array", body: "[]", code: "invalid_json" },
    { name: "missing messages", body: JSON.stringify({}), code: "invalid_completion_request" },
    {
      name: "malformed tools",
      body: JSON.stringify({ messages: [], tools: {} }),
      code: "invalid_completion_request",
    },
  ];

  for (const { body, code, name } of cases) {
    const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    });

    assert.equal(response.status, 400, name);
    assert.deepEqual(
      await response.json(),
      { error: { code, type: "bridge_error" } },
      name,
    );
  }
});

test("malformed research body returns a typed client error", async (t) => {
  const bridge = await startBridge(t);
  const response = await fetch(`${bridge.baseUrl}/v1/codex/research`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "[]",
  });

  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    error: { code: "invalid_json", type: "bridge_error" },
  });
});

test("modern tool streams use indexed calls and complete with a stable empty delta", async (t) => {
  const bridge = await startBridge(t);
  const response = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      stream: true,
      tools: [{ type: "function", function: tool }],
      messages: [{ role: "user", content: "Use the review tool." }],
    }),
  });

  assert.equal(response.status, 200);
  const events = parseSseEvents(await response.text());
  assert.equal(events.at(-1), "[DONE]");
  assert.equal(events.length, 3);
  assert.equal(events[0].choices[0].delta.tool_calls[0].index, 0);
  assert.equal(events[1].choices[0].finish_reason, "tool_calls");
  assert.deepEqual(events[1].choices[0].delta, {});
  assert.equal(events[1].id, events[0].id);
  assert.equal(events[1].model, events[0].model);
  assert.equal(events[1].created, events[0].created);
});

test("message and legacy function-call streams retain their response shapes", async (t) => {
  const bridge = await startBridge(t);
  const message = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      stream: true,
      messages: [{ role: "user", content: "Reply normally." }],
    }),
  });
  const messageEvents = parseSseEvents(await message.text());
  assert.equal(messageEvents[0].choices[0].delta.role, "assistant");
  assert.equal(messageEvents[0].choices[0].delta.content, "ok");
  assert.deepEqual(messageEvents[1].choices[0].delta, {});

  const legacy = await fetch(`${bridge.baseUrl}/v1/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      stream: true,
      functions: [tool],
      messages: [{ role: "user", content: "Use the review tool." }],
    }),
  });
  const legacyEvents = parseSseEvents(await legacy.text());
  assert.equal(
    legacyEvents[0].choices[0].delta.function_call.name,
    tool.name,
  );
  assert.equal(legacyEvents[0].choices[0].delta.tool_calls, undefined);
  assert.deepEqual(legacyEvents[1].choices[0].delta, {});
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
