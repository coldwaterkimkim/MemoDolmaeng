import test from "node:test";
import assert from "node:assert/strict";
import {
  markdownListEnterEdit,
  markdownListIndentEdit,
  parseListMarker
} from "../src/markdownListEditing.js";

test("continues ordered lists at the same level", () => {
  const line = "1. ㅁㄴㅇㄹ";
  const edit = markdownListEnterEdit(line, line.length);

  assert.deepEqual(edit, {
    type: "continue",
    insert: "\n2. "
  });
});

test("exits an empty list item immediately", () => {
  assert.deepEqual(markdownListEnterEdit("- ", 2), {
    type: "exit",
    fromOffset: 0,
    toOffset: 2,
    insert: "",
    cursorOffset: 0
  });

  assert.deepEqual(markdownListEnterEdit("   1. ", 6), {
    type: "exit",
    fromOffset: 0,
    toOffset: 6,
    insert: "",
    cursorOffset: 0
  });
});

test("indents ordered list items as nested lists starting from 1", () => {
  const edit = markdownListIndentEdit("2. 테스트", false);

  assert.deepEqual(edit, {
    fromOffset: 0,
    toOffset: 3,
    insert: "   1. "
  });
});

test("continues nested ordered lists from their nested number", () => {
  const marker = parseListMarker("   1. 테스트");

  assert.equal(marker.next, "   2. ");
});

test("outdents nested list items by one markdown indent level", () => {
  const edit = markdownListIndentEdit("   2. 테스트", true);

  assert.deepEqual(edit, {
    fromOffset: 0,
    toOffset: 3,
    insert: ""
  });
});

test("indents task list items without changing their checked state", () => {
  const edit = markdownListIndentEdit("- [x] done", false);

  assert.deepEqual(edit, {
    fromOffset: 0,
    toOffset: 6,
    insert: "   - [x] "
  });
});
