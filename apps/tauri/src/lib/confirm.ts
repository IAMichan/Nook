// Asking before something that cannot be undone, as the Mac's `ConfirmedButton` and `.confirmDelete` do
// (`UI/Components/ConfirmDestructive.swift`): the question as a visible title, what is lost under it, the red button
// and Cancel, always in the same dialog. Never `window.confirm`: it has no title, no Nook look and English buttons.
//
// `ConfirmQueue` is the logic without the view, so tests can drive it; `ConfirmHost.svelte` draws the front question.

export interface ConfirmRequest {
  /** The question, shown as the dialog's title: "Remove Claude Code from Nook?" */
  question: string;
  /** What is lost or kept, under the question. */
  detail?: string;
  /** The words on the button that does it ("Remove", "End session"). */
  confirmTitle: string;
  /** Red for what cannot be undone (the default); `false` for a confirmation that only needs a yes. */
  destructive?: boolean;
  /** A box under the question ("Don't ask again"); `onRemember` runs when it was ticked and the question was confirmed. */
  dontAskAgain?: string;
  onRemember?: () => void;
}

export interface PendingConfirm extends ConfirmRequest {
  id: number;
  answer: (yes: boolean) => void;
}

/** Questions wait in line: a second one shows when the first is answered, so none is lost. */
export class ConfirmQueue {
  private waiting: PendingConfirm[] = [];
  private next = 1;
  constructor(private changed: (front: PendingConfirm | null) => void = () => {}) {}

  get front(): PendingConfirm | null {
    return this.waiting[0] ?? null;
  }

  ask(request: ConfirmRequest): Promise<boolean> {
    return new Promise((resolve) => {
      const id = this.next++;
      this.waiting.push({ ...request, id, answer: (yes) => this.settle(id, yes, resolve) });
      if (this.waiting.length === 1) this.changed(this.front);
    });
  }

  private settle(id: number, yes: boolean, resolve: (yes: boolean) => void) {
    const i = this.waiting.findIndex((p) => p.id === id);
    if (i < 0) return;
    this.waiting.splice(i, 1);
    resolve(yes);
    if (i === 0) this.changed(this.front);
  }
}
