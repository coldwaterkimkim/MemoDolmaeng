# MemoDolmaeng

Stickies-like local macOS memo app.

## MVP 1

- Multiple independent memo windows
- Raw Markdown `content` is the source of truth
- Typora-like live Markdown editing through a bundled `WKWebView` + CodeMirror editor; there is no Source/Raw/Preview toggle inside the sticky note
- The active Markdown block stays directly editable while inactive blocks are visually rendered with headings, inline emphasis, inline code, task checkboxes, lists, quotes, rendered fenced code blocks with language labels, rendered GFM tables, math markers, links, strikethrough, and footnote markers
- Legacy bundled `WKWebView` preview renderer using `markdown-it`, task lists, footnotes, `markdown-it-texmath`/KaTeX, and DOMPurify is still available as a rendering resource, but the main note surface is the live editor
- ChatGPT-style Markdown paste keeps raw source intact for headings, nested lists, tables, task lists, strikethrough, fenced code blocks with language tags, math, links, autolinks, blockquotes, horizontal rules, safe HTML, footnotes, and Mermaid-as-code-block
- The legacy renderer sanitizes rendered HTML and blocks unsafe protocols such as `javascript:`, `data:`, and `vbscript:`
- Markdown image syntax stays raw in storage and is shown safely in the live editor rather than automatically fetching remote media
- `Enter` continues raw Markdown bullets/lists at the current level and exits an empty list item back to body text
- `Tab` indents raw Markdown list items with a Markdown sublist indent; ordered sublists restart at `1.` and `Shift+Tab` outdents them
- Rich clipboard paste prefers semantic HTML-to-Markdown import for headings, lists, task lists, tables, code fences, quotes, links, images, emphasis, and strikethrough, then falls back to plain text when HTML is unavailable
- Paste strips external font, size, CSS class, and theme styling while preserving selected semantic inline text colors as safe raw Markdown `<span style="color: #rrggbb">...</span>` fragments
- Rich paste drops clipboard UI artifacts such as copy buttons, SVG icons, hidden labels, and design-tool metadata before Markdown conversion
- Paired text input for `[]`, `''`, `""`, and `<>` is owned by the live editor and normalized against BetterTouchTool-style duplicate events, so opener/caret drift does not leave `[[`, `'''`, `"""`, or `<<`-style artifacts
- Direct image paste is no longer the primary path in this editor pass; ChatGPT-style image Markdown is preserved as source
- Compact typography: D2CodingLigature Nerd Font `12pt` body text, fill-matched caret, outside-like text stroke rendering, scaled Markdown headings, tight line spacing, and 10 px vertical text padding
- Preferences panel for text color, stroke color/weight, font sizes, paragraph spacing, indents, note width/height, padding, drag strip height, paper-only translucent alpha, window edge stroke, and shadow
- `Format` menu routes to the live Markdown editor and inserts raw Markdown markers for Body, headings, list blocks, quote, checkbox, code block, divider, bold, italic, inline code, and links
- Format shortcuts: `Cmd+Option+0/1/2/3` for Body/Heading 1/Heading 2/Heading 3, `Cmd+Shift+8` for bullets, `Cmd+Shift+7` for numbered lists, `Cmd+Option+Q` for quote, `Cmd+Option+C` for checkbox, `Cmd+B` for bold, `Cmd+I` for italic, `Cmd+E` for inline code, and `Cmd+K` for links
- Local app-managed persistence
- Window size and position restoration
- Dragging the note body moves the window only when the editor is not focused; while the caret is visible, body dragging remains text selection/editing and the top strip remains the move handle
- New blank notes start as a compact one-line `300 x 48` note by default, then grow vertically with content
- Automatic height stops after a manual window resize, so user-sized notes stay user-sized
- Autosave on edit, move, and resize
- The top drag strip has a bottom stroke that follows the window stroke settings, making the draggable area easier to read
- Double-clicking the top drag strip resets the memo width to the default width while preserving the current height
- If a note that has contained content becomes empty, the top-strip bottom stroke becomes a 2-second countdown line; typing again cancels it, otherwise the note window closes and the note is deleted
- Borderless sticky-note window shape without macOS traffic-light controls
- Black paper is the default new-note color, with older saved notes preserving their own colors
- Color menu for Black, Yellow, Blue, Green, Pink, Purple, Gray, and White
- New notes always use Black unless the user explicitly changes a note through the Color menu
- Window menu `Float on Top` option, off by default, with `Cmd+Option+F`
- Window menu `Translucent` option, off by default, with `Cmd+Option+T`; translucency affects the paper surface, not text or rich content
- Clicking or dragging one memo window brings only that window forward; `Float on Top` windows do not pull normal windows to the front
- Window menu `Bring All to Front` is the explicit action for raising all visible memo windows together, with `Cmd+Shift+S`
- Standard text shortcuts through the macOS responder chain without stealing `Cmd+Option` format shortcuts
- `Cmd+W` closes empty notes immediately and asks before closing notes with content

## Fixture

`Fixtures/chatgpt-markdown-compatibility.md` verifies raw Markdown preservation and live editor rendering.
`Fixtures/chatgpt-rich-clipboard.html` verifies semantic HTML clipboard import into raw Markdown.
`Fixtures/editor-render-qa.html` verifies the live editor rendering surface for lists, task checkboxes, quotes, GFM tables, and fenced code blocks.

## Run

```bash
./script/build_and_run.sh
```

Codex also has a project-local Run action wired to the same script.
The run script rebuilds the bundled CodeMirror editor before compiling Swift.

## Verify

```bash
./script/build_and_run.sh --verify
```
