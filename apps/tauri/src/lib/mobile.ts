// De telefoon: de terugknop van Android, veilige marges (notch, gebarenbalk), het toetsenbord en "Delen met Nook".
// De Android-kant (MainActivity.kt) geeft marges en gedeelde tekst door via `window.NookAndroid` en de events
// `nook-insets` en `nook-share`; zonder die brug (in de browser of op de computer) vallen we terug op CSS en visualViewport.

declare global {
  interface Window {
    NookAndroid?: {
      /** JSON: { top, bottom, left, right, keyboard } in CSS-pixels. */
      insets(): string;
      /** Tekst die een andere app met Nook deelde, één keer. */
      takeShared(): string | null;
    };
  }
}

export interface Insets {
  top: number;
  bottom: number;
  left: number;
  right: number;
  keyboard: number;
}

type BackHandler = () => boolean;
const handlers: BackHandler[] = [];

/** Een scherm dat de terugknop wil afvangen (bv. een open gesprek). Geeft `true` als het hem gebruikte. */
export function onBack(handler: BackHandler): () => void {
  handlers.push(handler);
  return () => {
    const i = handlers.lastIndexOf(handler);
    if (i >= 0) handlers.splice(i, 1);
  };
}

/** De bovenste handler die hem wil hebben; `false` als niemand hem nam. */
export function handleBack(): boolean {
  for (let i = handlers.length - 1; i >= 0; i--) if (handlers[i]()) return true;
  return false;
}

export function parseInsets(json: string | null | undefined): Insets | null {
  if (!json) return null;
  try {
    const v = JSON.parse(json);
    const n = (x: unknown) => (typeof x === "number" && isFinite(x) && x >= 0 ? Math.round(x) : 0);
    return { top: n(v.top), bottom: n(v.bottom), left: n(v.left), right: n(v.right), keyboard: n(v.keyboard) };
  } catch {
    return null;
  }
}

function applyInsets(insets: Insets) {
  const root = document.documentElement.style;
  root.setProperty("--safe-top", `${insets.top}px`);
  root.setProperty("--safe-bottom", `${insets.bottom}px`);
  root.setProperty("--safe-left", `${insets.left}px`);
  root.setProperty("--safe-right", `${insets.right}px`);
  root.setProperty("--keyboard", `${insets.keyboard}px`);
  document.documentElement.classList.toggle("keyboard-open", insets.keyboard > 0);
}

/** Start de telefoonlijm. `onShared` krijgt tekst die met Nook gedeeld werd. Kan de terugknop nergens heen, dan sluit de app. */
export async function setupMobile(onShared: (text: string) => void) {
  const bridge = window.NookAndroid;
  if (bridge) {
    const initial = parseInsets(bridge.insets());
    if (initial) applyInsets(initial);
    window.addEventListener("nook-insets", (e) => {
      const insets = parseInsets((e as CustomEvent<string>).detail);
      if (insets) applyInsets(insets);
    });
    const shared = bridge.takeShared();
    if (shared) onShared(shared);
    window.addEventListener("nook-share", () => {
      const text = window.NookAndroid?.takeShared();
      if (text) onShared(text);
    });
  } else if (window.visualViewport) {
    // Zonder brug: het toetsenbord is wat de zichtbare viewport kleiner maakt dan het venster.
    const vv = window.visualViewport;
    const update = () => {
      const keyboard = Math.max(0, window.innerHeight - vv.height - vv.offsetTop);
      document.documentElement.style.setProperty("--keyboard", `${Math.round(keyboard)}px`);
      document.documentElement.classList.toggle("keyboard-open", keyboard > 80);
    };
    vv.addEventListener("resize", update);
  }
  // Het veld waarin je typt blijft zichtbaar boven het toetsenbord.
  document.addEventListener("focusin", (e) => {
    const el = e.target as HTMLElement | null;
    if (el && /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName)) setTimeout(() => el.scrollIntoView({ block: "nearest" }), 300);
  });
  try {
    const { onBackButtonPress, exit } = await import("@tauri-apps/api/app");
    await onBackButtonPress(() => {
      if (!handleBack()) void exit(0);
    });
  } catch {
    // Niet op Android: geen terugknop.
  }
}
