// node --test tests/test_computer_use_client.mjs
//
// 覆盖 AX helpers 的缓存与失效语义，保证：
//   1. 同 app 相邻 ax.get 命中缓存，只调一次 sky.get_app_state
//   2. sky.click / set_value / press_key / scroll 等 mutation 后自动失效
//   3. 无 app 参数（坐标点击）保守失效全部缓存
//   4. sky.get_app_state({app, disableDiff:true}) 回填缓存，与 ax.get 共用
//   5. atomic.click 将定位、点击、验证收敛为一次动作和一次结构化输出

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  normalizePressKey,
  findIdx,
  findAllIdx,
  findFocusedIdx,
  linesMatching,
  summarizeAxState,
  createAxHelpers,
  createAtomicActions,
  wrapSkyClient,
  invalidateAxCache,
  axStatsSnapshot,
  resetAxStats,
  setupComputerUseRuntime,
} from "../scripts/computer-use-client.mjs";

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const SAMPLE_AX_TEXT = [
  "  1 window Google Chrome",
  "  2 text URL: https://example.com",
  "  3 settable, string 地址和搜索栏 http://a",
  "  4 button 关闭 按钮",
  "  5 dialog 确认删除",
  " 12 button 确定 按钮",
  " 33 text 文本 3",
  "note: focused UI element is 33",
].join("\n");

function makeSampleState(overrides = {}) {
  return { text: SAMPLE_AX_TEXT, ...overrides };
}

/**
 * 一个可控 sky mock，记录调用次数，便于验证缓存与失效。
 */
function createMockSky({ stateProvider } = {}) {
  const calls = { get_app_state: 0, click: 0, set_value: 0, press_key: 0, scroll: 0 };
  return {
    calls,
    async get_app_state(input) {
      calls.get_app_state += 1;
      return typeof stateProvider === "function"
        ? stateProvider(input, calls.get_app_state)
        : makeSampleState();
    },
    async click(input) {
      calls.click += 1;
      return { ok: true, input };
    },
    async set_value(input) {
      calls.set_value += 1;
      return { ok: true, input };
    },
    async press_key(input) {
      calls.press_key += 1;
      return { ok: true, input };
    },
    async scroll(input) {
      calls.scroll += 1;
      return { ok: true, input };
    },
    async double_click(input) {
      return { ok: true, input };
    },
    async type_text(input) {
      return { ok: true, input };
    },
  };
}

test("normalizePressKey 归一化常见别名", () => {
  assert.equal(normalizePressKey("Cmd+V"), "Command+V");
  assert.equal(normalizePressKey("ctrl+c"), "Control_L+c");
  assert.equal(normalizePressKey("Shift+Tab"), "Shift_L+Tab");
  assert.equal(normalizePressKey("Option+v"), "Alt_L+v");
  assert.equal(normalizePressKey("Command+v"), "Command+v");
  assert.equal(normalizePressKey("Return"), "Return");
});

test("findIdx / findAllIdx / findFocusedIdx 覆盖基础用法", () => {
  assert.equal(findIdx(SAMPLE_AX_TEXT, "确定", "按钮"), 12);
  assert.equal(findIdx(SAMPLE_AX_TEXT, "不存在"), null);
  assert.deepEqual(findAllIdx(SAMPLE_AX_TEXT, "按钮"), [
    { idx: 4, line: "4 button 关闭 按钮" },
    { idx: 12, line: "12 button 确定 按钮" },
  ]);
  assert.equal(findFocusedIdx(SAMPLE_AX_TEXT), 33);
  assert.equal(findFocusedIdx(""), null);
});

test("linesMatching 支持字符串与正则，限制条数", () => {
  const lines = linesMatching(SAMPLE_AX_TEXT, /button/);
  assert.equal(lines.length, 2);
  const limited = linesMatching(SAMPLE_AX_TEXT, "text", { limit: 1 });
  assert.equal(limited.length, 1);
});

test("summarizeAxState 只输出必要字段，绝不回传完整 text", () => {
  const s = summarizeAxState(makeSampleState(), {
    keywords: ["按钮"],
    patterns: [/dialog|确认/],
    maxLines: 5,
    textPreview: 20,
  });
  assert.equal(s.textLen, SAMPLE_AX_TEXT.length);
  assert.equal(s.url, "https://example.com");
  assert.equal(s.focusedIdx, 33);
  assert.equal(s.kwMatches.length, 2);
  assert.ok(s.matches.some((l) => l.includes("dialog")));
  assert.equal(s.preview.length, 20);
});

test("ax.get 相邻两次调用命中缓存，只发一次 sky.get_app_state", async () => {
  invalidateAxCache();
  const sky = createMockSky();
  const ax = createAxHelpers(sky);
  const s1 = await ax.get("com.google.Chrome");
  const s2 = await ax.get("com.google.Chrome");
  assert.equal(sky.calls.get_app_state, 1);
  assert.equal(s1, s2);
});

test("ax.get: 空 AX 快照重试，且不写入缓存", async () => {
  invalidateAxCache();
  const states = [{ text: "" }, makeSampleState()];
  const sky = createMockSky({ stateProvider: () => states.shift() });
  const ax = createAxHelpers(sky);

  const state = await ax.get("com.google.Chrome", { emptyRetries: 1, retryDelayMs: 0 });

  assert.equal(state.text, SAMPLE_AX_TEXT);
  assert.equal(sky.calls.get_app_state, 2);
  await ax.get("com.google.Chrome");
  assert.equal(sky.calls.get_app_state, 2, "有效快照应被缓存");
});

test("wrapSkyClient: 空 disableDiff 快照不能覆盖已有有效缓存", async () => {
  invalidateAxCache();
  const mock = createMockSky({ stateProvider: (_input, count) => count === 1 ? makeSampleState() : { text: "" } });
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);

  await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  await ax.get("com.google.Chrome");

  assert.equal(mock.calls.get_app_state, 2, "空快照不应覆盖之前的有效缓存");
});

test("ax.get 强制 disableDiff:true", async () => {
  invalidateAxCache();
  let seenInput;
  const sky = createMockSky({
    stateProvider: (input) => {
      seenInput = input;
      return makeSampleState();
    },
  });
  const ax = createAxHelpers(sky);
  await ax.get("com.google.Chrome");
  assert.deepEqual(seenInput, { app: "com.google.Chrome", disableDiff: true });
});

test("wrapSkyClient: click 后自动失效对应 app 缓存", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);

  await ax.get("com.google.Chrome");
  assert.equal(mock.calls.get_app_state, 1);

  await sky.click({ app: "com.google.Chrome", element_index: 12 });
  assert.equal(mock.calls.click, 1);

  await ax.get("com.google.Chrome");
  assert.equal(mock.calls.get_app_state, 2, "click 后必须重新取树以保证定位正确性");
});

test("wrapSkyClient: press_key 也失效缓存并归一化 key", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  let pressedKey;
  mock.press_key = async (input) => {
    pressedKey = input.key;
    return { ok: true };
  };
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);

  await ax.get("cn.neixin.pc");
  await sky.press_key({ app: "cn.neixin.pc", key: "Cmd+V" });
  assert.equal(pressedKey, "Command+V");

  const startGetAppStateCalls = mock.calls.get_app_state;
  await ax.get("cn.neixin.pc");
  assert.equal(mock.calls.get_app_state, startGetAppStateCalls + 1);
});

test("wrapSkyClient: 无 app 参数（坐标点击）保守失效所有缓存", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);

  await ax.get("com.google.Chrome");
  await ax.get("cn.neixin.pc");
  assert.equal(mock.calls.get_app_state, 2);

  await sky.click({ x: 100, y: 200 });

  await ax.get("com.google.Chrome");
  await ax.get("cn.neixin.pc");
  assert.equal(mock.calls.get_app_state, 4, "坐标点击无法判定 app，保守失效全部");
});

test("wrapSkyClient: sky.get_app_state({disableDiff:true}) 回填缓存，与 ax.get 共用", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);

  const s1 = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });
  const s2 = await ax.get("com.google.Chrome");
  assert.equal(mock.calls.get_app_state, 1, "第二次应命中 wrapSkyClient 回填的缓存");
  assert.equal(s1, s2);
});

test("wrapSkyClient: sky.get_app_state 不传 disableDiff:true 不回填缓存", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);

  await sky.get_app_state({ app: "com.google.Chrome" });
  await ax.get("com.google.Chrome");
  assert.equal(mock.calls.get_app_state, 2, "diff 模式不能作为完整快照缓存");
});

test("wrapSkyClient: Chrome AX -10005 自动恢复一次并重试同次 get_app_state", async () => {
  invalidateAxCache();
  const recoveryKey = Symbol.for("openai.computer-use.chrome-ax-recovery");
  const previousRecovery = Reflect.get(globalThis, recoveryKey);
  const previousPlatform = Object.getOwnPropertyDescriptor(process, "platform");
  const previousMode = process.env.CUA_ROUTER_CHROME_AX_RECOVERY;
  let recoveries = 0;
  let attempts = 0;

  Object.defineProperty(process, "platform", { value: "darwin" });
  Reflect.set(globalThis, recoveryKey, async () => {
    recoveries += 1;
    return true;
  });
  delete process.env.CUA_ROUTER_CHROME_AX_RECOVERY;

  try {
    const mock = createMockSky({
      stateProvider: () => {
        attempts += 1;
        if (attempts === 1) {
          throw new Error("Computer Use server error -10005: codex app-server exited before returning a response");
        }
        return makeSampleState();
      },
    });
    const sky = wrapSkyClient(mock);

    const state = await sky.get_app_state({ app: "com.google.Chrome", disableDiff: true });

    assert.equal(state.text, SAMPLE_AX_TEXT);
    assert.equal(mock.calls.get_app_state, 2);
    assert.equal(recoveries, 1);
  } finally {
    if (previousRecovery === undefined) {
      Reflect.deleteProperty(globalThis, recoveryKey);
    } else {
      Reflect.set(globalThis, recoveryKey, previousRecovery);
    }
    Object.defineProperty(process, "platform", previousPlatform);
    if (previousMode === undefined) {
      delete process.env.CUA_ROUTER_CHROME_AX_RECOVERY;
    } else {
      process.env.CUA_ROUTER_CHROME_AX_RECOVERY = previousMode;
    }
  }
});

test("wrapSkyClient: 非 Chrome get_app_state 失败不触发 Chrome AX 恢复", async () => {
  const recoveryKey = Symbol.for("openai.computer-use.chrome-ax-recovery");
  const previousRecovery = Reflect.get(globalThis, recoveryKey);
  const previousPlatform = Object.getOwnPropertyDescriptor(process, "platform");
  let recoveries = 0;

  Object.defineProperty(process, "platform", { value: "darwin" });
  Reflect.set(globalThis, recoveryKey, async () => {
    recoveries += 1;
    return true;
  });

  try {
    const mock = createMockSky({
      stateProvider: () => {
        throw new Error("Computer Use server error -10005: codex app-server exited before returning a response");
      },
    });
    const sky = wrapSkyClient(mock);

    await assert.rejects(
      () => sky.get_app_state({ app: "cn.neixin.pc", disableDiff: true }),
      /-10005/,
    );
    assert.equal(mock.calls.get_app_state, 1);
    assert.equal(recoveries, 0);
  } finally {
    if (previousRecovery === undefined) {
      Reflect.deleteProperty(globalThis, recoveryKey);
    } else {
      Reflect.set(globalThis, recoveryKey, previousRecovery);
    }
    Object.defineProperty(process, "platform", previousPlatform);
  }
});

test("wrapSkyClient: 调用失败也失效缓存，避免残留过期树", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  mock.click = async () => {
    throw new Error("boom");
  };
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);

  await ax.get("com.google.Chrome");
  await assert.rejects(() => sky.click({ app: "com.google.Chrome", element_index: 1 }));

  const before = mock.calls.get_app_state;
  await ax.get("com.google.Chrome");
  assert.equal(mock.calls.get_app_state, before + 1);
});

test("invalidateAxCache 支持整体清空与按 app 清空", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);

  await ax.get("com.google.Chrome");
  await ax.get("cn.neixin.pc");

  ax.invalidate("com.google.Chrome");
  await ax.get("com.google.Chrome");
  await ax.get("cn.neixin.pc");
  assert.equal(mock.calls.get_app_state, 3);

  ax.invalidate();
  await ax.get("com.google.Chrome");
  await ax.get("cn.neixin.pc");
  assert.equal(mock.calls.get_app_state, 5);
});

test("ax.get 参数校验：非字符串 app 抛错", async () => {
  const sky = createMockSky();
  const ax = createAxHelpers(sky);
  await assert.rejects(() => ax.get(""), /requires an app bundle id/);
  await assert.rejects(() => ax.get(undefined), /requires an app bundle id/);
});

test("ax.get({ maxAgeMs }): 未超时命中缓存", async () => {
  invalidateAxCache();
  const sky = createMockSky();
  const ax = createAxHelpers(sky);
  await ax.get("com.google.Chrome");
  await ax.get("com.google.Chrome", { maxAgeMs: 5000 });
  assert.equal(sky.calls.get_app_state, 1, "远未超时应命中缓存");
});

test("ax.get({ maxAgeMs }): 超时判定为陈旧，自动重取", async () => {
  invalidateAxCache();
  const sky = createMockSky();
  const ax = createAxHelpers(sky);
  await ax.get("com.google.Chrome");
  await sleep(30);
  await ax.get("com.google.Chrome", { maxAgeMs: 10 });
  assert.equal(sky.calls.get_app_state, 2, "缓存年龄 > maxAgeMs 应重取");
});

test("ax.get({ maxAgeMs: 0 }): 永远视为陈旧，等价于强制刷新", async () => {
  invalidateAxCache();
  const sky = createMockSky();
  const ax = createAxHelpers(sky);
  await ax.get("com.google.Chrome");
  await ax.get("com.google.Chrome", { maxAgeMs: 0 });
  assert.equal(sky.calls.get_app_state, 2);
});

test("ax.get: refresh:true 覆盖 maxAgeMs（refresh 优先级更高）", async () => {
  invalidateAxCache();
  const sky = createMockSky();
  const ax = createAxHelpers(sky);
  await ax.get("com.google.Chrome");
  await ax.get("com.google.Chrome", { refresh: true, maxAgeMs: 999999 });
  assert.equal(sky.calls.get_app_state, 2);
});

test("ax._stats: hits / misses / refreshes / staleMisses 计数正确", async () => {
  invalidateAxCache();
  resetAxStats();
  const sky = createMockSky();
  const ax = createAxHelpers(sky);

  await ax.get("com.google.Chrome"); // miss
  await ax.get("com.google.Chrome"); // hit
  await ax.get("com.google.Chrome", { refresh: true }); // refresh
  await sleep(20);
  await ax.get("com.google.Chrome", { maxAgeMs: 5 }); // staleMiss

  const s = ax._stats();
  assert.equal(s.misses, 1);
  assert.equal(s.hits, 1);
  assert.equal(s.refreshes, 1);
  assert.equal(s.staleMisses, 1);
  assert.equal(s.cacheSize, 1);
  assert.equal(s.entries[0].app, "com.google.Chrome");
  assert.ok(s.entries[0].ageMs >= 0);
  assert.ok(s.hitRate > 0 && s.hitRate < 1);
});

test("ax._stats: invalidations 计数（按 app 与整体）", () => {
  invalidateAxCache();
  resetAxStats();
  const cache = new Map();
  // 直接借 wrapSkyClient 回填两个 app
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  return (async () => {
    await sky.get_app_state({ app: "a", disableDiff: true });
    await sky.get_app_state({ app: "b", disableDiff: true });
    invalidateAxCache("a");
    assert.equal(ax_snapshotInvalidations(), 1);
    invalidateAxCache();
    assert.equal(ax_snapshotInvalidations(), 2);
  })();
});

function ax_snapshotInvalidations() {
  return axStatsSnapshot().invalidations;
}

test("ax._resetStats: 归零所有计数", async () => {
  invalidateAxCache();
  const sky = createMockSky();
  const ax = createAxHelpers(sky);
  await ax.get("com.google.Chrome");
  await ax.get("com.google.Chrome");
  assert.ok(ax._stats().hits + ax._stats().misses > 0);
  ax._resetStats();
  const s = ax._stats();
  assert.equal(s.hits, 0);
  assert.equal(s.misses, 0);
  assert.equal(s.refreshes, 0);
  assert.equal(s.staleMisses, 0);
  assert.equal(s.invalidations, 0);
});

test("ax._stats entries 携带每个 app 的年龄与 textLen", async () => {
  invalidateAxCache();
  const sky = createMockSky();
  const ax = createAxHelpers(sky);
  await ax.get("com.google.Chrome");
  await sleep(10);
  const s = ax._stats();
  assert.equal(s.cacheSize, 1);
  assert.equal(s.entries.length, 1);
  assert.equal(s.entries[0].app, "com.google.Chrome");
  assert.ok(s.entries[0].ageMs >= 10);
  assert.equal(s.entries[0].textLen, SAMPLE_AX_TEXT.length);
});

test("atomic.click 原子完成定位、单次点击、刷新验证并只写一次结构化结果", async () => {
  invalidateAxCache();
  const before = ["1 window Chrome", "28 按钮 工作流"].join("\n");
  const after = ["1 window Chrome", "28 按钮 工作流", "40 按钮 新建工作流"].join("\n");
  const mock = createMockSky({
    stateProvider: (_input, count) => ({ text: count === 1 ? before : after }),
  });
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);
  const writes = [];
  const atomic = createAtomicActions({ sky, ax, write: (text) => writes.push(text) });

  const result = await atomic.click({
    app: "com.google.Chrome",
    target: [["按钮", "工作流"], ["工作流"]],
    verify: [["新建工作流"]],
  });

  assert.equal(result.ok, true);
  assert.equal(result.stage, "verified");
  assert.equal(result.target.elementIndex, 28);
  assert.deepEqual(result.target.matchedKeywords, ["按钮", "工作流"]);
  assert.deepEqual(result.verification.matchedKeywords, ["新建工作流"]);
  assert.equal(mock.calls.click, 1);
  assert.equal(mock.calls.get_app_state, 2);
  assert.equal(writes.length, 1);
  assert.deepEqual(JSON.parse(writes[0]), result);
  assert.equal("text" in result.before, false, "结构化结果不得泄漏完整 AX Tree");
  assert.equal("text" in result.after, false, "结构化结果不得泄漏完整 AX Tree");
});

test("atomic.click 非法输入也只写一次 input 阶段结构化结果", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);
  const writes = [];
  const atomic = createAtomicActions({ sky, ax, write: (text) => writes.push(text) });

  const result = await atomic.click({ app: "com.google.Chrome", target: [] });

  assert.equal(result.ok, false);
  assert.equal(result.stage, "input");
  assert.equal(result.error.code, "invalid_input");
  assert.equal(writes.length, 1);
  assert.deepEqual(JSON.parse(writes[0]), result);
  assert.equal(mock.calls.get_app_state, 0);
});

test("atomic.click 无法字符串化的异常仍只写一次结构化结果", async () => {
  const badError = Object.create(null);
  const ax = {
    async get() { throw badError; },
    findIdx() { return null; },
    summarize() { return {}; },
  };
  const writes = [];
  const atomic = createAtomicActions({
    sky: { async click() {} },
    ax,
    write: (text) => writes.push(text),
  });

  const result = await atomic.click({ app: "com.google.Chrome", target: ["工作流"] });

  assert.equal(result.ok, false);
  assert.equal(result.error.message, "Unknown error");
  assert.equal(writes.length, 1);
  assert.deepEqual(JSON.parse(writes[0]), result);
});

test("atomic.click 找不到目标时不点击，并写出 locate 阶段失败结果", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);
  const writes = [];
  const atomic = createAtomicActions({ sky, ax, write: (text) => writes.push(text) });

  const result = await atomic.click({
    app: "com.google.Chrome",
    target: [["按钮", "工作流"]],
  });

  assert.equal(result.ok, false);
  assert.equal(result.stage, "locate");
  assert.equal(result.error.code, "target_not_found");
  assert.equal(mock.calls.click, 0);
  assert.equal(mock.calls.get_app_state, 1);
  assert.equal(writes.length, 1);
  assert.deepEqual(JSON.parse(writes[0]), result);
});

test("atomic.click 不依赖 sky wrapper，点击后也强制重新取树", async () => {
  invalidateAxCache();
  const before = ["1 window Chrome", "28 按钮 工作流"].join("\n");
  const after = ["1 window Chrome", "40 按钮 新建工作流"].join("\n");
  const mock = createMockSky({
    stateProvider: (_input, count) => ({ text: count === 1 ? before : after }),
  });
  const ax = createAxHelpers(mock);
  const writes = [];
  const atomic = createAtomicActions({ sky: mock, ax, write: (text) => writes.push(text) });

  const result = await atomic.click({
    app: "com.google.Chrome",
    target: ["按钮", "工作流"],
    verify: ["新建工作流"],
  });

  assert.equal(result.ok, true);
  assert.equal(mock.calls.get_app_state, 2);
  assert.equal(writes.length, 1);
});

test("atomic.click 点击异常时捕获错误并写出 action 阶段失败结果", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  mock.click = async () => {
    mock.calls.click += 1;
    throw new Error("click exploded");
  };
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);
  const writes = [];
  const atomic = createAtomicActions({ sky, ax, write: (text) => writes.push(text) });

  const result = await atomic.click({
    app: "com.google.Chrome",
    target: [["按钮", "确定"]],
  });

  assert.equal(result.ok, false);
  assert.equal(result.stage, "action");
  assert.equal(result.error.code, "click_failed");
  assert.match(result.error.message, /click exploded/);
  assert.equal(mock.calls.click, 1);
  assert.equal(writes.length, 1);
  assert.deepEqual(JSON.parse(writes[0]), result);
});

test("atomic.click AX 处理异常也写出 process 阶段结构化结果", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  const ax = createAxHelpers(mock);
  const brokenAx = { ...ax, summarize: () => { throw new Error("summary exploded"); } };
  const writes = [];
  const atomic = createAtomicActions({ sky: mock, ax: brokenAx, write: (text) => writes.push(text) });

  const result = await atomic.click({
    app: "com.google.Chrome",
    target: ["按钮", "确定"],
  });

  assert.equal(result.ok, false);
  assert.equal(result.stage, "process");
  assert.equal(result.error.code, "ax_processing_failed");
  assert.match(result.error.message, /summary exploded/);
  assert.equal(writes.length, 1);
  assert.deepEqual(JSON.parse(writes[0]), result);
});

test("setupComputerUseRuntime 将 atomic 挂到目标 globals", async () => {
  const runtimeKey = Symbol.for("openai.computer-use.runtime");
  const axHelpersKey = Symbol.for("openai.computer-use.ax-helpers");
  const atomicActionsKey = Symbol.for("openai.computer-use.atomic-actions");
  const previous = new Map(
    [runtimeKey, axHelpersKey, atomicActionsKey].map((key) => [key, Reflect.get(globalThis, key)]),
  );
  const previousSky = globalThis.sky;
  const previousAx = globalThis.ax;
  const previousAtomic = globalThis.atomic;
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  const globals = {};

  try {
    Reflect.set(globalThis, runtimeKey, sky);
    Reflect.deleteProperty(globalThis, axHelpersKey);
    Reflect.deleteProperty(globalThis, atomicActionsKey);
    await setupComputerUseRuntime({ globals });

    assert.equal(typeof globals.atomic?.click, "function");
    assert.equal(globals.atomic, globalThis.atomic);
    assert.equal(globals.sky, sky);
    assert.equal(typeof globals.ax?.get, "function");
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) Reflect.deleteProperty(globalThis, key);
      else Reflect.set(globalThis, key, value);
    }
    if (previousSky === undefined) delete globalThis.sky;
    else globalThis.sky = previousSky;
    if (previousAx === undefined) delete globalThis.ax;
    else globalThis.ax = previousAx;
    if (previousAtomic === undefined) delete globalThis.atomic;
    else globalThis.atomic = previousAtomic;
  }
});

test("setupComputerUseRuntime 在 runtime 变化时同步重建 ax 与 atomic", async () => {
  const runtimeKey = Symbol.for("openai.computer-use.runtime");
  const axHelpersKey = Symbol.for("openai.computer-use.ax-helpers");
  const atomicActionsKey = Symbol.for("openai.computer-use.atomic-actions");
  const previous = new Map(
    [runtimeKey, axHelpersKey, atomicActionsKey].map((key) => [key, Reflect.get(globalThis, key)]),
  );
  const previousSky = globalThis.sky;
  const previousAx = globalThis.ax;
  const previousAtomic = globalThis.atomic;
  const currentSky = wrapSkyClient(createMockSky());
  const staleAx = { get: async () => ({ text: "stale" }), findIdx: () => 1, summarize: () => ({}) };
  const staleAtomic = { click: async () => ({ stale: true }) };

  try {
    Reflect.set(globalThis, runtimeKey, currentSky);
    Reflect.set(globalThis, axHelpersKey, staleAx);
    Reflect.set(globalThis, atomicActionsKey, staleAtomic);
    const globals = {};
    await setupComputerUseRuntime({ globals });

    assert.notEqual(globals.ax, staleAx);
    assert.notEqual(globals.atomic, staleAtomic);
    assert.equal(globals.ax, globalThis.ax);
    assert.equal(globals.atomic, globalThis.atomic);
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) Reflect.deleteProperty(globalThis, key);
      else Reflect.set(globalThis, key, value);
    }
    if (previousSky === undefined) delete globalThis.sky;
    else globalThis.sky = previousSky;
    if (previousAx === undefined) delete globalThis.ax;
    else globalThis.ax = previousAx;
    if (previousAtomic === undefined) delete globalThis.atomic;
    else globalThis.atomic = previousAtomic;
  }
});

test("setupComputerUseRuntime 清理旧 runtime 留下的 AX 快照缓存", async () => {
  const runtimeKey = Symbol.for("openai.computer-use.runtime");
  const previousRuntime = Reflect.get(globalThis, runtimeKey);
  const previousSky = globalThis.sky;
  const previousAx = globalThis.ax;
  const previousAtomic = globalThis.atomic;
  invalidateAxCache();

  const oldMock = createMockSky({ stateProvider: () => ({ text: "7 按钮 OLD" }) });
  await createAxHelpers(oldMock).get("com.google.Chrome");
  const currentMock = createMockSky({ stateProvider: () => ({ text: "9 按钮 NEW" }) });
  const currentSky = wrapSkyClient(currentMock);

  try {
    Reflect.set(globalThis, runtimeKey, currentSky);
    const globals = {};
    await setupComputerUseRuntime({ globals });
    const writes = [];
    const atomic = createAtomicActions({
      sky: globals.sky,
      ax: globals.ax,
      write: (text) => writes.push(text),
    });
    const result = await atomic.click({
      app: "com.google.Chrome",
      target: ["按钮", "NEW"],
      refreshBefore: false,
    });

    assert.equal(result.ok, true);
    assert.equal(result.target.elementIndex, 9);
    assert.equal(currentMock.calls.get_app_state, 2);
  } finally {
    invalidateAxCache();
    if (previousRuntime === undefined) Reflect.deleteProperty(globalThis, runtimeKey);
    else Reflect.set(globalThis, runtimeKey, previousRuntime);
    if (previousSky === undefined) delete globalThis.sky;
    else globalThis.sky = previousSky;
    if (previousAx === undefined) delete globalThis.ax;
    else globalThis.ax = previousAx;
    if (previousAtomic === undefined) delete globalThis.atomic;
    else globalThis.atomic = previousAtomic;
  }
});

test("setupComputerUseRuntime 重建 atomic 以绑定当前 sky 和 ax", async () => {
  const runtimeKey = Symbol.for("openai.computer-use.runtime");
  const axHelpersKey = Symbol.for("openai.computer-use.ax-helpers");
  const atomicActionsKey = Symbol.for("openai.computer-use.atomic-actions");
  const previous = new Map(
    [runtimeKey, axHelpersKey, atomicActionsKey].map((key) => [key, Reflect.get(globalThis, key)]),
  );
  const previousSky = globalThis.sky;
  const previousAx = globalThis.ax;
  const previousAtomic = globalThis.atomic;
  const firstSky = wrapSkyClient(createMockSky());
  const staleAtomic = { click: async () => ({ stale: true }) };

  try {
    Reflect.set(globalThis, runtimeKey, firstSky);
    Reflect.deleteProperty(globalThis, axHelpersKey);
    Reflect.set(globalThis, atomicActionsKey, staleAtomic);
    await setupComputerUseRuntime({ globals: {} });

    assert.notEqual(globalThis.atomic, staleAtomic);
    assert.equal(globalThis.atomic, Reflect.get(globalThis, atomicActionsKey));
  } finally {
    for (const [key, value] of previous) {
      if (value === undefined) Reflect.deleteProperty(globalThis, key);
      else Reflect.set(globalThis, key, value);
    }
    if (previousSky === undefined) delete globalThis.sky;
    else globalThis.sky = previousSky;
    if (previousAx === undefined) delete globalThis.ax;
    else globalThis.ax = previousAx;
    if (previousAtomic === undefined) delete globalThis.atomic;
    else globalThis.atomic = previousAtomic;
  }
});

test("atomic.click 默认通过 nodeRepl.write 输出，调用方无需手写", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);
  const writes = [];
  const previousNodeRepl = globalThis.nodeRepl;
  globalThis.nodeRepl = { write: (text) => writes.push(text) };

  try {
    const atomic = createAtomicActions({ sky, ax });
    const result = await atomic.click({
      app: "com.google.Chrome",
      target: ["按钮", "确定"],
    });

    assert.equal(result.ok, true);
    assert.equal(result.verification.mode, "post_action_snapshot");
    assert.equal(writes.length, 1);
    assert.deepEqual(JSON.parse(writes[0]), result);
  } finally {
    if (previousNodeRepl === undefined) delete globalThis.nodeRepl;
    else globalThis.nodeRepl = previousNodeRepl;
  }
});

test("atomic.click 验证条件不满足时写出 verify 阶段失败和点击后摘要", async () => {
  invalidateAxCache();
  const mock = createMockSky();
  const sky = wrapSkyClient(mock);
  const ax = createAxHelpers(sky);
  const writes = [];
  const atomic = createAtomicActions({ sky, ax, write: (text) => writes.push(text) });

  const result = await atomic.click({
    app: "com.google.Chrome",
    target: [["按钮", "确定"]],
    verify: [["创建成功"]],
  });

  assert.equal(result.ok, false);
  assert.equal(result.stage, "verify");
  assert.equal(result.error.code, "verification_failed");
  assert.equal(result.after.textLen, SAMPLE_AX_TEXT.length);
  assert.equal(mock.calls.get_app_state, 2);
  assert.equal(writes.length, 1);
  assert.deepEqual(JSON.parse(writes[0]), result);
});
