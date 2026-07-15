import { Crepe } from "@milkdown/crepe";
import "@milkdown/crepe/theme/common/style.css";
import "@milkdown/crepe/theme/frame.css";
import { commandsCtx, editorViewCtx, serializerCtx } from "@milkdown/kit/core";
import {
  createCodeBlockCommand,
  liftListItemCommand,
  sinkListItemCommand,
  toggleEmphasisCommand,
  toggleStrongCommand,
  wrapInBulletListCommand,
  wrapInOrderedListCommand
} from "@milkdown/kit/preset/commonmark";
import {
  insertTableCommand,
  toggleStrikethroughCommand
} from "@milkdown/kit/preset/gfm";
import { toggleMark } from "@milkdown/kit/prose/commands";
import { AllSelection, Plugin, TextSelection } from "@milkdown/kit/prose/state";
import { $prose, getMarkdown, replaceAll } from "@milkdown/kit/utils";
import {
  editorToStorageMarkdown,
  isSafeHexColor,
  memoParagraphOrderPlugin,
  memoParagraphSchema,
  memoRemarkPlugin,
  memoTextColorSchema,
  memoUnderlineSchema,
  storageToEditorMarkdown
} from "./milkdownExtensions.js";
import "./crepe-overrides.css";

const bridge = window.webkit?.messageHandlers;
const editorRoot = document.getElementById("editor");
const pendingImageUploads = new Map();
const imageUploadTimeoutMs = 30_000;

let crepe = null;
let editorReady = false;
let pendingMarkdown = "";
let currentStorageMarkdown = "";
let applyingExternalDocument = false;
let documentDirty = false;

function post(name, value) {
  bridge?.[name]?.postMessage(value);
}

function normalizeStorageMarkdown(markdown) {
  return String(markdown || "").replace(/\r\n?/g, "\n");
}

function runRegisteredCommand(command, payload) {
  if (!editorReady || !crepe) return false;
  return crepe.editor.action((ctx) => ctx.get(commandsCtx).call(command.key, payload));
}

function proseView() {
  if (!editorReady || !crepe) return null;
  return crepe.editor.action((ctx) => ctx.get(editorViewCtx));
}

function publishDocumentChange(ctx, doc) {
  if (applyingExternalDocument) return;
  const serialized = ctx.get(serializerCtx)(doc);
  const storageMarkdown = normalizeStorageMarkdown(editorToStorageMarkdown(serialized));
  if (storageMarkdown === currentStorageMarkdown) return;
  documentDirty = true;
  currentStorageMarkdown = storageMarkdown;
  post("editorChanged", { markdown: storageMarkdown });
}

const memoContentBridge = $prose((ctx) => new Plugin({
  view: () => ({
    update(view, previousState) {
      if (!view.state.doc.eq(previousState.doc)) {
        publishDocumentChange(ctx, view.state.doc);
      }
    }
  })
}));

function toggleCustomMark(markName, attrs = null) {
  const view = proseView();
  const markType = view?.state.schema.marks[markName];
  if (!view || !markType) return false;
  return toggleMark(markType, attrs)(view.state, view.dispatch, view);
}

function setTextColor(color) {
  if (!isSafeHexColor(color)) return false;
  const view = proseView();
  const markType = view?.state.schema.marks.memo_text_color;
  if (!view || !markType) return false;

  const normalized = color.toUpperCase();
  const { from, to, empty } = view.state.selection;
  let transaction = view.state.tr;
  if (empty) {
    const current = view.state.storedMarks || view.state.selection.$from.marks();
    transaction = transaction.setStoredMarks([
      ...current.filter((mark) => mark.type !== markType),
      markType.create({ color: normalized })
    ]);
  } else {
    transaction = transaction
      .removeMark(from, to, markType)
      .addMark(from, to, markType.create({ color: normalized }));
  }
  view.dispatch(transaction.scrollIntoView());
  return true;
}

function toggleChecklist() {
  const view = proseView();
  if (!view) return false;

  const { $from } = view.state.selection;
  for (let depth = $from.depth; depth > 0; depth -= 1) {
    const node = $from.node(depth);
    if (node.type.name !== "list_item") continue;
    const position = $from.before(depth);
    const checked = node.attrs.checked == null ? false : null;
    view.dispatch(view.state.tr.setNodeMarkup(position, undefined, {
      ...node.attrs,
      checked
    }).scrollIntoView());
    return true;
  }

  return runRegisteredCommand(wrapInBulletListCommand);
}

function selectAll() {
  const view = proseView();
  if (!view) return false;
  view.dispatch(view.state.tr.setSelection(new AllSelection(view.state.doc)));
  view.focus();
  return true;
}

function runEditorCommand(command) {
  switch (command) {
  case "bold":
    return runRegisteredCommand(toggleStrongCommand);
  case "italic":
    return runRegisteredCommand(toggleEmphasisCommand);
  case "underline":
    return toggleCustomMark("memo_underline");
  case "strikethrough":
    return runRegisteredCommand(toggleStrikethroughCommand);
  case "bulletList":
    return runRegisteredCommand(wrapInBulletListCommand);
  case "numberedList":
    return runRegisteredCommand(wrapInOrderedListCommand);
  case "checkbox":
    return toggleChecklist();
  case "indent":
    return runRegisteredCommand(sinkListItemCommand);
  case "outdent":
    return runRegisteredCommand(liftListItemCommand);
  case "codeBlock":
    return runRegisteredCommand(createCodeBlockCommand, { language: "" });
  case "table":
    return runRegisteredCommand(insertTableCommand, { row: 3, col: 3 });
  case "selectAll":
    return selectAll();
  default:
    return false;
  }
}

function insertImage(url, caption = "") {
  const view = proseView();
  const nodeType = view?.state.schema.nodes["image-block"];
  if (!view || !nodeType) return false;
  const node = nodeType.create({ src: url, caption, ratio: 1 });
  view.dispatch(view.state.tr.replaceSelectionWith(node).scrollIntoView());
  return true;
}

function setMarkdown(markdown) {
  const normalized = normalizeStorageMarkdown(markdown);
  pendingMarkdown = normalized;
  currentStorageMarkdown = normalized;
  documentDirty = false;
  if (!editorReady || !crepe) return;

  applyingExternalDocument = true;
  crepe.editor.action(replaceAll(storageToEditorMarkdown(normalized), true));
  applyingExternalDocument = false;
}

function markdownValue() {
  if (!editorReady || !crepe) return currentStorageMarkdown;
  if (!documentDirty) return currentStorageMarkdown;
  return editorToStorageMarkdown(crepe.editor.action(getMarkdown()));
}

function focusEditor() {
  proseView()?.focus();
}

function focusEditorAt(x, y) {
  const view = proseView();
  if (!view) return;
  const result = view.posAtCoords({ left: Number(x), top: Number(y) });
  if (result) {
    const position = Math.max(1, Math.min(result.pos, view.state.doc.content.size));
    view.dispatch(view.state.tr.setSelection(TextSelection.near(view.state.doc.resolve(position))));
  }
  view.focus();
}

function applyTheme(values) {
  if (!values || typeof values !== "object") return;
  for (const [name, value] of Object.entries(values)) {
    if (/^memo-[a-z0-9-]+$/.test(name)) {
      document.documentElement.style.setProperty(`--${name}`, String(value));
    }
  }
}

function readFileAsBase64(file) {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error || new Error("이미지 파일을 읽지 못했어."));
    reader.onload = () => {
      const result = String(reader.result || "");
      const separator = result.indexOf(",");
      if (separator === -1) reject(new Error("이미지 데이터를 변환하지 못했어."));
      else resolve(result.slice(separator + 1));
    };
    reader.readAsDataURL(file);
  });
}

async function uploadImage(file) {
  if (!file?.type?.startsWith("image/")) throw new Error("이미지 파일만 추가할 수 있어.");
  if (!bridge?.editorImageUpload) throw new Error("메모돌맹 이미지 저장소에 연결되지 않았어.");

  const requestID = crypto.randomUUID();
  const base64 = await readFileAsBase64(file);
  return new Promise((resolve, reject) => {
    const timer = window.setTimeout(() => {
      pendingImageUploads.delete(requestID);
      reject(new Error("이미지 저장 시간이 초과됐어."));
    }, imageUploadTimeoutMs);
    pendingImageUploads.set(requestID, { resolve, reject, timer });
    post("editorImageUpload", {
      requestID,
      fileName: file.name,
      mimeType: file.type,
      base64
    });
  });
}

function resolveImageUpload(requestID, url, error) {
  const pending = pendingImageUploads.get(requestID);
  if (!pending) return;
  pendingImageUploads.delete(requestID);
  window.clearTimeout(pending.timer);
  if (error || !url) pending.reject(new Error(error || "이미지를 저장하지 못했어."));
  else pending.resolve(url);
}

function installKeyboardBridge() {
  document.addEventListener("keydown", (event) => {
    if (!event.metaKey || event.ctrlKey || event.altKey) return;
    const key = event.key.toLowerCase();
    if (key === "u") {
      event.preventDefault();
      runEditorCommand("underline");
    } else if (key === "w") {
      event.preventDefault();
      post("editorAppCommand", { command: "closeNote" });
    } else if (key === "n") {
      event.preventDefault();
      post("editorAppCommand", { command: "newNote" });
    }
  }, true);
}

async function createEditor() {
  const instance = new Crepe({
    root: editorRoot,
    defaultValue: storageToEditorMarkdown(pendingMarkdown),
    featureConfigs: {
      [Crepe.Feature.ImageBlock]: {
        onUpload: uploadImage,
        inlineOnUpload: uploadImage,
        blockOnUpload: uploadImage,
        proxyDomURL: (url) => url
      },
      [Crepe.Feature.Placeholder]: {
        text: "메모를 입력해",
        mode: "block"
      }
    }
  });

  instance.editor
    .use(memoRemarkPlugin)
    .use(memoUnderlineSchema)
    .use(memoTextColorSchema)
    .use(memoParagraphSchema.ctx)
    .use(memoParagraphSchema.node)
    .use(memoParagraphOrderPlugin)
    .use(memoContentBridge);

  instance.on((listener) => {
    listener
      .mounted(() => post("editorReady", {}))
      .focus(() => post("editorFocusChanged", { focused: true }))
      .blur(() => post("editorFocusChanged", { focused: false }));
  });

  crepe = instance;
  await instance.create();
  editorReady = true;
  currentStorageMarkdown = normalizeStorageMarkdown(pendingMarkdown);
  post("editorReady", {});
}

window.setMemoMarkdown = setMarkdown;
window.getMemoMarkdown = markdownValue;
window.memoEditorCommand = runEditorCommand;
window.memoInsertImage = insertImage;
window.memoSetTextColor = setTextColor;
window.focusMemoEditor = focusEditor;
window.focusMemoEditorAt = focusEditorAt;
window.setMemoEditorTheme = applyTheme;
window.resolveMemoImageUpload = resolveImageUpload;

installKeyboardBridge();
createEditor().catch((error) => {
  console.error("Crepe failed to initialize", error);
  post("editorReady", { error: String(error) });
});
