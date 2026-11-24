// A session as a Markdown document, to save or copy (`SessionExport` on the Mac): your messages and the agent's answers
// in full, the work in between as a short folded list, no thinking. No interface code, so tests use it on its own.
import type { RunEvent, WorkspaceRun } from "./api";
import { oneLine } from "./timeline";

export function sessionMarkdown(run: WorkspaceRun, events: RunEvent[], agent: string, project: string): string {
  const meta = [agent];
  const model = run.resolvedModel ?? (run.model || null);
  if (model) meta.push(model);
  meta.push(project);
  if (run.branch) meta.push(run.branch);
  meta.push(run.createdAt.slice(0, 10));
  const out = [`# ${run.title}`, "", `_${meta.join(" · ")}_`, ""];
  let work: string[] = [];
  const flushWork = () => {
    if (!work.length) return;
    out.push(`<details><summary>${work.length} ${work.length === 1 ? "step" : "steps"}</summary>`, "", ...work.map((w) => `- ${w}`), "", "</details>", "");
    work = [];
  };
  for (const event of events) {
    const text = event.text.trim();
    switch (event.kind) {
      case "user":
        flushWork();
        out.push("## You", "", text, "");
        break;
      case "assistant":
        flushWork();
        out.push(`## ${agent}`, "", text, "");
        break;
      case "tool":
      case "fileChange":
        if (text) work.push("`" + oneLine(text, 160).replace(/`/g, "'") + "`");
        break;
      case "error":
        flushWork();
        out.push(`> **Error:** ${oneLine(text, 400)}`, "");
        break;
      default:
        break;
    }
  }
  flushWork();
  return out.join("\n").trim() + "\n";
}

/// "fix-login-bug.md".
export function sessionFileName(title: string): string {
  const slug = title.toLowerCase().normalize("NFKD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 60).replace(/-+$/, "");
  return `${slug || "session"}.md`;
}
