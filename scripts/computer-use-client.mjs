import path from "node:path";
import { pathToFileURL } from "node:url";

const COMPUTER_USE_RUNTIME_KEY = Symbol.for("openai.computer-use.runtime");
const COMPUTER_USE_AX_CACHE_KEY = Symbol.for("openai.computer-use.ax-cache");
const COMPUTER_USE_AX_HELPERS_KEY = Symbol.for("openai.computer-use.ax-helpers");

const SKY_MAC_CLIENT_ENTRYPOINT = [
  "@oai",
  "sky",
  "dist",
  "project",
  "cua",
  "sky_js",
  "src",
  "targets",
  "mac",
  "create_client.js",
];

// sky 交互方法白名单：调用后会导致 AX Tree 变化，必须失效对应 app 的缓存。
// press_key 单独处理（要归一化 key）。
const AX_MUTATING_METHODS = Object.freeze([
  "click",
  "double_click",
  "right_click",
  "drag",
  "scroll",
  "set_value",
  "type_text",
  "key_down",
  "key_up",
  "hover",
  "mouse_move",
]);

/**
 * @typedef {{
 *   env?: Record<string, string | undefined>,
 * }} NodeRepl
 */

/** @typedef {object} ComputerUseGlobals */

/** @typedef {{ globals?: ComputerUseGlobals }} SetupComputerUseRuntimeOptions */

/** @param {string} key */
export function normalizePressKey(key) {
  /** @type {Record<string, string>} */
  const ALIASES = {
    cmd: "Command",
    command: "Command",
    meta: "Command",
    super: "Command",
    ctrl: "Control_L",
    control: "Control_L",
    shift: "Shift_L",
    alt: "Alt_L",
    option: "Alt_L",
  };

  return key
    .split("+")
    .map((part) => part.trim())
    .filter(Boolean)
    .map((part) => ALIASES[part.toLowerCase()] ?? part)
    .join("+");
}

// ─────────────────────────────────────────────────────────────
// AX Tree helpers（跨 /exec 复用；由 sky mutation wrapper 自动失效）
// ─────────────────────────────────────────────────────────────

function getAxCache() {
  let cache = Reflect.get(globalThis, COMPUTER_USE_AX_CACHE_KEY);
  if (!(cache instanceof Map)) {
    cache = new Map();
    Reflect.set(globalThis, COMPUTER_USE_AX_CACHE_KEY, cache);
  }
  return cache;
}

/** @param {string | null | undefined} app 传 null/undefined 时失效全部 */
export function invalidateAxCache(app) {
  const cache = getAxCache();
  if (app == null) {
    cache.clear();
    return;
  }
  cache.delete(app);
}

export function findIdx(axText, ...keywords) {
  if (typeof axText !== "string" || keywords.length === 0) return null;
  const line = axText.split("\n").find((l) => keywords.every((k) => l.includes(k)));
  if (!line) return null;
  const m = line.match(/^\s*(\d+)/);
  return m ? parseInt(m[1], 10) : null;
}

export function findAllIdx(axText, ...keywords) {
  if (typeof axText !== "string" || keywords.length === 0) return [];
  return axText
    .split("\n")
    .filter((l) => keywords.every((k) => l.includes(k)))
    .map((l) => {
      const m = l.match(/^\s*(\d+)/);
      return { idx: m ? parseInt(m[1], 10) : null, line: l.trim() };
    })
    .filter((x) => x.idx != null);
}

export function findFocusedIdx(axText) {
  if (typeof axText !== "string") return null;
  const line = axText.split("\n").find((l) => /focused UI element is/.test(l));
  if (!line) return null;
  const m = line.match(/\b(\d+)\b/);
  return m ? parseInt(m[1], 10) : null;
}

export function linesMatching(axText, pattern, { limit = 50 } = {}) {
  if (typeof axText !== "string") return [];
  const re = pattern instanceof RegExp ? pattern : new RegExp(pattern);
  const lines = axText.split("\n");
  const out = [];
  for (const l of lines) {
    if (re.test(l)) {
      out.push(l);
      if (out.length >= limit) break;
    }
  }
  return out;
}

/**
 * 输出前收敛完整 AX Tree，避免把数百 KB 的 text 回传给上层。
 */
export function summarizeAxState(state, opts = {}) {
  const {
    keywords = [],
    patterns = [],
    maxLines = 30,
    textPreview = 0,
    includeUrl = true,
    includeFocused = true,
  } = opts;

  if (state == null || typeof state.text !== "string") {
    return { textLen: 0 };
  }

  const text = state.text;
  /** @type {Record<string, unknown>} */
  const out = { textLen: text.length };

  if (includeUrl) {
    const m = text.match(/URL: ([^\s,\n]+)/);
    if (m) out.url = m[1];
  }

  if (includeFocused) {
    const focusedIdx = findFocusedIdx(text);
    if (focusedIdx != null) out.focusedIdx = focusedIdx;
  }

  if (keywords.length > 0) {
    out.kwMatches = findAllIdx(text, ...keywords).slice(0, maxLines);
  }

  if (patterns.length > 0) {
    const compiled = patterns.map((p) => (p instanceof RegExp ? p : new RegExp(p)));
    const lines = text.split("\n");
    const matches = [];
    for (const l of lines) {
      if (compiled.some((re) => re.test(l))) {
        matches.push(l.trim());
        if (matches.length >= maxLines) break;
      }
    }
    out.matches = matches;
  }

  if (textPreview > 0) {
    out.preview = text.slice(0, textPreview);
  }

  return out;
}

/** @param {ReturnType<import("@oai/sky").create_client>} sky */
export function createAxHelpers(sky) {
  return Object.freeze({
    /**
     * 拿 AX 完整快照（强制 disableDiff:true，保证 findIdx / element_index 正确）。
     * 跨 /exec 缓存；sky 交互后 wrapper 会自动失效。
     * 外部触发（swift / AppleScript / 手动鼠标）后需 refresh:true 或 invalidate。
     * @param {string} app
     * @param {{ refresh?: boolean }} [opts]
     */
    async get(app, opts = {}) {
      const { refresh = false } = opts;
      if (typeof app !== "string" || !app) {
        throw new Error("ax.get(app) requires an app bundle id string");
      }
      const cache = getAxCache();
      if (!refresh && cache.has(app)) {
        return cache.get(app);
      }
      const state = await sky.get_app_state({ app, disableDiff: true });
      cache.set(app, state);
      return state;
    },
    invalidate: invalidateAxCache,
    findIdx,
    findAllIdx,
    findFocusedIdx,
    linesMatching,
    summarize: summarizeAxState,
  });
}

// ─────────────────────────────────────────────────────────────
// sky client wrapper：normalize press_key + 自动失效 AX 缓存
// ─────────────────────────────────────────────────────────────

/** @param {string | null | undefined} app @param {Promise<unknown>|unknown} p */
function withAxInvalidate(app, p) {
  return Promise.resolve(p).finally(() => invalidateAxCache(app ?? null));
}

/** @param {ReturnType<import("@oai/sky").create_client>} sky */
export function wrapSkyClient(sky) {
  const originalPressKey = sky.press_key.bind(sky);
  const originalGetAppState = sky.get_app_state.bind(sky);

  /** @type {Record<string, Function>} */
  const overrides = {
    press_key(input) {
      const normalized =
        typeof input?.key === "string"
          ? { ...input, key: normalizePressKey(input.key) }
          : input;
      return withAxInvalidate(input?.app, originalPressKey(normalized));
    },
    // 保留原生调用行为；同时在 disableDiff:true 时回填 AX 缓存，
    // 让 sky.get_app_state 与 ax.get 共用同一份快照。
    async get_app_state(input, ...rest) {
      const state = await originalGetAppState(input, ...rest);
      if (input && typeof input.app === "string" && input.disableDiff === true) {
        getAxCache().set(input.app, state);
      }
      return state;
    },
  };

  for (const name of AX_MUTATING_METHODS) {
    const fn = sky[name];
    if (typeof fn !== "function") continue;
    const bound = fn.bind(sky);
    overrides[name] = (input, ...rest) =>
      withAxInvalidate(input?.app, bound(input, ...rest));
  }

  return Object.freeze({ ...sky, ...overrides });
}

async function importPackagedCreateClient() {
  const moduleDirs = requireNodeReplEnv()["NODE_REPL_NODE_MODULE_DIRS"];
  const searchRoots = typeof moduleDirs === "string" ? moduleDirs.split(path.delimiter) : [];
  let lastError;
  for (const searchRoot of searchRoots) {
    if (!searchRoot.trim()) {
      continue;
    }
    const resolvedRoot = path.resolve(searchRoot);
    const nodeModulesRoot =
      path.basename(resolvedRoot) === "node_modules"
        ? resolvedRoot
        : path.join(resolvedRoot, "node_modules");
    try {
      const module = await import(
        pathToFileURL(path.join(nodeModulesRoot, ...SKY_MAC_CLIENT_ENTRYPOINT)).href
      );
      if (typeof module.create_client !== "function") {
        throw new Error("@oai/sky is missing the compiled mac create_client entrypoint");
      }
      return module.create_client;
    } catch (error) {
      lastError = error;
    }
  }
  throw new Error("Computer Use could not load @oai/sky from the cua_node runtime", {
    cause: lastError,
  });
}

/** @param {SetupComputerUseRuntimeOptions} [options] */
export async function setupComputerUseRuntime({ globals = globalThis } = {}) {
  let sky = Reflect.get(globalThis, COMPUTER_USE_RUNTIME_KEY);
  if (sky == null) {
    const createClient = await importPackagedCreateClient();
    sky = wrapSkyClient(createClient({ target: "mac" }));
    Reflect.set(globalThis, COMPUTER_USE_RUNTIME_KEY, sky);
  }
  Reflect.set(globalThis, "sky", sky);
  Reflect.set(globals, "sky", sky);

  let ax = Reflect.get(globalThis, COMPUTER_USE_AX_HELPERS_KEY);
  if (ax == null) {
    ax = createAxHelpers(sky);
    Reflect.set(globalThis, COMPUTER_USE_AX_HELPERS_KEY, ax);
  }
  Reflect.set(globalThis, "ax", ax);
  Reflect.set(globals, "ax", ax);

  return sky;
}

function requireNodeReplEnv() {
  const nodeRepl = /** @type {typeof globalThis & { nodeRepl?: NodeRepl }} */ (globalThis).nodeRepl;
  if (nodeRepl?.env == null) {
    throw new Error("Computer Use requires nodeRepl.env");
  }
  return nodeRepl.env;
}
