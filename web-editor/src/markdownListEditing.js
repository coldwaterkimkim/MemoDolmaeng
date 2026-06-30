const markdownIndent = "   ";

export function markdownListEnterEdit(lineText, cursorOffset) {
  const before = lineText.slice(0, cursorOffset);
  const after = lineText.slice(cursorOffset);
  const marker = parseListMarker(before);

  if (!marker || after.trim().length > 0) {
    return null;
  }

  if (before.slice(marker.full.length).trim().length === 0) {
    return {
      type: "exit",
      fromOffset: 0,
      toOffset: lineText.length,
      insert: "",
      cursorOffset: 0
    };
  }

  return {
    type: "continue",
    insert: `\n${marker.next}`
  };
}

export function markdownListIndentEdit(lineText, outdent) {
  const marker = parseListMarker(lineText);
  if (!marker) return null;

  if (outdent) {
    const removeLength = outdentLength(marker.indent);
    if (removeLength === 0) return null;

    return {
      fromOffset: 0,
      toOffset: removeLength,
      insert: ""
    };
  }

  const nextMarkerText = marker.type === "ordered"
    ? `1${marker.delimiter}${marker.spacing}`
    : marker.markerText;

  return {
    fromOffset: 0,
    toOffset: marker.full.length,
    insert: `${marker.indent}${markdownIndent}${nextMarkerText}`
  };
}

export function parseListMarker(prefix) {
  let match = prefix.match(/^(\s*)([-*+])\s+\[([ xX])\]\s+/);
  if (match) {
    const markerText = `${match[2]} [${match[3]}] `;
    return {
      type: "task",
      full: match[0],
      indent: match[1],
      markerText,
      next: `${match[1]}- [ ] `
    };
  }

  match = prefix.match(/^(\s*)([-*+])\s+/);
  if (match) {
    const markerText = `${match[2]} `;
    return {
      type: "bullet",
      full: match[0],
      indent: match[1],
      markerText,
      next: match[0]
    };
  }

  match = prefix.match(/^(\s*)(\d+)([.)])(\s+)/);
  if (match) {
    const nextNumber = Number(match[2]) + 1;
    return {
      type: "ordered",
      full: match[0],
      indent: match[1],
      number: Number(match[2]),
      delimiter: match[3],
      spacing: match[4],
      markerText: `${match[2]}${match[3]}${match[4]}`,
      next: `${match[1]}${nextNumber}${match[3]}${match[4]}`
    };
  }

  return null;
}

function outdentLength(indent) {
  if (!indent) return 0;
  if (indent.startsWith("\t")) return 1;

  const spaces = indent.match(/^ +/)?.[0].length || 0;
  return Math.min(markdownIndent.length, spaces);
}
