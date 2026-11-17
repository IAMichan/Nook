// A path pasted into the composer or dropped on the window becomes an attachment, as on the Mac: a file, a zip archive
// or a folder. Anything else that is pasted stays text.

/// Whether pasted text is one path to a file or folder: absolute on macOS or Linux, `~/…`, a Windows drive or share
/// path, or a `file://` address. One line only: a pasted paragraph that starts with a slash is text.
export function looksLikePath(text: string): boolean {
  const t = text.trim();
  if (!t || t.length > 1024 || /[\r\n]/.test(t)) return false;
  return /^(\/[^/\s]|~\/|[A-Za-z]:[\\/]|\\\\[^\\]|file:\/\/)/.test(t);
}
