// The order a pull request's files read best in (`PullRequestFileOrder` on the Mac): the source files first, each one
// followed by its tests; then tests without a source file in the change; then documentation; then generated files
// (lockfiles, snapshots, build output, vendored and minified code), which nobody reads line by line. No interface code,
// so tests use it on its own.

export type FileKind = "source" | "test" | "docs" | "generated";

const LOCKFILES = new Set([
  "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "bun.lockb", "bun.lock", "cargo.lock", "gemfile.lock",
  "podfile.lock", "composer.lock", "poetry.lock", "uv.lock", "go.sum", "package.resolved", "pipfile.lock", "flake.lock",
]);
const GENERATED_FOLDERS = ["dist/", "build/", "vendor/", "node_modules/", "__snapshots__/", ".next/", "generated/", "gen/"];

function baseName(path: string): string {
  const parts = path.split(/[\\/]/);
  return parts[parts.length - 1] ?? path;
}

function stemOf(name: string): string {
  const dot = name.lastIndexOf(".");
  return dot > 0 ? name.slice(0, dot) : name;
}

export function isTest(path: string): boolean {
  const lower = path.toLowerCase().replace(/\\/g, "/");
  const folders = "/" + lower;
  const stem = stemOf(baseName(lower));
  return folders.includes("/tests/") || folders.includes("/test/") || folders.includes("/__tests__/") || folders.includes("/spec/")
    || stem.endsWith("tests") || stem.endsWith("test") || stem.endsWith("_spec") || stem.endsWith(".spec")
    || stem.startsWith("test_") || stem.endsWith(".test");
}

export function fileKind(path: string): FileKind {
  const lower = path.toLowerCase().replace(/\\/g, "/");
  const name = baseName(lower);
  const folders = "/" + lower;
  if (LOCKFILES.has(name) || name.includes(".min.") || name.endsWith(".snap") || name.endsWith(".pb.go")
    || name.endsWith(".generated.swift") || name.endsWith(".g.dart")
    || GENERATED_FOLDERS.some((f) => folders.includes("/" + f))) {
    return "generated";
  }
  if (isTest(lower)) return "test";
  if (name.endsWith(".md") || name.endsWith(".mdx") || name.endsWith(".rst") || name.endsWith(".txt") || folders.includes("/docs/")) {
    return "docs";
  }
  return "source";
}

/** The name a test is about: `AppModelTests.swift` → `appmodel`, `parser.test.ts` → `parser`, `test_util.py` → `util`. */
export function testSubject(path: string): string {
  let stem = stemOf(baseName(path.toLowerCase()));
  for (const suffix of [".test", ".spec", "_spec", "_test", "tests", "test"]) {
    if (stem.endsWith(suffix) && stem.length > suffix.length) {
      stem = stem.slice(0, -suffix.length);
      break;
    }
  }
  if (stem.startsWith("test_")) stem = stem.slice(5);
  return stem;
}

const byName = (a: string, b: string) => (a.toLowerCase() < b.toLowerCase() ? -1 : a.toLowerCase() > b.toLowerCase() ? 1 : 0);

/** The paths in reading order. */
export function orderedPaths(paths: string[]): string[] {
  const sources = paths.filter((p) => fileKind(p) === "source").sort(byName);
  let tests = paths.filter((p) => fileKind(p) === "test").sort(byName);
  const result: string[] = [];
  for (const source of sources) {
    result.push(source);
    const name = testSubject(source);
    const matching = tests.filter((t) => testSubject(t) === name);
    result.push(...matching);
    tests = tests.filter((t) => !matching.includes(t));
  }
  result.push(...tests);
  result.push(...paths.filter((p) => fileKind(p) === "docs").sort(byName));
  result.push(...paths.filter((p) => fileKind(p) === "generated").sort(byName));
  return result;
}

/** Any list of files with a `path`, in reading order. */
export function orderedFiles<T extends { path: string }>(files: T[]): T[] {
  const byPath = new Map(files.map((f) => [f.path, f] as const));
  return orderedPaths(files.map((f) => f.path)).map((p) => byPath.get(p)!).filter(Boolean);
}
