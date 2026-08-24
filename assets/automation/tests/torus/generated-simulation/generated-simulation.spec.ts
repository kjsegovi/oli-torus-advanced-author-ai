import { setRuntimeConfig } from '@core/runtimeConfig';
import { test } from '@fixture/my-fixture';
import { type Frame, type Locator, type Page, expect } from '@playwright/test';
import { TYPE_USER } from '@pom/types/type-user';
import path from 'node:path';

const runId = `-${Date.now()}`;
const courseTitle = `Generated Simulation Course${runId}`;
const studentEmail = `generated-simulation-student${runId}@example.com`;
const simulationOrigin = 'http://generated-simulations.localhost:9000';
const legacySimulationPath =
  '/torus-media-dev/generated-simulations/artifacts/artifact-gas-pressure-v1/v1/sha256/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const versionTwoSimulationPath =
  '/torus-media-dev/generated-simulations/storage-v2/artifacts/artifact-gas-pressure-v2/v2/sha256/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const legacySimulationUrl = `${simulationOrigin}${legacySimulationPath}/index.html`;
const versionTwoSimulationUrl = `${simulationOrigin}${versionTwoSimulationPath}/index.html`;
const scenarioPath = path.resolve(__dirname, './generated-simulation.scenario.yaml');
const password = 'changeme123456';

setRuntimeConfig({
  baseUrl: 'http://localhost',
  scenarioToken: 'my-token',
  loginData: {
    student: {
      type: TYPE_USER.student,
      pageTitle: 'OLI Torus',
      role: 'Student',
      welcomeText: 'Welcome to OLI Torus',
      welcomeTitle: 'Hi, Generated',
      email: studentEmail,
      name: 'Generated',
      last_name: 'Simulation Student',
      pass: password,
    },
    instructor: unusedLogin(TYPE_USER.instructor),
    author: unusedLogin(TYPE_USER.author),
    administrator: unusedLogin(TYPE_USER.administrator),
  },
});

test.beforeAll(async ({ seedScenario }) => {
  await seedScenario(scenarioPath, { RUN_ID: runId });
});

test.describe('generated simulation delivery security and accessibility', () => {
  test('uses the restricted iframe profile, typed CAPI handshake, keyboard controls, and native fallback', async ({
    page,
    homeTask,
    studentTask,
  }) => {
    await page.route(`${simulationOrigin}/**`, async (route) => {
      const pathname = new URL(route.request().url()).pathname;

      if (pathname.endsWith('/app.js')) {
        await route.fulfill({
          status: 200,
          contentType: 'application/javascript',
          body: simulationJavascript,
        });
        return;
      }

      if (pathname.endsWith('/torus-capi-bridge.js')) {
        await route.fulfill({
          status: 200,
          contentType: 'application/javascript',
          body: typedCapiBridgeJavascript,
        });
        return;
      }

      if (pathname.endsWith('/styles.css')) {
        await route.fulfill({ status: 200, contentType: 'text/css', body: simulationStyles });
        return;
      }

      await route.fulfill({
        status: 200,
        contentType: 'text/html',
        headers: {
          'content-security-policy': requiredCsp,
          'x-content-type-options': 'nosniff',
        },
        body: simulationHtml,
      });
    });

    await homeTask.login('student');
    await studentTask.searchProject(courseTitle);

    const lessonLink = page.locator('a').filter({ hasText: 'Observe Gas Pressure' }).first();
    await expect(lessonLink).toBeVisible();
    await lessonLink.click();

    for (const simulationUrl of [legacySimulationUrl, versionTwoSimulationUrl]) {
      await expect
        .poll(() => page.frames().some((frame) => frame.url() === simulationUrl))
        .toBe(true);
    }

    const simulationFrame = page.frames().find((frame) => frame.url() === legacySimulationUrl);
    const versionTwoFrame = page.frames().find((frame) => frame.url() === versionTwoSimulationUrl);
    expect(simulationFrame).toBeDefined();
    expect(versionTwoFrame).toBeDefined();

    const frameElement = await simulationFrame!.frameElement();
    expect(await frameElement.getAttribute('title')).toBe('Gas pressure model');
    expect(await frameElement.getAttribute('sandbox')).toBe('allow-scripts');
    expect(await frameElement.getAttribute('allow')).toBe('');
    expect(await frameElement.getAttribute('referrerpolicy')).toBe('no-referrer');

    const accessibleDescription = await frameElement.evaluate((iframe) => {
      const descriptionId = iframe.getAttribute('aria-describedby');
      return descriptionId ? iframe.ownerDocument.getElementById(descriptionId)?.textContent : null;
    });
    expect(accessibleDescription).toContain('Change volume and observe the resulting pressure.');

    await expect(simulationFrame!.locator('#capi-status')).toContainText('Connected');
    await expect(versionTwoFrame!.locator('#capi-status')).toContainText('Connected');

    const versionTwoFrameElement = await versionTwoFrame!.frameElement();
    expect(await versionTwoFrameElement.getAttribute('title')).toBe(
      'Gas pressure model, storage version 2',
    );
    expect(await versionTwoFrameElement.getAttribute('sandbox')).toBe('allow-scripts');
    expect(await versionTwoFrameElement.getAttribute('allow')).toBe('');
    expect(await versionTwoFrameElement.getAttribute('referrerpolicy')).toBe('no-referrer');

    const slider = simulationFrame!.getByRole('slider', { name: /Model setting/i });
    await slider.focus();
    await slider.press('ArrowRight');
    await expect(simulationFrame!.locator('#setting-value')).toHaveText('51');
    await expect(simulationFrame!.locator('#capi-status')).toHaveAttribute(
      'data-last-capi-value',
      '51',
    );

    await page.setViewportSize({ width: 390, height: 844 });
    const frameBox = await frameElement.boundingBox();
    expect(frameBox).not.toBeNull();
    expect(frameBox!.width).toBeLessThanOrEqual(390);

    expect(
      await simulationFrame!.evaluate(
        () => document.documentElement.scrollWidth <= document.documentElement.clientWidth,
      ),
    ).toBe(true);

    await slider.press('End');
    await expect(simulationFrame!.locator('#setting-value')).toHaveText('100');

    const simulationDeckFrame = await frameWithVisibleLocator(page, (frame) =>
      frame.getByRole('button', { name: 'Interpret state' }),
    );
    await simulationDeckFrame.getByRole('button', { name: 'Interpret state' }).click();

    const remediationFrame = await frameWithVisibleLocator(page, (frame) =>
      frame.getByText('Gas-model explanation', { exact: true }),
    );
    await remediationFrame.getByRole('button', { name: 'Continue' }).click();

    await frameWithVisibleLocator(page, (frame) =>
      frame.getByText('Which observation should you use to explain the pressure change?', {
        exact: true,
      }),
    );
  });
});

async function frameWithVisibleLocator(
  page: Page,
  locatorFor: (frame: Frame) => Locator,
): Promise<Frame> {
  await expect
    .poll(async () => {
      const visibility = await Promise.all(
        page.frames().map((frame) =>
          locatorFor(frame)
            .isVisible()
            .catch(() => false),
        ),
      );
      return visibility.some(Boolean);
    })
    .toBe(true);

  for (const frame of page.frames()) {
    if (
      await locatorFor(frame)
        .isVisible()
        .catch(() => false)
    ) {
      return frame;
    }
  }

  throw new Error('Expected locator did not become visible in any page frame');
}

function unusedLogin(type: typeof TYPE_USER[keyof typeof TYPE_USER]) {
  return {
    type,
    pageTitle: 'OLI Torus',
    role: 'Unused',
    welcomeText: 'Unused',
    welcomeTitle: 'Unused',
    email: `unused-${type}${runId}@example.com`,
    pass: password,
  };
}

const requiredCsp =
  "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self'; connect-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'; frame-src 'none'; worker-src 'none'";

const simulationHtml = `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <meta name="description" content="Change a bounded model setting and compare the observation.">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta http-equiv="Content-Security-Policy" content="${requiredCsp}">
    <title>Gas pressure model</title>
    <link rel="stylesheet" href="styles.css">
    <script src="torus-capi-bridge.js"></script>
    <script src="app.js" defer></script>
  </head>
  <body>
    <main>
      <h1>Gas pressure model</h1>
      <label for="model-setting">Model setting: <output id="setting-value" for="model-setting">50</output></label>
      <input id="model-setting" type="range" min="0" max="100" step="1" value="50">
      <p id="observation" role="status" aria-live="polite">Move the slider and compare two controlled states.</p>
      <p id="capi-status" aria-live="polite">Connecting to the lesson.</p>
    </main>
  </body>
</html>`;

const simulationStyles = `
:root { font-family: system-ui, sans-serif; color: #172554; background: #f8fafc; }
* { box-sizing: border-box; }
body { margin: 0; padding: clamp(.75rem, 4vw, 2rem); }
main { width: min(100%, 48rem); margin: 0 auto; }
input[type='range'] { width: 100%; min-height: 2.75rem; }
:focus-visible { outline: .2rem solid #f59e0b; outline-offset: .2rem; }
@media (max-width: 32rem) { body { padding: .5rem; } }
`;

const simulationJavascript = `
(() => {
  'use strict';
  const slider = document.getElementById('model-setting');
  const output = document.getElementById('setting-value');
  const observation = document.getElementById('observation');
  const capiStatus = document.getElementById('capi-status');

  const markReady = () => {
    capiStatus.textContent = 'Connected to the lesson with a typed CAPI contract.';
  };

  if (window.TorusCapi?.isReady()) markReady();
  window.addEventListener('torus-capi-ready', markReady, { once: true });

  slider.addEventListener('input', () => {
    const value = Number(slider.value);
    output.textContent = String(value);
    observation.textContent = 'The model setting is ' + value + '. Compare this state with the earlier observation.';
    if (window.TorusCapi.emit('pressure', value)) {
      capiStatus.dataset.lastCapiValue = String(value);
    }
  });
})();
`;

// Mirrors the system-owned bridge contract exercised by the sandbox tests. The
// simulation itself can only use the frozen, typed TorusCapi API below.
const typedCapiBridgeJavascript = `
(() => {
  'use strict';
  const HANDSHAKE_REQUEST = 1;
  const HANDSHAKE_RESPONSE = 2;
  const ON_READY = 3;
  const VALUE_CHANGE = 4;
  const requestToken = 'generated-simulation-browser-contract';
  let authToken = '';
  let ready = false;
  let handshakeTimer;

  const send = (type, values, includeAuth = true) => {
    parent.postMessage(JSON.stringify({
      handshake: {
        requestToken,
        ...(includeAuth ? { authToken } : {}),
      },
      type,
      values,
    }), '*');
  };

  const api = Object.freeze({
    emit(key, value) {
      if (!ready || key !== 'pressure' || typeof value !== 'number' || !Number.isFinite(value)) {
        return false;
      }
      send(VALUE_CHANGE, { pressure: { type: 1, value } });
      return true;
    },
    onInput() { return () => {}; },
    isReady() { return ready; },
  });

  Object.defineProperty(window, 'TorusCapi', {
    value: api,
    writable: false,
    configurable: false,
  });

  window.addEventListener('message', (event) => {
    if (event.source !== parent || typeof event.data !== 'string') return;
    let message;
    try { message = JSON.parse(event.data); } catch (_error) { return; }
    if (message.type !== HANDSHAKE_RESPONSE || message.handshake?.requestToken !== requestToken) return;
    authToken = message.handshake.authToken;
    ready = true;
    window.clearInterval(handshakeTimer);
    send(ON_READY, {});
    window.dispatchEvent(new Event('torus-capi-ready'));
  });

  const requestHandshake = () => send(HANDSHAKE_REQUEST, {}, false);
  handshakeTimer = window.setInterval(requestHandshake, 100);
  requestHandshake();
})();
`;
