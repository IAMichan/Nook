<script lang="ts">
  // Edit a picture before sending: crop, rotate, draw, text (`ChatImageEdit` / `ChatAttachmentStage` on the Mac, CH-50).
  // All coordinates live in the rotated picture's unit square [0, 1] x [0, 1], so every step can be undone or reset
  // and only renders into a final PNG File on Done.
  import { tr } from "../../lib/i18n.svelte";
  import Ico from "../../components/ui/Ico.svelte";

  type InkId = "white" | "black" | "red" | "yellow" | "green" | "blue";
  type ToolMode = "crop" | "draw" | "text";
  type CropHandle =
    | "topLeft"
    | "top"
    | "topRight"
    | "left"
    | "right"
    | "bottomLeft"
    | "bottom"
    | "bottomRight"
    | "inside";

  interface InkColor {
    id: InkId;
    css: string;
    tokenClass: string;
  }

  interface Point {
    x: number;
    y: number;
  }

  interface Stroke {
    points: Point[];
    ink: InkId;
  }

  interface TextLabel {
    id: string;
    text: string;
    center: Point;
    ink: InkId;
  }

  interface CropRect {
    x: number;
    y: number;
    w: number;
    h: number;
  }

  let {
    file,
    onsave,
    onclose,
  }: {
    file: File;
    onsave: (edited: File, previewUrl: string) => void;
    onclose: () => void;
  } = $props();

  // Matching macOS `ChatImageInk` RGB values (defined in script so template/CSS stays 100% token-clean).
  const INKS: InkColor[] = [
    { id: "white", css: "rgb(255, 255, 255)", tokenClass: "ink-white" },
    { id: "black", css: "rgb(0, 0, 0)", tokenClass: "ink-black" },
    { id: "red", css: "rgb(240, 59, 51)", tokenClass: "ink-red" },
    { id: "yellow", css: "rgb(255, 204, 26)", tokenClass: "ink-yellow" },
    { id: "green", css: "rgb(51, 199, 102)", tokenClass: "ink-green" },
    { id: "blue", css: "rgb(51, 128, 255)", tokenClass: "ink-blue" },
  ];

  const MIN_CROP = 0.08;

  let canvasEl = $state<HTMLCanvasElement | null>(null);
  let loadedImg = $state<HTMLImageElement | null>(null);
  let tool = $state<ToolMode>("draw");
  let activeInk = $state<InkId>("red");
  let quarterTurns = $state(0);
  let crop = $state<CropRect>({ x: 0, y: 0, w: 1, h: 1 });
  let strokes = $state<Stroke[]>([]);
  let currentStroke = $state<Stroke | null>(null);
  let labels = $state<TextLabel[]>([]);
  let textDraft = $state("");
  let activeCropHandle = $state<CropHandle | null>(null);
  let dragStart = $state<{ pt: Point; initial: CropRect } | null>(null);
  let draggingLabelId = $state<string | null>(null);
  let saving = $state(false);

  const hasChanges = $derived(
    quarterTurns % 4 !== 0 ||
      crop.x > 0.001 ||
      crop.y > 0.001 ||
      crop.w < 0.999 ||
      crop.h < 0.999 ||
      strokes.length > 0 ||
      labels.length > 0
  );

  function inkCss(id: InkId): string {
    return INKS.find((i) => i.id === id)?.css ?? "rgb(240, 59, 51)";
  }

  // Load image from File
  $effect(() => {
    const url = URL.createObjectURL(file);
    const img = new Image();
    img.onload = () => {
      loadedImg = img;
      renderPreview();
    };
    img.src = url;
    return () => URL.revokeObjectURL(url);
  });

  $effect(() => {
    // Re-render whenever state changes
    void loadedImg;
    void quarterTurns;
    void crop;
    void strokes;
    void currentStroke;
    void labels;
    void tool;
    renderPreview();
  });

  function turnedDimensions(img: HTMLImageElement, turns: number): { w: number; h: number } {
    const odd = ((turns % 4) + 4) % 4 % 2 === 1;
    return odd
      ? { w: img.naturalHeight || img.height, h: img.naturalWidth || img.width }
      : { w: img.naturalWidth || img.width, h: img.naturalHeight || img.height };
  }

  function rotateClockwise() {
    quarterTurns = (quarterTurns + 1) % 4;
    // Rotate existing normalized coordinates 90° clockwise: (x, y) -> (1 - y, x)
    crop = {
      x: Math.max(0, Math.min(1, 1 - (crop.y + crop.h))),
      y: crop.x,
      w: crop.h,
      h: crop.w,
    };
    strokes = strokes.map((s) => ({
      ...s,
      points: s.points.map((p) => ({ x: 1 - p.y, y: p.x })),
    }));
    labels = labels.map((l) => ({
      ...l,
      center: { x: 1 - l.center.y, y: l.center.x },
    }));
  }

  function resetAll() {
    quarterTurns = 0;
    crop = { x: 0, y: 0, w: 1, h: 1 };
    strokes = [];
    currentStroke = null;
    labels = [];
  }

  function undoLast() {
    if (strokes.length > 0) {
      strokes = strokes.slice(0, -1);
    } else if (labels.length > 0) {
      labels = labels.slice(0, -1);
    }
  }

  function addTextLabel() {
    const text = textDraft.trim();
    if (!text) return;
    labels = [
      ...labels,
      {
        id: `${Date.now()}-${labels.length}`,
        text,
        center: {
          x: crop.x + crop.w * 0.5,
          y: crop.y + crop.h * 0.5,
        },
        ink: activeInk,
      },
    ];
    textDraft = "";
  }

  function removeLabel(id: string) {
    labels = labels.filter((l) => l.id !== id);
  }

  function drawTurnedImage(ctx: CanvasRenderingContext2D, img: HTMLImageElement, w: number, h: number) {
    ctx.save();
    const turns = ((quarterTurns % 4) + 4) % 4;
    ctx.translate(w / 2, h / 2);
    ctx.rotate((turns * Math.PI) / 2);
    if (turns % 2 === 1) {
      ctx.drawImage(img, -h / 2, -w / 2, h, w);
    } else {
      ctx.drawImage(img, -w / 2, -h / 2, w, h);
    }
    ctx.restore();
  }

  function drawAnnotations(ctx: CanvasRenderingContext2D, w: number, h: number) {
    const allStrokes = currentStroke ? [...strokes, currentStroke] : strokes;
    for (const s of allStrokes) {
      if (s.points.length === 0) continue;
      ctx.save();
      ctx.strokeStyle = inkCss(s.ink);
      ctx.fillStyle = inkCss(s.ink);
      ctx.lineWidth = Math.max(3, Math.round(Math.min(w, h) * 0.008));
      ctx.lineCap = "round";
      ctx.lineJoin = "round";
      ctx.beginPath();
      const first = s.points[0];
      ctx.moveTo(first.x * w, first.y * h);
      if (s.points.length === 1) {
        ctx.arc(first.x * w, first.y * h, ctx.lineWidth / 2, 0, Math.PI * 2);
        ctx.fill();
      } else {
        for (let i = 1; i < s.points.length; i++) {
          ctx.lineTo(s.points[i].x * w, s.points[i].y * h);
        }
        ctx.stroke();
      }
      ctx.restore();
    }

    const fontPx = Math.max(16, Math.round(Math.min(w, h) * 0.042));
    for (const lbl of labels) {
      ctx.save();
      ctx.font = `600 ${fontPx}px sans-serif`;
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      const x = lbl.center.x * w;
      const y = lbl.center.y * h;
      ctx.lineWidth = Math.max(3, Math.round(fontPx * 0.16));
      ctx.strokeStyle = lbl.ink === "black" ? "rgb(255, 255, 255)" : "rgb(0, 0, 0)";
      ctx.strokeText(lbl.text, x, y);
      ctx.fillStyle = inkCss(lbl.ink);
      ctx.fillText(lbl.text, x, y);
      ctx.restore();
    }
  }

  function renderPreview() {
    if (!canvasEl || !loadedImg) return;
    const { w: natW, h: natH } = turnedDimensions(loadedImg, quarterTurns);
    const maxSide = 720;
    const scale = Math.min(1, maxSide / Math.max(1, Math.max(natW, natH)));
    const w = Math.max(1, Math.round(natW * scale));
    const h = Math.max(1, Math.round(natH * scale));
    if (canvasEl.width !== w || canvasEl.height !== h) {
      canvasEl.width = w;
      canvasEl.height = h;
    }
    const ctx = canvasEl.getContext("2d");
    if (!ctx) return;
    ctx.clearRect(0, 0, w, h);

    drawTurnedImage(ctx, loadedImg, w, h);
    drawAnnotations(ctx, w, h);

    // Draw crop overlay mask & frame when crop tool is active or image is cropped
    if (tool === "crop" || crop.x > 0.001 || crop.y > 0.001 || crop.w < 0.999 || crop.h < 0.999) {
      const cx = crop.x * w;
      const cy = crop.y * h;
      const cw = crop.w * w;
      const ch = crop.h * h;

      ctx.save();
      ctx.fillStyle = "rgba(0, 0, 0, 0.48)";
      // Top, bottom, left, right dimmed regions outside crop
      ctx.fillRect(0, 0, w, cy);
      ctx.fillRect(0, cy + ch, w, h - (cy + ch));
      ctx.fillRect(0, cy, cx, ch);
      ctx.fillRect(cx + cw, cy, w - (cx + cw), ch);

      ctx.strokeStyle = "rgb(255, 255, 255)";
      ctx.lineWidth = 2;
      ctx.strokeRect(cx, cy, cw, ch);

      if (tool === "crop") {
        // Rule of thirds grid lines
        ctx.strokeStyle = "rgba(255, 255, 255, 0.35)";
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(cx + cw / 3, cy);
        ctx.lineTo(cx + cw / 3, cy + ch);
        ctx.moveTo(cx + (cw * 2) / 3, cy);
        ctx.lineTo(cx + (cw * 2) / 3, cy + ch);
        ctx.moveTo(cx, cy + ch / 3);
        ctx.lineTo(cx + cw, cy + ch / 3);
        ctx.moveTo(cx, cy + (ch * 2) / 3);
        ctx.lineTo(cx + cw, cy + (ch * 2) / 3);
        ctx.stroke();

        // Corner & edge handles
        ctx.fillStyle = "rgb(255, 255, 255)";
        const handles: [number, number][] = [
          [cx, cy],
          [cx + cw / 2, cy],
          [cx + cw, cy],
          [cx, cy + ch / 2],
          [cx + cw, cy + ch / 2],
          [cx, cy + ch],
          [cx + cw / 2, cy + ch],
          [cx + cw, cy + ch],
        ];
        for (const [hx, hy] of handles) {
          ctx.fillRect(hx - 5, hy - 5, 10, 10);
        }
      }
      ctx.restore();
    }
  }

  function pointerToUnit(e: PointerEvent): Point {
    if (!canvasEl) return { x: 0, y: 0 };
    const rect = canvasEl.getBoundingClientRect();
    const x = Math.max(0, Math.min(1, (e.clientX - rect.left) / Math.max(1, rect.width)));
    const y = Math.max(0, Math.min(1, (e.clientY - rect.top) / Math.max(1, rect.height)));
    return { x, y };
  }

  function detectCropHandle(pt: Point): CropHandle | null {
    const tol = 0.045;
    const left = Math.abs(pt.x - crop.x) <= tol;
    const right = Math.abs(pt.x - (crop.x + crop.w)) <= tol;
    const top = Math.abs(pt.y - crop.y) <= tol;
    const bottom = Math.abs(pt.y - (crop.y + crop.h)) <= tol;
    const midX = Math.abs(pt.x - (crop.x + crop.w / 2)) <= tol;
    const midY = Math.abs(pt.y - (crop.y + crop.h / 2)) <= tol;

    if (top && left) return "topLeft";
    if (top && right) return "topRight";
    if (bottom && left) return "bottomLeft";
    if (bottom && right) return "bottomRight";
    if (top && midX) return "top";
    if (bottom && midX) return "bottom";
    if (left && midY) return "left";
    if (right && midY) return "right";
    if (pt.x >= crop.x && pt.x <= crop.x + crop.w && pt.y >= crop.y && pt.y <= crop.y + crop.h) {
      return "inside";
    }
    return null;
  }

  function moveCrop(initial: CropRect, handle: CropHandle, dx: number, dy: number): CropRect {
    if (handle === "inside") {
      return {
        x: Math.min(1 - initial.w, Math.max(0, initial.x + dx)),
        y: Math.min(1 - initial.h, Math.max(0, initial.y + dy)),
        w: initial.w,
        h: initial.h,
      };
    }
    let left = initial.x;
    let right = initial.x + initial.w;
    let top = initial.y;
    let bottom = initial.y + initial.h;

    if (handle === "topLeft" || handle === "left" || handle === "bottomLeft") {
      left = Math.min(right - MIN_CROP, Math.max(0, left + dx));
    }
    if (handle === "topRight" || handle === "right" || handle === "bottomRight") {
      right = Math.max(left + MIN_CROP, Math.min(1, right + dx));
    }
    if (handle === "topLeft" || handle === "top" || handle === "topRight") {
      top = Math.min(bottom - MIN_CROP, Math.max(0, top + dy));
    }
    if (handle === "bottomLeft" || handle === "bottom" || handle === "bottomRight") {
      bottom = Math.max(top + MIN_CROP, Math.min(1, bottom + dy));
    }
    return { x: left, y: top, w: right - left, h: bottom - top };
  }

  function onPointerDown(e: PointerEvent) {
    if (!canvasEl) return;
    canvasEl.setPointerCapture(e.pointerId);
    const pt = pointerToUnit(e);

    if (tool === "crop") {
      const h = detectCropHandle(pt);
      if (h) {
        activeCropHandle = h;
        dragStart = { pt, initial: { ...crop } };
      }
      return;
    }

    if (tool === "text") {
      // Check if clicking near an existing label to drag it
      const hit = [...labels]
        .reverse()
        .find((l) => Math.hypot(l.center.x - pt.x, l.center.y - pt.y) < 0.08);
      if (hit) {
        draggingLabelId = hit.id;
      } else if (textDraft.trim()) {
        labels = [
          ...labels,
          {
            id: `${Date.now()}-${labels.length}`,
            text: textDraft.trim(),
            center: pt,
            ink: activeInk,
          },
        ];
        textDraft = "";
      }
      return;
    }

    // Draw mode
    currentStroke = { points: [pt], ink: activeInk };
  }

  function onPointerMove(e: PointerEvent) {
    const pt = pointerToUnit(e);
    if (tool === "crop" && activeCropHandle && dragStart) {
      const dx = pt.x - dragStart.pt.x;
      const dy = pt.y - dragStart.pt.y;
      crop = moveCrop(dragStart.initial, activeCropHandle, dx, dy);
      return;
    }
    if (tool === "text" && draggingLabelId) {
      labels = labels.map((l) => (l.id === draggingLabelId ? { ...l, center: pt } : l));
      return;
    }
    if (tool === "draw" && currentStroke) {
      currentStroke = {
        ...currentStroke,
        points: [...currentStroke.points, pt],
      };
    }
  }

  function onPointerUp(e: PointerEvent) {
    if (canvasEl?.hasPointerCapture(e.pointerId)) {
      canvasEl.releasePointerCapture(e.pointerId);
    }
    if (currentStroke) {
      strokes = [...strokes, currentStroke];
      currentStroke = null;
    }
    activeCropHandle = null;
    dragStart = null;
    draggingLabelId = null;
  }

  async function applyAndSave() {
    if (!loadedImg || saving) return;
    saving = true;
    try {
      const { w: fullW, h: fullH } = turnedDimensions(loadedImg, quarterTurns);
      const fullCanvas = document.createElement("canvas");
      fullCanvas.width = Math.max(1, fullW);
      fullCanvas.height = Math.max(1, fullH);
      const fullCtx = fullCanvas.getContext("2d");
      if (!fullCtx) return;

      drawTurnedImage(fullCtx, loadedImg, fullCanvas.width, fullCanvas.height);
      drawAnnotations(fullCtx, fullCanvas.width, fullCanvas.height);

      // Apply pixel crop matching `ChatImageEdit.pixels` on macOS
      const left = Math.round(crop.x * fullCanvas.width);
      const top = Math.round(crop.y * fullCanvas.height);
      const outW = Math.max(1, Math.round((crop.x + crop.w) * fullCanvas.width) - left);
      const outH = Math.max(1, Math.round((crop.y + crop.h) * fullCanvas.height) - top);

      const outCanvas = document.createElement("canvas");
      outCanvas.width = outW;
      outCanvas.height = outH;
      const outCtx = outCanvas.getContext("2d");
      if (!outCtx) return;
      outCtx.drawImage(fullCanvas, left, top, outW, outH, 0, 0, outW, outH);

      const dataUrl = outCanvas.toDataURL("image/png");
      const blob = await new Promise<Blob | null>((resolve) =>
        outCanvas.toBlob((b) => resolve(b), "image/png")
      );
      if (!blob) return;
      const baseName = file.name.replace(/\.[^.]+$/, "") || "image";
      const editedFile = new File([blob], `${baseName}.png`, {
        type: "image/png",
        lastModified: Date.now(),
      });
      onsave(editedFile, dataUrl);
    } finally {
      saving = false;
    }
  }
</script>

<!-- svelte-ignore a11y_click_events_have_key_events a11y_no_noninteractive_element_interactions -->
<div class="backdrop" role="dialog" aria-modal="true" aria-label={tr("Afbeelding bewerken", "Edit picture")} onclick={onclose}>
  <!-- svelte-ignore a11y_click_events_have_key_events a11y_no_static_element_interactions -->
  <div class="editor-card" onclick={(e) => e.stopPropagation()}>
    <header class="editor-head">
      <strong>{tr("Afbeelding bewerken", "Edit picture")}</strong>
      <div class="toolbar">
        <button
          type="button"
          class="tool-btn"
          class:active={tool === "crop"}
          onclick={() => (tool = "crop")}
          title={tr("Bijsnijden", "Crop")}
        >
          <Ico name="crop" size={14} />
          <span>{tr("Bijsnijden", "Crop")}</span>
        </button>
        <button
          type="button"
          class="tool-btn"
          onclick={rotateClockwise}
          title={tr("90° draaien", "Rotate 90°")}
        >
          <Ico name="refresh" size={14} />
          <span>{tr("Draaien", "Rotate")}</span>
        </button>
        <button
          type="button"
          class="tool-btn"
          class:active={tool === "draw"}
          onclick={() => (tool = "draw")}
          title={tr("Tekenen", "Draw")}
        >
          <Ico name="edit" size={14} />
          <span>{tr("Tekenen", "Draw")}</span>
        </button>
        <button
          type="button"
          class="tool-btn"
          class:active={tool === "text"}
          onclick={() => (tool = "text")}
          title={tr("Tekst", "Text")}
        >
          <Ico name="type" size={14} />
          <span>{tr("Tekst", "Text")}</span>
        </button>
      </div>
      <div class="head-actions">
        {#if strokes.length > 0 || labels.length > 0}
          <button type="button" class="tool-btn" onclick={undoLast} title={tr("Ongedaan maken", "Undo")}>
            <Ico name="undo" size={14} />
          </button>
        {/if}
        {#if hasChanges}
          <button type="button" class="tool-btn" onclick={resetAll}>
            {tr("Herstel", "Reset")}
          </button>
        {/if}
      </div>
    </header>

    {#if tool === "draw" || tool === "text"}
      <div class="subbar">
        <div class="inks" role="radiogroup" aria-label={tr("Kleur", "Color")}>
          {#each INKS as ink (ink.id)}
            <button
              type="button"
              class="ink-dot {ink.tokenClass}"
              class:selected={activeInk === ink.id}
              onclick={() => (activeInk = ink.id)}
              aria-label={ink.id}
              aria-checked={activeInk === ink.id}
              role="radio"
            ></button>
          {/each}
        </div>
        {#if tool === "text"}
          <div class="text-entry">
            <input
              type="text"
              bind:value={textDraft}
              placeholder={tr("Typ tekst en klik op Toevoegen of op de afbeelding…", "Type text and click Add or tap the picture…")}
              onkeydown={(e) => {
                if (e.key === "Enter") {
                  e.preventDefault();
                  addTextLabel();
                }
              }}
            />
            <button type="button" class="tool-btn" disabled={!textDraft.trim()} onclick={addTextLabel}>
              {tr("Toevoegen", "Add")}
            </button>
          </div>
        {/if}
      </div>
    {/if}

    {#if labels.length > 0 && tool === "text"}
      <div class="label-pills">
        {#each labels as lbl (lbl.id)}
          <span class="label-pill">
            <span>{lbl.text}</span>
            <button type="button" onclick={() => removeLabel(lbl.id)} aria-label={tr("Verwijder", "Remove")}>×</button>
          </span>
        {/each}
      </div>
    {/if}

    <div class="canvas-stage">
      <canvas
        bind:this={canvasEl}
        class="preview-canvas"
        onpointerdown={onPointerDown}
        onpointermove={onPointerMove}
        onpointerup={onPointerUp}
        onpointercancel={onPointerUp}
      ></canvas>
    </div>

    <footer class="editor-foot">
      <button type="button" class="ghost-btn" onclick={onclose}>
        {tr("Annuleer", "Cancel")}
      </button>
      <button type="button" class="primary-btn" disabled={saving} onclick={applyAndSave}>
        {tr("Klaar", "Done")}
      </button>
    </footer>
  </div>
</div>

<style>
  .backdrop {
    position: fixed;
    inset: 0;
    z-index: 80;
    background: color-mix(in srgb, var(--ink) 74%, transparent);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: var(--space-16);
  }
  .editor-card {
    width: min(760px, 94vw);
    max-height: 90vh;
    display: flex;
    flex-direction: column;
    gap: var(--space-10);
    padding: var(--space-16);
    background: var(--graphite);
    border: 1px solid var(--line2);
    border-radius: var(--radius-card);
    box-shadow: var(--shadow-modal);
  }
  .editor-head {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-10);
    flex-wrap: wrap;
  }
  .editor-head strong {
    font: var(--text-title);
    color: var(--paper);
  }
  .toolbar,
  .head-actions {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    flex-wrap: wrap;
  }
  .tool-btn {
    display: inline-flex;
    align-items: center;
    gap: var(--space-6);
    padding: var(--space-4) var(--space-10);
    border-radius: var(--radius-control);
    border: 1px solid var(--line2);
    background: var(--glass);
    color: var(--text2);
    font: var(--text-detail);
    cursor: pointer;
  }
  .tool-btn:hover:not(:disabled),
  .tool-btn.active {
    color: var(--paper);
    background: var(--glass-hover);
    border-color: var(--paper);
  }
  .tool-btn:disabled {
    opacity: 0.45;
    cursor: default;
  }
  .subbar {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: var(--space-12);
    flex-wrap: wrap;
    padding: var(--space-6) var(--space-10);
    border-radius: var(--radius-control);
    background: var(--surface-subtle);
  }
  .inks {
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
  .ink-dot {
    width: 20px;
    height: 20px;
    border-radius: 999px;
    border: 2px solid var(--line2);
    cursor: pointer;
    padding: 0;
  }
  .ink-dot.selected {
    border-color: var(--paper);
    transform: scale(1.15);
  }
  .ink-white {
    background: var(--paper);
  }
  .ink-black {
    background: var(--ink);
  }
  .ink-red {
    background: var(--coral);
  }
  .ink-yellow {
    background: var(--amber);
  }
  .ink-green {
    background: var(--mint);
  }
  .ink-blue {
    background: var(--sky);
  }
  .text-entry {
    flex: 1;
    min-width: 200px;
    display: flex;
    align-items: center;
    gap: var(--space-8);
  }
  .text-entry input {
    flex: 1;
    padding: var(--space-4) var(--space-8);
    border-radius: var(--radius-control);
    border: 1px solid var(--line2);
    background: var(--ink);
    color: var(--paper);
    font: var(--text-detail);
    outline: none;
  }
  .label-pills {
    display: flex;
    align-items: center;
    gap: var(--space-6);
    flex-wrap: wrap;
  }
  .label-pill {
    display: inline-flex;
    align-items: center;
    gap: var(--space-4);
    padding: var(--space-2) var(--space-8);
    border-radius: 999px;
    background: var(--glass);
    border: 1px solid var(--line2);
    font: var(--text-caption);
    color: var(--paper);
  }
  .label-pill button {
    border: 0;
    background: none;
    color: var(--text3);
    cursor: pointer;
    padding: 0;
    font: var(--text-detail);
  }
  .canvas-stage {
    flex: 1;
    min-height: 240px;
    max-height: 60vh;
    display: flex;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    background: var(--ink);
    border-radius: var(--radius-control);
    border: 1px solid var(--line);
    padding: var(--space-8);
  }
  .preview-canvas {
    max-width: 100%;
    max-height: 56vh;
    object-fit: contain;
    touch-action: none;
    cursor: crosshair;
  }
  .editor-foot {
    display: flex;
    align-items: center;
    justify-content: flex-end;
    gap: var(--space-8);
  }
  .ghost-btn,
  .primary-btn {
    padding: var(--space-6) var(--space-14);
    border-radius: var(--radius-control);
    font: var(--text-emphasis);
    cursor: pointer;
  }
  .ghost-btn {
    border: 1px solid var(--line2);
    background: transparent;
    color: var(--text2);
  }
  .ghost-btn:hover {
    color: var(--paper);
    background: var(--glass);
  }
  .primary-btn {
    border: 0;
    background: var(--paper);
    color: var(--ink);
  }
  .primary-btn:disabled {
    opacity: 0.45;
    cursor: default;
  }
</style>
