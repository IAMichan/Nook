// The plan Nook works through (`brain::task_steps` in core, `RunTaskStep` on the Mac).

export type StepStatus = "pending" | "active" | "done" | "cancelled";

export interface TaskStep {
  text: string;
  status: StepStatus;
}

/** How far the plan is: finished steps of the steps that still count (a dropped step does not). */
export function checklistProgress(steps: TaskStep[]): { done: number; total: number } {
  const counted = steps.filter((s) => s.status !== "cancelled");
  return { done: counted.filter((s) => s.status === "done").length, total: counted.length };
}
