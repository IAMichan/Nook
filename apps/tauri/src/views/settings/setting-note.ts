// Pure tone metadata for `SettingNote`, mirroring Mac's `SettingNote.Tone` (`SettingsBlocks.swift`):
// info stays plain secondary text; success, warning, and error each carry both color and a clear symbol so
// warnings and errors stand out by more than color alone.

export type SettingNoteTone = "info" | "success" | "warning" | "error";
export type SettingNoteIcon = "circle-check" | "triangle-alert" | "octagon-alert";

export interface SettingNoteMeta {
  icon: SettingNoteIcon | null;
  toneClass: SettingNoteTone;
}

export function settingNoteMeta(tone: SettingNoteTone = "info"): SettingNoteMeta {
  switch (tone) {
    case "info":
      return { icon: null, toneClass: "info" };
    case "success":
      return { icon: "circle-check", toneClass: "success" };
    case "warning":
      return { icon: "triangle-alert", toneClass: "warning" };
    case "error":
      return { icon: "octagon-alert", toneClass: "error" };
  }
}
