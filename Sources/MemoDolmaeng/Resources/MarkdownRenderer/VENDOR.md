# Markdown Renderer Vendor Notes

MemoDolmaeng bundles these browser-side renderer libraries so preview mode works offline and does not depend on a CDN:

- `markdown-it` 14.1.0, MIT
- `markdown-it-task-lists` 2.1.1, ISC
- `markdown-it-footnote` 4.0.0, MIT
- `markdown-it-texmath` 1.0.0, MIT
- `KaTeX` 0.16.22, MIT
- `DOMPurify` 3.3.0, Apache-2.0 or MPL-2.0

The WebKit preview sanitizes rendered HTML with DOMPurify before inserting it into the preview document.
