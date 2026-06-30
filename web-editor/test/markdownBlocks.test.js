import test from "node:test";
import assert from "node:assert/strict";
import {
  parseFencedCodeBlocks,
  parseTableBlocks,
  splitTableRow
} from "../src/markdownBlocks.js";

test("parses fenced code blocks with language and body", () => {
  const blocks = parseFencedCodeBlocks([
    "before",
    "```text",
    "line one",
    "line two",
    "```",
    "after"
  ].join("\n"));

  assert.equal(blocks.length, 1);
  assert.equal(blocks[0].info, "text");
  assert.equal(blocks[0].code, "line one\nline two");
  assert.equal(blocks[0].startLine, 2);
  assert.equal(blocks[0].endLine, 5);
  assert.equal(blocks[0].closed, true);
});

test("parses GFM table blocks and alignments", () => {
  const blocks = parseTableBlocks([
    "| 원인 | 사용자 짜증 |",
    "| :--- | ---: |",
    "| 선택 과다 | 후보를 골라야 함 |",
    "| 실패 회피 | 선택 실패가 무서움 |"
  ].join("\n"));

  assert.equal(blocks.length, 1);
  assert.deepEqual(blocks[0].header, ["원인", "사용자 짜증"]);
  assert.deepEqual(blocks[0].alignments, ["left", "right"]);
  assert.deepEqual(blocks[0].rows[1], ["실패 회피", "선택 실패가 무서움"]);
});

test("does not parse table-looking lines inside code fences", () => {
  const markdown = [
    "```md",
    "| raw | code |",
    "| --- | --- |",
    "```",
    "",
    "| real | table |",
    "| --- | --- |",
    "| yes | rendered |"
  ].join("\n");
  const codeBlocks = parseFencedCodeBlocks(markdown);
  const tableBlocks = parseTableBlocks(markdown, codeBlocks);

  assert.equal(tableBlocks.length, 1);
  assert.deepEqual(tableBlocks[0].header, ["real", "table"]);
});

test("splits escaped pipe cells", () => {
  assert.deepEqual(splitTableRow("| a\\|b | c |"), ["a|b", "c"]);
});
