"use strict";

const fs = require("node:fs");
const http = require("node:http");
const path = require("node:path");
const { chromium } = require("playwright");
const { AxeBuilder } = require("@axe-core/playwright");

const [bundleRoot, contractPath, resultsRoot] = process.argv.slice(2);
const contract = JSON.parse(fs.readFileSync(contractPath, "utf8"));
const result = {
  status: "failed",
  seed: contract.seed,
  network_requests: [],
  console_errors: [],
  page_errors: [],
  capi_handshake: "failed",
  sample_cases_passed: false,
  sample_results: [],
  keyboard: "failed",
  focus_visible: false,
  serious_or_critical_a11y: -1,
  a11y_findings: [],
  desktop_overflow: true,
  mobile_overflow: true,
  reduced_motion: "failed",
  webgl_fallback: "failed",
  screenshots: [],
  traces: ["dom.html", "accessibility.json"],
};

fs.mkdirSync(resultsRoot, { recursive: true });

const typeCodes = {
  number: 1,
  string: 2,
  array: 3,
  boolean: 4,
  enum: 5,
  math_expr: 6,
  array_point: 7,
};

const contentTypes = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
};

const harness = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Torus validator</title></head><body>
<iframe
  id="sim"
  src="/bundle/index.html"
  title="Simulation validation frame"
  sandbox="allow-scripts"
  referrerpolicy="no-referrer"
></iframe>
<script>
  const frame = document.getElementById('sim');
  const state = { ready: false, requestToken: '', authToken: 'torus-validator-auth', outputs: {} };
  const send = (type, values) => frame.contentWindow.postMessage(JSON.stringify({
    handshake: { requestToken: state.requestToken, authToken: state.authToken }, type, values
  }), '*');
  addEventListener('message', (event) => {
    if (event.source !== frame.contentWindow || typeof event.data !== 'string') return;
    let message; try { message = JSON.parse(event.data); } catch (_) { return; }
    if (message.type === 1 && message.handshake && message.handshake.requestToken) {
      state.requestToken = message.handshake.requestToken;
      frame.contentWindow.postMessage(JSON.stringify({
        handshake: { requestToken: state.requestToken, authToken: state.authToken }, type: 2, values: {}
      }), '*');
    } else if (message.type === 3) {
      state.ready = true;
    } else if (message.type === 4) {
      Object.assign(state.outputs, message.values || {});
    }
  });
  window.torusValidator = {
    ready: () => state.ready,
    reset: () => { state.outputs = {}; },
    inputs: (values) => send(4, values),
    outputs: () => state.outputs
  };
</script></body></html>`;

const safeBundlePath = (requestPath) => {
  const relative = decodeURIComponent(requestPath.replace(/^\/bundle\//, ""));
  const resolved = path.resolve(bundleRoot, relative);
  return resolved.startsWith(path.resolve(bundleRoot) + path.sep)
    ? resolved
    : null;
};

const server = http.createServer((request, response) => {
  if (request.url === "/harness") {
    response.writeHead(200, { "content-type": "text/html; charset=utf-8" });
    response.end(harness);
    return;
  }

  if (request.url.startsWith("/bundle/")) {
    const filePath = safeBundlePath(request.url);
    if (filePath && fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
      response.writeHead(200, {
        "content-type":
          contentTypes[path.extname(filePath)] || "application/octet-stream",
        "cache-control": "no-store",
      });
      fs.createReadStream(filePath).pipe(response);
      return;
    }
  }

  response.writeHead(404);
  response.end("not found");
});

const listen = () =>
  new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });

const installNetworkFence = async (context, baseOrigin) => {
  await context.route("**/*", async (route) => {
    const url = new URL(route.request().url());
    if (url.origin === baseOrigin) return route.continue();
    result.network_requests.push(route.request().url());
    return route.abort("blockedbyclient");
  });
};

const wireErrors = (page) => {
  const onConsole = (message) => {
    if (message.type() === "error") result.console_errors.push(message.text());
  };
  const onPageError = (error) =>
    result.page_errors.push(String(error.message || error));

  page.on("console", onConsole);
  page.on("pageerror", onPageError);

  return () => {
    page.off("console", onConsole);
    page.off("pageerror", onPageError);
  };
};

const simulationFrame = (page) =>
  page.frames().find((frame) => frame.url().includes("/bundle/index.html"));

const hasOverflow = (frame) =>
  frame.evaluate(
    () =>
      document.documentElement.scrollWidth >
        document.documentElement.clientWidth + 1 ||
      document.body.scrollWidth > document.body.clientWidth + 1
  );

const runCapiSamples = async (page) => {
  await page.waitForFunction(() => window.torusValidator.ready(), null, {
    timeout: 5000,
  });
  result.capi_handshake = "passed";

  const declarations = Object.fromEntries(
    [
      ...(contract.capi_manifest.inputs || []),
      ...(contract.capi_manifest.outputs || []),
    ].map((entry) => [entry.key, entry])
  );

  for (const [index, sample] of (contract.sample_cases || []).entries()) {
    const inputs = {};
    for (const [key, value] of Object.entries(sample.inputs || {})) {
      inputs[key] = { type: typeCodes[declarations[key]?.type], value };
    }

    await page.evaluate(() => window.torusValidator.reset());
    await page.evaluate(
      (values) => window.torusValidator.inputs(values),
      inputs
    );
    const expected = sample.expected_outputs || {};
    await page.waitForFunction(
      (keys) =>
        keys.every((key) =>
          Object.prototype.hasOwnProperty.call(
            window.torusValidator.outputs(),
            key
          )
        ),
      Object.keys(expected),
      { timeout: 3000 }
    );
    const actualWire = await page.evaluate(() =>
      window.torusValidator.outputs()
    );
    const actual = Object.fromEntries(
      Object.entries(actualWire).map(([key, entry]) => [key, entry.value])
    );
    const tolerance = Number(sample.tolerance || 0);
    const passed = Object.entries(expected).every(([key, value]) => {
      if (typeof value === "number" && typeof actual[key] === "number") {
        return Math.abs(value - actual[key]) <= tolerance;
      }
      return JSON.stringify(value) === JSON.stringify(actual[key]);
    });
    result.sample_results.push({ index, passed, expected, actual, tolerance });
  }

  result.sample_cases_passed =
    result.sample_results.length > 0 &&
    result.sample_results.every((item) => item.passed);
};

const runKeyboardCheck = async (frame) => {
  const focusableCount = await frame
    .locator(
      'a[href], button, input, select, textarea, [tabindex]:not([tabindex="-1"])'
    )
    .count();
  const visited = [];
  let visible = focusableCount > 0;
  await frame.locator("body").click({ position: { x: 1, y: 1 } });

  for (let index = 0; index < focusableCount + 2; index += 1) {
    await frame.page().keyboard.press("Tab");
    const focus = await frame.evaluate(() => {
      const element = document.activeElement;
      if (!element || element === document.body) return null;
      const style = getComputedStyle(element);
      return {
        identity:
          element.id || element.getAttribute("aria-label") || element.tagName,
        visible:
          style.outlineStyle !== "none" &&
          parseFloat(style.outlineWidth || "0") > 0,
      };
    });
    if (focus) {
      visited.push(focus.identity);
      visible = visible && focus.visible;
    }
  }

  result.keyboard =
    focusableCount > 0 && new Set(visited).size >= focusableCount
      ? "passed"
      : "failed";
  result.focus_visible = visible;
};

const runWebglFallback = async (baseOrigin) => {
  if (contract.rendering_mode !== "3d") {
    result.webgl_fallback = "passed";
    return;
  }

  const browser = await chromium.launch({
    headless: true,
    args: ["--disable-webgl", "--disable-gpu"],
  });
  try {
    const context = await browser.newContext({
      viewport: { width: 1280, height: 720 },
    });
    await installNetworkFence(context, baseOrigin);
    const page = await context.newPage();
    await page.goto(`${baseOrigin}/harness`, { waitUntil: "load" });
    const frame = simulationFrame(page);
    await frame.waitForSelector("[data-webgl-fallback]", {
      state: "visible",
      timeout: 3000,
    });
    result.webgl_fallback = "passed";
  } finally {
    await browser.close();
  }
};

(async () => {
  let browser;
  try {
    const port = await listen();
    const baseOrigin = `http://127.0.0.1:${port}`;
    browser = await chromium.launch({
      headless: true,
      args: [
        "--use-gl=swiftshader",
        "--enable-unsafe-swiftshader",
        "--disable-dev-shm-usage",
      ],
    });
    const context = await browser.newContext({
      viewport: { width: 1280, height: 720 },
      reducedMotion: "no-preference",
    });
    await context.addInitScript((seed) => {
      let value = seed >>> 0;
      Math.random = () =>
        (value = (value * 1664525 + 1013904223) >>> 0) / 4294967296;
    }, contract.seed);
    await installNetworkFence(context, baseOrigin);
    const page = await context.newPage();
    const stopRuntimeErrorCapture = wireErrors(page);
    await page.goto(`${baseOrigin}/harness`, { waitUntil: "load" });
    const frame = simulationFrame(page);
    if (!frame) throw new Error("simulation frame did not load");

    await frame.waitForSelector("[data-simulation-text-alternative]", {
      state: "visible",
      timeout: 3000,
    });
    await runCapiSamples(page);
    await runKeyboardCheck(frame);
    result.desktop_overflow = await hasOverflow(frame);
    await page.screenshot({
      path: path.join(resultsRoot, "desktop.png"),
      fullPage: true,
    });
    result.screenshots.push("desktop.png");

    await page.setViewportSize({ width: 390, height: 844 });
    result.mobile_overflow = await hasOverflow(frame);
    await page.screenshot({
      path: path.join(resultsRoot, "mobile.png"),
      fullPage: true,
    });
    result.screenshots.push("mobile.png");

    await page.emulateMedia({ reducedMotion: "reduce" });
    result.reduced_motion = await frame.evaluate(() => {
      const moving = [...document.querySelectorAll("*")].some((element) => {
        const style = getComputedStyle(element);
        return (
          parseFloat(style.animationDuration || "0") > 0 ||
          parseFloat(style.transitionDuration || "0") > 0
        );
      });
      return moving ? "failed" : "passed";
    });
    await page.screenshot({
      path: path.join(resultsRoot, "reduced-motion.png"),
      fullPage: true,
    });
    result.screenshots.push("reduced-motion.png");

    // Axe may fetch same-bundle stylesheets while inspecting a sandboxed,
    // opaque-origin iframe. Those analyzer-owned CSP messages are not runtime
    // errors from the simulation; analyzer failures still reject via throw.
    stopRuntimeErrorCapture();
    const a11y = await new AxeBuilder({ page }).include("#sim").analyze();
    fs.writeFileSync(
      path.join(resultsRoot, "accessibility.json"),
      JSON.stringify(a11y, null, 2)
    );
    const seriousOrCritical = a11y.violations.filter((item) =>
      ["serious", "critical"].includes(item.impact)
    );
    result.serious_or_critical_a11y = seriousOrCritical.length;
    result.a11y_findings = seriousOrCritical.slice(0, 10).map((item) => ({
      id: String(item.id || "unknown").slice(0, 100),
      impact: String(item.impact || "unknown").slice(0, 100),
      help: String(item.help || "Accessibility validation failed").slice(
        0,
        500
      ),
      node_count: item.nodes.length,
      targets: item.nodes
        .slice(0, 5)
        .map((node) => node.target.slice(0, 5)),
    }));
    fs.writeFileSync(path.join(resultsRoot, "dom.html"), await frame.content());

    await runWebglFallback(baseOrigin);
    const pass =
      result.network_requests.length === 0 &&
      result.console_errors.length === 0 &&
      result.page_errors.length === 0 &&
      result.capi_handshake === "passed" &&
      result.sample_cases_passed &&
      result.keyboard === "passed" &&
      result.focus_visible &&
      result.serious_or_critical_a11y === 0 &&
      !result.desktop_overflow &&
      !result.mobile_overflow &&
      result.reduced_motion === "passed" &&
      result.webgl_fallback === "passed";
    result.status = pass ? "passed" : "failed";
  } catch (error) {
    result.failure = String(
      error && error.message ? error.message : error
    ).slice(0, 500);
  } finally {
    if (browser) await browser.close();
    server.close();
    fs.writeFileSync(
      path.join(resultsRoot, "validation.json"),
      JSON.stringify(result, null, 2)
    );
    process.exit(result.status === "passed" ? 0 : 1);
  }
})();
