// Diagrams and math in an answer, as the iPhone and the Mac draw them: a ```mermaid fence becomes its diagram, and
// `$…$`, `$$…$$` and a ```math fence are typeset with KaTeX. Both come with the app (the same versions as the Mac's:
// Mermaid 12.3.0, KaTeX 0.16.22) and load only when an answer has one; nothing goes to a server.

/** Whether a text has anything to draw, so the libraries load only then. */
export function hasRich(text: string): boolean {
  return /```(mermaid|math)\b/.test(text) || /\$\$[\s\S]+?\$\$/.test(text) || /(^|[^\\$\w])\$[^\s$][^$\n]*?[^\s\\$]\$(?!\w)/.test(text);
}

/** The math in a text node: `[{ math, display }]` and the text between, in order. */
export function splitMath(text: string): ({ text: string } | { math: string; display: boolean })[] {
  const parts: ({ text: string } | { math: string; display: boolean })[] = [];
  const re = /\$\$([\s\S]+?)\$\$|(^|[^\\$\w])\$([^\s$][^$\n]*?[^\s\\$]|[^\s$])\$(?!\w)/g;
  let last = 0;
  let m: RegExpExecArray | null;
  while ((m = re.exec(text))) {
    const lead = m[2] ?? "";
    const start = m.index + lead.length;
    if (start > last) parts.push({ text: text.slice(last, start) });
    parts.push(m[1] !== undefined ? { math: m[1].trim(), display: true } : { math: m[3], display: false });
    last = m.index + m[0].length;
  }
  if (last < text.length) parts.push({ text: text.slice(last) });
  return parts;
}

let mermaidReady: Promise<typeof import("mermaid").default> | null = null;
let katexReady: Promise<typeof import("katex").default> | null = null;
let count = 0;

export async function renderMermaid(code: string): Promise<string | null> {
  try {
    mermaidReady ??= import("mermaid").then((m) => {
      m.default.initialize({ startOnLoad: false, theme: "dark", securityLevel: "strict", fontFamily: "inherit" });
      return m.default;
    });
    const mermaid = await mermaidReady;
    const { svg } = await mermaid.render(`nook-diagram-${++count}`, code);
    return svg;
  } catch {
    return null;
  }
}

export async function renderKatex(tex: string, display = true): Promise<string> {
  katexReady ??= Promise.all([import("katex"), import("katex/dist/katex.min.css")]).then(([k]) => k.default);
  const katex = await katexReady;
  return katex.renderToString(tex, { displayMode: display, throwOnError: false, output: "html" });
}

/** Draws the diagrams and math inside an element that holds rendered Markdown. */
export async function enhance(root: HTMLElement): Promise<void> {
  const fences = [...root.querySelectorAll<HTMLElement>("code[data-lang]")];
  const diagrams = fences.filter((c) => c.dataset.lang === "mermaid");
  const mathFences = fences.filter((c) => c.dataset.lang === "math");
  const hasInline = hasRich(root.textContent ?? "");
  if (!diagrams.length && !mathFences.length && !hasInline) return;

  if (diagrams.length) {
    mermaidReady ??= import("mermaid").then((m) => {
      m.default.initialize({ startOnLoad: false, theme: "dark", securityLevel: "strict", fontFamily: "inherit" });
      return m.default;
    });
    const mermaid = await mermaidReady;
    for (const code of diagrams) {
      const block = code.closest(".code-block") ?? code.parentElement;
      try {
        const { svg } = await mermaid.render(`nook-diagram-${++count}`, code.textContent ?? "");
        const figure = document.createElement("div");
        figure.className = "diagram";
        figure.innerHTML = svg;
        block?.replaceWith(figure);
      } catch {
        // A diagram that does not parse stays as its code.
      }
    }
  }

  if (mathFences.length || hasInline) {
    const [{ default: katex }] = await Promise.all([import("katex"), import("katex/dist/katex.min.css")]);
    const typeset = (math: string, display: boolean) => katex.renderToString(math, { displayMode: display, throwOnError: false, output: "html" });
    for (const code of mathFences) {
      const figure = document.createElement("div");
      figure.className = "math-block";
      figure.innerHTML = typeset(code.textContent ?? "", true);
      (code.closest(".code-block") ?? code.parentElement)?.replaceWith(figure);
    }
    // Math in the text, never in code.
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) => (n.parentElement?.closest("code, pre, .katex") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT),
    });
    const nodes: Text[] = [];
    while (walker.nextNode()) nodes.push(walker.currentNode as Text);
    for (const node of nodes) {
      const parts = splitMath(node.data);
      if (parts.length < 2 && !("math" in (parts[0] ?? { text: "" }))) continue;
      const fragment = document.createDocumentFragment();
      for (const part of parts) {
        if ("text" in part) fragment.append(part.text);
        else {
          const span = document.createElement(part.display ? "div" : "span");
          span.innerHTML = typeset(part.math, part.display);
          fragment.append(span);
        }
      }
      node.replaceWith(fragment);
    }
  }
}

/** A Svelte action: draws what the element's Markdown holds, again whenever `text` changes. */
export function richContent(node: HTMLElement, text: string) {
  const run = (t: string) => { if (hasRich(t) || /```(mermaid|math)/.test(t)) void enhance(node); };
  run(text);
  return { update: run };
}
