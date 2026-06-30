import assert from "node:assert/strict";
import test from "node:test";
import {
  markdownFromClipboardPayload,
  markdownFromHtml,
  sanitizeURL,
  semanticTextColor
} from "../src/markdownPasteImporter.js";

test("converts semantic rich clipboard HTML into raw Markdown", () => {
  const markdown = markdownFromHtml(`
    <article>
      <h2>지금 제일 빠른 해결법</h2>
      <p><strong>핵심 단어</strong>와 <em>기울임</em>, <del>취소선</del></p>
      <ol>
        <li>성북구 고객센터에 전화한다</li>
        <li>누락 수거인지 확인한다</li>
      </ol>
      <ul>
        <li><input type="checkbox" checked> 처리 완료</li>
        <li><input type="checkbox"> 추가 신고</li>
      </ul>
      <blockquote>신고 품목과 수거원 판단이 다를 수 있음.</blockquote>
      <table>
        <thead><tr><th>품목</th><th>상태</th></tr></thead>
        <tbody><tr><td>2층침대</td><td>수거</td></tr></tbody>
      </table>
      <p><a href="https://example.com/path?q=1">안전 링크</a></p>
      <p><a href="javascript:alert(1)">위험 링크</a></p>
      <p><img src="https://example.com/image.png" alt="예시 이미지"></p>
      <pre><code class="language-swift">let answer = 42
</code></pre>
    </article>
  `);

  assert.match(markdown, /## 지금 제일 빠른 해결법/);
  assert.match(markdown, /\*\*핵심 단어\*\*/);
  assert.match(markdown, /\*기울임\*/);
  assert.match(markdown, /~~취소선~~/);
  assert.match(markdown, /1\. 성북구 고객센터에 전화한다/);
  assert.match(markdown, /2\. 누락 수거인지 확인한다/);
  assert.match(markdown, /- \[x\] 처리 완료/);
  assert.match(markdown, /- \[ \] 추가 신고/);
  assert.match(markdown, /> 신고 품목과 수거원 판단이 다를 수 있음\./);
  assert.match(markdown, /\| 품목 \| 상태 \|/);
  assert.match(markdown, /\[안전 링크\]\(https:\/\/example\.com\/path\?q=1\)/);
  assert.doesNotMatch(markdown, /javascript:/);
  assert.match(markdown, /!\[예시 이미지\]\(https:\/\/example\.com\/image\.png\)/);
  assert.match(markdown, /```swift\nlet answer = 42\n```/);
});

test("preserves only meaningful inline text colors", () => {
  const markdown = markdownFromHtml(`
    <p class="text-token-text-primary" style="color: rgb(255, 255, 255)">기본 흰색 본문</p>
    <p><span style="color: rgb(239, 68, 68)">빨간 강조</span></p>
    <p><span style="color: #777777">회색 UI톤</span></p>
    <p><font color="blue">파란 강조</font></p>
  `);

  assert.match(markdown, /기본 흰색 본문/);
  assert.doesNotMatch(markdown, /text-token-text-primary/);
  assert.match(markdown, /<span style="color: #ef4444">빨간 강조<\/span>/);
  assert.match(markdown, /회색 UI톤/);
  assert.doesNotMatch(markdown, /#777777/);
  assert.match(markdown, /<span style="color: #0000ff">파란 강조<\/span>/);
});

test("normalizes and rejects unsafe URLs and theme colors", () => {
  assert.equal(sanitizeURL("https://openai.com"), "https://openai.com");
  assert.equal(sanitizeURL("mailto:hello@example.com"), "mailto:hello@example.com");
  assert.equal(sanitizeURL("/local/path"), "/local/path");
  assert.equal(sanitizeURL("javascript:alert(1)"), null);
  assert.equal(sanitizeURL("data:text/html,hello"), null);

  assert.equal(semanticTextColor("rgb(255, 255, 255)"), null);
  assert.equal(semanticTextColor("rgb(20, 20, 20)"), null);
  assert.equal(semanticTextColor("rgb(119, 119, 119)"), null);
  assert.equal(semanticTextColor("rgba(239, 68, 68, 0.3)"), null);
  assert.equal(semanticTextColor("rgb(239, 68, 68)"), "#ef4444");
});

test("prefers HTML clipboard payload and falls back to plain text", () => {
  assert.equal(
    markdownFromClipboardPayload("<h2>HTML wins</h2>", "PLAIN FALLBACK"),
    "## HTML wins"
  );

  assert.equal(
    markdownFromClipboardPayload("", "PLAIN FALLBACK"),
    "PLAIN FALLBACK"
  );
});

test("drops clipboard UI artifacts and unescapes readable Markdown markers", () => {
  const markdown = markdownFromHtml(`
    <article>
      <button aria-label="Copy"><svg><title>Copy</title></svg></button>
      <h1>1. 먼저 아주 얇은 테스트 브리프 고정</h1>
      <p>지금은 **“사람들이 원하냐”**만 확인하면 됨.</p>
      <ul>
        <li>실제 앱</li>
        <li>실제 스트리밍</li>
        <li>판권 계약</li>
      </ul>
    </article>
  `);

  assert.doesNotMatch(markdown, /Copy/);
  assert.doesNotMatch(markdown, /\\\./);
  assert.match(markdown, /# 1\. 먼저 아주 얇은 테스트 브리프 고정/);
  assert.match(markdown, /\*\*“사람들이 원하냐”\*\*/);
  assert.match(markdown, /- 실제 앱\n- 실제 스트리밍\n- 판권 계약/);
});
