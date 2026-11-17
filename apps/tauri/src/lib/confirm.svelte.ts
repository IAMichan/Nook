// The app's one line of questions (see `confirm.ts`): `ask` from a handler or a menu item, `ConfirmHost` (mounted once
// in `App.svelte`) shows the front one.
import { ConfirmQueue, type ConfirmRequest, type PendingConfirm } from "./confirm";

class Confirmations {
  front = $state<PendingConfirm | null>(null);
  private queue = new ConfirmQueue((front) => (this.front = front));
  ask(request: ConfirmRequest): Promise<boolean> {
    return this.queue.ask(request);
  }
}

export const confirmations = new Confirmations();

/** Asks first and resolves `true` only when the red (or confirm) button was chosen; Cancel and Escape give `false`. */
export const ask = (request: ConfirmRequest) => confirmations.ask(request);
