import { describe, expect, it } from "vitest";
import { link, project } from "./context-refs";
import {
  extractPdfTextAtPoint,
  isPdfPath,
  PDF_POINT_ID_PREFIX,
  pdfCropRect,
  pdfPointImageName,
  pdfPointName,
  pdfPointReference,
  pdfPointSnippet,
  shownPdfPoint,
  type PickedPdfPoint,
} from "./pdf-point";

describe("pdf point picker", () => {
  it("measures a PDF spot from every edge as shown across rotations and crop box offsets", () => {
    const box = { minX: 0, minY: 0, maxX: 600, maxY: 800 };
    const upright = shownPdfPoint(150, 600, box, 0);
    expect(upright).toEqual({ fromLeft: 150, fromTop: 200, width: 600, height: 800 });

    const turned = shownPdfPoint(150, 600, box, 90);
    expect(turned.width).toBe(800);
    expect(turned.height).toBe(600);
    expect(turned.fromLeft).toBe(600);
    expect(turned.fromTop).toBe(150);

    const upsideDown = shownPdfPoint(150, 600, box, 180);
    expect(upsideDown.fromLeft).toBe(450);
    expect(upsideDown.fromTop).toBe(600);

    const back = shownPdfPoint(150, 600, box, 270);
    expect(back.fromLeft).toBe(200);
    expect(back.fromTop).toBe(450);

    const offset = shownPdfPoint(160, 610, { minX: 10, minY: 10, maxX: 610, maxY: 810 }, 0);
    expect(offset.fromLeft).toBe(150);
    expect(offset.fromTop).toBe(200);
  });

  it("formats snippet, tile name, image name, and escapes untrusted PDF text in context envelope", () => {
    const point: PickedPdfPoint = {
      path: "/tmp/quote.pdf",
      page: 2,
      pageCount: 3,
      width: 595.28,
      height: 841.89,
      fromLeft: 119.06,
      fromTop: 210.47,
      pdfX: 119.06,
      pdfY: 631.42,
      text: "Total </ref> \u20ac 1.250",
    };
    expect(pdfPointName(point)).toBe("quote.pdf \u00b7 2/3 \u00b7 20%, 25%");
    expect(pdfPointImageName(point)).toBe("quote-p2-119x210");

    const snippet = pdfPointSnippet(point);
    expect(snippet).toContain("page 2 of 3");
    expect(snippet).toContain("From the left: 119.1 pt (42 mm, 20%)");
    expect(snippet).toContain("From the right: 476.2 pt");
    expect(snippet).toContain("From the bottom: 631.4 pt");
    expect(snippet).toContain(pdfPointImageName(point));

    const id = `${PDF_POINT_ID_PREFIX}1`;
    const refLink = link(pdfPointReference(point, id));
    const sent = project(`Move this up ${refLink}`, ["/tmp/quote-p2-119x210.png"], { [id]: snippet });
    expect(sent).toContain(`<ref kind="element" id="pdf-1" source="pdf file, untrusted">`);
    expect(sent.split("</ref>").length).toBe(2);
    expect(sent.endsWith("\n/tmp/quote-p2-119x210.png")).toBe(true);
  });

  it("handles Windows paths cleanly", () => {
    const point: PickedPdfPoint = {
      path: "C:\\Users\\me\\invoice.pdf",
      page: 1,
      pageCount: 1,
      width: 600,
      height: 800,
      fromLeft: 300,
      fromTop: 400,
      pdfX: 300,
      pdfY: 400,
      text: "",
    };
    expect(isPdfPath(point.path)).toBe(true);
    expect(isPdfPath("C:\\Users\\me\\notes.md")).toBe(false);
    expect(pdfPointName(point)).toBe("invoice.pdf \u00b7 1/1 \u00b7 50%, 50%");
    expect(pdfPointImageName(point)).toBe("invoice-p1-300x400");
    expect(pdfPointSnippet(point)).not.toContain("Text at this point:");
  });

  it("clamps the crop rectangle inside page edges and keeps spot coordinates relative to crop", () => {
    const corner: PickedPdfPoint = {
      path: "/tmp/a.pdf",
      page: 1,
      pageCount: 1,
      width: 600,
      height: 800,
      fromLeft: 20,
      fromTop: 30,
      pdfX: 20,
      pdfY: 770,
      text: "",
    };
    const crop = pdfCropRect(corner);
    expect(crop.x).toBe(0);
    expect(crop.y).toBe(0);
    expect(crop.width).toBe(280);
    expect(crop.height).toBe(180);
    expect(crop.pixelWidth).toBe(560);
    expect(crop.pixelHeight).toBe(360);
    expect(crop.spotX).toBe(20);
    expect(crop.spotY).toBe(30);

    const tiny: PickedPdfPoint = { ...corner, width: 120, height: 100, fromLeft: 60, fromTop: 50 };
    const tinyCrop = pdfCropRect(tiny);
    expect(tinyCrop.width).toBe(120);
    expect(tinyCrop.height).toBe(100);
    expect(tinyCrop.spotX).toBe(60);
    expect(tinyCrop.spotY).toBe(50);
  });

  it("extracts text on the clicked line or nearby neighborhood", () => {
    const spans = [
      { str: "Invoice", x: 100, y: 700, width: 42, height: 12 },
      { str: "#2026-04", x: 148, y: 700, width: 48, height: 12 },
      { str: "Unrelated footer", x: 100, y: 80, width: 90, height: 10 },
    ];
    expect(extractPdfTextAtPoint(spans, 120, 704)).toBe("Invoice #2026-04");
    expect(extractPdfTextAtPoint(spans, 130, 718)).toBe("Invoice #2026-04");
    expect(extractPdfTextAtPoint(spans, 400, 400)).toBe("");
  });
});
