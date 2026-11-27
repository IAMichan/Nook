// Pure helpers for Settings › Companion › Away from home › Your own relay (`CloudflareRelayDeployer`,
// `CloudflareRelaySetup`, `OwnRelaySheet` on the Mac, CO-08): URL validation, step/error labels, and
// SetupCheckState derivation.
import type { SetupCheckState } from "../components/ui/setup-check";
import type { DeployError, DeployStep, RelaySetupState, RelayStatus } from "./companion";
import { tr } from "./i18n.svelte";

/** Accepts an `https://` relay address and strips trailing slashes, matching `CompanionRelay.normalize`. */
export function normalizeRelayUrl(raw: string): string | null {
  const trimmed = raw.trim().replace(/\/+$/, "");
  if (!trimmed) return null;
  try {
    const url = new URL(trimmed);
    if (url.protocol !== "https:" || !url.hostname) return null;
    return trimmed;
  } catch {
    return null;
  }
}

export function deployStepText(step: DeployStep): string {
  switch (step) {
    case "account":
      return tr("Je Cloudflare-account zoeken…", "Finding your Cloudflare account…");
    case "uploading":
      return tr("De relay op je account zetten…", "Putting the relay on your account…");
    case "starting":
      return tr("De relay starten…", "Starting the relay…");
  }
}

export function deployErrorText(error: DeployError): string {
  switch (error.kind) {
    case "badToken":
      return tr(
        "Cloudflare accepteerde deze sleutel niet. Kopieer hem opnieuw, of maak een nieuwe via Cloudflare openen.",
        "Cloudflare did not accept this token. Copy it again, or create a new one with Open Cloudflare.",
      );
    case "noAccount":
      return tr(
        "De sleutel ziet geen Cloudflare-account. Maak hem met de rechten die Cloudflare openen invult.",
        "The token cannot see a Cloudflare account. Create it with the permissions Open Cloudflare fills in.",
      );
    case "severalAccounts":
      return tr(
        "Deze sleutel ziet meerdere Cloudflare-accounts. Maak hem voor één account (Account Resources › Include › dat account) en plak hem opnieuw.",
        "This token can see several Cloudflare accounts. Create it for one account (Account Resources › Include › that account) and paste it again.",
      );
    case "noSubdomain":
      return tr(
        "Cloudflare gaf je account geen workers.dev-adres.",
        "Cloudflare did not give your account a workers.dev address.",
      );
    case "noAnswer":
      return tr(
        "De relay staat klaar maar antwoordt nog niet. Probeer het over een minuut opnieuw.",
        "The relay is set up but does not answer yet. Try again in a minute.",
      );
    case "cloudflare":
    case "network":
      return error.detail;
  }
}

/** Setup first, then whether this computer connected to the relay it created (mirrors macOS `OwnRelaySheet.checkState`). */
export function ownRelayCheckState(
  started: boolean,
  setup: RelaySetupState,
  address: string,
  status: RelayStatus,
): SetupCheckState {
  if (!started) return { kind: "idle" };
  if (setup.state === "working") return { kind: "checking" };
  if (setup.state === "failed") {
    return {
      kind: "failed",
      message: tr("Instellen is niet gelukt: {message}", "Setting up did not work: {message}", {
        message: deployErrorText(setup.error),
      }),
    };
  }
  if (!address.trim()) return { kind: "idle" };
  switch (status.state) {
    case "connected":
      return {
        kind: "passed",
        message: tr(
          "Verbonden met de relay. Je telefoon vindt deze computer nu ook onderweg.",
          "Connected to the relay. Your phone now finds this computer on the go too.",
        ),
      };
    case "connecting":
    case "off":
      return { kind: "checking" };
    case "invalid":
      return {
        kind: "failed",
        message: tr("Vul het https-adres van je relay in.", "Fill in your relay's https address."),
      };
    case "failed":
      return {
        kind: "failed",
        message: tr("De relay is niet bereikbaar: {message}", "The relay can't be reached: {message}", {
          message: status.message,
        }),
      };
  }
}
