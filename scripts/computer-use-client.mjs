import path from "node:path";
import { execFile } from "node:child_process";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";

const COMPUTER_USE_RUNTIME_KEY = Symbol.for("openai.computer-use.runtime");
const COMPUTER_USE_AX_CACHE_KEY = Symbol.for("openai.computer-use.ax-cache");
const COMPUTER_USE_AX_STATS_KEY = Symbol.for("openai.computer-use.ax-stats");
const COMPUTER_USE_AX_HELPERS_KEY = Symbol.for("openai.computer-use.ax-helpers");
const COMPUTER_USE_ATOMIC_ACTIONS_KEY = Symbol.for("openai.computer-use.atomic-actions");
const COMPUTER_USE_CHROME_AX_RECOVERY_KEY = Symbol.for("openai.computer-use.chrome-ax-recovery");

const execFileAsync = promisify(execFile);

function makeStats() {
  return { hits: 0, misses: 0, staleMisses: 0, invalidations: 0, refreshes: 0 };
}

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

function getAxStats() {
  let stats = Reflect.get(globalThis, COMPUTER_USE_AX_STATS_KEY);
  if (stats == null || typeof stats !== "object") {
    stats = makeStats();
    Reflect.set(globalThis, COMPUTER_USE_AX_STATS_KEY, stats);
  }
  return stats;
}

/** @param {string | null | undefined} app 传 null/undefined 时失效全部 */
export function invalidateAxCache(app) {
  const cache = getAxCache();
  const stats = getAxStats();
  if (app == null) {
    stats.invalidations += cache.size;
    cache.clear();
    return;
  }
  if (cache.delete(app)) {
    stats.invalidations += 1;
  }
}

/** 内部：写入缓存条目，附带获取时间戳。仅供 wrapSkyClient / createAxHelpers 使用。 */
function writeCacheEntry(app, state) {
  getAxCache().set(app, { state, fetchedAt: Date.now() });
}

export function axStatsSnapshot() {
  const cache = getAxCache();
  const stats = getAxStats();
  const now = Date.now();
  /** @type {{app:string, ageMs:number, fetchedAt:number, textLen:number}[]} */
  const entries = [];
  for (const [app, entry] of cache) {
    entries.push({
      app,
      ageMs: now - entry.fetchedAt,
      fetchedAt: entry.fetchedAt,
      textLen: typeof entry.state?.text === "string" ? entry.state.text.length : 0,
    });
  }
  const total = stats.hits + stats.misses + stats.staleMisses + stats.refreshes;
  return {
    hits: stats.hits,
    misses: stats.misses,
    staleMisses: stats.staleMisses,
    refreshes: stats.refreshes,
    invalidations: stats.invalidations,
    hitRate: total > 0 ? stats.hits / total : 0,
    cacheSize: cache.size,
    entries,
  };
}

export function resetAxStats() {
  Reflect.set(globalThis, COMPUTER_USE_AX_STATS_KEY, makeStats());
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
     * 外部触发（swift / AppleScript / 手动鼠标 / 页面自身异步更新）后：
     *   - 显式：ax.get(app, { refresh: true }) 或 ax.invalidate(app)
     *   - 兜底：ax.get(app, { maxAgeMs: 500 }) — 缓存超过 500ms 自动重取
     * @param {string} app
     * @param {{ refresh?: boolean, maxAgeMs?: number | null }} [opts]
     */
    async get(app, opts = {}) {
      const { refresh = false, maxAgeMs = null } = opts;
      if (typeof app !== "string" || !app) {
        throw new Error("ax.get(app) requires an app bundle id string");
      }
      const cache = getAxCache();
      const stats = getAxStats();
      const entry = cache.get(app);
      const now = Date.now();

      if (!refresh && entry != null) {
        // 语义：age >= maxAgeMs 判定为陈旧，因此 maxAgeMs:0 等价于强制刷新
        // （对齐 HTTP max-age=0 「必须 revalidate」的语义）。
        const stale =
          typeof maxAgeMs === "number" && maxAgeMs >= 0 && now - entry.fetchedAt >= maxAgeMs;
        if (!stale) {
          stats.hits += 1;
          return entry.state;
        }
        stats.staleMisses += 1;
      } else if (refresh) {
        stats.refreshes += 1;
      } else {
        stats.misses += 1;
      }

      const state = await sky.get_app_state({ app, disableDiff: true });
      writeCacheEntry(app, state);
      return state;
    },
    invalidate: invalidateAxCache,
    findIdx,
    findAllIdx,
    findFocusedIdx,
    linesMatching,
    summarize: summarizeAxState,
    _stats: axStatsSnapshot,
    _resetStats: resetAxStats,
  });
}

// ─────────────────────────────────────────────────────────────
// 原子动作：定位 → 单次交互 → 刷新验证 → 单次结构化输出
// ─────────────────────────────────────────────────────────────

function normalizeKeywordGroups(value, fieldName, { optional = false } = {}) {
  if (value == null && optional) return [];
  const groups = Array.isArray(value) && value.every((item) => typeof item === "string")
    ? [value]
    : value;
  if (
    !Array.isArray(groups) ||
    groups.length === 0 ||
    groups.some(
      (group) =>
        !Array.isArray(group) ||
        group.length === 0 ||
        group.some((keyword) => typeof keyword !== "string" || keyword.length === 0),
    )
  ) {
    throw new Error(`${fieldName} must be a non-empty keyword group or list of keyword groups`);
  }
  return groups;
}

function locateFirstKeywordGroup(ax, text, groups) {
  for (const keywords of groups) {
    const elementIndex = ax.findIdx(text, ...keywords);
    if (elementIndex != null) return { elementIndex, matchedKeywords: keywords };
  }
  return null;
}

function errorMessage(error) {
  if (error instanceof Error) return error.message;
  try {
    return String(error);
  } catch {
    return "Unknown error";
  }
}

/**
 * 创建通用原子动作。每次动作只写一次 JSON，调用方无需手写 nodeRepl.write。
 * @param {{ sky: object, ax: object, write?: (text: string) => void }} options
 */
export function createAtomicActions({ sky, ax, write = null }) {
  if (sky == null || typeof sky.click !== "function") {
    throw new Error("createAtomicActions requires sky.click");
  }
  if (ax == null || typeof ax.get !== "function" || typeof ax.findIdx !== "function") {
    throw new Error("createAtomicActions requires AX helpers");
  }

  const emit = (result) => {
    const output = JSON.stringify(result);
    if (typeof write === "function") {
      write(output);
    } else {
      const repl = /** @type {typeof globalThis & { nodeRepl?: { write?: Function } }} */ (globalThis)
        .nodeRepl;
      if (typeof repl?.write !== "function") {
        throw new Error("atomic actions require nodeRepl.write or an explicit write callback");
      }
      repl.write(output);
    }
    return result;
  };

  return Object.freeze({
    /**
     * @param {{
     *   app: string,
     *   target: string[] | string[][],
     *   verify?: string[] | string[][],
     *   refreshBefore?: boolean,
     *   summaryMaxLines?: number,
     * }} input
     */
    async click(input) {
      const app = input?.app;
      let targetGroups;
      let verifyGroups;
      let summaryOptions;
      try {
        if (typeof app !== "string" || app.length === 0) {
          throw new Error("atomic.click requires an app bundle id string");
        }
        targetGroups = normalizeKeywordGroups(input.target, "target");
        verifyGroups = normalizeKeywordGroups(input.verify, "verify", { optional: true });
        summaryOptions = { maxLines: input.summaryMaxLines ?? 30 };
      } catch (error) {
        return emit({
          ok: false,
          operation: "click",
          app: typeof app === "string" ? app : null,
          stage: "input",
          error: { code: "invalid_input", message: errorMessage(error) },
        });
      }

      let beforeState;
      try {
        beforeState = await ax.get(app, { refresh: input.refreshBefore ?? true });
      } catch (error) {
        return emit({
          ok: false,
          operation: "click",
          app,
          stage: "snapshot",
          error: { code: "snapshot_failed", message: errorMessage(error) },
        });
      }

      let before;
      let target;
      try {
        before = ax.summarize(beforeState, summaryOptions);
        target = locateFirstKeywordGroup(ax, beforeState.text, targetGroups);
      } catch (error) {
        return emit({
          ok: false,
          operation: "click",
          app,
          stage: "process",
          error: { code: "ax_processing_failed", message: errorMessage(error) },
        });
      }
      if (target == null) {
        return emit({
          ok: false,
          operation: "click",
          app,
          stage: "locate",
          target: { candidates: targetGroups },
          before,
          error: { code: "target_not_found", message: "No target keyword group matched" },
        });
      }

      try {
        await sky.click({ app, element_index: target.elementIndex });
      } catch (error) {
        return emit({
          ok: false,
          operation: "click",
          app,
          stage: "action",
          target,
          before,
          error: { code: "click_failed", message: errorMessage(error) },
        });
      }

      let afterState;
      try {
        afterState = await ax.get(app, { refresh: true });
      } catch (error) {
        return emit({
          ok: false,
          operation: "click",
          app,
          stage: "verify",
          target,
          before,
          error: { code: "verification_snapshot_failed", message: errorMessage(error) },
        });
      }

      let after;
      let verification;
      try {
        after = ax.summarize(afterState, summaryOptions);
        verification =
          verifyGroups.length > 0
            ? locateFirstKeywordGroup(ax, afterState.text, verifyGroups)
            : { mode: "post_action_snapshot" };
      } catch (error) {
        return emit({
          ok: false,
          operation: "click",
          app,
          stage: "process",
          target,
          before,
          error: { code: "ax_processing_failed", message: errorMessage(error) },
        });
      }
      if (verification == null) {
        return emit({
          ok: false,
          operation: "click",
          app,
          stage: "verify",
          target,
          verification: { candidates: verifyGroups },
          before,
          after,
          error: { code: "verification_failed", message: "No verification keyword group matched" },
        });
      }

      return emit({
        ok: true,
        operation: "click",
        app,
        stage: "verified",
        target,
        verification,
        before,
        after,
      });
    },
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

  const maybeCacheGetAppState = (input, state) => {
    if (input && typeof input.app === "string" && input.disableDiff === true) {
      writeCacheEntry(input.app, state);
    }
    return state;
  };

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
    // 让 sky.get_app_state 与 ax.get 共用同一份快照（带 fetchedAt 时间戳）。
    async get_app_state(input, ...rest) {
      try {
        return maybeCacheGetAppState(input, await originalGetAppState(input, ...rest));
      } catch (error) {
        if (!shouldRecoverChromeAx(input, error)) {
          throw error;
        }
        invalidateAxCache(input.app);
        const recovered = await recoverChromeAx(error);
        if (!recovered) {
          throw error;
        }
        return maybeCacheGetAppState(input, await originalGetAppState(input, ...rest));
      }
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

function shouldRecoverChromeAx(input, error) {
  if (process.env.CUA_ROUTER_CHROME_AX_RECOVERY === "off") return false;
  if (process.platform !== "darwin") return false;
  if (input == null || input.app !== "com.google.Chrome") return false;

  const message = errorMessage(error).toLowerCase();
  return (
    message.includes("-10005") ||
    message.includes("timeoutreached") ||
    message.includes("exited before returning a response")
  );
}

async function recoverChromeAx(error) {
  const override = Reflect.get(globalThis, COMPUTER_USE_CHROME_AX_RECOVERY_KEY);
  if (typeof override === "function") {
    return Boolean(await override(error));
  }

  try {
    await execFileAsync("/bin/bash", [
      "-lc",
      [
        "osascript -e 'tell application \"Google Chrome\" to quit' >/dev/null 2>&1 || true",
        "sleep 2",
        "if pgrep -x 'Google Chrome' >/dev/null 2>&1; then pkill -TERM -x 'Google Chrome' >/dev/null 2>&1 || true; sleep 1; fi",
        "open -a 'Google Chrome' >/dev/null 2>&1",
        "sleep 3",
        "osascript -e 'tell application \"Google Chrome\" to make new window' >/dev/null 2>&1 || true",
      ].join("; "),
    ], { timeout: 10000 });
    return true;
  } catch {
    return false;
  }
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
  invalidateAxCache();
  let sky = Reflect.get(globalThis, COMPUTER_USE_RUNTIME_KEY);
  if (sky == null) {
    const createClient = await importPackagedCreateClient();
    sky = wrapSkyClient(createClient({ target: "mac" }));
    Reflect.set(globalThis, COMPUTER_USE_RUNTIME_KEY, sky);
  }
  Reflect.set(globalThis, "sky", sky);
  Reflect.set(globals, "sky", sky);

  const ax = createAxHelpers(sky);
  Reflect.set(globalThis, COMPUTER_USE_AX_HELPERS_KEY, ax);
  Reflect.set(globalThis, "ax", ax);
  Reflect.set(globals, "ax", ax);

  const atomic = createAtomicActions({ sky, ax });
  Reflect.set(globalThis, COMPUTER_USE_ATOMIC_ACTIONS_KEY, atomic);
  Reflect.set(globalThis, "atomic", atomic);
  Reflect.set(globals, "atomic", atomic);

  return sky;
}

function requireNodeReplEnv() {
  const nodeRepl = /** @type {typeof globalThis & { nodeRepl?: NodeRepl }} */ (globalThis).nodeRepl;
  if (nodeRepl?.env == null) {
    throw new Error("Computer Use requires nodeRepl.env");
  }
  return nodeRepl.env;
}
