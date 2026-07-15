import assert from "node:assert/strict";
import test from "node:test";

import {
  editorToStorageMarkdown,
  isSafeHexColor,
  storageToEditorMarkdown
} from "../src/milkdownExtensions.js";

test("alignment wrappers become invisible editor markers and round-trip", () => {
  const stored = [
    "앞 문단",
    "",
    "<div style=\"text-align: center;\">",
    "가운데 문단",
    "</div>",
    "",
    "뒤 문단"
  ].join("\n");

  const editor = storageToEditorMarkdown(stored);
  assert.equal(editor.includes("<div"), false);
  assert.equal(editor.includes("가운데 문단<!--memo-align:center-->"), true);
  assert.equal(editorToStorageMarkdown(editor), stored);
});

test("only strict six-digit hex colors are accepted", () => {
  assert.equal(isSafeHexColor("#D93434"), true);
  assert.equal(isSafeHexColor("#fff"), false);
  assert.equal(isSafeHexColor("red"), false);
  assert.equal(isSafeHexColor("#000000; background:url(x)"), false);
});

test("unknown HTML is untouched by alignment conversion", () => {
  const markdown = "<details data-safe=\"keep\">\n내용\n</details>";
  assert.equal(storageToEditorMarkdown(markdown), markdown);
  assert.equal(editorToStorageMarkdown(markdown), markdown);
});
