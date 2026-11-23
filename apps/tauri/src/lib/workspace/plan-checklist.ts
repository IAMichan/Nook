// A plan as a checklist you can edit before it runs (`PlanChecklist` on the Mac): each list item of the plan's Markdown
// is a step you can leave out, and what is carried out is the plan with only the steps you kept. The plan is the agent's
// own text, so this works alike for every agent.

export interface PlanStep { id: number; text: string; indent: number; kept: boolean }

function item(line: string): { text: string; indent: number } | null {
  const indent = line.length - line.replace(/^[ \t]+/, "").length;
  const rest = line.slice(indent);
  const strip = (s: string) => s.trim().replace(/^\[( |x|X)\] /, "");
  for (const marker of ["- ", "* ", "+ "]) if (rest.startsWith(marker)) return { text: strip(rest.slice(2)), indent };
  const m = /^(\d{1,3})[.)] /.exec(rest);
  return m ? { text: strip(rest.slice(m[0].length)), indent } : null;
}

export function planSteps(markdown: string): PlanStep[] {
  const steps: PlanStep[] = [];
  let fence = false;
  markdown.split("\n").forEach((line, index) => {
    if (line.trim().startsWith("```")) fence = !fence;
    const found = fence ? null : item(line);
    if (found) steps.push({ id: index, ...found, kept: true });
  });
  return steps;
}

/** Steps that will run: kept themselves and not under a step you left out. */
export function keptCount(steps: PlanStep[]): number {
  let count = 0;
  let leftOut: number | null = null;
  for (const s of steps) {
    if (leftOut !== null && s.indent > leftOut) continue;
    leftOut = null;
    if (s.kept) count++;
    else leftOut = s.indent;
  }
  return count;
}

/** The plan without the steps you left out (and their indented sub-steps). */
export function keptText(markdown: string, steps: PlanStep[]): string {
  const lines = markdown.split("\n");
  const dropped = new Set<number>();
  for (const s of steps.filter((x) => !x.kept)) {
    dropped.add(s.id);
    for (let next = s.id + 1; next < lines.length; next++) {
      const child = item(lines[next]);
      if (!child || child.indent <= s.indent) break;
      dropped.add(next);
    }
  }
  return lines.filter((_, i) => !dropped.has(i)).join("\n");
}
