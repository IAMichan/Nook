<script lang="ts">
  // Een grafiek in de chat, in SVG: staaf, lijn, vlak, taart of punten. Dunne lijnen, een rustige as, een tooltip bij
  // aanwijzen, een legenda vanaf twee reeksen en een tabel als je de getallen wilt zien. Kleuren in vaste volgorde.
  import type { ChatChart } from "../lib/brain";

  let { chart }: { chart: ChatChart } = $props();
  let showTable = $state(false);
  let hover = $state<{ x: number; y: number; text: string } | null>(null);

  const colors = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"];
  const W = 520, H = 220, L = 44, R = 12, T = 12, B = 34;
  const series = $derived(chart.series.slice(0, chart.kind === "pie" ? 1 : 4));
  const labels = $derived(series[0]?.points.map((p) => p.label) ?? []);
  const values = $derived(series.flatMap((s) => s.points.map((p) => p.value)));
  const min = $derived(Math.min(0, ...values));
  const max = $derived(Math.max(...values, 0) || 1);
  const ticks = $derived(niceTicks(min, max));
  const top = $derived(ticks[ticks.length - 1]);
  const bottom = $derived(ticks[0]);

  function niceTicks(lo: number, hi: number): number[] {
    const span = hi - lo || 1;
    const step0 = Math.pow(10, Math.floor(Math.log10(span / 4)));
    const step = [1, 2, 5, 10].map((m) => m * step0).find((s) => span / s <= 5) ?? step0 * 10;
    const out: number[] = [];
    for (let v = Math.floor(lo / step) * step; v <= hi + step * 0.999; v += step) out.push(Number(v.toFixed(10)));
    return out.length > 1 ? out : [lo, hi];
  }
  const y = (v: number) => T + (H - T - B) * (1 - (v - bottom) / (top - bottom || 1));
  const band = $derived((W - L - R) / Math.max(labels.length, 1));
  const cx = (i: number) => L + band * (i + 0.5);
  function fmt(v: number): string {
    const text = Math.abs(v) >= 1000 ? v.toLocaleString("nl-NL", { maximumFractionDigits: 0 }) : v.toLocaleString("nl-NL", { maximumFractionDigits: 2 });
    return chart.unit === "€" || chart.unit === "$" ? `${chart.unit} ${text}` : chart.unit ? `${text} ${chart.unit}` : text;
  }
  function bar(i: number, s: number) {
    const groupW = band * 0.72;
    const w = Math.max(groupW / series.length - 2, 2);
    const x = L + band * i + (band - groupW) / 2 + s * (w + 2);
    const v = series[s].points[i]?.value ?? 0;
    const y0 = y(Math.max(0, bottom)), y1 = y(v);
    return { x, w, top: Math.min(y0, y1), h: Math.max(Math.abs(y1 - y0), 1), v };
  }
  function path(s: number, area: boolean): string {
    const pts = series[s].points.map((p, i) => `${cx(i)},${y(p.value)}`);
    if (!area) return "M" + pts.join(" L");
    const base = y(Math.max(0, bottom));
    return `M${cx(0)},${base} L${pts.join(" L")} L${cx(pts.length - 1)},${base} Z`;
  }
  const total = $derived(series[0]?.points.reduce((a, p) => a + Math.max(p.value, 0), 0) || 1);
  function slices() {
    let angle = -Math.PI / 2;
    return (series[0]?.points ?? []).map((p, i) => {
      const part = Math.max(p.value, 0) / total;
      const a0 = angle, a1 = angle + part * Math.PI * 2;
      angle = a1;
      const r = 80, c = { x: 120, y: 110 };
      const large = a1 - a0 > Math.PI ? 1 : 0;
      const d = part >= 0.9999
        ? `M${c.x - r},${c.y} a${r},${r} 0 1,0 ${2 * r},0 a${r},${r} 0 1,0 ${-2 * r},0`
        : `M${c.x},${c.y} L${c.x + r * Math.cos(a0)},${c.y + r * Math.sin(a0)} A${r},${r} 0 ${large},1 ${c.x + r * Math.cos(a1)},${c.y + r * Math.sin(a1)} Z`;
      return { d, color: colors[i % colors.length], label: p.label, value: p.value, part };
    });
  }
  function tip(e: MouseEvent, text: string) {
    const box = (e.currentTarget as SVGElement).ownerSVGElement!.getBoundingClientRect();
    hover = { x: e.clientX - box.left, y: e.clientY - box.top, text };
  }
</script>

<figure class="chart">
  <figcaption>
    <strong>{chart.title}</strong>
    <button class="ghost tiny" onclick={() => (showTable = !showTable)}>{showTable ? "Grafiek" : "Tabel"}</button>
  </figcaption>
  {#if showTable}
    <table>
      <thead><tr><th></th>{#each series as s, i (i)}<th>{s.name || chart.title}</th>{/each}</tr></thead>
      <tbody>
        {#each labels as label, i (i)}
          <tr><td>{label}</td>{#each series as s, j (j)}<td>{fmt(s.points[i]?.value ?? 0)}</td>{/each}</tr>
        {/each}
      </tbody>
    </table>
  {:else}
    <div class="plot">
      {#if chart.kind === "pie"}
        <svg viewBox="0 0 {W} 220" role="img" aria-label={chart.title}>
          {#each slices() as s, i (i)}
            <path d={s.d} fill={s.color} stroke="var(--field)" stroke-width="2" role="presentation"
              onmousemove={(e) => tip(e, `${s.label}: ${fmt(s.value)} (${Math.round(s.part * 100)}%)`)} onmouseleave={() => (hover = null)} />
          {/each}
          {#each slices() as s, i (i)}
            <g transform="translate(240,{30 + i * 22})">
              <rect width="10" height="10" rx="2" fill={s.color} y="-9" />
              <text x="16" class="label">{s.label} · {Math.round(s.part * 100)}%</text>
            </g>
          {/each}
        </svg>
      {:else}
        <svg viewBox="0 0 {W} {H}" role="img" aria-label={chart.title}>
          {#each ticks as t (t)}
            <line x1={L} x2={W - R} y1={y(t)} y2={y(t)} class="grid" />
            <text x={L - 6} y={y(t) + 4} class="axis" text-anchor="end">{fmt(t)}</text>
          {/each}
          {#each labels as label, i (i)}
            {#if labels.length <= 12 || i % Math.ceil(labels.length / 12) === 0}
              <text x={cx(i)} y={H - B + 16} class="axis" text-anchor="middle">{label.length > 10 ? label.slice(0, 9) + "…" : label}</text>
            {/if}
          {/each}
          {#if chart.kind === "bar"}
            {#each labels as _, i (i)}
              {#each series as s, j (j)}
                {@const b = bar(i, j)}
                <rect x={b.x} y={b.top} width={b.w} height={b.h} rx={Math.min(4, b.w / 2)} fill={colors[j]} role="presentation"
                  onmousemove={(e) => tip(e, `${labels[i]}${series.length > 1 ? " · " + (s.name || "") : ""}: ${fmt(b.v)}`)} onmouseleave={() => (hover = null)} />
              {/each}
            {/each}
          {:else}
            {#each series as s, j (j)}
              {#if chart.kind === "area"}<path d={path(j, true)} fill={colors[j]} opacity="0.22" />{/if}
              {#if chart.kind !== "point"}<path d={path(j, false)} fill="none" stroke={colors[j]} stroke-width="2" stroke-linejoin="round" />{/if}
              {#each s.points as p, i (i)}
                <circle cx={cx(i)} cy={y(p.value)} r={chart.kind === "point" ? 4.5 : 3} fill={colors[j]} stroke="var(--field)" stroke-width="2" />
                <rect x={cx(i) - band / 2} y={T} width={band} height={H - T - B} fill="transparent" role="presentation"
                  onmousemove={(e) => tip(e, `${labels[i]}: ${series.map((x) => (series.length > 1 ? (x.name || "") + " " : "") + fmt(x.points[i]?.value ?? 0)).join(" · ")}`)}
                  onmouseleave={() => (hover = null)} />
              {/each}
            {/each}
          {/if}
        </svg>
      {/if}
      {#if hover}<div class="tip" style="left:{hover.x + 12}px; top:{hover.y - 8}px">{hover.text}</div>{/if}
    </div>
    {#if series.length > 1 && chart.kind !== "pie"}
      <div class="legend">
        {#each series as s, j (j)}<span><i style="background:{colors[j]}"></i>{s.name || `Reeks ${j + 1}`}</span>{/each}
      </div>
    {/if}
  {/if}
</figure>

<style>
  .chart { margin: 8px 0; padding: 10px 12px; border: 1px solid var(--line2); border-radius: 12px; background: var(--field); }
  figcaption { display: flex; justify-content: space-between; align-items: center; margin-bottom: 6px; }
  .tiny { padding: 2px 8px; font-size: 11px; }
  .plot { position: relative; }
  svg { width: 100%; height: auto; display: block; }
  .grid { stroke: var(--line2); stroke-width: 1; }
  .axis { fill: var(--text3); font-size: 10px; }
  .label { fill: var(--text2); font-size: 12px; }
  .tip { position: absolute; pointer-events: none; background: var(--smoke); border: 1px solid var(--line2); border-radius: 8px; padding: 4px 8px; font-size: 12px; white-space: nowrap; color: var(--paper); }
  .legend { display: flex; gap: 12px; flex-wrap: wrap; font-size: 12px; color: var(--text2); margin-top: 4px; }
  .legend i { display: inline-block; width: 10px; height: 10px; border-radius: 2px; margin-right: 5px; vertical-align: -1px; }
  table { border-collapse: collapse; font-size: 12px; width: 100%; }
  th, td { border-bottom: 1px solid var(--line2); padding: 3px 6px; text-align: left; }
</style>
