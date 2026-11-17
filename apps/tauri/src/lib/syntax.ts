// Syntax colors and runnable-code checks for code blocks (`SyntaxTokenizer` + `CodeBlockStyle` on the Mac).
// Reads one line at a time, carrying block comments, multi-line strings, HTML tags and Markdown fences across lines.
// Token offsets are UTF-16 code-unit indices (matching JS `string.slice`), and every output slice is HTML-escaped.

export type SyntaxLanguage =
  | "swift"
  | "typescript"
  | "python"
  | "rust"
  | "go"
  | "json"
  | "yaml"
  | "shell"
  | "css"
  | "html"
  | "markdown";

export type SyntaxTokenKind = "keyword" | "string" | "comment" | "number" | "type" | "property" | "tag" | "attribute";

export interface SyntaxToken {
  kind: SyntaxTokenKind;
  start: number;
  end: number;
}

export type SyntaxCarry =
  | { kind: "none" }
  | { kind: "blockComment" }
  | { kind: "string"; delimiter: string }
  | { kind: "tag" }
  | { kind: "fence" };

export const NO_CARRY: SyntaxCarry = { kind: "none" };

const COLOR_LIMIT = 20_000;
const CACHE_LIMIT = 200;

const SHELL_NAMES = new Set([".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".envrc"]);

const EXTENSION_MAP: Record<string, SyntaxLanguage> = {
  swift: "swift",
  ts: "typescript",
  tsx: "typescript",
  mts: "typescript",
  cts: "typescript",
  js: "typescript",
  jsx: "typescript",
  mjs: "typescript",
  cjs: "typescript",
  py: "python",
  pyi: "python",
  rs: "rust",
  go: "go",
  json: "json",
  jsonc: "json",
  json5: "json",
  yml: "yaml",
  yaml: "yaml",
  sh: "shell",
  bash: "shell",
  zsh: "shell",
  fish: "shell",
  ps1: "shell",
  pwsh: "shell",
  powershell: "shell",
  css: "css",
  scss: "css",
  less: "css",
  html: "html",
  htm: "html",
  xml: "html",
  svg: "html",
  vue: "html",
  svelte: "html",
  plist: "html",
  md: "markdown",
  markdown: "markdown",
  mdx: "markdown",
};

const FENCE_ALIASES: Record<string, string> = {
  typescript: "ts",
  javascript: "js",
  tsx: "tsx",
  jsx: "jsx",
  python: "py",
  py: "py",
  rust: "rs",
  golang: "go",
  yml: "yaml",
  shell: "sh",
  console: "sh",
  shellsession: "sh",
  zsh: "zsh",
  bash: "sh",
  sh: "sh",
  fish: "fish",
  powershell: "ps1",
  pwsh: "pwsh",
  ps1: "ps1",
  markdown: "md",
  md: "md",
  xml: "xml",
  svg: "svg",
  vue: "vue",
  svelte: "svelte",
  jsonc: "jsonc",
  json5: "json5",
  scss: "scss",
  less: "less",
};

const SHELL_LANGUAGES = new Set(["sh", "bash", "zsh", "fish", "shell", "console", "shellsession", "powershell", "pwsh", "ps1"]);

export function isShellLanguage(language: string): boolean {
  return SHELL_LANGUAGES.has(language.toLowerCase());
}

/** The language of a file by its name or path; `null` when unknown (shown plain). */
export function detectSyntaxLanguage(path: string): SyntaxLanguage | null {
  const name = (path.split(/[\\/]/).pop() ?? "").toLowerCase();
  if (SHELL_NAMES.has(name)) return "shell";
  const dot = name.lastIndexOf(".");
  if (dot <= 0 || dot === name.length - 1) return null;
  const ext = name.slice(dot + 1);
  return EXTENSION_MAP[ext] ?? null;
}

/** The language of a code fence (`language` first, then file `title` when fence language is empty or unknown). */
export function syntaxForFence(language: string, title: string | null): SyntaxLanguage | null {
  const lang = language.trim().toLowerCase();
  if (lang) {
    const known = detectSyntaxLanguage(`x.${FENCE_ALIASES[lang] ?? lang}`);
    if (known) return known;
  }
  return title ? detectSyntaxLanguage(title) : null;
}

interface Spec {
  lineComments: string[];
  block?: { open: string; close: string };
  quotes: Set<number>;
  tripleQuotes: boolean;
  multilineBacktick: boolean;
  keywords: Set<string>;
  literals: Set<string>;
  capitalizedTypes: boolean;
  attributes: boolean;
  variables: boolean;
  keys: boolean;
  dashInNames: boolean;
  hashNumbers: boolean;
  signedNumbers: boolean;
  hashNeedsSpace: boolean;
}

const C_SPACE = 0x20;
const C_TAB = 0x09;
const C_CR = 0x0d;
const C_QUOTE = 0x22;
const C_APOS = 0x27;
const C_BACKTICK = 0x60;
const C_BACKSLASH = 0x5c;
const C_DOT = 0x2e;
const C_MINUS = 0x2d;
const C_PLUS = 0x2b;
const C_STAR = 0x2a;
const C_HASH = 0x23;
const C_AT = 0x40;
const C_DOLLAR = 0x24;
const C_COLON = 0x3a;
const C_LESS = 0x3c;
const C_GREATER = 0x3e;
const C_SLASH = 0x2f;
const C_BANG = 0x21;
const C_QUESTION = 0x3f;
const C_TILDE = 0x7e;
const C_OPEN_BRACE = 0x7b;
const C_CLOSE_BRACE = 0x7d;
const C_OPEN_PAREN = 0x28;
const C_CLOSE_PAREN = 0x29;
const C_CLOSE_BRACKET = 0x5d;

const SWIFT_KEYWORDS = new Set([
  "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch", "class", "continue", "convenience",
  "default", "defer", "deinit", "do", "else", "enum", "extension", "fallthrough", "fileprivate", "final", "for", "func",
  "get", "guard", "if", "import", "in", "indirect", "init", "inout", "internal", "is", "isolated", "lazy", "let",
  "mutating", "nonisolated", "nonmutating", "open", "operator", "override", "private", "protocol", "public", "repeat",
  "required", "rethrows", "return", "self", "Self", "set", "some", "static", "struct", "subscript", "super", "switch",
  "throw", "throws", "try", "typealias", "var", "weak", "unowned", "where", "while", "willSet", "didSet", "consuming",
  "borrowing", "sending",
]);

const TYPESCRIPT_KEYWORDS = new Set([
  "abstract", "as", "async", "await", "break", "case", "catch", "class", "const", "constructor", "continue", "debugger",
  "declare", "default", "delete", "do", "else", "enum", "export", "extends", "finally", "for", "from", "function", "get",
  "if", "implements", "import", "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "of", "private",
  "protected", "public", "readonly", "return", "satisfies", "set", "static", "super", "switch", "this", "throw", "try",
  "type", "typeof", "var", "void", "while", "with", "yield",
]);

const PYTHON_KEYWORDS = new Set([
  "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del", "elif", "else", "except",
  "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass",
  "raise", "return", "self", "try", "while", "with", "yield",
]);

const RUST_KEYWORDS = new Set([
  "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if",
  "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct",
  "super", "trait", "type", "unsafe", "use", "where", "while",
]);

const GO_KEYWORDS = new Set([
  "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto",
  "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var",
]);

const SHELL_KEYWORDS = new Set([
  "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return",
  "local", "export", "readonly", "set", "unset", "source", "exit", "echo", "cd", "shift", "trap", "eval", "exec",
]);

function specOf(language: SyntaxLanguage): Spec {
  switch (language) {
    case "swift":
      return {
        lineComments: ["//"], block: { open: "/*", close: "*/" }, quotes: new Set([C_QUOTE]), tripleQuotes: true,
        multilineBacktick: false, keywords: SWIFT_KEYWORDS, literals: new Set(["true", "false", "nil"]),
        capitalizedTypes: true, attributes: true, variables: false, keys: false, dashInNames: false,
        hashNumbers: false, signedNumbers: false, hashNeedsSpace: false,
      };
    case "typescript":
      return {
        lineComments: ["//"], block: { open: "/*", close: "*/" }, quotes: new Set([C_QUOTE, C_APOS, C_BACKTICK]),
        tripleQuotes: false, multilineBacktick: true, keywords: TYPESCRIPT_KEYWORDS,
        literals: new Set(["true", "false", "null", "undefined", "NaN"]), capitalizedTypes: true, attributes: true,
        variables: false, keys: false, dashInNames: false, hashNumbers: false, signedNumbers: false, hashNeedsSpace: false,
      };
    case "python":
      return {
        lineComments: ["#"], quotes: new Set([C_QUOTE, C_APOS]), tripleQuotes: true, multilineBacktick: false,
        keywords: PYTHON_KEYWORDS, literals: new Set(["True", "False", "None"]), capitalizedTypes: true, attributes: true,
        variables: false, keys: false, dashInNames: false, hashNumbers: false, signedNumbers: false, hashNeedsSpace: false,
      };
    case "rust":
      return {
        lineComments: ["//"], block: { open: "/*", close: "*/" }, quotes: new Set([C_QUOTE]), tripleQuotes: false,
        multilineBacktick: false, keywords: RUST_KEYWORDS, literals: new Set(["true", "false"]), capitalizedTypes: true,
        attributes: false, variables: false, keys: false, dashInNames: false, hashNumbers: false, signedNumbers: false, hashNeedsSpace: false,
      };
    case "go":
      return {
        lineComments: ["//"], block: { open: "/*", close: "*/" }, quotes: new Set([C_QUOTE, C_APOS, C_BACKTICK]),
        tripleQuotes: false, multilineBacktick: true, keywords: GO_KEYWORDS, literals: new Set(["true", "false", "nil", "iota"]),
        capitalizedTypes: true, attributes: false, variables: false, keys: false, dashInNames: false,
        hashNumbers: false, signedNumbers: false, hashNeedsSpace: false,
      };
    case "json":
      return {
        lineComments: ["//"], block: { open: "/*", close: "*/" }, quotes: new Set([C_QUOTE]), tripleQuotes: false,
        multilineBacktick: false, keywords: new Set(), literals: new Set(["true", "false", "null"]),
        capitalizedTypes: false, attributes: false, variables: false, keys: true, dashInNames: false,
        hashNumbers: false, signedNumbers: true, hashNeedsSpace: false,
      };
    case "yaml":
      return {
        lineComments: ["#"], quotes: new Set([C_QUOTE, C_APOS]), tripleQuotes: false, multilineBacktick: false,
        keywords: new Set(), literals: new Set(["true", "false", "null", "yes", "no", "on", "off", "~"]),
        capitalizedTypes: false, attributes: false, variables: false, keys: true, dashInNames: true,
        hashNumbers: false, signedNumbers: true, hashNeedsSpace: true,
      };
    case "shell":
      return {
        lineComments: ["#"], quotes: new Set([C_QUOTE, C_APOS]), tripleQuotes: false, multilineBacktick: false,
        keywords: SHELL_KEYWORDS, literals: new Set(["true", "false"]), capitalizedTypes: false, attributes: false,
        variables: true, keys: false, dashInNames: false, hashNumbers: false, signedNumbers: false, hashNeedsSpace: true,
      };
    case "css":
      return {
        lineComments: [], block: { open: "/*", close: "*/" }, quotes: new Set([C_QUOTE, C_APOS]), tripleQuotes: false,
        multilineBacktick: false, keywords: new Set(["important"]), literals: new Set(), capitalizedTypes: false,
        attributes: true, variables: false, keys: true, dashInNames: true, hashNumbers: true, signedNumbers: false, hashNeedsSpace: false,
      };
    case "html":
    case "markdown":
      return {
        lineComments: [], quotes: new Set(), tripleQuotes: false, multilineBacktick: false,
        keywords: new Set(), literals: new Set(), capitalizedTypes: false, attributes: false, variables: false,
        keys: false, dashInNames: false, hashNumbers: false, signedNumbers: false, hashNeedsSpace: false,
      };
  }
}

const isSpace = (c: number) => c === C_SPACE || c === C_TAB || c === C_CR;
const isDigit = (c: number) => c >= 0x30 && c <= 0x39;
const isUpper = (c: number) => c >= 0x41 && c <= 0x5a;
const isHex = (c: number) => isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
const isSign = (c: number) => c === C_PLUS || c === C_MINUS;
const isExponent = (c: number) => c === 0x65 || c === 0x45;
const isSpecialVariable = (c: number) => c === 0x23 || c === 0x3f || c === 0x40 || c === 0x2a || c === 0x21 || c === 0x24 || isDigit(c);
const isNameStart = (c: number) => (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c === 0x5f || c > 0x7f;
const isNameChar = (c: number) => isNameStart(c) || isDigit(c);

function matchesAt(line: string, pattern: string, index: number): boolean {
  return line.startsWith(pattern, index);
}

function findPast(line: string, pattern: string, from: number): number | null {
  const pos = line.indexOf(pattern, from);
  return pos >= 0 ? pos + pattern.length : null;
}

function findClosing(line: string, delimiter: string, from: number): number | null {
  let j = from;
  while (j + delimiter.length <= line.length) {
    if (line.charCodeAt(j) === C_BACKSLASH) {
      j += 2;
      continue;
    }
    if (line.startsWith(delimiter, j)) return j + delimiter.length;
    j += 1;
  }
  return null;
}

function nextIsColon(line: string, from: number): boolean {
  let j = from;
  while (j < line.length && (line.charCodeAt(j) === C_SPACE || line.charCodeAt(j) === C_TAB)) j += 1;
  if (j >= line.length || line.charCodeAt(j) !== C_COLON) return false;
  return j + 1 >= line.length || line.charCodeAt(j + 1) !== C_COLON;
}

function tokenizeGeneric(line: string, spec: Spec, carry: SyntaxCarry): { tokens: SyntaxToken[]; carry: SyntaxCarry } {
  const tokens: SyntaxToken[] = [];
  const n = line.length;
  let i = 0;
  const add = (kind: SyntaxTokenKind, start: number, end: number) => {
    if (end > start) tokens.push({ kind, start, end });
  };

  if (carry.kind === "blockComment" && spec.block) {
    const end = findPast(line, spec.block.close, 0);
    if (end !== null) {
      add("comment", 0, end);
      i = end;
    } else {
      add("comment", 0, n);
      return { tokens, carry };
    }
  } else if (carry.kind === "string") {
    const end = findClosing(line, carry.delimiter, 0);
    if (end !== null) {
      add("string", 0, end);
      i = end;
    } else {
      add("string", 0, n);
      return { tokens, carry };
    }
  }

  while (i < n) {
    const c = line.charCodeAt(i);
    if (isSpace(c)) {
      i += 1;
      continue;
    }
    const lineComment = spec.lineComments.find(
      (marker) => matchesAt(line, marker, i) && !(spec.hashNeedsSpace && marker === "#" && i > 0 && !isSpace(line.charCodeAt(i - 1))),
    );
    if (lineComment) {
      add("comment", i, n);
      break;
    }
    if (spec.block && matchesAt(line, spec.block.open, i)) {
      const end = findPast(line, spec.block.close, i + spec.block.open.length);
      if (end !== null) {
        add("comment", i, end);
        i = end;
        continue;
      }
      add("comment", i, n);
      return { tokens, carry: { kind: "blockComment" } };
    }
    if (spec.tripleQuotes && (c === C_QUOTE || c === C_APOS) && i + 2 < n && line.charCodeAt(i + 1) === c && line.charCodeAt(i + 2) === c) {
      const delimiter = c === C_QUOTE ? '"""' : "'''";
      const end = findClosing(line, delimiter, i + 3);
      if (end !== null) {
        add("string", i, end);
        i = end;
        continue;
      }
      add("string", i, n);
      return { tokens, carry: { kind: "string", delimiter } };
    }
    if (spec.quotes.has(c)) {
      const start = i;
      const delim = String.fromCharCode(c);
      const end = findClosing(line, delim, i + 1);
      if (end !== null) {
        i = end;
      } else {
        add("string", start, n);
        if (c === C_BACKTICK && spec.multilineBacktick) {
          return { tokens, carry: { kind: "string", delimiter: "`" } };
        }
        break;
      }
      add(spec.keys && nextIsColon(line, i) ? "property" : "string", start, i);
      continue;
    }
    if (
      isDigit(c) ||
      (c === C_DOT && i + 1 < n && isDigit(line.charCodeAt(i + 1)) && (i === 0 || !isNameChar(line.charCodeAt(i - 1)))) ||
      (spec.signedNumbers && c === C_MINUS && i + 1 < n && isDigit(line.charCodeAt(i + 1)) && (i === 0 || !isNameChar(line.charCodeAt(i - 1))))
    ) {
      const start = i;
      i += 1;
      while (
        i < n &&
        (isNameChar(line.charCodeAt(i)) ||
          line.charCodeAt(i) === C_DOT ||
          (isSign(line.charCodeAt(i)) && isExponent(line.charCodeAt(i - 1))))
      ) {
        i += 1;
      }
      add("number", start, i);
      continue;
    }
    if (spec.hashNumbers && c === C_HASH && i + 1 < n && isHex(line.charCodeAt(i + 1))) {
      const start = i;
      i += 1;
      while (i < n && isNameChar(line.charCodeAt(i))) i += 1;
      add("number", start, i);
      continue;
    }
    if (spec.attributes && c === C_AT && i + 1 < n && isNameStart(line.charCodeAt(i + 1))) {
      const start = i;
      i += 1;
      while (
        i < n &&
        (isNameChar(line.charCodeAt(i)) || (spec.dashInNames && line.charCodeAt(i) === C_MINUS) || line.charCodeAt(i) === C_DOT)
      ) {
        i += 1;
      }
      add("attribute", start, i);
      continue;
    }
    if (spec.variables && c === C_DOLLAR && i + 1 < n) {
      const start = i;
      i += 1;
      if (line.charCodeAt(i) === C_OPEN_BRACE) {
        while (i < n && line.charCodeAt(i) !== C_CLOSE_BRACE) i += 1;
        i = Math.min(i + 1, n);
      } else {
        while (i < n && (isNameChar(line.charCodeAt(i)) || (i === start + 1 && isSpecialVariable(line.charCodeAt(i))))) i += 1;
      }
      if (i > start + 1) add("property", start, i);
      continue;
    }
    if (isNameStart(c)) {
      const start = i;
      i += 1;
      while (
        i < n &&
        (isNameChar(line.charCodeAt(i)) ||
          (spec.dashInNames && line.charCodeAt(i) === C_MINUS && i + 1 < n && isNameChar(line.charCodeAt(i + 1))))
      ) {
        i += 1;
      }
      const word = line.slice(start, i);
      if (spec.keywords.has(word)) add("keyword", start, i);
      else if (spec.literals.has(word)) add("number", start, i);
      else if (spec.keys && nextIsColon(line, i)) add("property", start, i);
      else if (spec.capitalizedTypes && isUpper(line.charCodeAt(start))) add("type", start, i);
      continue;
    }
    i += 1;
  }
  return { tokens, carry: NO_CARRY };
}

function tokenizeHtml(line: string, carry: SyntaxCarry): { tokens: SyntaxToken[]; carry: SyntaxCarry } {
  const tokens: SyntaxToken[] = [];
  const n = line.length;
  let i = 0;
  let inTag = carry.kind === "tag";
  const add = (kind: SyntaxTokenKind, start: number, end: number) => {
    if (end > start) tokens.push({ kind, start, end });
  };

  if (carry.kind === "blockComment") {
    const end = findPast(line, "-->", 0);
    if (end === null) return { tokens: [{ kind: "comment", start: 0, end: n }], carry };
    add("comment", 0, end);
    i = end;
  }

  while (i < n) {
    const c = line.charCodeAt(i);
    if (inTag) {
      if (isSpace(c)) {
        i += 1;
        continue;
      }
      if (c === C_GREATER || (c === C_SLASH && i + 1 < n && line.charCodeAt(i + 1) === C_GREATER)) {
        const end = c === C_SLASH ? i + 2 : i + 1;
        add("tag", i, end);
        i = end;
        inTag = false;
        continue;
      }
      if (c === C_QUOTE || c === C_APOS) {
        const start = i;
        i += 1;
        while (i < n && line.charCodeAt(i) !== c) i += 1;
        i = Math.min(i + 1, n);
        add("string", start, i);
        continue;
      }
      if (isNameStart(c)) {
        const start = i;
        while (i < n && (isNameChar(line.charCodeAt(i)) || line.charCodeAt(i) === C_MINUS || line.charCodeAt(i) === C_COLON)) {
          i += 1;
        }
        add("property", start, i);
        continue;
      }
      i += 1;
      continue;
    }
    if (c === C_LESS && i + 3 < n && line.startsWith("<!--", i)) {
      const end = findPast(line, "-->", i + 4);
      if (end === null) {
        add("comment", i, n);
        return { tokens, carry: { kind: "blockComment" } };
      }
      add("comment", i, end);
      i = end;
      continue;
    }
    if (
      c === C_LESS &&
      i + 1 < n &&
      (isNameStart(line.charCodeAt(i + 1)) ||
        line.charCodeAt(i + 1) === C_SLASH ||
        line.charCodeAt(i + 1) === C_BANG ||
        line.charCodeAt(i + 1) === C_QUESTION)
    ) {
      const start = i;
      i += 1;
      if (line.charCodeAt(i) === C_SLASH || line.charCodeAt(i) === C_BANG || line.charCodeAt(i) === C_QUESTION) i += 1;
      while (i < n && (isNameChar(line.charCodeAt(i)) || line.charCodeAt(i) === C_MINUS || line.charCodeAt(i) === C_COLON)) {
        i += 1;
      }
      add("tag", start, i);
      inTag = true;
      continue;
    }
    i += 1;
  }
  return { tokens, carry: inTag ? { kind: "tag" } : NO_CARRY };
}

function tokenizeMarkdown(line: string, carry: SyntaxCarry): { tokens: SyntaxToken[]; carry: SyntaxCarry } {
  const n = line.length;
  let start = 0;
  while (start < n && isSpace(line.charCodeAt(start))) start += 1;
  const fence =
    start + 2 < n &&
    ((line.charCodeAt(start) === C_BACKTICK && line.charCodeAt(start + 1) === C_BACKTICK && line.charCodeAt(start + 2) === C_BACKTICK) ||
      (line.charCodeAt(start) === C_TILDE && line.charCodeAt(start + 1) === C_TILDE && line.charCodeAt(start + 2) === C_TILDE));
  if (fence) {
    return { tokens: [{ kind: "comment", start: 0, end: n }], carry: carry.kind === "fence" ? NO_CARRY : { kind: "fence" } };
  }
  if (carry.kind === "fence") return { tokens: [], carry };
  if (start >= n) return { tokens: [], carry: NO_CARRY };

  if (line.charCodeAt(start) === C_HASH) {
    let j = start;
    while (j < n && line.charCodeAt(j) === C_HASH) j += 1;
    if (j - start <= 6 && (j === n || isSpace(line.charCodeAt(j)))) {
      return { tokens: [{ kind: "keyword", start, end: n }], carry: NO_CARRY };
    }
  }
  if (line.charCodeAt(start) === C_GREATER) {
    return { tokens: [{ kind: "comment", start, end: n }], carry: NO_CARRY };
  }

  const tokens: SyntaxToken[] = [];
  let i = start;
  const c0 = line.charCodeAt(i);
  if ((c0 === C_MINUS || c0 === C_STAR || c0 === C_PLUS) && i + 1 < n && isSpace(line.charCodeAt(i + 1))) {
    tokens.push({ kind: "keyword", start: i, end: i + 1 });
    i += 2;
  } else {
    let j = i;
    while (j < n && isDigit(line.charCodeAt(j))) j += 1;
    if (j > i && j + 1 < n && line.charCodeAt(j) === C_DOT && isSpace(line.charCodeAt(j + 1))) {
      tokens.push({ kind: "keyword", start: i, end: j + 1 });
      i = j + 2;
    }
  }

  while (i < n) {
    const c = line.charCodeAt(i);
    if (c === C_BACKTICK) {
      const begin = i;
      i += 1;
      while (i < n && line.charCodeAt(i) !== C_BACKTICK) i += 1;
      if (i < n) {
        i += 1;
        tokens.push({ kind: "string", start: begin, end: i });
      }
      continue;
    }
    if (c === C_CLOSE_BRACKET && i + 1 < n && line.charCodeAt(i + 1) === C_OPEN_PAREN) {
      const begin = i + 2;
      let j = begin;
      while (j < n && line.charCodeAt(j) !== C_CLOSE_PAREN) j += 1;
      if (j < n && j > begin) tokens.push({ kind: "property", start: begin, end: j });
      i = j + 1;
      continue;
    }
    i += 1;
  }
  return { tokens, carry: NO_CARRY };
}

export function tokenizeLine(
  line: string,
  language: SyntaxLanguage,
  carry: SyntaxCarry = NO_CARRY,
): { tokens: SyntaxToken[]; carry: SyntaxCarry } {
  if (language === "html") return tokenizeHtml(line, carry);
  if (language === "markdown") return tokenizeMarkdown(line, carry);
  return tokenizeGeneric(line, specOf(language), carry);
}

function escapeHtml(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

const highlightCache = new Map<string, string>();

/** Renders `code` to HTML with `<span class="tok-…">` token runs, or `null` when unknown or over 20,000 chars. */
export function highlightCodeToHtml(code: string, language: string, title: string | null = null): string | null {
  const syntax = syntaxForFence(language, title);
  if (!syntax || code.length > COLOR_LIMIT) return null;
  const key = `${syntax}\0${code}`;
  const hit = highlightCache.get(key);
  if (hit !== undefined) return hit;

  const lines = code.split("\n");
  const out: string[] = [];
  let carry: SyntaxCarry = NO_CARRY;
  for (let lineIdx = 0; lineIdx < lines.length; lineIdx += 1) {
    if (lineIdx > 0) out.push("\n");
    const line = lines[lineIdx];
    const { tokens, carry: next } = tokenizeLine(line, syntax, carry);
    carry = next;
    if (!tokens.length) {
      out.push(escapeHtml(line));
      continue;
    }
    let cursor = 0;
    for (const token of tokens) {
      const start = Math.max(cursor, Math.min(line.length, token.start));
      const end = Math.max(start, Math.min(line.length, token.end));
      if (start > cursor) out.push(escapeHtml(line.slice(cursor, start)));
      if (end > start) out.push(`<span class="tok-${token.kind}">${escapeHtml(line.slice(start, end))}</span>`);
      cursor = end;
    }
    if (cursor < line.length) out.push(escapeHtml(line.slice(cursor)));
  }

  const html = out.join("");
  if (highlightCache.size >= CACHE_LIMIT) {
    const oldest = highlightCache.keys().next().value;
    if (oldest !== undefined) highlightCache.delete(oldest);
  }
  highlightCache.set(key, html);
  return html;
}

/** Whether a shell code block can safely be offered with a Run button (`CodeBlockStyle.canRun` on the Mac). */
export function canRunCode(code: string): boolean {
  const text = code.trim();
  if (!text || text.endsWith("\\")) return false;
  for (let i = 0; i < text.length; i += 1) {
    const codeUnit = text.charCodeAt(i);
    if ((codeUnit < 0x20 && codeUnit !== 0x0a && codeUnit !== 0x09) || codeUnit === 0x7f) return false;
    if ((codeUnit >= 0x202a && codeUnit <= 0x202e) || (codeUnit >= 0x2066 && codeUnit <= 0x2069)) return false;
  }
  return true;
}

/** Strips leading `$ ` prompts when every non-empty line carries one (`CodeBlockStyle.command` on the Mac). */
export function shellCommand(code: string): string {
  const lines = code.trim().split("\n");
  const prompted = lines.every((line) => !line.trim() || line.startsWith("$ "));
  return (prompted ? lines.map((line) => (line.startsWith("$ ") ? line.slice(2) : line)) : lines).join("\n");
}
