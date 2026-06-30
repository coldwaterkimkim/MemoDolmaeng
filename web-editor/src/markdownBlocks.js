export function parseFencedCodeBlocks(markdown) {
  const lines = splitMarkdownLines(markdown);
  const blocks = [];
  let open = null;

  for (const line of lines) {
    const match = line.text.match(/^(\s*)(`{3,}|~{3,})(.*)$/);
    if (!open && match) {
      open = {
        startLine: line.number,
        from: line.from,
        fenceCharacter: match[2][0],
        openingMarkerLength: match[1].length + match[2].length,
        info: (match[3].trim().split(/\s+/)[0] || "").trim()
      };
      continue;
    }

    if (!open) continue;

    if (match && match[2][0] === open.fenceCharacter) {
      blocks.push(buildCodeBlock(open, line, lines, true, match[1].length + match[2].length));
      open = null;
    }
  }

  if (open && lines.length) {
    blocks.push(buildCodeBlock(open, lines[lines.length - 1], lines, false, 0));
  }

  return blocks;
}

export function parseTableBlocks(markdown, ignoredBlocks = []) {
  const lines = splitMarkdownLines(markdown);
  const ignoredLines = ignoredLineNumbers(ignoredBlocks);
  const blocks = [];
  let index = 0;

  while (index < lines.length - 1) {
    const headerLine = lines[index];
    const delimiterLine = lines[index + 1];

    if (
      ignoredLines.has(headerLine.number)
      || ignoredLines.has(delimiterLine.number)
      || !looksLikeTableLine(headerLine.text)
      || !isTableDelimiterLine(delimiterLine.text)
    ) {
      index += 1;
      continue;
    }

    const header = splitTableRow(headerLine.text);
    const alignments = splitTableRow(delimiterLine.text).map(tableAlignment);
    const rows = [];
    let endIndex = index + 1;
    let rowIndex = index + 2;

    while (
      rowIndex < lines.length
      && !ignoredLines.has(lines[rowIndex].number)
      && looksLikeTableLine(lines[rowIndex].text)
    ) {
      rows.push(splitTableRow(lines[rowIndex].text));
      endIndex = rowIndex;
      rowIndex += 1;
    }

    blocks.push({
      type: "table",
      startLine: headerLine.number,
      endLine: lines[endIndex].number,
      from: headerLine.from,
      to: lines[endIndex].to,
      header,
      alignments,
      rows
    });

    index = endIndex + 1;
  }

  return blocks;
}

export function splitTableRow(text) {
  let trimmed = text.trim();
  if (trimmed.startsWith("|")) trimmed = trimmed.slice(1);
  if (trimmed.endsWith("|")) trimmed = trimmed.slice(0, -1);

  const cells = [];
  let current = "";
  let escaping = false;

  for (const character of trimmed) {
    if (escaping) {
      current += character;
      escaping = false;
      continue;
    }

    if (character === "\\") {
      escaping = true;
      continue;
    }

    if (character === "|") {
      cells.push(current.trim());
      current = "";
      continue;
    }

    current += character;
  }

  cells.push(current.trim());
  return cells;
}

export function looksLikeTableLine(text) {
  const trimmed = text.trim();
  return trimmed.includes("|") && /^\|?.+\|.+\|?$/.test(trimmed);
}

function splitMarkdownLines(markdown) {
  const text = markdown || "";
  const rawLines = text.split("\n");
  const lines = [];
  let from = 0;

  rawLines.forEach((line, index) => {
    lines.push({
      number: index + 1,
      text: line,
      from,
      to: from + line.length
    });
    from += line.length + 1;
  });

  return lines;
}

function buildCodeBlock(open, closeLine, lines, closed, closingMarkerLength) {
  const bodyStart = open.startLine + 1;
  const bodyEnd = closed ? closeLine.number - 1 : closeLine.number;
  const body = lines
    .filter((line) => line.number >= bodyStart && line.number <= bodyEnd)
    .map((line) => line.text)
    .join("\n");

  return {
    type: "code",
    startLine: open.startLine,
    endLine: closeLine.number,
    from: open.from,
    to: closeLine.to,
    info: open.info,
    code: body,
    closed,
    openingMarkerLength: open.openingMarkerLength,
    closingMarkerLength
  };
}

function ignoredLineNumbers(blocks) {
  const ignored = new Set();
  for (const block of blocks) {
    for (let line = block.startLine; line <= block.endLine; line += 1) {
      ignored.add(line);
    }
  }
  return ignored;
}

function isTableDelimiterLine(text) {
  const cells = splitTableRow(text);
  return cells.length > 1 && cells.every((cell) => /^:?-{3,}:?$/.test(cell.trim()));
}

function tableAlignment(cell) {
  const trimmed = cell.trim();
  const left = trimmed.startsWith(":");
  const right = trimmed.endsWith(":");
  if (left && right) return "center";
  if (right) return "right";
  return "left";
}
