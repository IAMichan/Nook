<script lang="ts">
  // A PDF shown beside a session (`PdfPointView` + `PdfPointCapture` on the Mac, AG-106): every page rendered sharply
  // with a crosshair cursor over the page. Clicking a spot measures its distance from every edge, grabs the text at the
  // spot, renders a cropped 2x picture with a crosshair on it, leaves an in-memory iris ring on the page, and hands the
  // snippet + picture to the session's composer. The file on disk is never modified.
  import { invoke } from "@tauri-apps/api/core";
  import { tr } from "../../../lib/i18n.svelte";
  import { toast } from "../../../lib/toast.svelte";
  import { composerInbox } from "../../../lib/workspace/composer-inbox.svelte";
  import {
    drawPdfCrosshair,
    extractPdfTextAtPoint,
    PDF_PICTURE_SCALE,
    pdfCropRect,
    pdfPointImageName,
    shownPdfPoint,
    type PdfTextSpan,
    type PickedPdfPoint,
  } from "../../../lib/workspace/pdf-point";
  import Ico from "../../../components/ui/Ico.svelte";
  import IconButton from "../../../components/ui/IconButton.svelte";
  import Spinner from "../../../components/ui/Spinner.svelte";

  type PdfModule = typeof import("pdfjs-dist/legacy/build/pdf.mjs");
  type PdfDocumentProxy = import("pdfjs-dist/types/src/display/api").PDFDocumentProxy;
  type PdfPageProxy = import("pdfjs-dist/types/src/display/api").PDFPageProxy;
  type PdfRenderTask = import("pdfjs-dist/types/src/display/api").RenderTask;

  interface FilePreview {
    path: string;
    name: string;
    kind: string;
    mediaType: string;
    size: number;
    base64: string | null;
  }

  interface PageMeta {
    num: number;
    width: number;
    height: number;
  }

  interface PdfMark {
    id: number;
    page: number;
    fromLeft: number;
    fromTop: number;
  }

  let { runId = null, path, version = 0 }: {
    /** The session receiving clicked spots; null for read-only viewing. */
    runId?: string | null;
    path: string;
    /** Bumped when the file on disk changes so the viewer reloads cleanly. */
    version?: number | string;
  } = $props();

  let pdfjsPromise: Promise<PdfModule> | null = null;
  async function loadPdfJs(): Promise<PdfModule> {
    if (!pdfjsPromise) {
      pdfjsPromise = Promise.all([
        import("pdfjs-dist/legacy/build/pdf.mjs"),
        import("pdfjs-dist/legacy/build/pdf.worker.min.mjs?url"),
      ]).then(([mod, worker]) => {
        mod.GlobalWorkerOptions.workerSrc = worker.default;
        return mod;
      });
    }
    return pdfjsPromise;
  }

  let scroller = $state<HTMLElement>();
  let containerWidth = $state(0);
  let zoom = $state(1);
  let loading = $state(true);
  let error = $state<string | null>(null);
  let pages = $state<PageMeta[]>([]);
  let marks = $state<PdfMark[]>([]);
  let markSeq = 0;

  // Held outside reactivity: PDF.js document/page handles carry private state & workers.
  let doc: PdfDocumentProxy | null = null;
  const pageHandles = new Map<number, PdfPageProxy>();
  const canvases = new Map<number, HTMLCanvasElement>();
  const renderTasks = new Map<number, PdfRenderTask>();
  let renderGeneration = 0;

  const canPick = $derived(!!runId);

  function displayScaleFor(page: PageMeta): number {
    const available = Math.max(180, (containerWidth || 520) - 32);
    const fit = page.width > 0 ? available / page.width : 1;
    return Math.max(0.25, Math.min(4, fit * zoom));
  }

  function bindCanvas(node: HTMLCanvasElement, pageNum: number) {
    canvases.set(pageNum, node);
    void renderPage(pageNum, renderGeneration);
    return {
      destroy() {
        renderTasks.get(pageNum)?.cancel();
        renderTasks.delete(pageNum);
        canvases.delete(pageNum);
      },
    };
  }

  async function renderPage(pageNum: number, generation: number) {
    const canvas = canvases.get(pageNum);
    const page = pageHandles.get(pageNum);
    const meta = pages.find((p) => p.num === pageNum);
    if (!canvas || !page || !meta || generation !== renderGeneration) return;

    renderTasks.get(pageNum)?.cancel();
    renderTasks.delete(pageNum);

    const scale = displayScaleFor(meta);
    const dpr = Math.min(window.devicePixelRatio || 1, 2.5);
    const cssViewport = page.getViewport({ scale });
    const renderViewport = page.getViewport({ scale: scale * dpr });

    canvas.width = Math.max(1, Math.round(renderViewport.width));
    canvas.height = Math.max(1, Math.round(renderViewport.height));
    canvas.style.width = `${cssViewport.width}px`;
    canvas.style.height = `${cssViewport.height}px`;

    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, canvas.width, canvas.height);

    const task = page.render({ canvasContext: ctx, canvas, viewport: renderViewport });
    renderTasks.set(pageNum, task);
    try {
      await task.promise;
    } catch {
      // Cancelled when zooming, resizing, or unloading the PDF.
    } finally {
      if (renderTasks.get(pageNum) === task) renderTasks.delete(pageNum);
    }
  }

  function rerenderAll() {
    const gen = ++renderGeneration;
    for (const meta of pages) void renderPage(meta.num, gen);
  }

  // Track viewport width so pages fit neatly inside the side panel as it is resized.
  $effect(() => {
    const el = scroller;
    if (!el || typeof ResizeObserver === "undefined") return;
    containerWidth = el.clientWidth;
    const observer = new ResizeObserver((entries) => {
      const next = Math.round(entries[0]?.contentRect.width ?? el.clientWidth);
      if (Math.abs(next - containerWidth) >= 2) containerWidth = next;
    });
    observer.observe(el);
    return () => observer.disconnect();
  });

  // Redraw when container width or zoom changes.
  $effect(() => {
    void containerWidth;
    void zoom;
    if (pages.length) rerenderAll();
  });

  // Load the PDF bytes via the safe `file_preview` command and decode every page's dimensions.
  $effect(() => {
    const targetPath = path;
    void version;
    let stale = false;
    let loadingTask: { destroy(): Promise<void> } | null = null;
    let loadedDoc: PdfDocumentProxy | null = null;

    loading = true;
    error = null;
    pages = [];
    marks = [];
    pageHandles.clear();
    for (const task of renderTasks.values()) task.cancel();
    renderTasks.clear();

    void (async () => {
      try {
        const [pdfjs, preview] = await Promise.all([
          loadPdfJs(),
          invoke<FilePreview>("file_preview", { path: targetPath }),
        ]);
        if (stale) return;
        if (!preview.base64) {
          error = tr("Dit bestand is te groot om hier te tonen; open het in zijn app.", "This file is too large to show here; open it in its app.");
          loading = false;
          return;
        }
        const binary = atob(preview.base64);
        const bytes = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);

        const task = pdfjs.getDocument({ data: bytes });
        loadingTask = task;
        loadedDoc = await task.promise;
        if (stale) {
          await task.destroy().catch(() => {});
          return;
        }
        doc = loadedDoc;
        const metas: PageMeta[] = [];
        for (let n = 1; n <= loadedDoc.numPages; n++) {
          const p = await loadedDoc.getPage(n);
          if (stale) return;
          pageHandles.set(n, p);
          const vp = p.getViewport({ scale: 1 });
          metas.push({ num: n, width: vp.width, height: vp.height });
        }
        pages = metas;
        loading = false;
        rerenderAll();
      } catch (e) {
        if (stale) return;
        error = e instanceof Error ? e.message : tr("Deze PDF kon niet worden getekend.", "Could not render this PDF.");
        loading = false;
      }
    })();

    return () => {
      stale = true;
      for (const task of renderTasks.values()) task.cancel();
      renderTasks.clear();
      pageHandles.clear();
      if (doc === loadedDoc) doc = null;
      if (loadingTask) void loadingTask.destroy().catch(() => {});
    };
  });

  async function extractText(page: PdfPageProxy, pdfX: number, pdfY: number): Promise<string> {
    try {
      const content = await page.getTextContent();
      const spans: PdfTextSpan[] = [];
      for (const item of content.items) {
        if (!("str" in item) || !item.str) continue;
        const t = item.transform;
        const height = item.height > 0 ? item.height : Math.hypot(t[2], t[3]) || 10;
        spans.push({ str: item.str, x: t[4], y: t[5], width: item.width, height });
      }
      return extractPdfTextAtPoint(spans, pdfX, pdfY);
    } catch {
      return "";
    }
  }

  async function renderCropPicture(page: PdfPageProxy, point: PickedPdfPoint): Promise<string | null> {
    const crop = pdfCropRect(point);
    if (crop.pixelWidth <= 0 || crop.pixelHeight <= 0) return null;
    const offscreen = document.createElement("canvas");
    offscreen.width = crop.pixelWidth;
    offscreen.height = crop.pixelHeight;
    const ctx = offscreen.getContext("2d");
    if (!ctx) return null;
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, offscreen.width, offscreen.height);

    const cropViewport = page.getViewport({
      scale: PDF_PICTURE_SCALE,
      offsetX: -crop.x * PDF_PICTURE_SCALE,
      offsetY: -crop.y * PDF_PICTURE_SCALE,
    });
    await page.render({ canvasContext: ctx, canvas: offscreen, viewport: cropViewport }).promise;
    drawPdfCrosshair(ctx, crop.spotX, crop.spotY, PDF_PICTURE_SCALE);
    const dataUrl = offscreen.toDataURL("image/png");
    return invoke<string>("workspace_save_picture", {
      data: dataUrl,
      extension: "png",
      name: pdfPointImageName(point),
    });
  }

  async function pickSpot(pageNum: number, e: MouseEvent) {
    if (!runId || !doc) return;
    const page = pageHandles.get(pageNum);
    const meta = pages.find((p) => p.num === pageNum);
    const canvas = canvases.get(pageNum);
    if (!page || !meta || !canvas) return;

    const rect = canvas.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return;
    const offsetX = Math.min(Math.max(0, e.clientX - rect.left), rect.width);
    const offsetY = Math.min(Math.max(0, e.clientY - rect.top), rect.height);

    const scale = rect.width / Math.max(meta.width, 0.0001);
    const viewport = page.getViewport({ scale });
    const [pdfX, pdfY] = viewport.convertToPdfPoint(offsetX, offsetY);
    const [minX, minY, maxX, maxY] = page.view;
    const shown = shownPdfPoint(pdfX, pdfY, { minX, minY, maxX, maxY }, page.rotate);

    // Mark the spot immediately in memory (never written to disk).
    marks = [...marks, { id: ++markSeq, page: pageNum, fromLeft: shown.fromLeft, fromTop: shown.fromTop }];

    const text = await extractText(page, pdfX, pdfY);
    const point: PickedPdfPoint = {
      path,
      page: pageNum,
      pageCount: doc.numPages,
      width: shown.width,
      height: shown.height,
      fromLeft: shown.fromLeft,
      fromTop: shown.fromTop,
      pdfX,
      pdfY,
      text,
    };

    let imagePath: string | null = null;
    try {
      imagePath = await renderCropPicture(page, point);
    } catch (err) {
      toast.error(tr("Kon de afbeelding niet opslaan", "Could not save the picture"), err);
    }
    composerInbox.addPdfPoint(point, imagePath, runId);
  }

  const zoomOut = () => (zoom = Math.max(0.5, Number((zoom - 0.15).toFixed(2))));
  const zoomIn = () => (zoom = Math.min(2.5, Number((zoom + 0.15).toFixed(2))));
  const resetZoom = () => (zoom = 1);
</script>

<div class="pdf-view">
  <div class="toolbar">
    {#if canPick}
      <span class="hint">
        <Ico name="crosshair" size={13} />
        <span class="truncate">{tr("Klik op een plek op een pagina om die naar de composer te sturen", "Click a spot on any page to send it to the composer")}</span>
      </span>
    {:else if pages.length}
      <span class="count">{tr("{count} pagina's", "{count} pages", { count: pages.length })}</span>
    {/if}
    <span class="spacer"></span>
    {#if marks.length}
      <button class="clear" onclick={() => (marks = [])}>{tr("Markeringen wissen", "Clear marks")}</button>
    {/if}
    {#if pages.length}
      <span class="count">{pages.length === 1 ? "1/1" : tr("{count} pagina's", "{count} pages", { count: pages.length })}</span>
      <IconButton title={tr("Uitzoomen", "Zoom out")} size={24} onclick={zoomOut}><Ico name="minus" size={13} /></IconButton>
      <button class="zoom" title={tr("Zoom herstellen", "Reset zoom")} onclick={resetZoom}>{Math.round(zoom * 100)}%</button>
      <IconButton title={tr("Inzoomen", "Zoom in")} size={24} onclick={zoomIn}><Ico name="plus" size={13} /></IconButton>
    {/if}
  </div>

  <div class="pages" bind:this={scroller}>
    {#if error}
      <p class="note">{error}</p>
    {:else if loading}
      <div class="center"><Spinner /></div>
    {:else}
      {#each pages as page (page.num)}
        {@const scale = displayScaleFor(page)}
        {@const pageMarks = marks.filter((m) => m.page === page.num)}
        <div class="sheet" class:pickable={canPick}>
          <!-- svelte-ignore a11y_no_noninteractive_element_interactions, a11y_click_events_have_key_events -->
          <canvas
            class="canvas"
            aria-label={tr("Pagina {n} van {total}", "Page {n} of {total}", { n: page.num, total: pages.length })}
            use:bindCanvas={page.num}
            onclick={(e) => void pickSpot(page.num, e)}
          ></canvas>
          {#each pageMarks as m (m.id)}
            <span
              class="mark"
              style:left="{(m.fromLeft / Math.max(page.width, 0.0001)) * 100}%"
              style:top="{(m.fromTop / Math.max(page.height, 0.0001)) * 100}%"
              style:width="{Math.max(12, 14 * scale)}px"
              style:height="{Math.max(12, 14 * scale)}px"
            ></span>
          {/each}
        </div>
      {/each}
    {/if}
  </div>
</div>

<style>
  .pdf-view { display: flex; flex-direction: column; flex: 1; min-height: 0; background: var(--canvas); }
  .toolbar { display: flex; align-items: center; gap: var(--space-6); min-height: 32px; padding: 0 var(--space-8) 0 var(--space-12); border-bottom: 1px solid var(--hairline); color: var(--text2); background: var(--surface); }
  .hint { display: inline-flex; align-items: center; gap: var(--space-6); min-width: 0; font: var(--text-detail); color: var(--text2); }
  .truncate { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .spacer { flex: 1; }
  .count { font: var(--text-caption); color: var(--text3); flex: none; }
  .clear, .zoom { margin: 0; padding: var(--space-2) var(--space-6); border: 0; border-radius: var(--radius-chip); background: transparent; color: var(--text2); font: var(--text-caption); flex: none; }
  .clear:hover, .zoom:hover { background: var(--row-hover); color: var(--paper); }
  .pages { flex: 1; min-height: 0; overflow: auto; display: flex; flex-direction: column; align-items: center; gap: var(--space-12); padding: var(--space-12); cursor: default; }
  .sheet { position: relative; flex: none; box-shadow: var(--shadow-card); background: var(--paper); line-height: 0; }
  .sheet.pickable .canvas { cursor: crosshair; }
  .canvas { display: block; }
  .mark { position: absolute; transform: translate(-50%, -50%); border: 2px solid var(--iris); border-radius: 999px; background: color-mix(in srgb, var(--iris) 25%, transparent); pointer-events: none; box-sizing: border-box; }
  .center { display: grid; place-items: center; flex: 1; padding: var(--space-24); }
  .note { margin: 0; padding: var(--space-24) var(--space-16); font: var(--text-body); color: var(--text2); text-align: center; }
</style>
