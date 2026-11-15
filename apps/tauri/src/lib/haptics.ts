// The iPhone's haptics on Android (`Haptics`): a light tap, success, and a warning, as short vibrations.
export function haptic(kind: "tap" | "success" | "warning" = "tap") {
  try {
    navigator.vibrate?.(kind === "tap" ? 8 : kind === "success" ? [10, 40, 14] : [18, 50, 18]);
  } catch {
    // A device without vibration says nothing.
  }
}
