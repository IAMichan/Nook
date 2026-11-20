// Back and forward through what you opened (the Mac's `SessionHistory` trail, ⌘[ and ⌘]): the open item is
// `items[at]`; opening another drops what was ahead of it. Pure, so the shell keeps one per tab and tests can walk it.

export class Trail<T> {
  items: T[];
  at: number;

  constructor(first: T | null = null, readonly limit = 50) {
    this.items = first === null ? [] : [first];
    this.at = this.items.length - 1;
  }

  get current(): T | undefined { return this.items[this.at]; }
  get canBack(): boolean { return this.at > 0; }
  get canForward(): boolean { return this.at < this.items.length - 1; }

  /// Records `item` as opened. The same item again, or one the trail is walking to, changes nothing.
  visit(item: T) {
    if (this.items[this.at] === item) return;
    this.items = [...this.items.slice(0, this.at + 1), item].slice(-this.limit);
    this.at = this.items.length - 1;
  }

  /// The item one step back, now current; undefined at the start.
  back(): T | undefined {
    if (!this.canBack) return undefined;
    this.at -= 1;
    return this.items[this.at];
  }

  forward(): T | undefined {
    if (!this.canForward) return undefined;
    this.at += 1;
    return this.items[this.at];
  }

  /// Forgets an item that no longer exists (a deleted Nook), keeping the place on the trail.
  drop(item: T) {
    const before = this.items.slice(0, this.at + 1).filter((i) => i === item).length;
    this.items = this.items.filter((i) => i !== item);
    this.at = Math.max(0, Math.min(this.items.length - 1, this.at - before));
  }
}
