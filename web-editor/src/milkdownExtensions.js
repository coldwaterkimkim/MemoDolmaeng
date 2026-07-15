import { nodesCtx } from "@milkdown/kit/core";
import { paragraphSchema } from "@milkdown/kit/preset/commonmark";
import { $markSchema, $remark } from "@milkdown/kit/utils";

const alignmentMarkerPattern = /^<!--memo-align:(left|center|right)-->$/;
const underlineOpenPattern = /^<u>$/i;
const underlineClosePattern = /^<\/u>$/i;
const colorOpenPattern = /^<span\s+style=(?:"|')color:\s*(#[0-9a-f]{6})\s*;?(?:"|')>$/i;
const colorClosePattern = /^<\/span>$/i;

export function isSafeHexColor(value) {
  return /^#[0-9a-f]{6}$/i.test(String(value || ""));
}

export function storageToEditorMarkdown(markdown) {
  return String(markdown || "").replace(
    /<div\s+style=(?:"|')text-align:\s*(left|center|right)\s*;?(?:"|')\s*>\s*\n?([\s\S]*?)\n?\s*<\/div>/gi,
    (_, alignment, content) => `${content.trim()}<!--memo-align:${alignment.toLowerCase()}-->`
  );
}

export function editorToStorageMarkdown(markdown) {
  return String(markdown || "")
    .split(/(\n\n+)/)
    .map((block) => block.replace(
      /^([\s\S]*?)<!--memo-align:(left|center|right)-->(\n*)$/,
      (_, content, alignment, trailingNewlines) => {
        const body = content.trim();
        return `<div style="text-align: ${alignment};">\n${body}\n</div>${trailingNewlines}`;
      }
    ))
    .join("");
}

function transformChildren(parent) {
  if (!Array.isArray(parent?.children)) return;

  const children = parent.children;
  const transformed = [];

  for (let index = 0; index < children.length; index += 1) {
    const child = children[index];
    if (Array.isArray(child.children)) transformChildren(child);

    if (child.type === "html") {
      const marker = String(child.value || "").trim().match(alignmentMarkerPattern);
      if (marker && parent.type === "paragraph") {
        parent.memoAlign = marker[1];
        continue;
      }

      if (underlineOpenPattern.test(String(child.value || "").trim())) {
        const closingIndex = findClosingHTML(children, index + 1, underlineClosePattern);
        if (closingIndex !== -1) {
          const inner = children.slice(index + 1, closingIndex);
          inner.forEach((node) => transformChildren(node));
          transformed.push({ type: "memoUnderline", children: inner });
          index = closingIndex;
          continue;
        }
      }

      const colorMatch = String(child.value || "").trim().match(colorOpenPattern);
      if (colorMatch) {
        const closingIndex = findClosingHTML(children, index + 1, colorClosePattern);
        if (closingIndex !== -1) {
          const inner = children.slice(index + 1, closingIndex);
          inner.forEach((node) => transformChildren(node));
          transformed.push({
            type: "memoTextColor",
            color: colorMatch[1].toUpperCase(),
            children: inner
          });
          index = closingIndex;
          continue;
        }
      }
    }

    transformed.push(child);
  }

  parent.children = transformed;
}

function findClosingHTML(children, start, pattern) {
  for (let index = start; index < children.length; index += 1) {
    const child = children[index];
    if (child.type === "html" && pattern.test(String(child.value || "").trim())) {
      return index;
    }
  }
  return -1;
}

function memoRemarkAttacher() {
  const data = this.data();
  const extensions = data.toMarkdownExtensions || (data.toMarkdownExtensions = []);
  extensions.push({
    handlers: {
      memoUnderline(node, parent, state, info) {
        return `<u>${state.containerPhrasing(node, info)}</u>`;
      },
      memoTextColor(node, parent, state, info) {
        const color = isSafeHexColor(node.color) ? node.color.toUpperCase() : "#1F1F1F";
        return `<span style="color: ${color};">${state.containerPhrasing(node, info)}</span>`;
      }
    }
  });

  return (tree) => {
    transformChildren(tree);
  };
}

export const memoRemarkPlugin = $remark("memo-formatting", () => memoRemarkAttacher);

export const memoUnderlineSchema = $markSchema("memo_underline", () => ({
  parseDOM: [{ tag: "u" }],
  toDOM: () => ["u", 0],
  parseMarkdown: {
    match: (node) => node.type === "memoUnderline",
    runner: (state, node, markType) => {
      state.openMark(markType);
      state.next(node.children);
      state.closeMark(markType);
    }
  },
  toMarkdown: {
    match: (mark) => mark.type.name === "memo_underline",
    runner: (state, mark) => {
      state.withMark(mark, "memoUnderline");
    }
  }
}));

export const memoTextColorSchema = $markSchema("memo_text_color", () => ({
  attrs: { color: { default: "#1F1F1F" } },
  parseDOM: [{
    tag: "span[style]",
    getAttrs: (element) => {
      const color = element instanceof HTMLElement ? element.style.color : "";
      const match = color.match(/^#([0-9a-f]{6})$/i);
      return match ? { color: `#${match[1].toUpperCase()}` } : false;
    }
  }],
  toDOM: (mark) => ["span", { style: `color: ${mark.attrs.color}` }, 0],
  parseMarkdown: {
    match: (node) => node.type === "memoTextColor" && isSafeHexColor(node.color),
    runner: (state, node, markType) => {
      state.openMark(markType, { color: node.color.toUpperCase() });
      state.next(node.children);
      state.closeMark(markType);
    }
  },
  toMarkdown: {
    match: (mark) => mark.type.name === "memo_text_color",
    runner: (state, mark) => {
      state.withMark(mark, "memoTextColor", undefined, {
        color: isSafeHexColor(mark.attrs.color) ? mark.attrs.color.toUpperCase() : "#1F1F1F"
      });
    }
  }
}));

export const memoParagraphSchema = paragraphSchema.extendSchema((previous) => (ctx) => {
  const base = previous(ctx);
  return {
    ...base,
    attrs: {
      ...base.attrs,
      textAlign: { default: "left" }
    },
    parseDOM: [{
      tag: "p",
      getAttrs: (element) => {
        const alignment = element instanceof HTMLElement ? element.style.textAlign : "";
        return { textAlign: ["center", "right"].includes(alignment) ? alignment : "left" };
      }
    }],
    toDOM: (node) => [
      "p",
      node.attrs.textAlign === "left" ? {} : { style: `text-align: ${node.attrs.textAlign}` },
      0
    ],
    parseMarkdown: {
      match: (node) => node.type === "paragraph",
      runner: (state, node, type) => {
        state.openNode(type, { textAlign: node.memoAlign || "left" });
        if (node.children) state.next(node.children);
        else state.addText(node.value || "");
        state.closeNode();
      }
    },
    toMarkdown: {
      match: (node) => node.type.name === "paragraph",
      runner: (state, node) => {
        state.openNode("paragraph");
        state.next(node.content);
        if (["center", "right"].includes(node.attrs.textAlign)) {
          state.addNode("html", undefined, `<!--memo-align:${node.attrs.textAlign}-->`);
        }
        state.closeNode();
      }
    }
  };
});

export const memoParagraphOrderPlugin = (ctx) => async () => {
  ctx.update(nodesCtx, (nodes) => {
    const paragraphIndex = nodes.findIndex(([name]) => name === "paragraph");
    const headingIndex = nodes.findIndex(([name]) => name === "heading");
    if (paragraphIndex === -1 || headingIndex === -1 || paragraphIndex < headingIndex) return nodes;

    const reordered = [...nodes];
    const [paragraph] = reordered.splice(paragraphIndex, 1);
    const nextHeadingIndex = reordered.findIndex(([name]) => name === "heading");
    reordered.splice(nextHeadingIndex, 0, paragraph);
    return reordered;
  });
};
