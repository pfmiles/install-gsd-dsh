# install-gsd-dsh

> Put [GSD Core](https://github.com/open-gsd/gsd-core) — a spec-driven, context-engineering
> workflow system for AI coding agents — onto [DeepSeek Harness](https://github.com/deepseek-ai/dsh)
> (DSH) with one script.

`install-gsd-dsh.sh` is a **single-file installer**. It stages the official
[`@opengsd/gsd-core`](https://www.npmjs.com/package/@opengsd/gsd-core) npm package and redeploys
it into a DSH data home (`~/.dsh` by default), using DSH's native extension surfaces: the
filesystem **skill** provider and the Claude-Code **hooks bridge**.

- **One command everything:** ~72 `gsd-*` skills (`/gsd-health`, `/gsd-new-project`,
  `/gsd-plan-phase`, `/gsd-execute-phase`, …), the GSD engine payload, hook scripts, the
  hooks-bridge profile patch and the global `gsd_run` CLI — all on by default.
- **Version-pinned and idempotent:** `GSD_VERSION` is required for online installs (a `v`
  prefix is tolerated, and the fetched version is cross-checked against the requested one).
  Upgrade and rollback are the same command with a different version number.
- **Complete by default, no partial upgrades:** every run installs the hooks patch and the global
  CLI unless you opt out with `--no-ghooks` / `--no-npm-bin` (fresh installs only). Upgrades over
  an existing deployment always refresh the full surface.
- **Safe:** `--uninstall` removes only what the script itself manages and never touches your
  other `~/.dsh` content; install refuses to overwrite directories it does not manage.
- **Supported:** macOS, Linux, WSL (bash). Native Windows is not supported.

> **Unofficial community port.** GSD Core officially supports Claude Code, Codex, OpenCode and
> other runtimes — not DSH. This script reuses the official installer's own `--claude`
> passthrough into a throwaway staging directory, then deploys only the surfaces DSH understands,
> adding a small model-facing adaptation note to every skill. Compatibility-tested with
> **DSH 0.2.2-rc.1** (web profile, standard preset; the mechanism surface was designed against
> 0.2.0-rc.2 — earlier DSH builds are not guaranteed) and **GSD Core 1.16.0 through v1.20.1**
> (latest compatibility-tested release: **v1.20.1**).

---

## Quick start

```bash
# 1) Download (single file, no other dependencies)
curl -fsSL https://raw.githubusercontent.com/pfmiles/install-gsd-dsh/main/install-gsd-dsh.sh \
  -o install-gsd-dsh.sh
chmod +x install-gsd-dsh.sh

# 2) Install: skills + engine + hook files + hooks-bridge patch + global CLI
#    (the hooks patch and global CLI are on by default). GSD_VERSION pins the
#    release and is required while online; "v1.20.1" also works.
GSD_VERSION=1.20.1 bash install-gsd-dsh.sh

# 3) Restart DSH (dsh web). Skill discovery hot-reloads in running sessions,
#    but the hooks bridge is mounted at process startup and needs a restart.
```

Then, in any DSH session:

- type `/gsd-health` (or let the model call the `gsd-health` skill) to confirm the skills are live;
- new project → `/gsd-new-project`; existing repo → `/gsd-onboard`;
- in a POSIX terminal: `gsd_run runtime-identity --raw` should print
  `{"packageName":"@opengsd/gsd-core", ...}` with the installed version (the global CLI is
  installed by default; it is omitted only with `--no-npm-bin`).

## Requirements

- **OS:** macOS / Linux / WSL with a bash environment. Native Windows is unsupported — use WSL.
- `bash`, `node`, `npm` on `PATH`.
- **Node ≥ 24** for GSD Core 1.16+ engines (for older Node, pick an older GSD tag — see
  *Rollback* below, or override with `GSD_ALLOW_OLD_NODE` at your own risk).
- DSH with its default `~/.dsh` data root — or pass the same home DSH actually uses via `DSH_HOME`.
- DSH's filesystem skill discovery (`dsh-skill-filesystem`) and skill tool: both are present in
  the standard preset of the compatibility-tested DSH 0.2.2-rc.1 web profile.

## What it installs

| Location (relative to `$DSH_HOME`, default `~/.dsh`) | Content | Purpose |
|---|---|---|
| `skills/gsd-*/SKILL.md` (72) | GSD skill bundle, each with an injected DSH adaptation note | loadable via the `skill` tool; directly invocable as `/gsd-*` |
| `gsd-core/` | GSD workflows / references / templates / agents / CLI engine | workflow contents and the `gsd_run` engine |
| `hooks/` + `hooks/dsh-gsd-suite/run.cjs` | GSD hook scripts + a DSH tool-name adapter | guards wired through the hooks bridge (see below) |
| `scripts/` | package-level scripts | required by the engine at runtime |
| `gsd-hooks.dsh.json` | hooks-bridge config with DSH tool-name matchers | read by the bridge |
| `profiles/*/cordis.patch.yml` (default; skip with `--no-ghooks`) | appended bridge-mount section | makes the hooks effective in DSH sessions |

The script **never** touches: `~/.claude`, your project files, the rest of your DSH configuration
(except the profiles patch above), or any skill not prefixed `gsd-*`. (The one deliberate
exception: an explicit `--fix-repo` run refreshes the build outputs inside the `gsd-core` source
checkout you run it from.)

## Options and environment variables

### Options

| Option | Effect |
|---|---|
| *(none)* | **Complete install (default):** skills + engine + hook scripts, hooks-bridge profile patch and global `gsd_run` CLI |
| `--with-ghooks` | Explicitly enable the hooks-bridge patch (already the default; kept for compatibility) |
| `--npm-bin` | Explicitly enable the npm global CLI (already the default; kept for compatibility) |
| `--no-ghooks` | Lean fresh install: skip the hooks-bridge profile patch |
| `--no-npm-bin` | Lean fresh install: skip the npm global CLI |
| `--fix-repo` | Only meaningful inside a `gsd-core` source checkout: refresh the build outputs in the repo |
| `--uninstall` | Remove everything this script deployed (only its own managed files, see *Uninstall*) |
| `-h` / `--help` | Usage |

Every run is complete by default. The `--no-*` flags opt into a lean **fresh** install (e.g. CI
staging). When an existing deployment is detected the run is an **upgrade**, and the lean opt-outs
are ignored: the hooks patch, bridge config and the `gsd_run` CLI always move with the engine.

### Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `GSD_VERSION` | *(required online)* | GSD Core version tag to install. **Required for online installs** — the script refuses to guess, so a bare re-run can never silently roll a machine back to a default. A leading `v` is tolerated; the fetched version is cross-checked against the requested one. Offline installs (`GSD_PACKAGE_DIR`) may omit it and inherit the package's version |
| `DSH_HOME` | `~/.dsh` | DSH data root. **Must match the home your DSH actually uses** (DSH resolution: explicit config → `$DSH_HOME` → `~/.dsh`) |
| `GSD_PACKAGE_DIR` | *(empty)* | Offline mode: an unpacked npm-layout directory (`package.json` + `bin/install.js`, e.g. an unpacked `npm pack` artifact). Fully offline once set. **A bare git clone is not accepted** (it needs `npm install && npm run build:lib` first) |
| `GSD_PROFILE` | *(empty)* | Skill profile passed to the official installer: `core` / `standard` / `full`. Fewer skills = fewer tokens injected per session; use `core` in token-sensitive setups |
| `GSD_FORCE_HOOKS_PATCH` | `0` | Write the hooks-bridge patch even when the `dsh-hooks-claude-code` plugin package is not detected |
| `GSD_ALLOW_OLD_NODE` | `0` | Proceed despite Node < 24 (the engine may not run; only for when you know what you are doing) |
| `GSD_NO_BRIDGE_SYNC` | `0` | Skip aligning the hooks bridge plugin version with your DSH version |
| `GSD_HOOKS_SANDBOX_PATCH` | `0` | `1` = on a host where the probe finds no usable backend, patch every profile's sandbox-policy default mode to `danger-full-access` so hooks stop failing open (a deliberate, deployment-wide sandbox downgrade — never applied when a backend exists); `strip` = remove a previously applied downgrade block |
| `GSD_INSTALL_BWRAP` | `0` | Backend missing on Linux: attempt to install bubblewrap through the distro package manager (root or sudo), re-probe functionally, and remove any earlier `GSD-DSH-sandbox` downgrade block; best-effort — on failure it falls back to the printed instructions |

## Upgrade, rollback and offline install

Every run rebuilds the deployment from the requested version, so upgrade and rollback are the
**same command** with a different version number:

```bash
# Upgrade (e.g. onto the latest compatibility-tested release)
GSD_VERSION=1.20.1 bash install-gsd-dsh.sh

# Rollback
GSD_VERSION=1.19.0 bash install-gsd-dsh.sh
```

- `GSD_VERSION` must be set explicitly — the script never defaults it. A leading `v` is fine
  (`v1.20.1`).
- Re-running is idempotent: the deployment surface is rebuilt and the profile patch is never
  appended twice. Upgrades always refresh the full surface — `--no-ghooks` / `--no-npm-bin` are
  ignored in upgrade mode.
- **Offline:** on an internet-connected machine run
  `npm pack @opengsd/gsd-core@1.20.1`, unpack the tarball, copy it to the target machine, then:
  `GSD_PACKAGE_DIR=<unpacked dir> bash install-gsd-dsh.sh`.
- The toolchain can move freely between versions, but project `.planning/` artifacts do **not**
  auto-downgrade with the engine (GSD's convention is to commit `.planning/` to git) — roll
  project state back with git if a downgrade complains about state formats.
- **Do not** use GSD's built-in `/gsd-update` skill: it installs along the official runtimes'
  paths (into `~/.claude`) and does not know about DSH. This script is the upgrade path on DSH.

## Hooks bridge (on by default)

The installer mounts `@deepseek-ai/dsh-hooks-claude-code` at DSH startup by writing a profile
patch, enabling GSD's lifecycle guards: prompt-injection scanning, read-before-write hints,
secret-read hard-blocks, commit-convention validation, and more.

- Enabled by default; a lean fresh install can skip it with `--no-ghooks`. Upgrades always
  (re)apply it.
- **Version-locked to your DSH:** the installer detects your DSH version and pins
  `@deepseek-ai/dsh-hooks-claude-code` to the same release (via `dsh plugin add --save-exact`;
  `GSD_NO_BRIDGE_SYNC=1` opts out). DSH disables any row whose package version it deems
  incompatible, so after upgrading DSH itself, re-run this installer before restarting to keep
  the bridge mounted.
- **Linux sandbox backend is a hard requirement, or the guards fail open.** Hooks run through
  DSH's bash sandbox under the deployment default mode (`workspace-write` unless overridden). A
  Linux host without **bubblewrap** and without Landlock has no backend for that mode: every hook
  then dies with `SANDBOX_UNAVAILABLE` ("no sandbox backend is usable on this host") and the hook
  protocol fails **open** (`decision: pass`) — the bridge looks alive, nothing is enforced. The
  installer probes this at install time with a **functional bubblewrap smoke** (mirroring DSH's
  own runner probe — a binary whose user namespaces are disabled counts as missing) and prints
  both remedies: (A) install bubblewrap — the exact distro command, or let the script attempt it
  with `GSD_INSTALL_BWRAP=1`; on success it re-probes and automatically removes any earlier
  `GSD-DSH-sandbox` downgrade, (B) lower the deployment default via
  `DSH_PERMISSION_MODE=danger-full-access` / `GSD_HOOKS_SANDBOX_PATCH=1` (removable later with
  `=strip`); restart `dsh web` either way (the backend choice is cached per process). macOS
  (seatbelt) is unaffected.
- All commands are routed through `hooks/dsh-gsd-suite/run.cjs`, which normalizes DSH's lowercase
  tool names (`read`, `write`, `bash`, …) to the PascalCase vocabulary GSD's guards expect —
  e.g. a model `read` of a `.env` file is hard-blocked (exit 2) with the guard's explanation text.
- Known gap: the DSH bridge has no `PreCompact` / `FileChanged` / statusline events, so the
  corresponding GSD guards stay silent on DSH (the same status as GSD on Codex itself). This is a
  host limitation, not a script defect.
- **Mounting is the patch, not the install:** `dsh plugin add` only installs the package (it
  forwards to pnpm) — the mount happens exclusively through the block the installer appends to
  each profile's `cordis.patch.yml` (the patch layer is created if the profile has none). The
  installer detects the bridge package in each profile's own `node_modules` first and the shared
  hoisted store second, and after every run it **verifies** that
  `dsh --profile <name> --dump-config` contains `gsd-hooks-bridge` with its `configPath` pointing
  at the deployed `gsd-hooks.dsh.json`, and that the bridge imports from the profile tree. Any
  non-canonical bridge block (a hand-appended insert, an older installer's `!!js` form) is
  **rewritten to canonical form**, so re-running the script self-heals a half-fixed machine; a
  silent "installed but never mounted" state ends the run with an explicit WARNING (which prints
  the exact block to append by hand) instead of passing silently.
- The patch block is wrapped in `# GSD-DSH-bridge BEGIN/END` markers; `--uninstall` strips it
  automatically (leaving a backup).
- If no bridge plugin package can be found (checked in every profile's node_modules and the
  shared store), the script skips the patch with a message (skill installation is unaffected).
  Force it with `GSD_FORCE_HOOKS_PATCH=1`.
- The bridge is a process-level mount: **restart `dsh web`** after installing for it to take
  effect.

## How it works

1. **Fetch** `@opengsd/gsd-core@<GSD_VERSION>` from npm (`GSD_VERSION` is required online and a
   `v` prefix is normalized; if `npm pack` fails, the script falls back to
   `npm install --prefix`) — or use `GSD_PACKAGE_DIR` for offline — and verify the fetched
   version equals the requested one.
2. **Stage** using the official installer's `--claude --global` passthrough into a throwaway
   `CLAUDE_CONFIG_DIR` (flat skills + engine payload + hook scripts, internal path references
   rewritten to the staging root).
3. **Deploy** to `$DSH_HOME`: `skills/`, `gsd-core/`, `hooks/`, `scripts/` and the bridge config.
   Into every `SKILL.md` it injects a marked, idempotent `<runtime_note>` that adapts GSD to DSH:
   agent dispatch via `subagent` (role files read from `gsd-core/agents/` and injected into the
   subagent prompt), tool-name mapping (`Skill`→`skill`, `Bash`→`bash`, …), and handling for
   `@path` references / `$ARGUMENTS` (see *Limitations*).
4. **Append** the hooks-bridge mount block to each profile's `cordis.patch.yml` (on by default;
   skipped with `--no-ghooks` on fresh installs; the patch layer is created if the profile has
   none; begin/end-marked, backed up before every write; foreign/historic bridge blocks are
   rewritten to canonical form), **align the bridge plugin version with the running DSH** so
   DSH's version gate won't disable the row — then **verify the mount**: every profile's merged
   config must contain `gsd-hooks-bridge` with the deployed `configPath`, and the bridge must
   import from the profile tree, or the run ends with an explicit WARNING (`dsh plugin add`
   installs; it never mounts — mounting is this patch alone).

## What works — and the honest limitations

**Works** (verified by plugin-source review plus a live install):

- **All 72 skills** — names pass DSH's skill-name syntax 1:1; hot discovery in running sessions
  was verified live.
- **Engine payload and `.planning/` state** — plain files/Markdown plus a Node CLI; the payload
  CLI runs standalone.
- **`/gsd-*` user invocation** — DSH's user-invocable skill mechanism is the GSD command surface.
- **Subagents** — DSH's `subagent` / `subagent_fork` cover GSD's parallel "wave" execution; agent
  role definitions are read and injected as subagent prompts.
- **Hooks** — the DSH Claude-Code bridge shares the stdin dialect and exit-code semantics
  (`2` = block) with GSD's hook scripts; matchers were rewritten for DSH's tool names.

**Three real gaps** (host limitations; no patch can fix them):

1. **No named subagent registration** — DSH has no equivalent of Claude Code's `Agent` interface,
   so the per-agent `tools:` allowlists, `model:` tiers and colors in `agents/gsd-*.md` are not
   enforced. GSD's workflow compensates with prompt discipline plus filesystem/git commit checks.
   (Similarly, DSH's default subagent depth limit of 1 means `/gsd-debug`'s second-level dispatch
   degrades or requires raising `maxDepth` in the profile.)
2. **Hook event subset** — `PreCompact`, `FileChanged` and statusline do not exist in the DSH
   bridge, so the corresponding GSD guards and context-usage warnings stay silent (same status as
   GSD on Codex).
3. **No `@`-include auto-expansion or `$ARGUMENTS` substitution** — compensated by the injected
   adaptation note, which instructs the model to `read` referenced paths and parse arguments from
   the message (transparent to the user; costs one extra read).

A further honest note: GSD's prompt tuning (e.g. planner model tiers) is Claude-family oriented.
On DeepSeek models the workflow mechanics work, but output quality is a "community port"
expectation until proven otherwise. Optional MCP tooling (Context7 etc.) works if you configure
`dsh-mcp-client` entries in your profile.

## Verify the installation

1. The session skill catalog lists all 72 `gsd-*` skills; `/gsd-health` executes.
2. Terminal: `gsd_run runtime-identity --raw` prints `@opengsd/gsd-core` and the target version
   (the global CLI is installed by default; omitted only with `--no-npm-bin`).
3. With the bridge installed **and DSH restarted**: `dsh --profile <name> --dump-config | grep gsd-hooks-bridge`
   lists the mount; asking the model to `read` a `.env` file is blocked with an explanation; a
   GSD update check appears at session start.
4. `/gsd-new-project --auto` in a small test repo scaffolds a `.planning/` skeleton.

## Uninstall

```bash
bash install-gsd-dsh.sh --uninstall
```

- Removes only what this script manages: the managed `gsd-core/`, `hooks/`, `scripts/`,
  `gsd-hooks.dsh.json` and all `gsd-*` skills.
- Strips the bridge patch block from every profile patch (per-file backups are kept).
- Same-named directories/files not managed by the script are **skipped with a warning** — never
  touched. The install phase behaves the same way: it aborts rather than overwrite unrelated
  content (`ERROR: refusing to overwrite`).
- The npm global package (installed by default; only skipped with `--no-npm-bin`) is outside the
  uninstall scope: `npm uninstall -g @opengsd/gsd-core`.
- GSD's own global state directory `~/.gsd` (if created) is left alone on purpose.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `ERROR: GSD v1.16+ requires Node >= 24` | Upgrade Node, or install an older tag: `GSD_VERSION=1.15.0 bash install-gsd-dsh.sh` |
| `ERROR: GSD_VERSION is required for online installs` | Pin the version: `GSD_VERSION=1.20.1 bash install-gsd-dsh.sh` (offline installs may omit it with `GSD_PACKAGE_DIR`) |
| `ERROR: invalid GSD_VERSION '…'` | Use a semver like `1.20.1`; `v1.20.1` and `1.20.1-rc.1` are also accepted |
| Skills don't appear in the session | Confirm `DSH_HOME` matches the home DSH actually uses; confirm `skills/gsd-*` files are in place; reopen the session (skill directories hot-reload in running sessions) |
| Typing `/gsd-*` does nothing | That is DSH's user-invocable skill mechanism; ensure the skill directory is visible (above) and your DSH version supports `/name` invocation |
| `gsd_run` not found | The global CLI is installed by default; if the script reported `'npm i -g' failed` (npm prefix not writable), call `node $DSH_HOME/gsd-core/bin/gsd-tools.cjs` directly or fix the prefix and re-run `npm i -g @opengsd/gsd-core@<version>` |
| Hooks bridge has no effect | First restart `dsh web` (the patch mounts at process startup). If it still does nothing, run `dsh --profile <name> --dump-config | grep gsd-hooks-bridge`: a **missing row = installed but never mounted**, a row whose `configPath` is not your `$DSH_HOME/gsd-hooks.dsh.json` = a stale or hand-edited block — in both cases re-run this installer (it rewrites the mount block in every profile's `cordis.patch.yml` to canonical form and verifies the merged config before finishing; its WARNING prints the exact block to append by hand), then restart |
| Startup log: `disabling profile plugin row "gsd-hooks-bridge" … incompatible` | Your DSH was upgraded past the bridge package version. Re-run the installer (it pins the bridge and its `dsh-hook-protocol` dependency to your DSH version automatically) or run `dsh plugin --profile <name> add --save-exact @deepseek-ai/dsh-hooks-claude-code@<your DSH version> @deepseek-ai/dsh-hook-protocol@<your DSH version>`, then restart |
| Startup log: `failed to import … does not provide an export named 'selectHookGroups'` | Same fix as the line above — the bridge's `dsh-hook-protocol` dependency resolves to a stale hoisted copy; pin both packages to your DSH version and restart |
| Hooks fire but every `hook/result` says `decision: pass` with stderr `SANDBOX_UNAVAILABLE` / "no sandbox backend is usable on this host" | The bridge is mounted but the Linux host cannot enforce the sandbox's default `workspace-write` mode (no bubblewrap, no Landlock), so hooks fail open. Fix A: install bubblewrap (`sudo apt-get install -y bubblewrap`, or re-run the installer with `GSD_INSTALL_BWRAP=1` to auto-attempt and strip a leftover downgrade) and restart `dsh web` (recommended — keeps the sandbox). Fix B: start dsh with `DSH_PERMISSION_MODE=danger-full-access`, or re-run the installer with `GSD_HOOKS_SANDBOX_PATCH=1` (patches the `sandbox-policy` mode in every profile; `GSD_HOOKS_SANDBOX_PATCH=strip` removes it once a backend exists). Restart either way |
| `ERROR: refusing to overwrite` | The target home already has same-named content not managed by this script; move it aside or use a different `DSH_HOME` |
| `ERROR: fetched version X != requested Y` | Tag typo or npm cache issue; confirm the tag exists (e.g. `1.20.1`) |
| Offline install fails | `GSD_PACKAGE_DIR` must be an npm-layout unpack artifact, not a git clone; a clone needs `npm install && npm run build:lib` first |
| New hooks don't take effect after an upgrade | The hook list lands per GSD version; when a new GSD release adds hook events, re-run this installer after updating it (the hooks patch is refreshed automatically by default) |

## Compatibility

- Latest compatibility-tested: **DSH 0.2.2-rc.1** (web profile, standard preset; the mechanism
  surface was designed against 0.2.0-rc.2). Earlier DSH versions are not guaranteed.
- Any **GSD Core tag from 1.16.0 on** via `GSD_VERSION`, with **v1.20.1** the latest
  compatibility-tested release (remember the Node ≥ 24 requirement), and older tags for older
  Node.
- Token-sensitive sessions: install with `GSD_PROFILE=core` first, then add `standard`/`full`.

## License and credits

- License: **Apache-2.0** — see [LICENSE](LICENSE).
- Upstream: [GSD Core](https://github.com/open-gsd/gsd-core) (`open-gsd/gsd-core`, MIT) and
  [DeepSeek Harness](https://github.com/deepseek-ai/dsh) (`@deepseek-ai/dsh`, MIT). This project
  is not affiliated with either upstream; third-party components keep their own licenses.
