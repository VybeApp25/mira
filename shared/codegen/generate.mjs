#!/usr/bin/env node
// Generates Swift and C# types from the JSON Schema contracts in shared/contracts/,
// via quicktype. One schema file in shared/contracts/** produces one generated file
// per target language, containing every named type declared in that schema file
// (its root type, if it has one, plus every entry under $defs).
//
// Usage:
//   npm install                        # once, from this directory (installs quicktype)
//   node generate.mjs                  # generate everything
//   node generate.mjs --check          # generate into a temp dir and diff against
//                                        committed output; nonzero exit if they differ
//                                        (for CI)
//
// quicktype is invoked by resolving its installed JS entry point and running it
// directly via `node`, NOT through the `npx`/`quicktype` shell shim — on Windows
// that shim is a .cmd batch file, which Node can only launch through a shell
// (shell:true), and shell:true means argument escaping becomes the caller's
// problem. Running the resolved .js entry point directly via `node` sidesteps
// that entirely and works identically on every OS with no shell involved.

import { execFileSync } from "node:child_process";
import { readFileSync, mkdirSync, readdirSync, statSync, rmSync, mkdtempSync } from "node:fs";
import { join, basename, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { tmpdir } from "node:os";
import { createRequire } from "node:module";

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

const REPO_ROOT = join(__dirname, "..", "..");
const CONTRACTS_DIR = join(REPO_ROOT, "shared", "contracts");
const COMMON_ERROR_SCHEMA = join(CONTRACTS_DIR, "common", "error-response.schema.json");

function resolveQuicktypeEntry() {
  let pkgJsonPath;
  try {
    pkgJsonPath = require.resolve("quicktype/package.json");
  } catch {
    throw new Error(
      "quicktype is not installed. Run `npm install` in shared/codegen/ first."
    );
  }
  const pkg = JSON.parse(readFileSync(pkgJsonPath, "utf8"));
  const binRelPath = typeof pkg.bin === "string" ? pkg.bin : Object.values(pkg.bin)[0];
  return join(dirname(pkgJsonPath), binRelPath);
}

const QUICKTYPE_ENTRY = resolveQuicktypeEntry();

const TARGETS = [
  { lang: "swift", ext: "swift", outDir: join(__dirname, "generated", "swift") },
  { lang: "csharp", ext: "cs", outDir: join(__dirname, "generated", "csharp") },
];

function findSchemaFiles(dir) {
  const out = [];
  for (const entry of readdirSync(dir)) {
    const full = join(dir, entry);
    if (statSync(full).isDirectory()) {
      out.push(...findSchemaFiles(full));
    } else if (entry.endsWith(".schema.json")) {
      out.push(full);
    }
  }
  return out;
}

// Returns [{ name, pointer }] — every named type this schema file declares.
// `pointer` is the JSON-pointer fragment to pass to quicktype's --src
// (empty string means "the whole file is the type").
function namedTypesIn(schemaPath) {
  const schema = JSON.parse(readFileSync(schemaPath, "utf8"));
  const types = [];

  // Require actual properties/enum, not just `type: "object"` — a bare permissive
  // object (`type: object, additionalProperties: true`, no properties — used for
  // path-forwarding proxies with no fixed shape, e.g. assemblyai-proxy/composio-proxy)
  // has nothing for quicktype to generate a type from and crashes it if attempted.
  const rootIsType = schema.title && (schema.properties || schema.enum);

  if (rootIsType && schema.$defs) {
    // A root type whose own properties $ref one of this file's $defs (today, only
    // auth/session-response.schema.json: SupabaseAuthResponse.user -> SupabaseAuthUser).
    // Passing the root AND that $def as two separate --src fragments in the same
    // quicktype invocation does NOT dedupe them — quicktype resolves the root's
    // internal $ref into its own freshly-named nested type (observed: "UserClass",
    // duplicating the separately-named "SupabaseAuthUser") instead of reusing the
    // named type from the other fragment. Generating the root ALONE lets quicktype
    // resolve its own internal $refs naturally, correctly using each $def's own
    // `title` for naming, with no duplication — verified by hand for this file.
    // This assumes every $def in such a file is reachable from the root (true for
    // the one file this applies to today) — if a future contract adds a root type
    // with an $def NOT reachable from it, that def would be silently skipped; check
    // this comment before adding a new file with this shape.
    return [{ name: schema.title, pointer: "" }];
  }

  if (rootIsType) types.push({ name: schema.title, pointer: "" });

  if (schema.$defs) {
    for (const [key, def] of Object.entries(schema.$defs)) {
      types.push({ name: def.title || key, pointer: `#/$defs/${key}` });
    }
  }

  if (types.length === 0) {
    throw new Error(
      `${schemaPath}: no named type found (no root title+type, no $defs). ` +
      `Every contract file must declare at least one.`
    );
  }
  return types;
}

function outputFileName(schemaPath) {
  // shared/contracts/edge-functions/anthropic-proxy.schema.json -> AnthropicProxy
  const base = basename(schemaPath, ".schema.json");
  return base
    .split("-")
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join("");
}

function generateOne(schemaPath, target) {
  const types = namedTypesIn(schemaPath);
  const args = [
    QUICKTYPE_ENTRY,
    "--src-lang", "schema",
    "--lang", target.lang,
    "-S", COMMON_ERROR_SCHEMA,
  ];
  for (const t of types) {
    args.push("--src", t.pointer ? `${schemaPath}${t.pointer}` : schemaPath);
  }
  // With exactly one --src, quicktype names the top-level type from the OUTPUT
  // filename rather than the schema's own `title` (observed directly) — force it
  // explicitly so the name always matches the contract's declared title. With
  // multiple --src fragments this isn't needed: each fragment is already named
  // from its own schema's `title` correctly (also observed directly).
  if (types.length === 1) args.push("--top-level", types[0].name);

  const outName = `${outputFileName(schemaPath)}.${target.ext}`;
  const outPath = join(target.outDir, outName);
  args.push("-o", outPath);

  mkdirSync(target.outDir, { recursive: true });
  execFileSync(process.execPath, args, { stdio: "inherit" });
  return outPath;
}

function main() {
  const check = process.argv.includes("--check");
  const schemaFiles = findSchemaFiles(CONTRACTS_DIR).filter(
    (f) => f !== COMMON_ERROR_SCHEMA // generated implicitly wherever it's referenced; also emit it standalone below
  );

  const genRoot = check ? mkdtempSync(join(tmpdir(), "mira-codegen-")) : join(__dirname, "generated");

  for (const target of TARGETS) {
    const realTarget = check ? { ...target, outDir: join(genRoot, target.lang) } : target;
    // Standalone common/ErrorResponse type, in addition to every contract's own file.
    generateOne(COMMON_ERROR_SCHEMA, realTarget);
    for (const schemaPath of schemaFiles) {
      generateOne(schemaPath, realTarget);
    }
  }

  if (check) {
    const diff = execFileSync("diff", ["-rq", genRoot, join(__dirname, "generated")], {
      encoding: "utf8",
    }).trim();
    rmSync(genRoot, { recursive: true, force: true });
    if (diff) {
      console.error("Generated output is stale relative to shared/codegen/generated/:");
      console.error(diff);
      process.exit(1);
    }
    console.log("shared/codegen/generated/ is up to date.");
  } else {
    console.log(`Generated Swift + C# types into ${join(__dirname, "generated")}`);
  }
}

main();
