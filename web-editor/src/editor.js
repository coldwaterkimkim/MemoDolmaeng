import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown } from "@codemirror/lang-markdown";
import { EditorSelection, EditorState, Prec, RangeSetBuilder, StateField } from "@codemirror/state";
import { Decoration, EditorView, keymap, WidgetType } from "@codemirror/view";
import {
  markdownFromClipboardData,
  markdownFromClipboardPayload,
  semanticTextColor
} from "./markdownPasteImporter.js";
import {
  looksLikeTableLine,
  parseFencedCodeBlocks,
  parseTableBlocks
} from "./markdownBlocks.js";
import {
  markdownListEnterEdit,
  markdownListIndentEdit
} from "./markdownListEditing.js";

const bridge = window.webkit?.messageHandlers;

let editorView = null;
let applyingExternalUpdate = false;
let recentPairedInput = null;
let pairedInputCorrectionTimer = null;
let pairedInputDriftPollTimer = null;
let pairRunCleanupTimer = null;
let normalizingPairedInput = false;

class TaskWidget extends WidgetType {
  constructor(checked) {
    super();
    this.checked = checked;
  }

  eq(other) {
    return other.checked === this.checked;
  }

  toDOM() {
    const element = document.createElement("span");
    element.className = "memo-md-task-widget";
    element.textContent = this.checked ? "☑ " : "☐ ";
    return element;
  }

  ignoreEvent() {
    return false;
  }
}

class LanguageWidget extends WidgetType {
  constructor(language) {
    super();
    this.language = language || "code";
  }

  eq(other) {
    return other.language === this.language;
  }

  toDOM() {
    const element = document.createElement("span");
    element.className = "memo-md-code-language";
    element.textContent = this.language;
    return element;
  }
}

class CodeBlockWidget extends WidgetType {
  constructor(block) {
    super();
    this.block = block;
  }

  eq(other) {
    return other.block.from === this.block.from
      && other.block.to === this.block.to
      && other.block.info === this.block.info
      && other.block.code === this.block.code;
  }

  toDOM(view) {
    const wrapper = document.createElement("div");
    wrapper.className = "memo-md-rendered-block memo-md-rendered-code";
    wrapper.addEventListener("mousedown", (event) => activateRenderedBlock(event, view, this.block.from));

    if (this.block.info) {
      const label = document.createElement("div");
      label.className = "memo-md-rendered-code-label";
      label.textContent = this.block.info;
      wrapper.appendChild(label);
    }

    const pre = document.createElement("pre");
    const code = document.createElement("code");
    code.textContent = this.block.code || "\u200b";
    pre.appendChild(code);
    wrapper.appendChild(pre);
    return wrapper;
  }

  ignoreEvent() {
    return false;
  }
}

class TableWidget extends WidgetType {
  constructor(block) {
    super();
    this.block = block;
  }

  eq(other) {
    return other.block.from === this.block.from
      && other.block.to === this.block.to
      && JSON.stringify(other.block.header) === JSON.stringify(this.block.header)
      && JSON.stringify(other.block.rows) === JSON.stringify(this.block.rows)
      && JSON.stringify(other.block.alignments) === JSON.stringify(this.block.alignments);
  }

  toDOM(view) {
    const wrapper = document.createElement("div");
    wrapper.className = "memo-md-rendered-block memo-md-table-widget";
    wrapper.addEventListener("mousedown", (event) => activateRenderedBlock(event, view, this.block.from));

    const scroller = document.createElement("div");
    scroller.className = "memo-md-table-scroll";
    const table = document.createElement("table");
    const columnCount = tableColumnCount(this.block);

    const thead = document.createElement("thead");
    thead.appendChild(renderTableRow("th", paddedCells(this.block.header, columnCount), this.block.alignments));
    table.appendChild(thead);

    const tbody = document.createElement("tbody");
    for (const row of this.block.rows) {
      tbody.appendChild(renderTableRow("td", paddedCells(row, columnCount), this.block.alignments));
    }
    table.appendChild(tbody);

    scroller.appendChild(table);
    wrapper.appendChild(scroller);
    return wrapper;
  }

  ignoreEvent() {
    return false;
  }
}

function activateRenderedBlock(event, view, position) {
  if (event.button !== 0) return;

  event.preventDefault();
  view.focus();
  view.dispatch({
    selection: EditorSelection.cursor(position),
    scrollIntoView: true,
    userEvent: "select.pointer"
  });
}

function tableColumnCount(block) {
  return Math.max(
    block.header.length,
    block.alignments.length,
    ...block.rows.map((row) => row.length),
    1
  );
}

function paddedCells(cells, count) {
  const padded = [...cells];
  while (padded.length < count) {
    padded.push("");
  }
  return padded.slice(0, count);
}

function renderTableRow(cellTag, cells, alignments) {
  const row = document.createElement("tr");

  cells.forEach((value, index) => {
    const cell = document.createElement(cellTag);
    const alignment = alignments[index] || "left";
    cell.className = `memo-md-table-align-${alignment}`;
    cell.textContent = value || "\u00a0";
    row.appendChild(cell);
  });

  return row;
}

const markdownDecorations = StateField.define({
  create(state) {
    return buildMarkdownDecorations(state);
  },

  update(decorations, transaction) {
    if (transaction.docChanged || transaction.selection) {
      return buildMarkdownDecorations(transaction.state);
    }
    return decorations;
  },

  provide(field) {
    return EditorView.decorations.from(field);
  }
});

function post(name, value) {
  bridge?.[name]?.postMessage(value);
}

function buildMarkdownDecorations(state) {
  const items = [];
  const activeLines = activeLineNumbers(state);
  const markdownText = state.doc.toString();
  const codeBlocks = parseFencedCodeBlocks(markdownText);
  const tableBlocks = parseTableBlocks(markdownText, codeBlocks);
  const codeLines = fencedCodeLineMap(codeBlocks);
  const replacedLines = addRenderedBlockDecorations(codeBlocks, tableBlocks, activeLines, items);

  for (let number = 1; number <= state.doc.lines; number += 1) {
    if (!replacedLines.has(number)) {
      const line = state.doc.line(number);
      decorateLine(line, activeLines.has(line.number), codeLines.get(line.number), items);
    }
  }

  items.sort((lhs, rhs) => {
    if (lhs.from !== rhs.from) return lhs.from - rhs.from;
    if (lhs.to !== rhs.to) return lhs.to - rhs.to;
    return lhs.rank - rhs.rank;
  });

  const builder = new RangeSetBuilder();
  let lastFrom = 0;
  for (const item of items) {
    if (item.from < lastFrom) {
      continue;
    }
    builder.add(item.from, item.to, item.decoration);
    lastFrom = item.from;
  }

  return builder.finish();
}

function addRenderedBlockDecorations(codeBlocks, tableBlocks, activeLines, items) {
  const replacedLines = new Set();
  const blocks = [
    ...codeBlocks.map((block) => ({ ...block, renderKind: "code" })),
    ...tableBlocks.map((block) => ({ ...block, renderKind: "table" }))
  ].sort((lhs, rhs) => lhs.from - rhs.from);

  for (const block of blocks) {
    if (blockContainsActiveLine(block, activeLines)) {
      continue;
    }

    items.push({
      from: block.from,
      to: block.to,
      rank: -1,
      decoration: Decoration.replace({
        block: true,
        widget: block.renderKind === "code"
          ? new CodeBlockWidget(block)
          : new TableWidget(block)
      })
    });

    for (let line = block.startLine; line <= block.endLine; line += 1) {
      replacedLines.add(line);
    }
  }

  return replacedLines;
}

function blockContainsActiveLine(block, activeLines) {
  for (let line = block.startLine; line <= block.endLine; line += 1) {
    if (activeLines.has(line)) return true;
  }
  return false;
}

function activeLineNumbers(state) {
  const lines = new Set();
  for (const range of state.selection.ranges) {
    lines.add(state.doc.lineAt(range.head).number);
  }
  return lines;
}

function fencedCodeLineMap(blocks) {
  const map = new Map();

  for (const block of blocks) {
    for (let number = block.startLine; number <= block.endLine; number += 1) {
      if (number === block.startLine) {
        map.set(number, { role: "start", markerLength: block.openingMarkerLength, info: block.info });
      } else if (block.closed && number === block.endLine) {
        map.set(number, { role: "end", markerLength: block.closingMarkerLength, info: block.info });
      } else {
        map.set(number, { role: "body", markerLength: 0, info: block.info });
      }
    }
  }

  return map;
}

function decorateLine(line, isActive, codeInfo, items) {
  const text = line.text;
  const trimmed = text.trim();

  if (codeInfo) {
    addLineClass(
      items,
      line,
      [
        "memo-md-code-line",
        codeInfo.role === "start" ? "memo-md-code-start" : "",
        codeInfo.role === "end" ? "memo-md-code-end" : ""
      ].filter(Boolean).join(" ")
    );

    if (codeInfo.role === "start") {
      decorateFenceMarker(line, codeInfo, isActive, items);
    } else if (codeInfo.role === "end") {
      decorateMarker(line.from, line.from + codeInfo.markerLength, isActive, items);
    }
    return;
  }

  const heading = text.match(/^(\s*)(#{1,6})\s+(.+)$/);
  if (heading) {
    const level = Math.min(heading[2].length, 6);
    addLineClass(items, line, `memo-md-heading memo-md-heading-${level}`);
    decorateMarker(line.from + heading[1].length, line.from + heading[1].length + heading[2].length + 1, isActive, items);
  }

  const blockquote = text.match(/^(\s{0,3})>\s?/);
  if (blockquote) {
    addLineClass(items, line, "memo-md-quote");
    decorateMarker(line.from + blockquote[1].length, line.from + blockquote[0].length, isActive, items);
  }

  const task = text.match(/^(\s*)[-*+]\s+\[([ xX])\]\s+/);
  if (task) {
    addLineClass(items, line, "memo-md-list");
    const from = line.from + task[1].length;
    const to = line.from + task[0].length;
    if (isActive) {
      decorateMarker(from, to, true, items);
    } else {
      items.push({
        from,
        to,
        rank: 1,
        decoration: Decoration.replace({ widget: new TaskWidget(task[2].toLowerCase() === "x") })
      });
    }
  } else if (/^\s*(?:[-*+]\s+|\d+[.)]\s+)/.test(text)) {
    addLineClass(items, line, "memo-md-list");
  }

  if (/^\s{0,3}([-*_])(?:\s*\1){2,}\s*$/.test(text)) {
    addLineClass(items, line, "memo-md-hr");
    if (!isActive && trimmed.length > 0) {
      items.push({
        from: line.from,
        to: line.to,
        rank: 1,
        decoration: Decoration.replace({})
      });
    }
  }

  if (looksLikeTableLine(text)) {
    addLineClass(items, line, "memo-md-table");
  }

  if (/^\s*\$\$\s*$/.test(text)) {
    addLineClass(items, line, "memo-md-math");
  }

  decorateInline(line, isActive, items);
}

function decorateFenceMarker(line, codeInfo, isActive, items) {
  const from = line.from;
  const markerTo = line.from + codeInfo.markerLength;
  decorateMarker(from, markerTo, isActive, items);

  if (codeInfo.info && !isActive) {
    items.push({
      from: markerTo,
      to: line.to,
      rank: 1,
      decoration: Decoration.replace({ widget: new LanguageWidget(codeInfo.info) })
    });
  } else if (line.to > markerTo) {
    addMark(items, markerTo, line.to, "memo-md-muted-marker");
  }
}

function decorateInline(line, isActive, items) {
  const text = line.text;

  addDelimited(items, line, /`([^`\n]+)`/g, 1, 1, "memo-md-inline-code", isActive);
  addDelimited(items, line, /\*\*([^*\n]+)\*\*/g, 2, 2, "memo-md-strong", isActive);
  addDelimited(items, line, /__([^_\n]+)__/g, 2, 2, "memo-md-strong", isActive);
  addDelimited(items, line, /~~([^~\n]+)~~/g, 2, 2, "memo-md-strike", isActive);
  addDelimited(items, line, /\$([^$\n]+)\$/g, 1, 1, "memo-md-math", isActive);

  for (const match of text.matchAll(/(^|[^\*])\*([^*\n]+)\*(?!\*)/g)) {
    const prefixLength = match[1].length;
    const markerStart = line.from + match.index + prefixLength;
    const contentStart = markerStart + 1;
    const contentEnd = contentStart + match[2].length;
    addEmphasis(items, markerStart, contentStart, contentEnd, contentEnd + 1, "memo-md-emphasis", isActive);
  }

  for (const match of text.matchAll(/(^|[^_])_([^_\n]+)_(?!_)/g)) {
    const prefixLength = match[1].length;
    const markerStart = line.from + match.index + prefixLength;
    const contentStart = markerStart + 1;
    const contentEnd = contentStart + match[2].length;
    addEmphasis(items, markerStart, contentStart, contentEnd, contentEnd + 1, "memo-md-emphasis", isActive);
  }

  for (const match of text.matchAll(/\[([^\]\n]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/g)) {
    const from = line.from + match.index;
    const labelFrom = from + 1;
    const labelTo = labelFrom + match[1].length;
    const to = from + match[0].length;
    addMark(items, labelFrom, labelTo, "memo-md-link");
    if (isActive) {
      addMark(items, from, labelFrom, "memo-md-muted-marker");
      addMark(items, labelTo, to, "memo-md-muted-marker");
    } else {
      items.push({ from, to: labelFrom, rank: 1, decoration: Decoration.replace({}) });
      items.push({ from: labelTo, to, rank: 1, decoration: Decoration.replace({}) });
    }
  }

  for (const match of text.matchAll(/<((?:https?:\/\/|mailto:)[^>\s]+)>/g)) {
    const from = line.from + match.index;
    const to = from + match[0].length;
    addMark(items, from, to, "memo-md-link");
  }

  for (const match of text.matchAll(/\[\^([^\]\s]+)\]/g)) {
    const from = line.from + match.index;
    addMark(items, from, from + match[0].length, "memo-md-footnote");
  }

  for (const match of text.matchAll(/<span\s+style="color:\s*(#[0-9a-fA-F]{6})">([^<\n]+)<\/span>/g)) {
    const color = semanticTextColor(match[1]);
    if (!color) continue;

    const from = line.from + match.index;
    const contentFrom = from + match[0].indexOf(">") + 1;
    const contentTo = contentFrom + match[2].length;
    const to = from + match[0].length;
    addStyleMark(items, contentFrom, contentTo, "memo-md-color-text", `color: ${color}; -webkit-text-fill-color: ${color};`);

    if (isActive) {
      addMark(items, from, contentFrom, "memo-md-muted-marker");
      addMark(items, contentTo, to, "memo-md-muted-marker");
    } else {
      items.push({ from, to: contentFrom, rank: 1, decoration: Decoration.replace({}) });
      items.push({ from: contentTo, to, rank: 1, decoration: Decoration.replace({}) });
    }
  }
}

function addDelimited(items, line, regex, openLength, closeLength, className, isActive) {
  for (const match of line.text.matchAll(regex)) {
    const from = line.from + match.index;
    const contentFrom = from + openLength;
    const contentTo = from + match[0].length - closeLength;
    const to = from + match[0].length;
    addEmphasis(items, from, contentFrom, contentTo, to, className, isActive);
  }
}

function addEmphasis(items, openFrom, contentFrom, contentTo, closeTo, className, isActive) {
  addMark(items, contentFrom, contentTo, className);

  if (isActive) {
    addMark(items, openFrom, contentFrom, "memo-md-muted-marker");
    addMark(items, contentTo, closeTo, "memo-md-muted-marker");
  } else {
    items.push({ from: openFrom, to: contentFrom, rank: 1, decoration: Decoration.replace({}) });
    items.push({ from: contentTo, to: closeTo, rank: 1, decoration: Decoration.replace({}) });
  }
}

function decorateMarker(from, to, isActive, items) {
  if (from >= to) return;

  if (isActive) {
    addMark(items, from, to, "memo-md-muted-marker");
  } else {
    items.push({ from, to, rank: 1, decoration: Decoration.replace({}) });
  }
}

function addLineClass(items, line, className) {
  items.push({
    from: line.from,
    to: line.from,
    rank: 0,
    decoration: Decoration.line({ class: className })
  });
}

function addMark(items, from, to, className) {
  if (from >= to) return;
  items.push({
    from,
    to,
    rank: 2,
    decoration: Decoration.mark({ class: className })
  });
}

function addStyleMark(items, from, to, className, style) {
  if (from >= to) return;
  items.push({
    from,
    to,
    rank: 2,
    decoration: Decoration.mark({
      class: className,
      attributes: { style }
    })
  });
}

function createState(markdownText) {
  return EditorState.create({
    doc: markdownText || "",
    extensions: [
      history(),
      markdown(),
      EditorView.lineWrapping,
      markdownDecorations,
      EditorView.inputHandler.of(handlePairedTextInput),
      keymap.of(markdownKeymap),
      keymap.of(historyKeymap),
      keymap.of(defaultKeymap),
      EditorView.updateListener.of((update) => {
        observePairedInputUpdate(update);

        if (update.docChanged && !applyingExternalUpdate) {
          post("editorChanged", { markdown: update.state.doc.toString() });
          scheduleHeightPublish(update.view);
        }

        if (update.focusChanged) {
          post("editorFocusChanged", { focused: update.view.hasFocus });
        }

        if (update.geometryChanged || update.viewportChanged) {
          scheduleHeightPublish(update.view);
        }
      }),
      Prec.highest(EditorView.domEventHandlers({
        keydown(event, view) {
          if (isLeftArrowEvent(event) && handlePairedInputArrowLeft(view)) {
            event.preventDefault();
            return true;
          }

          return false;
        },
        keyup(event, view) {
          if (isLeftArrowEvent(event) && recentPairedInput) {
            schedulePairedInputCorrection(view);
          }

          return false;
        },
        paste(event, view) {
          const text = markdownFromClipboardData(event.clipboardData);
          if (!text) return false;

          event.preventDefault();
          view.dispatch(view.state.replaceSelection(text));
          return true;
        }
      }))
    ]
  });
}

const pairedTextInputs = new Map([
  ["[]", ["[", "]"]],
  ["[[]", ["[", "]"]],
  ["''", ["'", "'"]],
  ["'''", ["'", "'"]],
  ['""', ['"', '"']],
  ['"""', ['"', '"']],
  ["<>", ["<", ">"]],
  ["<<>", ["<", ">"]]
]);

const openerPairs = new Map([
  ["[", "]"],
  ["'", "'"],
  ['"', '"'],
  ["<", ">"]
]);

const closers = new Set([...openerPairs.values()]);
const pairedInputCorrectionWindowMs = 1600;

function handlePairedTextInput(view, from, to, text) {
  const explicitPair = pairedTextInputs.get(text);
  if (explicitPair) {
    return insertNormalizedPair(view, from, to, explicitPair[0], explicitPair[1]);
  }

  const close = openerPairs.get(text);
  if (close) {
    return insertNormalizedPair(view, from, to, text, close);
  }

  if (closers.has(text) && from === to && view.state.sliceDoc(from, from + text.length) === text) {
    view.dispatch({
      selection: EditorSelection.cursor(from + text.length),
      userEvent: "input.type"
    });
    return true;
  }

  return false;
}

function insertNormalizedPair(view, from, to, open, close) {
  const selected = view.state.sliceDoc(from, to);
  let replaceFrom = from;
  let replaceTo = to;

  if (from === to && from > 0 && view.state.sliceDoc(from - 1, from) === open) {
    replaceFrom = from - 1;
    if (view.state.sliceDoc(from, from + close.length) === close) {
      replaceTo = from + close.length;
    }
  }

  const insert = selected ? `${open}${selected}${close}` : `${open}${close}`;
  rememberPairedInput(replaceFrom, open, close);
  view.dispatch({
    changes: { from: replaceFrom, to: replaceTo, insert },
    selection: selected
      ? EditorSelection.range(replaceFrom + open.length, replaceFrom + open.length + selected.length)
      : EditorSelection.cursor(replaceFrom + open.length),
    userEvent: "input.type"
  });
  return true;
}

function observePairedInputUpdate(update) {
  if (normalizingPairedInput || applyingExternalUpdate) return;

  let shouldCleanupPairRun = false;
  if (update.docChanged) {
    update.changes.iterChanges((_fromA, _toA, fromB, _toB, inserted) => {
      const text = inserted.toString();
      const pair = pairForInsertedText(text);
      if (pair) {
        rememberPairedInput(fromB, pair[0], pair[1]);
      }
      if (isPairedRunText(text)) {
        shouldCleanupPairRun = true;
      }
    });
  }

  if (recentPairedInput && (update.docChanged || update.selectionSet)) {
    schedulePairedInputCorrection(update.view);
  }

  if (shouldCleanupPairRun) {
    schedulePairRunCleanup(update.view);
  }
}

function pairForInsertedText(text) {
  const explicitPair = pairedTextInputs.get(text);
  if (explicitPair) return explicitPair;

  const close = openerPairs.get(text);
  if (close) return [text, close];

  return null;
}

function rememberPairedInput(from, open, close) {
  recentPairedInput = {
    from,
    open,
    close,
    expiresAt: Date.now() + pairedInputCorrectionWindowMs
  };
  startPairedInputDriftPoll();
}

function schedulePairedInputCorrection(view) {
  if (pairedInputCorrectionTimer !== null) {
    window.clearTimeout(pairedInputCorrectionTimer);
  }

  pairedInputCorrectionTimer = window.setTimeout(() => {
    pairedInputCorrectionTimer = null;
    correctRecentPairedInput(view);
  }, 12);
}

function schedulePairRunCleanup(view) {
  if (pairRunCleanupTimer !== null) {
    window.clearTimeout(pairRunCleanupTimer);
  }

  pairRunCleanupTimer = window.setTimeout(() => {
    pairRunCleanupTimer = null;
    cleanupPairRunAroundSelection(view);
  }, 20);
}

function startPairedInputDriftPoll() {
  if (pairedInputDriftPollTimer !== null) return;

  const poll = () => {
    if (!recentPairedInput || Date.now() > recentPairedInput.expiresAt) {
      recentPairedInput = null;
      pairedInputDriftPollTimer = null;
      return;
    }

    if (editorView) {
      correctRecentPairedInput(editorView);
      correctDomSelectionPairDrift(editorView);
      cleanupPairRunAroundSelection(editorView);
    }

    pairedInputDriftPollTimer = window.setTimeout(poll, 40);
  };

  pairedInputDriftPollTimer = window.setTimeout(poll, 40);
}

function cleanupPairRunAroundSelection(view) {
  const selection = view.state.selection.main;
  if (!selection.empty) return false;

  for (const [open, close] of openerPairs.entries()) {
    if (normalizePairRunAt(view, selection.from, open, close)) {
      return true;
    }
  }

  return false;
}

function correctRecentPairedInput(view) {
  const candidate = recentPairedInput;
  if (!candidate || Date.now() > candidate.expiresAt) {
    recentPairedInput = null;
    return;
  }

  const selection = view.state.selection.main;
  if (!selection.empty) return;

  if (normalizePairRunAt(view, candidate.from, candidate.open, candidate.close)) {
    return;
  }

  const positions = Array.from(new Set([candidate.from, selection.from]))
    .filter((position) => position >= 0 && position <= view.state.doc.length);

  for (const position of positions) {
    if (selection.from !== position) continue;
    if (restorePairedInputAt(view, position, candidate.open, candidate.close)) {
      return;
    }
  }
}

function restorePairedInputAt(view, position, open, close) {
  const pair = `${open}${close}`;
  const textAtCursor = view.state.sliceDoc(position, position + pair.length);

  if (textAtCursor === pair) {
    normalizingPairedInput = true;
    view.dispatch({
      selection: EditorSelection.cursor(position + open.length),
      userEvent: "select"
    });
    normalizingPairedInput = false;
    return true;
  }

  const openAtCursor = view.state.sliceDoc(position, position + open.length);
  const closeAfterOpen = view.state.sliceDoc(
    position + open.length,
    position + open.length + close.length
  );

  if (openAtCursor === open && closeAfterOpen !== close) {
    normalizingPairedInput = true;
    view.dispatch({
      changes: { from: position, to: position + open.length, insert: pair },
      selection: EditorSelection.cursor(position + open.length),
      userEvent: "input.type"
    });
    normalizingPairedInput = false;
    rememberPairedInput(position, open, close);
    return true;
  }

  return false;
}

function normalizePairRunAt(view, position, open, close) {
  const selection = view.state.selection.main;
  if (!selection.empty) return false;

  const pair = `${open}${close}`;
  const pairedChars = new Set(open === close ? [open] : [open, close]);
  let from = Math.max(0, position);
  let to = from;

  while (from > 0 && position - from < 12 && pairedChars.has(view.state.sliceDoc(from - 1, from))) {
    from -= 1;
  }

  while (to < view.state.doc.length && to - from < 16 && pairedChars.has(view.state.sliceDoc(to, to + 1))) {
    to += 1;
  }

  const run = view.state.sliceDoc(from, to);
  if (!run || !run.includes(open)) return false;
  if (open !== close && !run.includes(close) && run.length === open.length) return false;
  if (open === close && run.length < open.length * 2) return false;

  const cursor = from + open.length;
  if (run === pair && selection.from === cursor) return false;

  normalizingPairedInput = true;
  const transaction = run === pair
    ? { selection: EditorSelection.cursor(cursor), userEvent: "select" }
    : {
        changes: { from, to, insert: pair },
        selection: EditorSelection.cursor(cursor),
        userEvent: "input.type"
      };
  view.dispatch(transaction);
  normalizingPairedInput = false;
  rememberPairedInput(from, open, close);
  return true;
}

function correctDomSelectionPairDrift(view) {
  const candidate = recentPairedInput;
  if (!candidate) return false;

  const selection = document.getSelection();
  if (!selection?.isCollapsed || !selection.anchorNode || !view.dom.contains(selection.anchorNode)) {
    return false;
  }

  let position;
  try {
    position = view.posAtDOM(selection.anchorNode, selection.anchorOffset);
  } catch {
    return false;
  }

  if (position !== candidate.from) return false;

  return restorePairedInputAt(view, candidate.from, candidate.open, candidate.close);
}

function handlePairedInputArrowLeft(view) {
  const candidate = recentPairedInput;
  if (!candidate || Date.now() > candidate.expiresAt) {
    recentPairedInput = null;
    return false;
  }

  const selection = view.state.selection.main;
  if (!selection.empty) return false;

  const insidePosition = candidate.from + candidate.open.length;
  if (selection.from !== insidePosition) return false;

  return restorePairedInputAt(view, candidate.from, candidate.open, candidate.close);
}

function isLeftArrowEvent(event) {
  return event.key === "ArrowLeft"
    || event.key === "Left"
    || event.code === "ArrowLeft"
    || event.keyCode === 37;
}

function isPairedRunText(text) {
  if (!text) return false;
  for (const character of text) {
    if (!openerPairs.has(character) && !closers.has(character)) {
      return false;
    }
  }
  return true;
}

const markdownKeymap = [
  { key: "[", run: (view) => normalizeDuplicateOpenerCommand(view, "[", "]") },
  { key: "]", run: (view) => skipExistingCloserCommand(view, "]") },
  { key: "'", run: (view) => normalizeQuotePairCommand(view, "'") },
  { key: '"', run: (view) => normalizeQuotePairCommand(view, '"') },
  { key: "<", run: (view) => normalizeDuplicateOpenerCommand(view, "<", ">") },
  { key: ">", run: (view) => skipExistingCloserCommand(view, ">") },
  { key: "Mod-w", run: () => runAppCommand("closeNote") },
  { key: "Mod-n", run: () => runAppCommand("newNote") },
  { key: "Mod-Alt-f", run: () => runAppCommand("toggleFloatOnTop") },
  { key: "Mod-Alt-t", run: () => runAppCommand("toggleTranslucent") },
  { key: "Mod-a", run: selectAllMarkdown },
  { key: "Enter", run: continueMarkdownList },
  { key: "Tab", run: (view) => adjustMarkdownIndent(view, false) },
  { key: "Shift-Tab", run: (view) => adjustMarkdownIndent(view, true) },
  { key: "Mod-b", run: () => runEditorCommand("bold") },
  { key: "Mod-i", run: () => runEditorCommand("italic") },
  { key: "Mod-e", run: () => runEditorCommand("inlineCode") },
  { key: "Mod-k", run: () => runEditorCommand("link") },
  { key: "Mod-Alt-0", run: () => runEditorCommand("body") },
  { key: "Mod-Alt-1", run: () => runEditorCommand("heading1") },
  { key: "Mod-Alt-2", run: () => runEditorCommand("heading2") },
  { key: "Mod-Alt-3", run: () => runEditorCommand("heading3") },
  { key: "Mod-Shift-8", run: () => runEditorCommand("bullet") },
  { key: "Mod-Shift-7", run: () => runEditorCommand("numbered") },
  { key: "Mod-Alt-q", run: () => runEditorCommand("quote") },
  { key: "Mod-Alt-c", run: () => runEditorCommand("checkbox") }
];

function runAppCommand(command) {
  post("editorAppCommand", { command });
  return true;
}

function normalizeDuplicateOpenerCommand(view, open, close) {
  const selection = view.state.selection.main;
  if (!selection.empty) return false;

  if (selection.from === 0 || view.state.sliceDoc(selection.from - open.length, selection.from) !== open) {
    rememberPairedInput(selection.from, open, close);
    return false;
  }

  view.dispatch({
    changes: { from: selection.from - open.length, to: selection.to, insert: `${open}${close}` },
    selection: EditorSelection.cursor(selection.from),
    userEvent: "input.type"
  });
  return true;
}

function skipExistingCloserCommand(view, close) {
  const selection = view.state.selection.main;
  if (!selection.empty) return false;
  if (view.state.sliceDoc(selection.from, selection.from + close.length) !== close) return false;

  view.dispatch({
    selection: EditorSelection.cursor(selection.from + close.length),
    userEvent: "input.type"
  });
  return true;
}

function normalizeQuotePairCommand(view, quote) {
  return skipExistingCloserCommand(view, quote)
    || normalizeDuplicateOpenerCommand(view, quote, quote);
}

function continueMarkdownList(view) {
  const selection = view.state.selection.main;
  if (!selection.empty) return false;

  const line = view.state.doc.lineAt(selection.head);
  const offset = selection.head - line.from;
  const edit = markdownListEnterEdit(line.text, offset);
  if (!edit) return false;

  if (edit.type === "exit") {
    view.dispatch({
      changes: {
        from: line.from + edit.fromOffset,
        to: line.from + edit.toOffset,
        insert: edit.insert
      },
      selection: EditorSelection.cursor(line.from + edit.cursorOffset),
      userEvent: "input"
    });
    return true;
  }

  view.dispatch({
    changes: { from: selection.head, insert: edit.insert },
    selection: EditorSelection.cursor(selection.head + edit.insert.length),
    userEvent: "input"
  });
  return true;
}

function adjustMarkdownIndent(view, outdent) {
  const selection = view.state.selection.main;
  const startLine = view.state.doc.lineAt(selection.from);
  const endLine = view.state.doc.lineAt(selection.to);
  const changes = [];

  for (let number = startLine.number; number <= endLine.number; number += 1) {
    const line = view.state.doc.line(number);
    const edit = markdownListIndentEdit(line.text, outdent);
    if (!edit) continue;
    changes.push({
      from: line.from + edit.fromOffset,
      to: line.from + edit.toOffset,
      insert: edit.insert
    });
  }

  if (!changes.length) {
    if (outdent) return false;
    view.dispatch(view.state.replaceSelection("   "));
    return true;
  }

  view.dispatch({ changes, userEvent: "input" });
  return true;
}

function selectAllMarkdown(view) {
  view.dispatch({
    selection: EditorSelection.range(0, view.state.doc.length),
    scrollIntoView: true,
    userEvent: "select"
  });
  return true;
}

function runEditorCommand(command) {
  if (!editorView) return false;

  switch (command) {
    case "bold":
      wrapSelection("**", "**");
      return true;
    case "italic":
      wrapSelection("*", "*");
      return true;
    case "inlineCode":
      wrapSelection("`", "`");
      return true;
    case "link":
      wrapSelection("[", "](https://)");
      return true;
    case "heading1":
      applyLinePrefix("# ");
      return true;
    case "heading2":
      applyLinePrefix("## ");
      return true;
    case "heading3":
      applyLinePrefix("### ");
      return true;
    case "body":
      applyLinePrefix("");
      return true;
    case "bullet":
      applyLinePrefix("- ");
      return true;
    case "numbered":
      applyLinePrefix("1. ");
      return true;
    case "quote":
      applyLinePrefix("> ");
      return true;
    case "checkbox":
      applyLinePrefix("- [ ] ");
      return true;
    case "codeBlock":
      wrapBlock("```", "```");
      return true;
    case "divider":
      insertAtCursor("\n---\n");
      return true;
    case "reset":
      return true;
    case "selectAll":
      return selectAllMarkdown(editorView);
    default:
      return false;
  }
}

function wrapSelection(open, close) {
  const state = editorView.state;
  const changes = state.changeByRange((range) => {
    const selected = state.sliceDoc(range.from, range.to);
    const insert = `${open}${selected}${close}`;
    const cursor = selected.length === 0
      ? EditorSelection.cursor(range.from + open.length)
      : EditorSelection.range(range.from + open.length, range.to + open.length);

    return {
      changes: { from: range.from, to: range.to, insert },
      range: cursor
    };
  });
  editorView.dispatch(changes);
  editorView.focus();
}

function insertAtCursor(text) {
  editorView.dispatch(editorView.state.replaceSelection(text));
  editorView.focus();
}

function applyLinePrefix(prefix) {
  const state = editorView.state;
  const selection = state.selection.main;
  const startLine = state.doc.lineAt(selection.from);
  const endLine = state.doc.lineAt(selection.to);
  const changes = [];

  for (let number = startLine.number; number <= endLine.number; number += 1) {
    const line = state.doc.line(number);
    const existing = line.text.match(/^(\s*)(#{1,6}\s+|>\s+|- \[ \]\s+|- \[[xX]\]\s+|[-*+]\s+|\d+[.)]\s+)?/);
    const indent = existing?.[1] || "";
    const marker = existing?.[2] || "";
    const from = line.from + indent.length;
    const to = from + marker.length;
    changes.push({ from, to, insert: prefix });
  }

  editorView.dispatch({ changes });
  editorView.focus();
}

function wrapBlock(open, close) {
  const state = editorView.state;
  const selection = state.selection.main;
  const startLine = state.doc.lineAt(selection.from);
  const endLine = state.doc.lineAt(selection.to);
  const selected = state.sliceDoc(startLine.from, endLine.to);
  const replacement = `${open}\n${selected}\n${close}`;

  editorView.dispatch({
    changes: { from: startLine.from, to: endLine.to, insert: replacement },
    selection: EditorSelection.cursor(startLine.from + open.length + 1 + selected.length)
  });
  editorView.focus();
}

function scheduleHeightPublish(view) {
  window.requestAnimationFrame(() => {
    const content = view.contentDOM;
    const height = Math.ceil(content.scrollHeight);
    post("editorHeightChanged", { height });
  });
}

function setMarkdown(markdownText) {
  if (!editorView) return;
  const current = editorView.state.doc.toString();
  const next = markdownText || "";
  if (current === next) return;

  applyingExternalUpdate = true;
  editorView.dispatch({
    changes: { from: 0, to: current.length, insert: next }
  });
  applyingExternalUpdate = false;
  scheduleHeightPublish(editorView);
}

function pasteClipboard(html, plainText) {
  if (!editorView) return false;
  const markdown = markdownFromClipboardPayload(html || "", plainText || "");
  if (!markdown) return false;

  editorView.dispatch(editorView.state.replaceSelection(markdown));
  editorView.focus();
  scheduleHeightPublish(editorView);
  return true;
}

function focusEditor() {
  editorView?.focus();
}

function focusEditorAt(x, y) {
  if (!editorView) return;

  editorView.focus();
  const position = editorView.posAtCoords({ x, y }, false);
  if (position != null) {
    editorView.dispatch({
      selection: EditorSelection.cursor(position),
      scrollIntoView: true
    });
  }
}

function setTheme(theme) {
  const root = document.documentElement;
  for (const [key, value] of Object.entries(theme || {})) {
    root.style.setProperty(`--${key}`, value);
  }
  if (editorView) scheduleHeightPublish(editorView);
}

function boot() {
  const initialMarkdown = typeof window.memoInitialMarkdown === "string"
    ? window.memoInitialMarkdown
    : "";

  editorView = new EditorView({
    state: createState(initialMarkdown),
    parent: document.getElementById("editor")
  });

  window.setMemoMarkdown = setMarkdown;
  window.memoPasteClipboard = pasteClipboard;
  window.focusMemoEditor = focusEditor;
  window.focusMemoEditorAt = focusEditorAt;
  window.memoEditorCommand = runEditorCommand;
  window.memoAppCommand = runAppCommand;
  window.setMemoEditorTheme = setTheme;

  scheduleHeightPublish(editorView);
  post("editorReady", { ready: true });
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", boot, { once: true });
} else {
  boot();
}
