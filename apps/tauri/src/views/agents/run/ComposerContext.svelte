<script lang="ts">
  // What a session composer carries besides your words (`ComposerChips`, `ImageAttachmentStrip` and the `@` / `#` lists
  // of the Mac's `ComposerRich`): files, folders and pictures as tiles above the text (added with "+", dropped on the
  // window or pasted), and the lists that open while you type `@` (a file of the project, or another session), `#` (a
  // pull request) or `$` (a skill the agent reads, `SkillIndex`). The new-session composer and a running session's composer both use this one view.
  import { getCurrentWebview } from "@tauri-apps/api/webview";
  import { invoke } from "@tauri-apps/api/core";
  import { tr } from "../../../lib/i18n.svelte";
  import { pullRequests } from "../../../lib/pulls.svelte";
  import { workspace } from "../../../lib/workspace/store.svelte";
  import { fileRef, isPicture, mentionToken, type ContextRef } from "../../../lib/workspace/context-refs";
  import Ico from "../../../components/ui/Ico.svelte";

  let {
    textarea,
    draft = $bindable(""),
    root,
    attached = $bindable([]),
    pictures = $bindable([]),
    mentions = $bindable([]),
    exclude,
    provider,
    open = $bindable(false),
  }: {
    textarea: HTMLTextAreaElement | undefined;
    draft: string;
    /** The project's folder, for the `@` file list; none: no files to offer. */
    root: string | null;
    attached: ContextRef[];
    pictures: string[];
    mentions: ContextRef[];
    /** The session this composer belongs to: not offered as an `@` session, and whose agent's skills `$` lists. */
    exclude?: string;
    /** The agent picked in the new-session composer, for its skills. */
    provider?: string;
    /** A list is open: Return and the arrows belong to it. */
    open?: boolean;
  } = $props();

  type Item = { key: string; icon: string; title: string; detail: string; ref: ContextRef };
  let items = $state<Item[]>([]);
  let index = $state(0);
  let trigger = $state<{ char: "@" | "#" | "$"; query: string; start: number; end: number } | null>(null);
  type Skill = { name: string; description: string; path: string; source: string };
  let skills = $state<Skill[]>([]);
  // The skills on disk the agent reads, read again when the session, folder or agent changes.
  $effect(() => {
    const args = exclude ? { run: exclude, folder: null, provider: null } : { run: null, folder: root, provider: provider ?? null };
    invoke<Skill[]>("workspace_skills", args).then((s) => (skills = s)).catch(() => (skills = []));
  });

  /// Prefix on the name, then a name that contains it, then a hit in the description (`SkillIndex.filter`).
  function filterSkills(query: string): Skill[] {
    const q = query.toLowerCase();
    if (!q) return skills.slice(0, 8);
    const by = (f: (s: Skill) => boolean) => skills.filter(f);
    const prefix = by((s) => s.name.toLowerCase().startsWith(q));
    const contains = by((s) => !s.name.toLowerCase().startsWith(q) && s.name.toLowerCase().includes(q));
    const desc = by((s) => !s.name.toLowerCase().includes(q) && s.description.toLowerCase().includes(q));
    return [...prefix, ...contains, ...desc].slice(0, 8);
  }
  let error = $state<string | null>(null);

  /// The `@` or `#` token that ends right at the caret, after a space or at the start (`ComposerTrigger.detect`).
  function detect() {
    const el = textarea;
    if (!el) return (trigger = null);
    const caret = el.selectionStart ?? draft.length;
    const before = draft.slice(0, caret);
    const m = /(^|\s)([@#$])([^\s@#$]*)$/.exec(before);
    trigger = m ? { char: m[2] as "@" | "#" | "$", query: m[3], start: caret - m[3].length - 1, end: caret } : null;
  }

  let request = 0;
  $effect(() => {
    const t = trigger;
    if (!t) { items = []; open = false; return; }
    const mine = ++request;
    const q = t.query.toLowerCase();
    if (t.char === "$") {
      items = filterSkills(t.query).map((s) => ({ key: `skill:${s.name}`, icon: "sparkles", title: "$" + s.name, detail: s.description || s.source, ref: { kind: "skill", id: s.name, label: s.name } }));
      index = 0;
      open = items.length > 0;
      return;
    }
    if (t.char === "#") {
      const all = pullRequests.accounts.flatMap((a) => [...a.mine, ...a.reviews]);
      const seen = new Set<string>();
      items = all
        .filter((p) => (`${p.number} ${p.title} ${p.repo}`.toLowerCase().includes(q)) && !seen.has(`${p.repo}#${p.number}`) && seen.add(`${p.repo}#${p.number}`))
        .slice(0, 6)
        .map((p) => ({ key: `pr:${p.repo}#${p.number}`, icon: "git-pull-request", title: `#${p.number} ${p.title}`, detail: p.repo, ref: { kind: "pullRequest", id: `${p.repo}#${p.number}`, label: String(p.number) } }));
      index = 0;
      open = items.length > 0;
      return;
    }
    const sessions: Item[] = workspace.runs
      .filter((r) => `run:${r.id}` !== exclude && r.id !== exclude && r.title.toLowerCase().includes(q))
      .slice(0, 4)
      .map((r) => ({ key: `run:${r.id}`, icon: "terminal", title: r.title, detail: tr("Sessie", "Session"), ref: { kind: "session", id: r.id, label: r.title } }));
    const done = (files: string[]) => {
      if (mine !== request) return;
      const fileItems: Item[] = files.map((f) => ({ key: `file:${f}`, icon: f.endsWith("/") ? "folder" : "file", title: f.replace(/\/$/, "").split("/").pop() ?? f, detail: f, ref: { kind: "file", id: f.replace(/\/$/, ""), label: f.replace(/\/$/, "").split("/").pop() ?? f } }));
      items = [...fileItems.slice(0, 8), ...sessions];
      index = 0;
      open = items.length > 0;
    };
    if (!root) return done([]);
    invoke<string[]>("workspace_files", { root, query: t.query }).then(done).catch(() => done([]));
  });

  function pick(item: Item) {
    const t = trigger;
    if (!t) return;
    const token = mentionToken(item.ref);
    draft = draft.slice(0, t.start) + token + " " + draft.slice(t.end);
    if (!mentions.some((m) => m.kind === item.ref.kind && m.id === item.ref.id)) mentions = [...mentions, item.ref];
    trigger = null;
    const caret = t.start + token.length + 1;
    requestAnimationFrame(() => { textarea?.focus(); textarea?.setSelectionRange(caret, caret); });
  }

  /// Keys while a list is open; true when it took the key.
  export function key(e: KeyboardEvent): boolean {
    if (!open || !items.length) return false;
    if (e.key === "ArrowDown") { e.preventDefault(); index = (index + 1) % items.length; return true; }
    if (e.key === "ArrowUp") { e.preventDefault(); index = (index - 1 + items.length) % items.length; return true; }
    if ((e.key === "Enter" && !e.shiftKey) || e.key === "Tab") { e.preventDefault(); pick(items[index]); return true; }
    if (e.key === "Escape") { e.preventDefault(); trigger = null; return true; }
    return false;
  }

  /// A path as an attachment: a picture as a picture, the rest as a file or folder.
  export function addPath(path: string) {
    if (isPicture(path)) {
      if (!pictures.includes(path)) pictures = [...pictures, path];
    } else if (!attached.some((a) => a.id === path)) {
      attached = [...attached, fileRef(path)];
    }
  }

  // The textarea's caret moves with typing and clicks: the list follows it.
  $effect(() => {
    const el = textarea;
    if (!el) return;
    const on = () => detect();
    el.addEventListener("input", on);
    el.addEventListener("click", on);
    el.addEventListener("keyup", on);
    // A pasted picture is kept as a file the agent reads (`ImageAttachment`); a pasted path list stays text.
    const paste = (e: ClipboardEvent) => {
      const files = [...(e.clipboardData?.files ?? [])].filter((f) => f.type.startsWith("image/"));
      if (!files.length) return;
      e.preventDefault();
      for (const file of files) {
        const reader = new FileReader();
        reader.onload = () => {
          invoke<string>("workspace_save_picture", { data: String(reader.result), extension: file.type.split("/")[1] ?? "png" })
            .then((path) => (pictures = [...pictures, path]))
            .catch((err) => (error = String(err)));
        };
        reader.readAsDataURL(file);
      }
    };
    el.addEventListener("paste", paste);
    return () => {
      el.removeEventListener("input", on);
      el.removeEventListener("click", on);
      el.removeEventListener("keyup", on);
      el.removeEventListener("paste", paste);
    };
  });

  // Files dropped on the window land here while this composer is on screen (the window gives their paths).
  $effect(() => {
    let stop: (() => void) | undefined;
    let gone = false;
    getCurrentWebview()
      .onDragDropEvent((event) => {
        if (event.payload.type !== "drop" || !textarea?.offsetParent) return;
        for (const path of event.payload.paths) addPath(path);
      })
      .then((un) => (gone ? un() : (stop = un)))
      .catch(() => {});
    return () => { gone = true; stop?.(); };
  });

  const name = (path: string) => path.replace(/[\\/]+$/, "").split(/[\\/]/).pop() ?? path;
</script>

{#if attached.length || pictures.length}
  <!-- The tiles above the text: a picture, a file or a folder, each with its × (`ImageAttachmentStrip`). -->
  <div class="tiles">
    {#each pictures as path (path)}
      <span class="tile" title={path}><Ico name="image" size={14} /><span class="tname">{name(path)}</span>
        <button class="x" aria-label={tr("Verwijder", "Remove")} onclick={() => (pictures = pictures.filter((p) => p !== path))}><Ico name="x" size={11} stroke={2.6} /></button></span>
    {/each}
    {#each attached as ref (ref.id)}
      <span class="tile" title={ref.id}><Ico name={/\.[a-z0-9]{1,6}$/i.test(ref.id) ? "file" : "folder"} size={14} /><span class="tname">{ref.label}</span>
        <button class="x" aria-label={tr("Verwijder", "Remove")} onclick={() => (attached = attached.filter((a) => a.id !== ref.id))}><Ico name="x" size={11} stroke={2.6} /></button></span>
    {/each}
  </div>
{/if}
{#if error}<p class="err">{error}</p>{/if}
{#if open && items.length}
  <!-- The `@` and `#` lists over the composer. -->
  <div class="mentions" role="listbox" aria-label={tr("Verwijzingen", "References")}>
    {#each items as item, i (item.key)}
      <button role="option" aria-selected={i === index} class:lit={i === index} onmousedown={(e) => { e.preventDefault(); pick(item); }}>
        <Ico name={item.icon} size={14} /><span class="mtitle">{item.title}</span><span class="mdetail">{item.detail}</span>
      </button>
    {/each}
  </div>
{/if}

<style>
  .tiles { display: flex; flex-wrap: wrap; gap: var(--space-6); }
  .tile { display: inline-flex; align-items: center; gap: var(--space-6); max-width: 220px; height: 28px; padding: 0 var(--space-4) 0 var(--space-8); border: 1px solid var(--line2); border-radius: var(--radius-control); background: var(--smoke); color: var(--text2); font: var(--text-detail); }
  .tname { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: var(--paper); }
  .x { display: grid; place-items: center; width: 20px; height: 20px; margin: 0; padding: 0; border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text3); }
  .x:hover { background: var(--graphite); color: var(--paper); }
  .err { margin: 0; color: var(--coral); font: var(--text-detail); }
  .mentions { position: absolute; left: 0; right: 0; bottom: calc(100% + var(--space-6)); z-index: 30; display: flex; flex-direction: column; padding: var(--space-4); max-height: 300px; overflow-y: auto; background: var(--menu); border: 1px solid var(--line2); border-radius: var(--radius-card); box-shadow: var(--shadow-popover); }
  .mentions button { display: flex; align-items: center; gap: var(--space-8); margin: 0; padding: var(--space-6) var(--space-8); border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text2); text-align: left; }
  .mentions button.lit, .mentions button:hover { background: var(--smoke); color: var(--paper); }
  .mtitle { font: var(--text-body); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .mdetail { flex: 1; min-width: 0; font: var(--text-detail); color: var(--text3); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; text-align: right; }
</style>
