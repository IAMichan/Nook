// German, French, and Spanish for every `tr("…", "English")` in the interface, keyed by the English text. Each area
// keeps its own file next to this one (`agents.ts`, `settings.ts`, …) exporting `table`; they are merged here, so
// adding an area needs no change in this file. `i18n.test.ts` fails when an English text has no entry.
export type Entry = { de: string; fr: string; es: string };
export type Table = Record<string, Entry>;

const modules = import.meta.glob<{ table: Table }>("./*.ts", { eager: true });

export const catalog: Table = Object.assign(
  {},
  ...Object.entries(modules)
    .filter(([path]) => !path.endsWith("/catalog.ts") && !path.endsWith(".test.ts"))
    .map(([, m]) => m.table ?? {}),
);
