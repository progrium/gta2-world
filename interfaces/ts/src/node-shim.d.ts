// Minimal declarations so the tests compile without @types/node.
declare module "node:fs" {
  export function readFileSync(path: string | URL, enc: "utf8"): string;
}
