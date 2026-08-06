import { JSONSchema7Object } from 'json-schema';
import { formatExpression } from 'adaptivity/scripting';
import { CapiVariableTypes } from '../../../adaptivity/capi';
import { Expression, JanusAbsolutePositioned, JanusCustomCss } from '../types/parts';

export type IframeSourceMode = 'url' | 'page';

export interface IframeSourceEditorConfig {
  mode: IframeSourceMode;
  url: string;
  pageId: number | null;
  pageSlug: string;
}

export interface IframeDynamicLinkFallback {
  type: 'unresolved_internal_source';
  message: string;
  href: string;
}

export type IframeSecurityProfile = 'generated_simulation';

export type CapiDeclarationType =
  | 'number'
  | 'string'
  | 'array'
  | 'boolean'
  | 'enum'
  | 'math_expr'
  | 'array_point';

export interface CapiVariableDeclaration {
  key: string;
  type: CapiDeclarationType;
  defaultValue?: unknown;
  allowedValues?: string[];
  branching?: {
    operator:
      | 'equal'
      | 'notEqual'
      | 'greaterThan'
      | 'greaterThanInclusive'
      | 'lessThan'
      | 'lessThanInclusive';
    value: unknown;
    remediation_section_id: string;
    feedback?: string;
  };
}

export interface GeneratedSimulationArtifactIdentity {
  proposalId: string;
  artifactId: string;
  version: number;
  contentHash: string;
  storageOrigin: string;
}

export interface CapiIframeModel extends JanusAbsolutePositioned, JanusCustomCss {
  src: string;
  title?: string;
  description?: string;
  source?: string;
  sourceType?: IframeSourceMode;
  sourcePageSlug?: string;
  linkType?: 'page';
  idref?: number;
  resource_id?: number;
  dynamicLinkFallback?: IframeDynamicLinkFallback;
  configData: any;
  allowScrolling: boolean;
  securityProfile?: IframeSecurityProfile;
  artifactIdentity?: GeneratedSimulationArtifactIdentity;
  capiInputs?: CapiVariableDeclaration[];
  capiOutputs?: CapiVariableDeclaration[];
}

export const DEFAULT_IFRAME_TITLE = 'Embedded content';
export const GENERATED_SIMULATION_SANDBOX = 'allow-scripts';
export const THIRD_PARTY_IFRAME_PERMISSIONS =
  'accelerometer *; magnetometer; gyroscope; fullscreen; autoplay; clipboard-write; encrypted-media; xr-spatial-tracking; gamepad *;';

export const isGeneratedSimulation = (model: Partial<CapiIframeModel>): boolean =>
  model.securityProfile === 'generated_simulation';

export const resolveIframeTitle = (title?: string): string =>
  title?.trim() ? title : DEFAULT_IFRAME_TITLE;

export const resolveIframeDescription = (description?: string): string | undefined =>
  description?.trim() ? description : undefined;

export const resolveIframeSandbox = (model: Partial<CapiIframeModel>): string | undefined =>
  isGeneratedSimulation(model) ? GENERATED_SIMULATION_SANDBOX : undefined;

export const resolveIframePermissions = (model: Partial<CapiIframeModel>): string =>
  isGeneratedSimulation(model) ? '' : THIRD_PARTY_IFRAME_PERMISSIONS;

export const resolveIframeReferrerPolicy = (
  model: Partial<CapiIframeModel>,
): 'no-referrer' | undefined => (isGeneratedSimulation(model) ? 'no-referrer' : undefined);

export const GENERATED_SIMULATION_REDACTED_CONFIG = Object.freeze({
  context: 'VIEWER',
  lessonId: '',
  questionId: '',
  sectionSlug: '',
  userId: '',
});

interface GeneratedHandshake {
  requestToken?: unknown;
  authToken?: unknown;
  version?: unknown;
  config?: unknown;
}

export const redactGeneratedSimulationHandshake = (
  handshake: GeneratedHandshake,
): Record<string, unknown> => ({
  requestToken: typeof handshake.requestToken === 'string' ? handshake.requestToken : '',
  authToken: typeof handshake.authToken === 'string' ? handshake.authToken : '',
  ...(typeof handshake.version === 'string' ? { version: handshake.version } : {}),
  config: { ...GENERATED_SIMULATION_REDACTED_CONFIG },
});

export const authorizeGeneratedSimulationMessage = (
  message: { handshake?: GeneratedHandshake },
  expected: GeneratedHandshake,
  handshakeMade: boolean,
  handshakeRequest: boolean,
): boolean => {
  const requestToken = message?.handshake?.requestToken;

  if (handshakeRequest) {
    return (
      !handshakeMade &&
      typeof requestToken === 'string' &&
      requestToken.length > 0 &&
      requestToken.length <= 256
    );
  }

  return (
    handshakeMade &&
    typeof requestToken === 'string' &&
    requestToken === expected.requestToken &&
    typeof message?.handshake?.authToken === 'string' &&
    message.handshake.authToken === expected.authToken
  );
};

const GENERATED_VALUE_MAX_BYTES = 16_384;
const GENERATED_ARRAY_MAX_ITEMS = 256;

const capiTypeCode = (type: CapiDeclarationType): CapiVariableTypes => {
  switch (type) {
    case 'number':
      return CapiVariableTypes.NUMBER;
    case 'string':
      return CapiVariableTypes.STRING;
    case 'array':
      return CapiVariableTypes.ARRAY;
    case 'boolean':
      return CapiVariableTypes.BOOLEAN;
    case 'enum':
      return CapiVariableTypes.ENUM;
    case 'math_expr':
      return CapiVariableTypes.MATH_EXPR;
    case 'array_point':
      return CapiVariableTypes.ARRAY_POINT;
  }
};

const boundedSerializedValue = (value: unknown): boolean => {
  try {
    const serialized = JSON.stringify(value);
    return typeof serialized === 'string' && serialized.length <= GENERATED_VALUE_MAX_BYTES;
  } catch (_error) {
    return false;
  }
};

const validDeclaredValue = (declaration: CapiVariableDeclaration, value: unknown): boolean => {
  if (!boundedSerializedValue(value)) {
    return false;
  }

  switch (declaration.type) {
    case 'number':
      return typeof value === 'number' && Number.isFinite(value);
    case 'string':
    case 'math_expr':
      return typeof value === 'string';
    case 'boolean':
      return typeof value === 'boolean';
    case 'enum':
      return (
        typeof value === 'string' &&
        Array.isArray(declaration.allowedValues) &&
        declaration.allowedValues.includes(value)
      );
    case 'array':
    case 'array_point':
      return Array.isArray(value) && value.length <= GENERATED_ARRAY_MAX_ITEMS;
  }
};

/**
 * Reduces an untrusted generated-simulation VALUE_CHANGE payload to the exact
 * compiler-declared output contract. Undeclared keys, type mismatches, invalid
 * enum values, and oversized values are ignored before they reach adaptivity.
 */
export const sanitizeGeneratedSimulationValueChange = (
  model: Partial<CapiIframeModel>,
  values: unknown,
): Record<string, { type: CapiVariableTypes; value: unknown; allowedValues?: string[] }> => {
  const sanitized: Record<
    string,
    { type: CapiVariableTypes; value: unknown; allowedValues?: string[] }
  > = Object.create(null);

  if (!isGeneratedSimulation(model) || !values || typeof values !== 'object') {
    return sanitized;
  }

  const rawValues = values as Record<string, unknown>;

  (model.capiOutputs || []).forEach((declaration) => {
    if (!Object.prototype.hasOwnProperty.call(rawValues, declaration.key)) {
      return;
    }

    const raw = rawValues[declaration.key];
    if (!raw || typeof raw !== 'object' || Array.isArray(raw)) {
      return;
    }

    const variable = raw as { type?: unknown; value?: unknown };
    const expectedType = capiTypeCode(declaration.type);

    if (variable.type !== expectedType || !validDeclaredValue(declaration, variable.value)) {
      return;
    }

    sanitized[declaration.key] = {
      type: expectedType,
      value: variable.value,
      ...(declaration.allowedValues ? { allowedValues: declaration.allowedValues } : {}),
    };
  });

  return sanitized;
};

const SOURCE_PREFIX = '/course/link/';
const defaultSourceConfig = (): IframeSourceEditorConfig => ({
  mode: 'url',
  url: '',
  pageId: null,
  pageSlug: '',
});

const extractCourseLinkSlug = (value: string): string | null => {
  if (!value.startsWith(SOURCE_PREFIX)) {
    return null;
  }
  const slug = value.replace(SOURCE_PREFIX, '');
  return slug.length > 0 ? slug : null;
};

const normalizeSourceConfig = (raw: unknown): IframeSourceEditorConfig => {
  if (!raw || typeof raw !== 'object') {
    return defaultSourceConfig();
  }

  const maybe = raw as Partial<IframeSourceEditorConfig>;
  const mode: IframeSourceMode = maybe.mode === 'page' ? 'page' : 'url';
  const pageId = typeof maybe.pageId === 'number' ? maybe.pageId : null;
  const pageSlug = typeof maybe.pageSlug === 'string' ? maybe.pageSlug : '';
  const url = typeof maybe.url === 'string' ? maybe.url : '';

  return { mode, pageId, pageSlug, url };
};

export const decodeSourceConfig = (source: unknown, fallbackSrc = ''): IframeSourceEditorConfig => {
  if (typeof source === 'string') {
    const raw = source.trim();
    if (raw.length === 0) {
      const fallbackSlug = extractCourseLinkSlug(fallbackSrc);
      return fallbackSlug
        ? { mode: 'page', pageId: null, pageSlug: fallbackSlug, url: '' }
        : { ...defaultSourceConfig(), url: fallbackSrc || '' };
    }

    if (raw.startsWith('{')) {
      try {
        return normalizeSourceConfig(JSON.parse(raw));
      } catch (_e) {
        return { ...defaultSourceConfig(), url: raw };
      }
    }

    const internalSlug = extractCourseLinkSlug(raw);
    return internalSlug
      ? { mode: 'page', pageId: null, pageSlug: internalSlug, url: '' }
      : { ...defaultSourceConfig(), url: raw };
  }

  if (typeof source === 'object') {
    return normalizeSourceConfig(source);
  }

  const fallbackSlug = extractCourseLinkSlug(fallbackSrc);
  return fallbackSlug
    ? { mode: 'page', pageId: null, pageSlug: fallbackSlug, url: '' }
    : { ...defaultSourceConfig(), url: fallbackSrc || '' };
};

export const encodeSourceConfig = (config: IframeSourceEditorConfig): string =>
  JSON.stringify(config);

export const simpleSchema: JSONSchema7Object = {
  source: {
    title: 'Source',
    type: 'string',
  },
  allowScrolling: {
    title: 'Allow Scrolling',
    type: 'boolean',
  },
  title: {
    title: 'Title',
    description: 'Provides an accessible title for the embedded content',
    type: 'string',
  },
  description: {
    title: 'Description',
    description: 'Provides additional accessible context for the embedded content',
    type: 'string',
  },
};

export const schema: JSONSchema7Object = {
  customCssClass: {
    title: 'Custom CSS class',
    type: 'string',
  },
  source: {
    title: 'Source',
    type: 'string',
  },
  title: {
    title: 'Title',
    description: 'Provides an accessible title for the embedded content',
    type: 'string',
  },
  description: {
    title: 'Description',
    description: 'Provides additional accessible context for the embedded content',
    type: 'string',
  },
  allowScrolling: {
    title: 'Allow Scrolling',
    type: 'boolean',
  },
};

export const getCapabilities = () => ({
  configure: true,
  canUseExpression: true,
});

export const validateUserConfig = (part: any, owner: any): Expression[] => {
  const brokenExpressions: Expression[] = [];
  part.custom.configData.forEach((element: any) => {
    const evaluatedValue = formatExpression(element);
    if (evaluatedValue && evaluatedValue?.length) {
      brokenExpressions.push({
        key: element.key,
        owner,
        part,
        suggestedFix: evaluatedValue,
        formattedExpression: true,
        message: ` configData - "${element.key}" variable`,
      });
    }
  });
  return [...brokenExpressions];
};

export const adaptivitySchema = ({
  currentModel,
  editorContext,
}: {
  currentModel: any;
  editorContext: string;
}) => {
  const context = editorContext;
  let adaptivitySchema = {};
  const configData: any = currentModel?.custom?.configData;
  if (configData && Array.isArray(configData)) {
    adaptivitySchema = configData.reduce((acc: any, typeToAdaptivitySchemaMap: any) => {
      let finalType: CapiVariableTypes = typeToAdaptivitySchemaMap.type;
      if (finalType) {
        if (isNaN(finalType)) {
          console.warn('Type is not a valid CapiVariableType', typeToAdaptivitySchemaMap);
          // attempt to fix the bad type
          if (finalType.toString().toLowerCase() === 'number') {
            finalType = CapiVariableTypes.NUMBER;
          } else if (finalType.toString().toLowerCase() === 'string') {
            finalType = CapiVariableTypes.STRING;
          } else if (finalType.toString().toLowerCase() === 'array') {
            finalType = CapiVariableTypes.ARRAY;
          } else if (finalType.toString().toLowerCase() === 'boolean') {
            finalType = CapiVariableTypes.BOOLEAN;
          } else if (finalType.toString().toLowerCase() === 'enum') {
            finalType = CapiVariableTypes.ENUM;
          } else if (finalType.toString().toLowerCase() === 'math_expr') {
            finalType = CapiVariableTypes.MATH_EXPR;
          } else if (finalType.toString().toLowerCase() === 'array_point') {
            finalType = CapiVariableTypes.ARRAY_POINT;
          } else {
            // couldn't fix it, so just remove it
            return acc;
          }
        }
        if (context === 'mutate') {
          if (!typeToAdaptivitySchemaMap.readonly) {
            acc[typeToAdaptivitySchemaMap.key] = finalType;
          }
        } else {
          acc[typeToAdaptivitySchemaMap.key] = finalType;
        }
      }
      return acc;
    }, {});
  }
  return adaptivitySchema;
};

export const transformModelToSchema = (model: Partial<CapiIframeModel>) => {
  const sourceConfig = decodeSourceConfig(model.source, model.src || '');
  if (model.sourceType === 'page') {
    sourceConfig.mode = 'page';
  } else if (model.sourceType === 'url') {
    sourceConfig.mode = 'url';
  } else if (model.linkType === 'page') {
    // Legacy fallback when explicit sourceType is not available.
    sourceConfig.mode = 'page';
  }
  if (typeof model.idref === 'number') {
    sourceConfig.pageId = model.idref;
  } else if (typeof model.resource_id === 'number') {
    sourceConfig.pageId = model.resource_id;
  }
  if (model.sourcePageSlug && typeof model.sourcePageSlug === 'string') {
    sourceConfig.pageSlug = model.sourcePageSlug;
  }

  return {
    ...model,
    title: resolveIframeTitle(model.title),
    source: encodeSourceConfig(sourceConfig),
  };
};

export const transformSchemaToModel = (schema: Partial<CapiIframeModel>) => {
  if (isGeneratedSimulation(schema)) {
    const {
      source: _source,
      sourceType: _sourceType,
      sourcePageSlug: _sourcePageSlug,
      linkType: _linkType,
      idref: _idref,
      resource_id: _resourceId,
      dynamicLinkFallback: _dynamicLinkFallback,
      ...trustedArtifactModel
    } = schema;

    // A generated simulation source is compiler-resolved from an approved
    // artifact. Never convert author-entered source editor data back into src.
    return {
      ...trustedArtifactModel,
      title: resolveIframeTitle(schema.title),
      sourceType: 'url' as const,
    };
  }

  const sourceConfig = decodeSourceConfig(schema.source, schema.src || '');
  const {
    source: _source,
    sourceType: _sourceType,
    sourcePageSlug: _sourcePageSlug,
    linkType: _linkType,
    idref: _idref,
    resource_id: _resourceId,
    ...rest
  } = schema;

  if (sourceConfig.mode === 'page') {
    return {
      ...rest,
      src: sourceConfig.pageSlug ? `${SOURCE_PREFIX}${sourceConfig.pageSlug}` : '',
      sourceType: 'page' as const,
      sourcePageSlug: sourceConfig.pageSlug,
      linkType: 'page' as const,
      idref: sourceConfig.pageId ?? undefined,
      resource_id: sourceConfig.pageId ?? undefined,
    };
  }

  return {
    ...rest,
    src: sourceConfig.url,
    sourceType: 'url' as const,
    sourcePageSlug: undefined,
    linkType: undefined,
    idref: undefined,
    resource_id: undefined,
    dynamicLinkFallback: undefined,
  };
};

export const uiSchema = {
  source: {
    'ui:widget': 'IframeSourceEditor',
  },
};

export const simpleUISchema = {
  source: {
    'ui:widget': 'IframeSourceEditor',
  },
};

export const createSchema = (): Partial<CapiIframeModel> => ({
  customCssClass: '',
  title: DEFAULT_IFRAME_TITLE,
  description: '',
  src: '',
  source: encodeSourceConfig(defaultSourceConfig()),
  sourceType: 'url',
  allowScrolling: true,
  configData: [],
  width: 400,
  height: 400,
});
