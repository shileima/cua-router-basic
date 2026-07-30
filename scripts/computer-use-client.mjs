import path from "node:path";
import { pathToFileURL } from "node:url";

const COMPUTER_USE_RUNTIME_KEY = Symbol.for("openai.computer-use.runtime");
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

/** @param {ReturnType<import("@oai/sky").create_client>} sky */
function wrapSkyClient(sky) {
  const originalPressKey = sky.press_key.bind(sky);
  return Object.freeze({
    ...sky,
    press_key(input) {
      const normalized =
        typeof input?.key === "string"
          ? { ...input, key: normalizePressKey(input.key) }
          : input;
      return originalPressKey(normalized);
    },
  });
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
  const installedRuntime = Reflect.get(globalThis, COMPUTER_USE_RUNTIME_KEY);
  if (installedRuntime != null) {
    Reflect.set(globalThis, "sky", installedRuntime);
    Reflect.set(globals, "sky", installedRuntime);
    return installedRuntime;
  }

  const createClient = await importPackagedCreateClient();
  const sky = wrapSkyClient(createClient({ target: "mac" }));
  Reflect.set(globalThis, COMPUTER_USE_RUNTIME_KEY, sky);
  Reflect.set(globalThis, "sky", sky);
  Reflect.set(globals, "sky", sky);
  return sky;
}

function requireNodeReplEnv() {
  const nodeRepl = /** @type {typeof globalThis & { nodeRepl?: NodeRepl }} */ (globalThis).nodeRepl;
  if (nodeRepl?.env == null) {
    throw new Error("Computer Use requires nodeRepl.env");
  }
  return nodeRepl.env;
}
