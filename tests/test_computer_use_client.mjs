// node --test tests/test_computer_use_client.mjs
//
// 覆盖 AX helpers 的缓存与失效语义，保证：
//   1. 同 app 相邻 ax.get 命中缓存，只调一次 sky.get_app_state
//   2. sky.click / set_value / press_key / scroll 等 mutation 后自动失效
//   3. 无 app 参数（坐标点击）保守失效全部缓存
//   4. sky.get_app_state({app, disableDiff:true}) 回填缓存，与 ax.get 共用

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
  wrapSkyClient,
  invalidateAxCache,
} from "../scripts/computer-use-client.mjs";

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

test("ax.get({refresh:true}) 强制绕过缓存", async () => {
  invalidateAxCache();
  const sky = createMockSky();
  const ax = createAxHelpers(sky);
  await ax.get("com.google.Chrome");
  await ax.get("com.google.Chrome", { refresh: true });
  assert.equal(sky.calls.get_app_state, 2);
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
