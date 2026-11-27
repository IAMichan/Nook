import { describe, expect, it } from "vitest";
import {
  blankTask,
  curlExample,
  deliveryDetailLabel,
  deliveryOutcomeLabel,
  editorValues,
  newWebhookFilter,
  presetOf,
  problem,
  reasonLabel,
  ruleFor,
  ruleLabel,
} from "./automation";

const values = { minutes: 30, time: "07:05", weekdays: [] as number[], at: "2099-01-02T03:04" };

describe("scheduled task editor", () => {
  it("turns presets into rules and back", () => {
    expect(ruleFor("interval", values)).toEqual({ type: "interval", seconds: 1800 });
    expect(ruleFor("interval", { ...values, minutes: 0 })).toEqual({ type: "interval", seconds: 60 });
    expect(ruleFor("daily", values)).toEqual({ type: "fixedTime", hour: 7, minute: 5, weekdays: [] });
    expect(ruleFor("weekdays", values)).toEqual({ type: "fixedTime", hour: 7, minute: 5, weekdays: [2, 3, 4, 5, 6] });
    expect(ruleFor("weekdays", { ...values, weekdays: [6, 2] })).toEqual({ type: "fixedTime", hour: 7, minute: 5, weekdays: [2, 6] });
    expect(ruleFor("webhook", values)).toEqual({ type: "webhook" });
    const message = ruleFor("message", { ...values, apps: "WhatsApp, ", from: " Lisa ", keywords: "invoice, payment", groups: false });
    expect(message).toEqual({ type: "message", trigger: { apps: ["whatsapp"], from: "Lisa", keywords: ["invoice", "payment"], groups: false } });
    expect(presetOf(message)).toBe("message");
    expect(editorValues(message)).toMatchObject({ apps: "whatsapp", from: "Lisa", keywords: "invoice, payment" });
    expect(ruleLabel(message)).toBe("On a new message in whatsapp from Lisa about invoice, payment");
    const once = ruleFor("once", values);
    expect(once.type).toBe("once");
    expect(editorValues(once).at).toBe("2099-01-02T03:04");
    expect(presetOf({ type: "fixedTime", hour: 1, minute: 2, weekdays: [1] })).toBe("weekdays");
    expect(presetOf({ type: "fixedTime", hour: 1, minute: 2, weekdays: [] })).toBe("daily");
    expect(editorValues({ type: "fixedTime", hour: 7, minute: 5, weekdays: [3] })).toMatchObject({ time: "07:05", weekdays: [3] });
    expect(editorValues({ type: "interval", seconds: 5400 }).minutes).toBe(90);
  });

  it("says what is missing", () => {
    const t = blankTask("", "claude");
    expect(problem(t)).toBeTruthy();
    t.prompt = "Check the build";
    expect(problem(t)).toBeTruthy();
    t.target = { type: "newSession", projectPath: "/p", provider: "claude", profileId: null };
    expect(problem(t)).toBeNull();
    t.rule = { type: "once", at: "2000-01-01T00:00:00Z" };
    expect(problem(t)).toBeTruthy();
    t.rule = { type: "webhook" };
    t.webhook = { filters: [newWebhookFilter()], duplicateKey: "", coalesceSeconds: 0 };
    expect(problem(t)).toContain("body.action");
    t.webhook.filters[0].field = "body.action";
    expect(problem(t)).toBeNull();
    expect(t.permission).toBe("ask");
    expect(t.enabled).toBe(true);
  });

  it("labels rules, reasons, and webhook deliveries", () => {
    expect(ruleLabel({ type: "webhook" })).toBeTruthy();
    expect(ruleLabel({ type: "fixedTime", hour: 9, minute: 0, weekdays: [] })).toContain("09:00");
    expect(reasonLabel("sched.skip.missed")).not.toBe("sched.skip.missed");
    expect(reasonLabel("boom")).toBe("boom");
    expect(reasonLabel(null)).toBeNull();
    expect(curlExample("http://127.0.0.1:8787/hooks/x")).toContain("X-Hub-Signature-256: sha256=$sig");
    expect(deliveryOutcomeLabel("accepted")).toBe("Accepted");
    expect(deliveryOutcomeLabel("coalesced")).toBe("Combined");
    expect(deliveryDetailLabel({ outcome: "accepted", detail: null })).toContain("Runs");
    expect(deliveryDetailLabel({ outcome: "accepted", detail: "120" })).toContain("120");
    expect(deliveryDetailLabel({ outcome: "filtered", detail: "body.action = opened" })).toContain("body.action = opened");
    expect(deliveryDetailLabel({ outcome: "duplicate", detail: "pr-42" })).toContain("pr-42");
    expect(deliveryDetailLabel({ outcome: "coalesced", detail: "3" })).toContain("3");
    expect(deliveryDetailLabel({ outcome: "queueFull", detail: null })).toContain("waiting");
  });
});
