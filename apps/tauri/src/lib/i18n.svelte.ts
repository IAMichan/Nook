// The interface language of the Tauri app: Dutch (the default) or English, from the `appLanguage` setting. Write each
// visible string as `tr("Nederlands", "English")`; it reads the setting, so a view redraws when the language flips.
import { nook } from "./state.svelte";

export const english = () => nook.settings?.appLanguage === "en";

export function tr(nl: string, en: string): string {
  return english() ? en : nl;
}
