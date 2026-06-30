# Status

## Current Stage

MVP 1 scaffold plus raw Markdown source-of-truth and Typora-like live Markdown editor are implemented.

## Product Behavior

- Launching the app opens the last visible memo windows.
- If there are no saved memos, the app creates one empty memo.
- Memo windows are normal-level windows, so other apps can cover them.
- New memo windows default to `300` px wide and compact height, then grow vertically with typed content.
- Manually resizing a memo disables automatic height for that note and persists the user-sized frame.
- Memo windows use a borderless sticky-note shape without macOS traffic-light controls.
- New note surfaces default to black paper with a near-black drag strip; older notes keep their saved color.
- Empty notes render as blank paper, without placeholder text.
- Note content uses D2CodingLigature Nerd Font `12pt` body text, fill-matched caret, outside-like stroke rendering, tight line spacing, 12 px horizontal text inset, 10 px vertical text inset, and no extra hidden `NSTextContainer` side padding.
- Markdown typography is scaled for the readable compact body size: Heading 1 `19pt`, Heading 2 `16.5pt`, Heading 3 `14pt`, list/quote text `12pt`, inline/code block text `12pt`, list indent `15`, and quote indent `10`.
- New empty notes open at a compact one-line size by default; the new code default is `300 x 48`, while existing local preferences may preserve a previously saved minimum height.
- `MemoDolmaeng > Preferences...` opens a tuning panel for fill color, stroke color/weight, body and Markdown font sizes, paragraph spacing, list/quote indents, note width/height, text padding, drag strip height, paper-only translucent alpha, window edge stroke, and shadow.
- Memo windows intentionally avoid forced app activation/frontmost behavior so they do not steal attention.
- Clicking or dragging one memo window now raises only that window. `Float on Top` windows stay independent and do not pull normal windows to the front.
- `Window > Bring All to Front` remains the explicit command for raising all visible memo windows together. Shortcut: `Cmd+Shift+S`.
- When the editor is not focused, dragging the note body moves the window. When the caret is visible, the note body remains an editing surface and only the top strip moves the window.
- The top drag strip has a bottom stroke that follows the window edge stroke color, opacity, and weight, making the draggable area easier to identify without adding heavier chrome.
- Double-clicking the top drag strip resets only the memo width to the default automatic width while preserving the current height and persisted frame.
- If a note has had real content and then becomes empty, the top strip bottom stroke becomes a thin countdown line for 2 seconds. The line uses the window edge stroke weight, keeps the existing shrink direction, follows the text ink color, cancels when the user types content again, and deletes/closes the note if it remains empty. Fresh blank notes are not auto-deleted.
- Inactive body dragging for the `WKWebView` editor is handled by the native `MemoMarkdownWebView` mouse events, not by JavaScript drag messages, so each note window decides focus independently and window movement stays smooth.
- Text editing now uses a bundled `WKWebView` + CodeMirror Markdown editor as the primary note surface. There is no Live/Preview, Source, or Raw button in the sticky note.
- The CodeMirror document is the editable raw Markdown source. Visual rendering is applied through editor decorations, so headings, inline bold/italic, inline code, raw list/task/numbered markers, blockquotes, horizontal rules, math markers, links/autolinks, strikethrough, and footnote markers remain editable.
- Inactive fenced code blocks and GFM tables render as block widgets; clicking the rendered block returns the caret to the raw Markdown source for editing.
- The older bundled `markdown-it`, task-list, footnote, `markdown-it-texmath`/KaTeX, and DOMPurify preview renderer remains in resources for renderer-backed use, but the main app flow is the live editor.
- ChatGPT-style pasted Markdown remains raw in note `content`, including headings, nested lists, GFM tables, task lists, strikethrough, fenced code blocks with language tags, math, links, autolinks, blockquotes, horizontal rules, safe HTML, footnotes, and Mermaid code fences.
- Markdown image syntax remains Markdown source and is displayed safely in the live editor, not as an automatic remote image fetch.
- `Enter` continues raw Markdown lists; pressing `Enter` on an empty list item immediately removes the marker and returns to body text.
- `Tab` indents raw Markdown list items as sublists and ordered sublists restart at `1.`; `Shift+Tab` outdents by one Markdown indent level.
- Paste now prefers semantic HTML-to-Markdown import when the clipboard includes rendered web content, then falls back to plain text when HTML is unavailable.
- Rich paste preserves headings, ordered/unordered/task lists, tables, fenced code language tags, blockquotes, links, images, emphasis, and strikethrough as raw Markdown source.
- Rich paste strips external font, size, CSS class, and theme styling. Only meaningful inline text colors are preserved as safe raw Markdown `<span style="color: #rrggbb">...</span>` fragments; neutral white/black/gray theme colors are ignored.
- Rich paste drops non-content clipboard artifacts such as copy buttons, SVG icons, hidden labels, and Figma metadata, and normalizes avoidable Turndown escapes such as heading `1\.` and escaped paired emphasis markers.
- Paired text input for `[]`, `''`, `""`, and `<>` is owned by the CodeMirror input layer and normalized against BetterTouchTool-style duplicate events, so opener/caret drift collapses into one editable pair with the caret inside.
- `Format` menu exposes Body, headings, list blocks, quote, checkbox, code block, divider, bold, italic, inline code, links, and Reset Formatting. These commands now route into the CodeMirror editor and insert or remove raw Markdown markers instead of converting source into rendered rich text.
- Format shortcuts are owned by the live editor: `Cmd+Option+0/1/2/3` for Body/Heading 1/Heading 2/Heading 3, `Cmd+Shift+8` for bullets, `Cmd+Shift+7` for numbered lists, `Cmd+Option+Q` for quote, `Cmd+Option+C` for checkbox, `Cmd+B` for bold, `Cmd+I` for italic, `Cmd+E` for inline code, and `Cmd+K` for links.
- App-level shortcuts are also bridged while the WebView editor has focus: `Cmd+N` creates a note, `Cmd+W` closes the current note, `Cmd+Option+F` toggles Float on Top, and `Cmd+Option+T` toggles Translucent.
- `Cmd+A` is bridged into the CodeMirror editor, so it selects the full raw Markdown document including rendered table/code widgets.
- Bold, italic, and inline code shortcuts wrap selected text in raw Markdown markers. Empty selections insert paired markers with the caret between them.
- `File > Show All Notes` intentionally has no shortcut so `Cmd+Option+0` belongs unambiguously to `Format > Body`.
- `Window > Float on Top` toggles floating state per note and persists it. Shortcut: `Cmd+Option+F`.
- `Window > Translucent` toggles note paper translucency per note and persists it. Text and rich content stay fully opaque. Shortcut: `Cmd+Option+T`.
- `Cmd+A`, `Cmd+Option+F`, and `Cmd+Option+T` are also handled at the sticky-window/WebView level, so they keep working while the memo editor owns keyboard focus.
- `Color` menu changes the current note color and persists it. Available colors: Black, Yellow, Blue, Green, Pink, Purple, Gray, and White.
- Closing an empty memo hides it immediately.
- Closing a memo with content shows a Stickies-like confirmation with Save, Delete Note, and Cancel.
- `File > New Note` creates another independent memo window. New notes always start Black unless the user explicitly changes a note through the Color menu.
- `File > Show All Notes` reopens hidden memo windows.
- Memo text and window frames are stored locally in Application Support.
- Raw Markdown `content` is the source of truth. New text edits write Markdown strings through the CodeMirror bridge and stop writing rendered rich text archives.
- `Fixtures/chatgpt-markdown-compatibility.md` is the compatibility fixture for raw ChatGPT-style Markdown paste and live editor verification.
- `Fixtures/chatgpt-rich-clipboard.html` is the compatibility fixture for rendered ChatGPT/web HTML clipboard import.
- `Fixtures/editor-render-qa.html` is the visual rendering fixture for the live editor surface, covering list/task/quote indent, rendered GFM tables, and rendered fenced code blocks.
- `script/build_and_run.sh` rebuilds the bundled CodeMirror editor before compiling and packaging the macOS app.

## Next Stage

MVP 2 should add the next sticky-note affordances:

- collapse/expand
- duplicate
- explicit Save/Export behavior behind the current Save prompt
- optional live-editor polish such as real KaTeX inline rendering, code-block copy buttons, syntax highlighting, and a user-controlled remote image loading policy
