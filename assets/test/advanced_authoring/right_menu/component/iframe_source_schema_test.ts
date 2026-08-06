import {
  DEFAULT_IFRAME_TITLE,
  GENERATED_SIMULATION_REDACTED_CONFIG,
  GENERATED_SIMULATION_SANDBOX,
  THIRD_PARTY_IFRAME_PERMISSIONS,
  authorizeGeneratedSimulationMessage,
  createSchema,
  decodeSourceConfig,
  redactGeneratedSimulationHandshake,
  resolveIframeDescription,
  resolveIframePermissions,
  resolveIframeReferrerPolicy,
  resolveIframeSandbox,
  resolveIframeTitle,
  sanitizeGeneratedSimulationValueChange,
  schema,
  simpleSchema,
  transformModelToSchema,
  transformSchemaToModel,
} from 'components/parts/janus-capi-iframe/schema';

describe('janus-capi-iframe source schema transforms', () => {
  it('exposes distinct accessible title and description fields', () => {
    expect(simpleSchema.title).toMatchObject({ title: 'Title', type: 'string' });
    expect(simpleSchema.description).toMatchObject({ title: 'Description', type: 'string' });
    expect(schema.title).toMatchObject({ title: 'Title', type: 'string' });
    expect(schema.description).toMatchObject({ title: 'Description', type: 'string' });
    expect(createSchema()).toMatchObject({
      title: DEFAULT_IFRAME_TITLE,
      description: '',
    });
  });

  it('normalizes iframe accessibility metadata', () => {
    expect(resolveIframeTitle(undefined)).toBe(DEFAULT_IFRAME_TITLE);
    expect(resolveIframeTitle('  ')).toBe(DEFAULT_IFRAME_TITLE);
    expect(resolveIframeTitle('Molecule model')).toBe('Molecule model');
    expect(resolveIframeDescription('  ')).toBeUndefined();
    expect(resolveIframeDescription('Change the temperature.')).toBe('Change the temperature.');
  });

  it('applies the restricted generated-simulation profile without changing third-party policy', () => {
    const generated = { securityProfile: 'generated_simulation' as const };
    const thirdParty = {};

    expect(resolveIframeSandbox(generated)).toBe(GENERATED_SIMULATION_SANDBOX);
    expect(resolveIframePermissions(generated)).toBe('');
    expect(resolveIframeReferrerPolicy(generated)).toBe('no-referrer');

    expect(resolveIframeSandbox(thirdParty)).toBeUndefined();
    expect(resolveIframePermissions(thirdParty)).toBe(THIRD_PARTY_IFRAME_PERMISSIONS);
    expect(resolveIframeReferrerPolicy(thirdParty)).toBeUndefined();
  });

  it('keeps generated handshakes redacted and requires the negotiated session tokens', () => {
    const expected = {
      requestToken: 'simulation-request',
      authToken: 'parent-secret',
      config: {
        lessonId: 'real-lesson',
        questionId: 'real-question',
        sectionSlug: 'real-section',
        userId: 'real-user',
      },
    };

    expect(redactGeneratedSimulationHandshake(expected)).toEqual({
      requestToken: 'simulation-request',
      authToken: 'parent-secret',
      config: GENERATED_SIMULATION_REDACTED_CONFIG,
    });

    expect(
      authorizeGeneratedSimulationMessage(
        { handshake: { requestToken: 'simulation-request' } },
        expected,
        false,
        true,
      ),
    ).toBe(true);

    expect(
      authorizeGeneratedSimulationMessage(
        {
          handshake: {
            requestToken: 'simulation-request',
            authToken: 'parent-secret',
          },
        },
        expected,
        true,
        false,
      ),
    ).toBe(true);

    expect(
      authorizeGeneratedSimulationMessage(
        {
          handshake: {
            requestToken: 'simulation-request',
            authToken: 'wrong-origin-session',
          },
        },
        expected,
        true,
        false,
      ),
    ).toBe(false);

    expect(
      authorizeGeneratedSimulationMessage(
        { handshake: { requestToken: 'replacement-request' } },
        expected,
        true,
        true,
      ),
    ).toBe(false);
  });

  it('accepts only exact typed CAPI outputs from generated simulations', () => {
    const model = {
      securityProfile: 'generated_simulation' as const,
      capiOutputs: [
        { key: 'pressure', type: 'number' as const },
        {
          key: 'state',
          type: 'enum' as const,
          allowedValues: ['stable', 'changing'],
        },
      ],
    };

    const sanitized = sanitizeGeneratedSimulationValueChange(model, {
      pressure: { type: 1, value: 2.5 },
      state: { type: 5, value: 'not-declared' },
      injected: { type: 2, value: 'ignore me' },
    });

    expect(Object.keys(sanitized)).toEqual(['pressure']);
    expect(sanitized.pressure).toEqual({ type: 1, value: 2.5 });
  });

  it('rejects generated CAPI type confusion and oversized values', () => {
    const model = {
      securityProfile: 'generated_simulation' as const,
      capiOutputs: [
        { key: 'pressure', type: 'number' as const },
        { key: 'notes', type: 'string' as const },
      ],
    };

    const sanitized = sanitizeGeneratedSimulationValueChange(model, {
      pressure: { type: 2, value: '2.5' },
      notes: { type: 2, value: 'x'.repeat(20_000) },
    });

    expect(Object.keys(sanitized)).toHaveLength(0);
  });

  it('does not convert source-editor data into a generated simulation src', () => {
    const trustedSrc =
      'https://media.example.edu/bundles/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/index.html';

    const transformed = transformSchemaToModel({
      src: trustedSrc,
      source: JSON.stringify({
        mode: 'url',
        pageId: null,
        pageSlug: '',
        url: 'https://model-authored.example/unsafe.html',
      }),
      securityProfile: 'generated_simulation',
      artifactIdentity: {
        proposalId: 'proposal-1',
        artifactId: 'artifact-1',
        version: 1,
        contentHash: 'a'.repeat(64),
        storageOrigin: 'https://media.example.edu',
      },
    });

    expect(transformed.src).toBe(trustedSrc);
    expect(transformed).not.toHaveProperty('source');
  });

  it('encodes legacy external src into source config for editor', () => {
    const transformed = transformModelToSchema({
      src: 'https://example.com/widget',
      allowScrolling: true,
    });

    expect(typeof transformed.source).toBe('string');
    const sourceConfig = decodeSourceConfig(transformed.source);
    expect(sourceConfig.mode).toBe('url');
    expect(sourceConfig.url).toBe('https://example.com/widget');
  });

  it('encodes page metadata into source config for editor', () => {
    const transformed = transformModelToSchema({
      src: '/course/link/introduction',
      sourceType: 'page',
      idref: 27,
      sourcePageSlug: 'introduction',
    });

    const sourceConfig = decodeSourceConfig(transformed.source);
    expect(sourceConfig.mode).toBe('page');
    expect(sourceConfig.pageId).toBe(27);
    expect(sourceConfig.pageSlug).toBe('introduction');
  });

  it('maps page source config back to model fields', () => {
    const transformed = transformSchemaToModel({
      source: JSON.stringify({
        mode: 'page',
        pageId: 44,
        pageSlug: 'module-1',
        url: '',
      }),
      allowScrolling: false,
    }) as any;

    expect(transformed.src).toBe('/course/link/module-1');
    expect(transformed.sourceType).toBe('page');
    expect(transformed.linkType).toBe('page');
    expect(transformed.idref).toBe(44);
    expect(transformed.resource_id).toBe(44);
    expect(transformed).not.toHaveProperty('source');
  });

  it('maps url source config back to model fields', () => {
    const transformed = transformSchemaToModel({
      source: JSON.stringify({
        mode: 'url',
        pageId: null,
        pageSlug: '',
        url: 'https://oli.example/content',
      }),
      allowScrolling: false,
    }) as any;

    expect(transformed.src).toBe('https://oli.example/content');
    expect(transformed.sourceType).toBe('url');
    expect(transformed).not.toHaveProperty('source');
  });

  it('keeps url mode when legacy linkType is still present', () => {
    const transformed = transformModelToSchema({
      src: 'https://oli.example/content',
      sourceType: 'url',
      linkType: 'page',
      idref: 44,
      sourcePageSlug: 'module-1',
    });

    const sourceConfig = decodeSourceConfig(transformed.source);
    expect(sourceConfig.mode).toBe('url');
    expect(sourceConfig.url).toBe('https://oli.example/content');
  });

  it('uses resource_id as page id fallback for editor source config', () => {
    const transformed = transformModelToSchema({
      src: '/course/link/module-1',
      sourceType: 'page',
      resource_id: 44,
      sourcePageSlug: 'module-1',
    });

    const sourceConfig = decodeSourceConfig(transformed.source);
    expect(sourceConfig.mode).toBe('page');
    expect(sourceConfig.pageId).toBe(44);
    expect(sourceConfig.pageSlug).toBe('module-1');
  });

  it('clears internal link metadata when switching from page mode to url mode', () => {
    const existing = {
      src: '/course/link/module-1',
      sourceType: 'page' as const,
      linkType: 'page' as const,
      idref: 44,
      sourcePageSlug: 'module-1',
      resource_id: 44,
      dynamicLinkFallback: {
        type: 'unresolved_internal_source' as const,
        message: 'old',
        href: '/sections/demo/lesson/current',
      },
    };

    const transformed = transformSchemaToModel({
      ...existing,
      source: JSON.stringify({
        mode: 'url',
        pageId: null,
        pageSlug: '',
        url: 'https://oli.example/content',
      }),
    }) as any;

    const merged = { ...existing, ...transformed };

    expect(merged.src).toBe('https://oli.example/content');
    expect(merged.sourceType).toBe('url');
    expect(merged.linkType).toBeUndefined();
    expect(merged.idref).toBeUndefined();
    expect(merged.resource_id).toBeUndefined();
    expect(merged.sourcePageSlug).toBeUndefined();
    expect(merged.dynamicLinkFallback).toBeUndefined();
  });
});
