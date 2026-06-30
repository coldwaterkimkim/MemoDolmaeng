(() => {
  const safeSchemes = new Set(["http:", "https:", "mailto:"]);

  function escapeHtml(value) {
    return String(value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/"/g, "&quot;")
      .replace(/'/g, "&#039;");
  }

  function isSafeUrl(value) {
    try {
      const url = new URL(value, "https://memo.local");
      return safeSchemes.has(url.protocol);
    } catch {
      return false;
    }
  }

  const md = window.markdownit({
    html: true,
    linkify: true,
    typographer: false,
    breaks: true
  });

  md.validateLink = isSafeUrl;

  if (window.markdownitTaskLists) {
    md.use(window.markdownitTaskLists, {
      enabled: false,
      label: true,
      labelAfter: true
    });
  }

  if (window.markdownitFootnote) {
    md.use(window.markdownitFootnote);
  }

  if (window.texmath && window.katex) {
    md.use(window.texmath, {
      engine: window.katex,
      delimiters: ["dollars", "brackets"],
      outerSpace: true,
      katexOptions: {
        throwOnError: false,
        output: "htmlAndMathml"
      }
    });
  }

  md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
    const href = tokens[idx].attrGet("href") || "";
    if (!isSafeUrl(href)) {
      tokens[idx].attrSet("href", "#");
      tokens[idx].attrSet("aria-disabled", "true");
      tokens[idx].attrJoin("class", "blocked-link");
    } else {
      tokens[idx].attrSet("target", "_blank");
      tokens[idx].attrSet("rel", "noopener noreferrer");
    }
    return self.renderToken(tokens, idx, options);
  };

  md.renderer.rules.image = (tokens, idx) => {
    const token = tokens[idx];
    const src = token.attrGet("src") || "";
    const alt = token.content || token.attrGet("alt") || "image";
    const label = escapeHtml(alt || "image");

    if (!isSafeUrl(src)) {
      return `<span class="image-placeholder blocked-image">Blocked image: ${label}</span>`;
    }

    return `<a class="image-placeholder" href="${escapeHtml(src)}" target="_blank" rel="noopener noreferrer">Image: ${label}</a>`;
  };

  md.renderer.rules.fence = (tokens, idx) => {
    const token = tokens[idx];
    const info = token.info ? token.info.trim() : "";
    const language = info.split(/\s+/)[0];
    const languageClass = language ? ` language-${escapeHtml(language)}` : "";
    const label = language ? `<div class="code-language">${escapeHtml(language)}</div>` : "";

    return `<div class="code-block">${label}<pre><code class="${languageClass.trim()}">${escapeHtml(token.content)}</code></pre></div>`;
  };

  const sanitizeConfig = {
    USE_PROFILES: {
      html: true,
      mathMl: true
    },
    ADD_TAGS: [
      "details",
      "summary",
      "kbd",
      "input",
      "section",
      "eq",
      "eqn"
    ],
    ADD_ATTR: [
      "checked",
      "disabled",
      "type",
      "target",
      "rel",
      "class",
      "aria-disabled",
      "aria-hidden",
      "title",
      "alt",
      "href",
      "colspan",
      "rowspan"
    ],
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto):|[^a-z]|[a-z+.\-]+(?:[^a-z+.\-:]|$))/i
  };

  window.renderMarkdown = (markdown) => {
    const rendered = md.render(markdown || "");
    const sanitized = window.DOMPurify.sanitize(rendered, sanitizeConfig);
    document.getElementById("content").innerHTML = sanitized;
  };
})();
