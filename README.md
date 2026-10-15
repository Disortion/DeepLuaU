# DeepLuaU

A source-to-source **Luau obfuscator** built on a real parser and AST — not regex
hacks — designed around one hard constraint:

> **Maximize how hard the output is to reverse-engineer *without* paying a runtime
> (FPS) cost.**

Those two goals pull against each other, so DeepLuaU is honest about the trade-off
instead of pretending it away (see [Honest limitations](#honest-limitations)).

---

## The core idea: obfuscate where it's free

The technique that is genuinely hard to undo — compiling your code to a custom
bytecode and shipping an interpreter (a "VM") — is also the one that destroys
performance (commonly **10–100× slower**). That's the wrong tool for anything that
runs in a render/update loop.

DeepLuaU instead pushes obfuscation into forms that **cost nothing at runtime**:

| Technique | How it stays free |
|---|---|
| **Local renaming** | Purely lexical. The compiled bytecode is identical apart from debug names. |
| **Number obfuscation** | Integer literals become arithmetic like `((0xD-9)+(0xB-5))`. The Luau compiler **constant-folds** this back to the literal — the emitted bytecode is byte-for-byte identical. |
| **String encryption** | Every string is decrypted **once at load** into a local table; each use becomes a single table index (`pool[i]`). No per-call / per-frame decryption. |
| **Minification** | Smaller source → *faster* to load. |

Only **control-flow flattening** (the `max` profile) adds real runtime cost, so it's
opt-in and documented as such.

### Proof it's free

`((0xD-9)+(0xB-5))` and the literal `10` compile to the exact same instruction:

```
$ luau-compile text -O2 fold.luau
LOADN R1 10        -- ((0xD-9)+(0xB-5))
LOADN R2 30        -- (((0x8*8)+3)-(0x1A+0xB))
LOADN R3 282       -- the real constant, never visible in source
```

Measured on a CPU-heavy loop (string building + math, 20k iterations × 200 runs):

```
orig     : 0.6025s
balanced : 0.5928s   (98.4% of orig — within noise)
max      : 0.6167s   (102.3% of orig)
```

---

## Profiles

Pick based on where the code runs.

| Profile | Passes | Runtime cost | Use for |
|---|---|---|---|
| `none` | minify | none (loads faster) | baseline / debugging |
| `light` | + rename locals | **none** | anything, incl. hot loops |
| `balanced` *(default)* | + string encryption (incl. interpolation text) + number obfuscation | **near-zero** | game clients, modules, render-loop code |
| `max` | + control-flow flattening + member-name hiding | some (dispatch loop; member access loses inline caching) | cold / non-hot modules where resistance matters most |

> Rule of thumb: **`balanced` for code on the hot path, `max` for the rest.**

### What stays readable

Source-to-source obfuscation (no VM) cannot hide everything:

- **Global and standard-library names** (`print`, `game`, `Vector3`, `math`, `pairs`)
  remain in every profile — hiding them needs `getfenv`/`_ENV` tricks that
  deoptimize the whole script, defeating the performance goal.
- **Member names** (`.x`, `:method`, table keys) are visible on `balanced` because
  turning `a.b` into `a[pool[i]]` loses Luau's field inline-cache (a real per-access
  cost). `max` hides them by accepting that cost. (Method calls on a non-variable
  receiver, e.g. `f():m()`, keep `m` visible, to avoid evaluating the receiver twice.)
- **Original local names, comments and type annotations** are deleted outright on
  every profile — unrecoverable, but not the same as hidden.

---

## Usage

### Library (Roblox, Lune, any Luau runtime)

Grab the single bundled file [`dist/deepluau.luau`](dist/deepluau.luau) (regenerate
with `python3 tools/bundle.py`) and require it:

```lua
local Obfuscator = require(path.to.deepluau)

local protected = Obfuscator.obfuscate(sourceString, {
    profile = "balanced",  -- "none" | "light" | "balanced" | "max"
    seed = 12345,          -- optional; same seed => identical output (reproducible)
    header = true,         -- optional; false drops the banner comment
})
```

### Web (runs in the browser, no backend)

`web/deepluau.js` is a JavaScript port of the obfuscator that runs fully
client-side — nothing is uploaded. `web/index.html` is a self-contained page that
embeds it (rebuild with `python3 web/build_site.py`). The port is validated by
running its output through the real `luau` interpreter (`node tests/validate_js.mjs`).

```js
const DeepLuaU = require("./web/deepluau.js");
const out = DeepLuaU.obfuscate(source, { profile: "balanced", seed: 1337 });
```

### CLI (via [Lune](https://lune-rs.github.io))

```sh
lune run cli.luau -- game/client.luau -o out/client.luau -p balanced -s 123
lune run cli.luau -- module.luau -p max > module.obf.luau
lune run cli.luau -- --help
```

---

## What it handles

Full Lua 5.1 grammar plus Luau extensions, parsed into an AST and regenerated:

- compound assignment (`+=`, `..=`, `//=`, …), `continue`, if-expressions
- type annotations, generics, `type` / `export type` (**parsed and stripped** — they
  carry no runtime meaning and removing them deletes information)
- type assertions (`::`), attributes (`@native`), all numeric forms (hex, binary,
  underscores, hex-floats, exponents), long/short/interpolated strings
- **semantics preserved**: multi-return truncation via parentheses, `repeat`/`until`
  locals visible in the condition, loop-variable capture, upvalues, metatables,
  coroutines, varargs, `pcall`/`error`. Roblox API globals and member names
  (`game`, `workspace`, `:GetService`, `Vector3`, …) are never renamed.

The transformation is **verified behaviourally**: `tests/run_all.sh` obfuscates every
example at every profile and asserts the program's output is unchanged.

---

## Project layout

```
src/
  Lexer.lua        tokenizer (full Luau token set)
  Parser.lua       recursive-descent parser -> AST
  Scope.lua        scope resolver + local renamer
  Generator.lua    AST -> minified Luau
  Rng.lua          deterministic (seedable) RNG
  passes/
    Numbers.lua    fold-safe arithmetic literal obfuscation
    Strings.lua    load-once encrypted string pool
    Flatten.lua    control-flow flattening (max)
  Obfuscator.lua   pipeline / profiles
cli.luau           Lune command-line interface
tools/bundle.py    bundles src/ -> dist/deepluau.luau
tests/             harness + behavioural test suite + examples
```

## Running the tests

```sh
bash tests/run_all.sh          # behavioural equivalence across all profiles
python3 tests/harness.py examples/stress.luau max
```

(The suite uses the `luau` CLI; `python3` drives the harness.)

---

## Honest limitations

- **No obfuscator is unbreakable.** Anything that runs on a machine you don't control
  can, with enough effort, be understood. DeepLuaU raises the cost of casual and
  moderate reverse-engineering; it is not a guarantee against a determined expert.
- **This is deliberately not a VM/virtualizer.** A bytecode VM resists static analysis
  harder, but at a large, constant runtime cost — incompatible with the "no FPS loss"
  goal. If you need maximum resistance for a *cold* module and can accept the cost,
  that's a different tool.
- **`balanced` targets zero runtime cost; `max` does not.** Flattening adds a dispatch
  loop per function. Don't flatten per-frame code.
- Obfuscation protects *source readability*, not secrets. Never ship private keys,
  passwords, or server-trusted logic in client code — obfuscated or not. Keep
  authority on the server.

## Scope / intended use

For protecting the intellectual property of **your own** Luau/Roblox code
(game logic, libraries, client scripts) from casual copying and tampering. Don't use
it to smuggle malicious code past review or detection.
