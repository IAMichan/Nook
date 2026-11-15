<script lang="ts">
  // Who has your message and who read it (the iPhone's Message info): Read by, Delivered to and Not yet, with when.
  import { locale, tr } from "../../lib/i18n.svelte";
  import type { InboxLine } from "../../lib/companion";
  import TicksMark from "./ui/TicksMark.svelte";
  let { line, onclose }: { line: InboxLine; onclose: () => void } = $props();
  const readers = $derived(line.readers ?? []);
  const groups = $derived([
    { title: tr("Gelezen door", "Read by"), ticks: "read", list: readers.filter((r) => r.receipt === "read") },
    { title: tr("Afgeleverd bij", "Delivered to"), ticks: "delivered", list: readers.filter((r) => r.receipt === "delivered") },
    { title: tr("Nog niet", "Not yet"), ticks: "sent", list: readers.filter((r) => r.receipt !== "read" && r.receipt !== "delivered") },
  ].filter((g) => g.list.length));
  const when = (s?: number) => (s ? new Date(s * 1000).toLocaleString(locale(), { weekday: "short", hour: "2-digit", minute: "2-digit" }) : "");
</script>

<div class="info">
  <div class="bar"><span></span><strong>{tr("Berichtinfo", "Message info")}</strong><button class="link" onclick={onclose}>{tr("Klaar", "Done")}</button></div>
  <div class="scroll">
    <p class="message">{line.text}</p>
    <small class="foot">{tr("{x} van {n} hebben het gelezen", "{x} of {n} have read it", { x: readers.filter((r) => r.receipt === "read").length, n: readers.length })}</small>
    {#each groups as g (g.title)}
      <h3><TicksMark ticks={g.ticks} />{g.title}</h3>
      <div class="card">
        {#each g.list as r (r.name)}<div class="row"><span>{r.name}</span><small>{when(r.date)}</small></div>{/each}
      </div>
    {/each}
  </div>
</div>

<style>
  .info { flex: 1; display: flex; flex-direction: column; padding-top: 10px; }
  .bar { display: grid; grid-template-columns: 1fr auto 1fr; align-items: center; padding: 8px 16px; }
  .bar strong { font: 600 17px var(--font); }
  .link { justify-self: end; font: 600 17px var(--font) !important; }
  .scroll { flex: 1; overflow-y: auto; padding: 12px 16px 24px; display: flex; flex-direction: column; gap: 8px; }
  .message { margin: 0; padding: 12px; background: var(--surface); border-radius: 12px; font: var(--pt-body); white-space: pre-wrap; }
  .foot { font: var(--pt-caption); color: var(--text3); padding: 0 12px; }
  h3 { margin: 12px 0 0 12px; display: flex; align-items: center; gap: 6px; font: var(--pt-label); color: var(--text3); }
  .card { background: var(--surface); border-radius: 12px; }
  .row { display: flex; justify-content: space-between; padding: 12px 16px; font: var(--pt-body); }
  .row + .row { border-top: 0.5px solid var(--hairline); }
  .row small { font: var(--pt-caption); color: var(--text3); }
</style>
