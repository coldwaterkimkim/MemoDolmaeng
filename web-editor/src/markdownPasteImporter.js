import TurndownService from "turndown";
import { gfm } from "turndown-plugin-gfm";

const unsafeProtocolPattern = /^(?:javascript|data|vbscript|file):/i;
const allowedProtocolPattern = /^(?:https?:|mailto:|tel:|sms:)/i;
const semanticColorMinimumSaturation = 0.28;
const semanticColorMinimumSpread = 34;

const turndown = new TurndownService({
  bulletListMarker: "-",
  codeBlockStyle: "fenced",
  fence: "```",
  headingStyle: "atx",
  hr: "---",
  linkStyle: "inlined",
  strongDelimiter: "**",
  emDelimiter: "*"
});

turndown.use(gfm);

turndown.addRule("memoDropClipboardArtifacts", {
  filter(node) {
    return shouldDropClipboardArtifact(node);
  },
  replacement() {
    return "";
  }
});

turndown.addRule("memoFenceWithLanguage", {
  filter(node) {
    return node.nodeName === "PRE" && node.firstElementChild?.nodeName === "CODE";
  },
  replacement(_content, node) {
    const code = node.firstElementChild;
    const language = languageFromCodeNode(code);
    const text = code.textContent.replace(/\n+$/g, "");
    return `\n\n\`\`\`${language}\n${text}\n\`\`\`\n\n`;
  }
});

turndown.addRule("memoSafeLink", {
  filter(node) {
    return node.nodeName === "A" && node.getAttribute("href");
  },
  replacement(content, node) {
    const href = sanitizeURL(node.getAttribute("href"));
    if (!href) return content;
    const title = node.getAttribute("title");
    const safeTitle = title ? ` "${escapeMarkdownTitle(title)}"` : "";
    return `[${content || href}](${href}${safeTitle})`;
  }
});

turndown.addRule("memoSafeImage", {
  filter(node) {
    return node.nodeName === "IMG" && node.getAttribute("src");
  },
  replacement(_content, node) {
    const src = sanitizeURL(node.getAttribute("src"));
    if (!src) return "";
    const alt = escapeMarkdownLabel(node.getAttribute("alt") || "");
    const title = node.getAttribute("title");
    const safeTitle = title ? ` "${escapeMarkdownTitle(title)}"` : "";
    return `![${alt}](${src}${safeTitle})`;
  }
});

turndown.addRule("memoStrikethrough", {
  filter(node) {
    return ["DEL", "S", "STRIKE"].includes(node.nodeName);
  },
  replacement(content) {
    return content.trim() ? `~~${content}~~` : "";
  }
});

turndown.addRule("memoSemanticColor", {
  filter(node) {
    return isInlineColorNode(node) && Boolean(semanticColorForNode(node));
  },
  replacement(content, node) {
    const color = semanticColorForNode(node);
    if (!color || !content.trim()) return content;
    return `<span style="color: ${color}">${content}</span>`;
  }
});

export function markdownFromClipboardData(dataTransfer) {
  return markdownFromClipboardPayload(
    dataTransfer?.getData("text/html") || "",
    dataTransfer?.getData("text/plain") || ""
  );
}

export function markdownFromClipboardPayload(html, plainText) {
  if (html?.trim()) {
    const markdown = markdownFromHtml(html);
    if (markdown.trim()) return markdown;
  }

  return plainText || "";
}

export function markdownFromHtml(html) {
  if (!html?.trim()) return "";
  return normalizeMarkdown(turndown.turndown(stripAppleClipboardWrapper(html)));
}

export function normalizeImportedMarkdownText(markdown) {
  return normalizeMarkdown(markdown || "");
}

export function semanticTextColor(rawColor) {
  const color = parseCSSColor(rawColor);
  if (!color || color.a < 0.5) return null;

  const max = Math.max(color.r, color.g, color.b);
  const min = Math.min(color.r, color.g, color.b);
  const spread = max - min;
  const saturation = max === 0 ? 0 : spread / max;

  if (spread < semanticColorMinimumSpread) return null;
  if (saturation < semanticColorMinimumSaturation) return null;

  return rgbToHex(color.r, color.g, color.b);
}

export function sanitizeURL(rawURL) {
  if (!rawURL) return null;
  const value = rawURL.trim().replace(/[\u0000-\u001f\u007f\s]+/g, "");
  if (!value || unsafeProtocolPattern.test(value)) return null;
  if (value.startsWith("#") || value.startsWith("/") || value.startsWith("./") || value.startsWith("../")) {
    return value;
  }
  if (allowedProtocolPattern.test(value)) return value;
  return null;
}

function stripAppleClipboardWrapper(html) {
  return html
    .replace(/<!--StartFragment-->/gi, "")
    .replace(/<!--EndFragment-->/gi, "");
}

function normalizeMarkdown(markdown) {
  let normalized = markdown
    .replace(/\u00a0/g, " ")
    .replace(/[ \t]+\n/g, "\n")
    .replace(/(\[[ xX]\]) {2,}/g, "$1 ")
    .replace(/^(\s*[-*+] \[[ xX]\])\s+/gm, "$1 ")
    .replace(/^(\s*(?:[-*+](?: \[[ xX]\])?|\d+[.)])) {2,}/gm, "$1 ")
    .replace(/\n{3,}/g, "\n\n");

  normalized = unescapeTurndownTextMarkers(normalized);
  normalized = collapseLooseSimpleLists(normalized);

  return normalized.trim();
}

function isInlineColorNode(node) {
  return ["SPAN", "FONT", "B", "STRONG", "I", "EM", "U", "S", "DEL", "CODE"].includes(node.nodeName);
}

function semanticColorForNode(node) {
  return semanticTextColor(node.style?.color || node.getAttribute?.("color"));
}

function shouldDropClipboardArtifact(node) {
  const nodeName = node.nodeName;
  if (["SCRIPT", "STYLE", "NOSCRIPT", "BUTTON", "SVG", "PATH", "CANVAS"].includes(nodeName)) {
    return true;
  }

  if (node.getAttribute?.("aria-hidden") === "true" || node.hidden) {
    return true;
  }

  const metadata = [
    node.getAttribute?.("data-metadata"),
    node.getAttribute?.("data-buffer")
  ].filter(Boolean).join(" ");
  if (/(?:figmeta|figma)/i.test(metadata)) return true;

  const role = node.getAttribute?.("role") || "";
  const className = node.getAttribute?.("class") || "";
  const testId = node.getAttribute?.("data-testid") || "";
  const label = node.getAttribute?.("aria-label") || "";
  const artifactText = `${role} ${className} ${testId} ${label}`;

  return /\b(?:copy|clipboard|action|button|icon|sr-only|visually-hidden)\b/i.test(artifactText);
}

function unescapeTurndownTextMarkers(markdown) {
  return markdown
    .split("\n")
    .map((line) => {
      let next = line;
      if (/^\s*#{1,6}\s+/.test(next)) {
        next = next.replace(/\\([.)])/g, "$1");
      }

      return next
        .replace(/\\\*\\\*([^*\n]+?)\\\*\\\*/g, "**$1**")
        .replace(/\\_\\_([^_\n]+?)\\_\\_/g, "__$1__")
        .replace(/\\\*([^*\n]+?)\\\*/g, "*$1*");
    })
    .join("\n");
}

function collapseLooseSimpleLists(markdown) {
  let previous;
  let next = markdown;
  const looseListGapPattern = /^(\s*(?:[-*+](?: \[[ xX]\])?|\d+[.)])\s+[^\n]*)\n\n(?=\s*(?:[-*+](?: \[[ xX]\])?|\d+[.)])\s+)/gm;

  do {
    previous = next;
    next = next.replace(looseListGapPattern, "$1\n");
  } while (next !== previous);

  return next;
}

function languageFromCodeNode(codeNode) {
  const className = codeNode.getAttribute("class") || "";
  const languageClass = className
    .split(/\s+/)
    .find((name) => /^language-/.test(name) || /^lang-/.test(name));

  if (!languageClass) return "";
  return languageClass.replace(/^(?:language|lang)-/, "").replace(/[^\w.+-]/g, "");
}

function parseCSSColor(rawColor) {
  if (!rawColor) return null;
  const value = rawColor.trim().toLowerCase();

  const hexMatch = value.match(/^#([0-9a-f]{3}|[0-9a-f]{6}|[0-9a-f]{8})$/i);
  if (hexMatch) return parseHexColor(hexMatch[1]);

  const rgbMatch = value.match(/^rgba?\((.+)\)$/i);
  if (rgbMatch) return parseRGBColor(rgbMatch[1]);

  return namedColor(value);
}

function parseHexColor(hex) {
  if (hex.length === 3) {
    return {
      r: parseInt(hex[0] + hex[0], 16),
      g: parseInt(hex[1] + hex[1], 16),
      b: parseInt(hex[2] + hex[2], 16),
      a: 1
    };
  }

  if (hex.length === 6 || hex.length === 8) {
    return {
      r: parseInt(hex.slice(0, 2), 16),
      g: parseInt(hex.slice(2, 4), 16),
      b: parseInt(hex.slice(4, 6), 16),
      a: hex.length === 8 ? parseInt(hex.slice(6, 8), 16) / 255 : 1
    };
  }

  return null;
}

function parseRGBColor(rawChannels) {
  const channels = rawChannels
    .replace(/\s*\/\s*/g, ",")
    .split(/[,\s]+/)
    .filter(Boolean);
  if (channels.length < 3) return null;

  const [r, g, b] = channels.slice(0, 3).map(parseRGBChannel);
  if ([r, g, b].some((channel) => channel == null)) return null;

  const alpha = channels[3] == null ? 1 : parseAlphaChannel(channels[3]);
  return { r, g, b, a: alpha ?? 1 };
}

function parseRGBChannel(rawChannel) {
  if (rawChannel.endsWith("%")) {
    const percent = Number(rawChannel.slice(0, -1));
    if (!Number.isFinite(percent)) return null;
    return clamp(Math.round((percent / 100) * 255), 0, 255);
  }

  const value = Number(rawChannel);
  if (!Number.isFinite(value)) return null;
  return clamp(Math.round(value), 0, 255);
}

function parseAlphaChannel(rawChannel) {
  if (rawChannel.endsWith("%")) {
    const percent = Number(rawChannel.slice(0, -1));
    if (!Number.isFinite(percent)) return null;
    return clamp(percent / 100, 0, 1);
  }

  const value = Number(rawChannel);
  if (!Number.isFinite(value)) return null;
  return clamp(value, 0, 1);
}

function namedColor(name) {
  const colors = {
    red: [255, 0, 0],
    orange: [255, 165, 0],
    yellow: [255, 255, 0],
    green: [0, 128, 0],
    blue: [0, 0, 255],
    purple: [128, 0, 128],
    violet: [238, 130, 238],
    pink: [255, 192, 203],
    cyan: [0, 255, 255],
    magenta: [255, 0, 255]
  };

  const rgb = colors[name];
  return rgb ? { r: rgb[0], g: rgb[1], b: rgb[2], a: 1 } : null;
}

function rgbToHex(r, g, b) {
  return `#${[r, g, b].map((channel) => channel.toString(16).padStart(2, "0")).join("")}`;
}

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function escapeMarkdownLabel(text) {
  return text.replace(/\\/g, "\\\\").replace(/\]/g, "\\]");
}

function escapeMarkdownTitle(text) {
  return text.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}
