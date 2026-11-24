<script lang="ts">
  // A chart in the chat, drawn as the Mac's `ChatChartView`: the title with the unit on the right, then a bar, line,
  // area or point chart 190 px high (values above the bars while there are at most twelve, the y axis short as "20k"),
  // or a ring with its legend beside it. One series takes Nook's accent; more series take the fixed palette, with a
  // legend under the chart. Hovering a mark shows its exact value.
  import type { ChatChart } from "../lib/brain";
  import { tr, locale } from "../lib/i18n.svelte";

  let { chart }: { chart: ChatChart } = $props();
  let hover = $state<{ x: number; y: number; text: string } | null>(null);
  let width = $state(520);

  /** `ChatChartView.palette`: a validated dark-background palette, easy to tell apart with colour blindness. */
  const palette = ["#3987e5", "#d95926", "#199e70", "#c98500", "#d55181", "#008300", "#9085e9", "#e66767"];
  const H = 190, R = 4, T = 18, B = 22;
  const series = $derived(chart.series.slice(0, chart.kind === "pie" ? 1 : 8));
  const multi = $derived(series.length > 1);
  const color = (j: number) => (multi ? palette[j % palette.length] : "var(--iris)");
  const labels = $derived(series[0]?.points.map((p) => p.label) ?? []);
  const values = $derived(series.flatMap((s) => s.points.map((p) => p.value)));
  const min = $derived(Math.min(0, ...values));
  const max = $derived(Math.max(...values, 0) || 1);
  const ticks = $derived(niceTicks(min, max));
  const top = $derived(ticks[ticks.length - 1]);
  const bottom = $derived(ticks[0]);
  /** Room for the widest y label on the left, as Swift Charts makes it. */
  const L = $derived(Math.max(...ticks.map((t) => format(t).length), 1) * 6.5 + 8);
  const W = $derived(Math.max(width, 200));
  const labelBars = $derived((series[0]?.points.length ?? 0) <= 12);

  function niceTicks(lo: number, hi: number): number[] {
    const span = hi - lo || 1;
    const step0 = Math.pow(10, Math.floor(Math.log10(span / 4)));
    const step = [1, 2, 5, 10].map((m) => m * step0).find((s) => span / s <= 5) ?? step0 * 10;
    const out: number[] = [];
    for (let v = Math.floor(lo / step) * step; v <= hi + step * 0.999; v += step) out.push(Number(v.toFixed(10)));
    return out.length > 1 ? out : [lo, hi];
  }

  /** `ChatChartView.format`: "1,2 mln" from a million, "13,6k" from ten thousand, otherwise the number itself. */
  function format(v: number): string {
    const n = (x: number, digits: number) => x.toLocaleString(locale(), { maximumFractionDigits: digits });
    if (Math.abs(v) >= 1_000_000) return n(v / 1_000_000, 1) + " mln";
    if (Math.abs(v) >= 10_000) return n(v / 1_000, 1) + "k";
    return n(v, 2);
  }
  const withUnit = (v: number) => format(v) + (chart.unit ? ` ${chart.unit}` : "");

  const y = (v: number) => T + (H - T - B) * (1 - (v - bottom) / (top - bottom || 1));
  const band = $derived((W - L - R) / Math.max(labels.length, 1));
  const cx = (i: number) => L + band * (i + 0.5);
  function bar(i: number, s: number) {
    const groupW = band * (multi ? 0.8 : 0.6);
    const w = Math.max(groupW / series.length - (multi ? 2 : 0), 2);
    const x = L + band * i + (band - groupW) / 2 + s * (w + (multi ? 2 : 0));
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

  /** More than seven slices: the smallest go together as "Other". */
  const parts = $derived.by(() => {
    const all = (series[0]?.points ?? []).map((p) => ({ label: p.label, value: Math.max(0, p.value) }));
    if (all.length <= 7) return all;
    const sorted = [...all].sort((a, b) => b.value - a.value);
    const rest = sorted.slice(6).reduce((a, p) => a + p.value, 0);
    return [...sorted.slice(0, 6), { label: tr("Overig", "Other"), value: rest }];
  });
  const total = $derived(parts.reduce((a, p) => a + p.value, 0) || Number.MIN_VALUE);
  /** Ring sectors with an inner radius of 0.58 and a small gap between them (`SectorMark`). */
  const sectors = $derived.by(() => {
    let angle = -Math.PI / 2;
    const r = 75, inner = r * 0.58, c = 75, gap = parts.length > 1 ? 0.013 : 0;
    return parts.map((p, i) => {
      const part = p.value / total;
      const a0 = angle + gap, a1 = angle + part * Math.PI * 2 - gap;
      angle += part * Math.PI * 2;
      const pt = (rad: number, a: number) => `${c + rad * Math.cos(a)},${c + rad * Math.sin(a)}`;
      const large = a1 - a0 > Math.PI ? 1 : 0;
      const d = part >= 0.9999
        ? `M${c - r},${c} a${r},${r} 0 1,0 ${2 * r},0 a${r},${r} 0 1,0 ${-2 * r},0 M${c - inner},${c} a${inner},${inner} 0 1,1 ${2 * inner},0 a${inner},${inner} 0 1,1 ${-2 * inner},0`
        : `M${pt(r, a0)} A${r},${r} 0 ${large},1 ${pt(r, a1)} L${pt(inner, a1)} A${inner},${inner} 0 ${large},0 ${pt(inner, a0)} Z`;
      return { d, color: palette[i % palette.length], label: p.label, value: p.value, part };
    });
  });

  function tip(e: MouseEvent, text: string) {
    const box = (e.currentTarget as SVGElement).ownerSVGElement!.getBoundingClientRect();
    hover = { x: e.clientX - box.left, y: e.clientY - box.top, text };
  }
</script>

<figure class="chart">
  <figcaption>
    <span class="title">{chart.title || tr("Grafiek", "Chart")}</span>
    {#if chart.unit}<span class="unit">{chart.unit}</span>{/if}
  </figcaption>
  {#if chart.kind === "pie"}
    <div class="pie">
      <svg class="ring" viewBox="0 0 150 150" width="150" height="150" role="img" aria-label={chart.title}>
        {#each sectors as s, i (i)}
          <path d={s.d} fill={s.color} fill-rule="evenodd" role="presentation"
            onmousemove={(e) => tip(e, `${s.label}: ${withUnit(s.value)} (${Math.round(s.part * 100)}%)`)} onmouseleave={() => (hover = null)} />
        {/each}
      </svg>
      <div class="pie-legend">
        {#each sectors as s, i (i)}
          <div class="pie-row">
            <i style:background={s.color}></i>
            <span class="pie-label">{s.label}</span>
            <span class="pie-value">{withUnit(s.value)}</span>
            <span class="pie-share">{Math.round(s.part * 100)}%</span>
          </div>
        {/each}
      </div>
      {#if hover}<div class="tip" style:left="{hover.x + 12}px" style:top="{hover.y - 8}px">{hover.text}</div>{/if}
    </div>
  {:else}
    <div class="plot" bind:clientWidth={width}>
      <svg width={W} height={H} viewBox="0 0 {W} {H}" role="img" aria-label={chart.title}>
        {#each ticks as t (t)}
          <line x1={L} x2={W - R} y1={y(t)} y2={y(t)} class="grid" />
          <text x={L - 6} y={y(t) + 3.5} class="axis" text-anchor="end">{format(t)}</text>
        {/each}
        {#each labels as label, i (i)}
          {#if labels.length <= 12 || i % Math.ceil(labels.length / 12) === 0}
            <text x={cx(i)} y={H - 6} class="axis x" text-anchor="middle">{label.length > 10 ? label.slice(0, 9) + "…" : label}</text>
          {/if}
        {/each}
        {#if chart.kind === "bar"}
          {#each labels as _, i (i)}
            {#each series as s, j (j)}
              {@const b = bar(i, j)}
              <path
                d={`M${b.x},${b.top + b.h} V${b.top + Math.min(4, b.h)} Q${b.x},${b.top} ${b.x + Math.min(4, b.w / 2)},${b.top} H${b.x + b.w - Math.min(4, b.w / 2)} Q${b.x + b.w},${b.top} ${b.x + b.w},${b.top + Math.min(4, b.h)} V${b.top + b.h} Z`}
                fill={color(j)} role="presentation"
                onmousemove={(e) => tip(e, `${labels[i]}${multi ? " · " + (s.name || "") : ""}: ${withUnit(b.v)}`)} onmouseleave={() => (hover = null)} />
              {#if !multi && labelBars}
                <text x={b.x + b.w / 2} y={b.top - 4} class="value" text-anchor="middle">{format(b.v)}</text>
              {/if}
            {/each}
          {/each}
        {:else}
          {#each series as s, j (j)}
            {#if chart.kind === "area"}<path d={path(j, true)} fill={color(j)} opacity={multi ? 0.75 : 0.85} />{/if}
            {#if chart.kind === "line"}<path d={path(j, false)} fill="none" stroke={color(j)} stroke-width="2" stroke-linejoin="round" stroke-linecap="round" />{/if}
            {#each s.points as p, i (i)}
              {#if chart.kind !== "area"}<circle cx={cx(i)} cy={y(p.value)} r={chart.kind === "point" ? 4.5 : 3} fill={color(j)} />{/if}
              <rect x={cx(i) - band / 2} y={T} width={band} height={H - T - B} fill="transparent" role="presentation"
                onmousemove={(e) => tip(e, `${labels[i]}: ${series.map((x) => (multi ? (x.name || "") + " " : "") + withUnit(x.points[i]?.value ?? 0)).join(" · ")}`)}
                onmouseleave={() => (hover = null)} />
            {/each}
          {/each}
        {/if}
      </svg>
      {#if hover}<div class="tip" style:left="{hover.x + 12}px" style:top="{hover.y - 8}px">{hover.text}</div>{/if}
    </div>
    {#if multi}
      <div class="legend">
        {#each series as s, j (j)}<span><i style:background={color(j)}></i>{s.name || tr("Reeks {n}", "Series {n}", { n: j + 1 })}</span>{/each}
      </div>
    {/if}
  {/if}
</figure>

<style>
  .chart { margin: 0; padding: var(--space-16); border-radius: var(--radius-sheet); background: var(--field); display: flex; flex-direction: column; gap: var(--space-12); }
  figcaption { display: flex; justify-content: space-between; align-items: baseline; gap: var(--space-8); }
  .title { font: var(--text-emphasis); color: var(--paper); }
  .unit { font: var(--text-detail); color: var(--text3); }
  .plot, .pie { position: relative; }
  .plot svg { display: block; overflow: visible; }
  .grid { stroke: var(--line2); stroke-width: 0.5; }
  .axis { fill: var(--text3); font: var(--text-caption); }
  .axis.x, .value { fill: var(--text2); font: var(--text-caption); }
  .pie { display: flex; align-items: center; gap: 20px; flex-wrap: wrap; }
  .ring { flex: none; }
  .pie-legend { flex: 1; min-width: 200px; display: flex; flex-direction: column; gap: var(--space-6); }
  .pie-row { display: flex; align-items: center; gap: var(--space-8); }
  .pie-row i, .legend i { display: inline-block; width: 10px; height: 10px; border-radius: var(--space-2); flex: none; }
  .pie-label { flex: 1; min-width: 0; font: var(--text-detail); color: var(--paper); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
  .pie-value { font: var(--text-label); color: var(--text2); white-space: nowrap; }
  .pie-share { width: 34px; text-align: right; font: var(--text-detail); color: var(--text3); }
  .tip { position: absolute; pointer-events: none; background: var(--smoke); border: 1px solid var(--line2); border-radius: var(--radius-control); padding: var(--space-4) var(--space-8); font: var(--text-detail); white-space: nowrap; color: var(--paper); z-index: 1; }
  .legend { display: flex; gap: 10px; flex-wrap: wrap; font: var(--text-detail); color: var(--text2); }
  .legend span { display: inline-flex; align-items: center; gap: 5px; }
</style>
