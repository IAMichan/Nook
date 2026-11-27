// Helpers for CLIProxyAPI hubs (`CLIProxyHubViews.swift` + `I18n+CLIProxy.swift` on the Mac):
// localized problem text, account availability state, and window display conversion.
import { formatCompactDuration, type CliProxyAccount, type CliProxyProblem, type CliProxyWindow } from "./agents";
import { tr } from "./i18n.svelte";
import type { LimitDisplay } from "./workspace/limit-pool";

export type CliProxyAccountTone = "ready" | "warning" | "muted";

export interface CliProxyAccountState {
  text: string;
  tone: CliProxyAccountTone;
}

/** Localized error explanation for each CLIProxyAPI hub problem. */
export function cliproxyProblemText(problem: CliProxyProblem): string {
  switch (problem) {
    case "noKey":
      return tr(
        "Vul de beheersleutel in, of de sleutelhanger bewaarde hem niet.",
        "Enter the management key, or the keychain did not keep it.",
      );
    case "badAddress":
      return tr(
        "Dit is geen webadres. Gebruik http:// of https:// met de host van de hub.",
        "This is not a web address. Use http:// or https:// with the hub's host.",
      );
    case "insecureAddress":
      return tr(
        "Gebruik https voor een hub buiten dit netwerk, anders reist de beheersleutel onversleuteld. Gewone http mag voor deze computer en het lokale netwerk.",
        "Use https for a hub outside this network, or the management key travels unencrypted. Plain http is fine for this computer and the local network.",
      );
    case "rejectedKey":
      return tr("De hub weigerde de beheersleutel.", "The hub refused the management key.");
    case "unreachable":
      return tr("De hub is niet bereikbaar.", "The hub cannot be reached.");
    case "notAHub":
      return tr(
        "Dit adres antwoordt niet als een CLIProxyAPI-hub. Staat het beheer aan in de config van de hub?",
        "This address does not answer like a CLIProxyAPI hub. Is management switched on in the hub's config?",
      );
  }
}

/** Whether a hub account is ready, disabled, or cooling down (`CLIProxyAccountRow.state` on the Mac). */
export function cliproxyAccountState(account: CliProxyAccount, now: Date): CliProxyAccountState {
  if (account.disabled) {
    return { text: tr("Uitgeschakeld", "Disabled"), tone: "muted" };
  }
  const retry = account.retryAt ? new Date(account.retryAt) : null;
  const retryInFuture = retry !== null && !Number.isNaN(retry.getTime()) && retry.getTime() > now.getTime();
  const isAvailable = account.unavailable ? !retryInFuture && retry !== null : true;
  if (!isAvailable) {
    if (retryInFuture && retry) {
      const secs = (retry.getTime() - now.getTime()) / 1000;
      return {
        text: tr("Wacht nog {d}", "Waiting {d}", { d: formatCompactDuration(secs) }),
        tone: "warning",
      };
    }
    return { text: tr("Niet beschikbaar", "Unavailable"), tone: "warning" };
  }
  return { text: tr("Klaar", "Ready"), tone: "ready" };
}

/** Converts a hub account's windows into settled `LimitDisplay` rows matching `UsageLimitRows`. */
export function cliproxyWindowLimits(windows: CliProxyWindow[], now: Date): LimitDisplay[] {
  return windows.map((w) => {
    const label =
      w.key === "five_hour"
        ? tr("5 uur", "5 hours")
        : w.key === "seven_day"
          ? tr("Week", "Week")
          : tr("Venster", "Window");
    const parsedReset = w.resetsAt ? new Date(w.resetsAt) : null;
    const validReset = parsedReset && !Number.isNaN(parsedReset.getTime()) ? parsedReset : null;
    const expired = validReset !== null && validReset.getTime() <= now.getTime();
    return {
      label,
      group: "",
      window: label,
      used: expired ? 0 : Math.max(0, Math.min(100, w.usedPercent)),
      resetsAt: expired ? null : validReset,
      duration: w.durationSecs,
      note: null,
    };
  });
}
