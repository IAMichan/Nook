// Edits to a text file in the file viewer (`FileEditor` on the Mac), kept apart from the view: switching tabs or opening
// another file keeps what you typed, until you save it or stop editing.
import { invoke } from "@tauri-apps/api/core";

export interface FileEditText {
  text: string;
  encoding: "utf8" | "utf16-le" | "utf16-be" | "latin1";
  byteOrderMark: boolean;
  windowsBreaks: boolean;
  modified: number | null;
}
export interface FileView { kind: "text" | "preview" | "folder" | "missing"; size: number; file: FileEditText | null }
export type SaveResult = { result: "saved"; modified: number | null } | { result: "changedOnDisk" } | { result: "failed"; reason: string };

export const readFile = (path: string) => invoke<FileView>("workspace_file_read", { path });

export class FileEditor {
  /** The file as it was opened to edit (and last saved); null while it is only read. */
  file = $state<FileEditText | null>(null);
  draft = $state("");
  constructor(readonly path: string) {}

  get editing() { return this.file !== null; }
  get unsaved() { return this.file !== null && this.file.text !== this.draft; }

  /** Starts editing with the file's text; false for a file that is not text. */
  async begin(): Promise<boolean> {
    const view = await readFile(this.path).catch(() => null);
    if (!view || view.kind !== "text" || !view.file) return false;
    this.file = view.file;
    this.draft = view.file.text;
    return true;
  }

  /** Writes the draft; "changedOnDisk" when someone else wrote the file since it was opened, unless `overwrite`. */
  async save(overwrite = false): Promise<SaveResult> {
    if (!this.file) return { result: "failed", reason: "" };
    const result = await invoke<SaveResult>("workspace_file_save", { path: this.path, text: this.draft, file: this.file, overwrite });
    if (result.result === "saved") this.file = { ...this.file, text: this.draft, modified: result.modified };
    return result;
  }

  /** Back to reading; the caller has asked about unsaved changes. */
  end() {
    this.file = null;
    this.draft = "";
  }
}

const open = new Map<string, FileEditor>();
/** The one editor of a file, so the panel and a window share what you typed. */
export function editorFor(path: string): FileEditor {
  let e = open.get(path);
  if (!e) open.set(path, (e = new FileEditor(path)));
  return e;
}
