# Codegen — Swift + C# types from `shared/contracts/`

Generates one Swift file and one C# file per schema in [`../contracts/`](../contracts/), via [quicktype](https://quicktype.io/). This exists so Swift and C# request/response types are never hand-copied from reading each other's source — see [docs/windows/WINDOWS_ARCHITECTURE.md §5](../../docs/windows/WINDOWS_ARCHITECTURE.md).

## Usage

```bash
cd shared/codegen
npm install        # once — installs quicktype (pinned version, see package.json)
npm run generate    # writes into generated/swift/ and generated/csharp/
npm run check       # CI mode: regenerates into a temp dir and diffs against
                     # generated/ — nonzero exit if they differ (catches
                     # "edited a contract, forgot to regenerate")
```

`generated/` is committed to the repo (not gitignored) so a reviewer can see the actual generated code in a PR diff, same as the contracts that produced it. Regenerate and commit together whenever a contract changes.

## How it works

`generate.mjs` walks every `*.schema.json` under `shared/contracts/`, and for each one runs quicktype once per target language, combining every named type the file declares (its root type, if it has one, plus everything under `$defs`) into a single output file. It invokes quicktype by resolving its installed JS entry point and running it directly via `node` — **not** through the `npx`/`quicktype` shell shim, which on Windows is a `.cmd` batch file that Node can only launch through a shell (`shell: true`), which in turn means the caller has to hand-escape arguments (Node prints a deprecation/security warning about exactly this). Resolving and invoking the real `.js` entry point sidesteps that entirely and behaves identically on macOS, Linux, and Windows.

## Known quicktype quirks this script works around

These aren't bugs in the contracts — they're specific, verified behaviors of quicktype's JSON-Schema-input mode that the generator has to route around:

1. **A bare `type: object` schema with no `properties` crashes quicktype**, even when you only ask it to generate a different named `$def` from the same file (observed directly: `assemblyai-proxy.schema.json` and `composio-proxy.schema.json` are intentionally shapeless passthrough proxies with no fixed request/response body — their root schemas declare no `type` key at all for exactly this reason. If a new contract needs a genuinely-any-shape root, don't give it a `type: object` — omit `type` entirely and rely on `$defs` only).

2. **A single `--src` fragment gets its type named from the output filename, not the schema's `title`.** The generator explicitly passes `--top-level <title>` whenever a schema resolves to exactly one named type, to force the name to match the contract instead.

3. **A root type that internally `$ref`s one of the file's own `$defs`, when that `$def` is ALSO passed as a separate `--src` fragment in the same invocation, gets duplicated** — quicktype resolves the root's internal `$ref` into its own freshly-and-differently-named nested type instead of reusing the separately-named one (observed directly on `auth/session-response.schema.json`: asking for both the root and `$defs/SupabaseAuthUser` produced *two* structurally-identical structs, `SupabaseAuthResponse.user: UserClass` and a separate, unused `SupabaseAuthUser`). The fix: when a schema has both a root type and `$defs`, generate the root alone and let quicktype resolve its own internal refs, which it does correctly (with the right names) as long as you don't also ask for the referenced `$def` independently in the same run. See the comment in `namedTypesIn()` in `generate.mjs` — this assumes every `$def` in such a file is reachable from the root, which is true for the one file this applies to today (`session-response.schema.json`); a future contract shaped the same way needs the same check re-verified.

4. **Every property whose JSON Schema type is a generic name (`model`, `status`, `plan`, `voice`, `category`, `error`, ...) needs an explicit, contract-specific `"title"`** on that property's own schema object, or quicktype names the synthesized enum/const type after the bare property name — which collides the instant two different contracts both have, say, a `model` field. This mattered for Swift (no per-file namespacing there at all) before quirk 5's fix gave C# its own per-file namespaces. Caught by generating everything and diffing struct/enum names across every output file for duplicates (see the verification step below) — it will not surface from looking at any single contract file in isolation, only from generating the whole set at once.

5. **C#-only: quicktype's per-file `Serialize`/`Converter` helper classes are NOT declared `partial`, so two generated `.cs` files in the same project collide the instant both are referenced** — even after every named *model* type has a unique name (quirk 4's fix), every file still independently declares its own `public static class Serialize { ... }` and `internal static class Converter { ... }` with the *same* simple names, in the *same* default `QuickType` namespace. The actual failure looks like `error CS0101: the namespace 'QuickType' already contains a definition for 'Serialize'`, and it surfaces the moment a real consuming project (`windows/Mira.Windows.Core`) links more than one generated file — never from generating in isolation. The fix: `generate.mjs` passes `--namespace Mira.Contracts.<ContractName>` for the C# target only, so every file gets its own namespace and the repeated `Serialize`/`Converter` names stop colliding (same simple name is fine in different namespaces). Swift needed no equivalent fix — its per-file helper functions (`newJSONDecoder()`, etc.) are free functions, not types, and were verified not to collide across files.

## Verifying a change didn't reintroduce a collision

Because every generated file shares one Swift/C# namespace, the one class of bug that doesn't show up file-by-file is a **type name that's fine on its own but collides with another contract's generated output**. After adding or editing a contract, regenerate everything and check for duplicates across the whole set, not just the one file you touched:

```bash
cd generated/swift
grep -rh "^struct\|^enum" *.swift | sed -E 's/^(struct|enum) ([A-Za-z0-9_]+).*/\2/' | sort | uniq -c | sort -rn | awk '$1>1'
# any output here is a real cross-file collision — give the colliding property an
# explicit, contract-specific "title" in its schema (see quirk 4 above) and regenerate
```

## Integrating generated output into the actual apps

- **macOS (Swift)**: still not done, and deliberately out of scope. Swapping `Mira/Services/*.swift`'s hand-written request/response structs for the generated equivalents in `generated/swift/` is its own reviewed change, call site by call site — not something to do as a side effect of standing up the codegen pipeline. `Mira/` is not touched by any commit in this effort.
- **Windows (C#)**: done, as of Phase 2 (`windows/Mira.Windows.Core`). Files are **linked, not copied** — `Mira.Windows.Core.csproj` references `../../shared/codegen/generated/csharp/*.cs` directly via `<Compile Include="..." Link="..." />`, so regenerating after a contract change picks up automatically with no manual copy step. Only the files Phase 2's scope (auth/entitlements/device-lock) actually needs are linked so far (`SessionResponse.cs`, `SignInRequest.cs`, `SignUpRequest.cs`, `ProfileRow.cs`, `ErrorResponse.cs`, `CheckDevice.cs`, `RegisterDevice.cs`) — link more into that `<ItemGroup>` as later phases need them (voice, model routing, etc.).
