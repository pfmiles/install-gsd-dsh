#!/usr/bin/env bash
# install-gsd-dsh.sh — stage GSD Core (open-gsd/gsd-core) into DeepSeek Harness (DSH)
# User-facing instructions: see the project README (README.md) next to this file.
#
# The official GSD installer has no DSH runtime, so we reuse its "claude" passthrough
# into a throwaway staging dir (flat skills, engine payload, hook scripts, and
# @-references rewritten to the staging root), then deploy only the surfaces DSH
# understands:
#
#   ~/.dsh/skills/gsd-<name>/SKILL.md   <- DSH filesystem skill provider root
#   ~/.dsh/gsd-core/                    <- engine payload (workflows/references/…)
#   ~/.dsh/hooks/                       <- hook scripts (optional hooks bridge)
#   ~/.dsh/scripts/                     <- package scripts (gsd-core/bin/lib requires it)
#   ~/.dsh/gsd-hooks.dsh.json           <- hook config with DSH tool-name matchers
#
# Requirements: bash, node, npm; macOS / Linux / WSL. Native Windows is unsupported
# (use WSL). GSD v1.16+ requires Node >= 24 — set an older GSD_VERSION for older Node.
# GSD_VERSION is REQUIRED for online installs (a leading "v" is tolerated); offline
# installs may omit it with GSD_PACKAGE_DIR. Every run is a COMPLETE install by
# default (hooks-bridge patch + global gsd_run CLI); pass --no-ghooks/--no-npm-bin
# for a lean fresh install. Re-running over an existing deployment is upgrade mode
# and always refreshes the full surface, so an upgrade can never be partial.
# If your DSH uses a custom home (DSH_HOME env or configured path), run this script
# with the SAME value:  DSH_HOME=<that dir> bash install-gsd-dsh.sh
#
# Usage:
#   GSD_VERSION=1.16.0 bash install-gsd-dsh.sh        # complete install (defaults)
#   bash install-gsd-dsh.sh --no-ghooks    # lean: skip hooks-bridge patch
#   bash install-gsd-dsh.sh --no-npm-bin   # lean: skip global gsd_run CLI
#   bash install-gsd-dsh.sh --fix-repo     # refresh build outputs under <cwd>/gsd-core/bin
#   bash install-gsd-dsh.sh --uninstall    # remove everything this script deployed
#   bash install-gsd-dsh.sh --help
#
# Upgrade / Rollback:  GSD_VERSION=<tag> bash install-gsd-dsh.sh   (same command)
#
# Environment:
#   GSD_VERSION             target version tag — REQUIRED for online installs
#   DSH_HOME                DSH data root to deploy into (default ~/.dsh)
#   GSD_PACKAGE_DIR         offline mode: path to an unpacked @opengsd/gsd-core
#                           source/npm layout (skips npm download entirely)
#   GSD_PROFILE             installer skill profile passthrough (core|standard|full)
#   GSD_FORCE_HOOKS_PATCH=1 write the bridge patch even if the bridge plugin package
#                           is not detected anywhere under $DSH_HOME/profiles
#   GSD_ALLOW_OLD_NODE=1    proceed despite Node < 24 (engine may not run)
#   GSD_NO_BRIDGE_SYNC=1    skip aligning the hooks bridge plugin to the DSH version
set -euo pipefail

DSH_HOME="${DSH_HOME:-$HOME/.dsh}"

# Complete-by-default: hooks patch + global CLI are ON for every run. The two
# --no-* flags opt into a LEAN fresh install; upgrade mode ignores them.
WITH_PATCH=1
NPM_BIN=1
DECLINED_PATCH=0
DECLINED_BIN=0
HOOKS_OK=0
UNINSTALL=0
FIX_REPO=0
for a in "$@"; do
  case "$a" in
    -h|--help)  sed -n '2,34p' "$0"; exit 0 ;;
    --with-ghooks) DECLINED_PATCH=0 ;;
    --npm-bin)     DECLINED_BIN=0 ;;
    --no-ghooks)   DECLINED_PATCH=1 ;;
    --no-npm-bin)  DECLINED_BIN=1 ;;
    --uninstall)   UNINSTALL=1 ;;
    --fix-repo)    FIX_REPO=1 ;;
    *) echo "unknown arg: $a (see --help)"; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Version gate: GSD_VERSION is required for online installs/upgrades — pin the
# version so a bare re-run can never silently roll a machine back to a default.
# A leading "v" is tolerated. Offline installs (GSD_PACKAGE_DIR) may omit it and
# inherit the version from the package. --uninstall / --help never need it.
# ---------------------------------------------------------------------------
RAW_GSD_VERSION="${GSD_VERSION:-}"
if [ -n "$RAW_GSD_VERSION" ]; then
  GSD_VERSION="${RAW_GSD_VERSION#v}"
  if [[ ! "$GSD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
    echo "ERROR: invalid GSD_VERSION '$RAW_GSD_VERSION' — expected a semver like 1.17.0" >&2
    echo "       (a leading 'v' or a build tag like 1.17.0-rc.1 is allowed)." >&2
    exit 2
  fi
elif [ "$UNINSTALL" != 1 ] && [ -z "${GSD_PACKAGE_DIR:-}" ]; then
  echo "ERROR: GSD_VERSION is required for online installs. Pin the version, e.g." >&2
  echo "    GSD_VERSION=1.16.0 bash install-gsd-dsh.sh" >&2
  echo "  (offline installs may omit it when GSD_PACKAGE_DIR is set.)" >&2
  exit 2
else
  GSD_VERSION=""    # --uninstall needs no version; offline derives it below
fi

MARKER=".gsd-dsh-managed"
BRIDGE_PKG="$DSH_HOME/profiles/node_modules/@deepseek-ai/dsh-hooks-claude-code"

banner()  { echo "== $* =="; }
note()    { echo "   $*"; }

# Version of the DSH that owns this home: the dsh CLI, else the dsh package the
# profile's node_modules resolves from. Empty when neither is available.
dsh_version() {
  local v
  if command -v dsh >/dev/null 2>&1; then
    v="$(dsh --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?' | head -1 || true)"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  fi
  for bp in "$DSH_HOME"/profiles/*/node_modules; do
    if [ -f "$bp/dsh/package.json" ]; then
      v="$(node -p "require('$bp/dsh/package.json').version" 2>/dev/null || true)"
      if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    fi
  done
  if [ -f "$DSH_HOME/profiles/node_modules/dsh/package.json" ]; then
    v="$(node -p "require('$DSH_HOME/profiles/node_modules/dsh/package.json').version" 2>/dev/null || true)"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  fi
  return 1
}

# Version of the installed hooks bridge plugin. DSH resolves the row from the
# profile's own node_modules, so check profile-local trees first; the hoisted
# top-level store is only a fallback (it can be stale after DSH upgrades).
bridge_version() {
  local bp v
  for bp in "$DSH_HOME"/profiles/*/node_modules; do
    if [ -f "$bp/@deepseek-ai/dsh-hooks-claude-code/package.json" ]; then
      v="$(node -p "require('$bp/@deepseek-ai/dsh-hooks-claude-code/package.json').version" 2>/dev/null || true)"
      if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
    fi
  done
  if [ -f "$DSH_HOME/profiles/node_modules/@deepseek-ai/dsh-hooks-claude-code/package.json" ]; then
    v="$(node -p "require('$DSH_HOME/profiles/node_modules/@deepseek-ai/dsh-hooks-claude-code/package.json').version" 2>/dev/null || true)"
    if [ -n "$v" ]; then printf '%s' "$v"; return 0; fi
  fi
  return 1
}

# ---------------------------------------------------------------------------
# Uninstall (marker-aware)
# ---------------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  banner "uninstall GSD/DSH deployment from $DSH_HOME"
  rm -rf "$DSH_HOME"/skills/gsd-*
  for d in gsd-core hooks scripts; do
    if [ -e "$DSH_HOME/$d/$MARKER" ]; then
      rm -rf "$DSH_HOME/$d"; note "removed managed $d/"
    elif [ -e "$DSH_HOME/$d" ]; then
      note "SKIPPED $d/ (exists but is not managed by this script — leaving it alone)"
    fi
  done
  if [ -f "$DSH_HOME/gsd-hooks.dsh.json" ]; then
    if [ -f "$DSH_HOME/gsd-hooks.dsh.json$MARKER" ]; then
      rm -f "$DSH_HOME/gsd-hooks.dsh.json" "$DSH_HOME/gsd-hooks.dsh.json$MARKER"
      note "removed managed gsd-hooks.dsh.json"
    else
      note "SKIPPED gsd-hooks.dsh.json (not managed by this script — leaving it alone)"
    fi
  fi
  # strip marked hooks-bridge blocks from every profile patch (backs up each file)
  NODE_STRIP="$(mktemp)"
  cat > "$NODE_STRIP" <<'EOF'
const fs = require('fs');
const B = '# GSD-DSH-bridge BEGIN', E = '# GSD-DSH-bridge END';
for (const f of process.argv.slice(2)) {
  const s = fs.readFileSync(f, 'utf8');
  if (!(s.includes(B) && s.includes(E))) { console.log('no marked block: ' + f); continue; }
  const i = s.indexOf(B), j = s.indexOf(E);
  fs.writeFileSync(f + '.stripped-bak', s);
  const out = s.slice(0, i) + s.slice(j + E.length + 1);
  fs.writeFileSync(f, out.replace(/\n{3,}$/, '\n'));
  console.log('stripped ' + f + ' (backup: ' + f + '.stripped-bak)');
}
EOF
  shopt -s nullglob
  node "$NODE_STRIP" "$DSH_HOME"/profiles/*/cordis.patch.yml || true
  rm -f "$NODE_STRIP"
  note "Done. If you also want to drop GSD's global state: rm -rf ~/.gsd"
  exit 0
fi

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
command -v node >/dev/null || { echo "ERROR: node is required"; exit 1; }
command -v npm  >/dev/null || { echo "ERROR: npm is required (network mode)"; exit 1; }

echo "GSD_VERSION=$GSD_VERSION"
echo "DSH_HOME=$DSH_HOME"
if [ "$DSH_HOME" != "$HOME/.dsh" ]; then
  note "custom DSH home detected — make sure this matches the home your DSH runs with"
  note "(dsh resolves: explicit config path > \$DSH_HOME > ~/.dsh)"
fi

NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [ "$NODE_MAJOR" -lt 24 ] && [ "${GSD_ALLOW_OLD_NODE:-0}" != 1 ]; then
  echo "ERROR: GSD v1.16+ requires Node >= 24 (yours: $NODE_MAJOR)."
  echo "  - upgrade Node, or pick an older tag, e.g.  GSD_VERSION=1.15.0 ./install-gsd-dsh.sh"
  echo "  - force anyway with  GSD_ALLOW_OLD_NODE=1  (engine may fail)"
  exit 1
fi

_TMP_BASE="${TMPDIR:-/tmp}"; _TMP_BASE="${_TMP_BASE%/}"
STAGING="$(mktemp -d "$_TMP_BASE/gsd-dsh-staging.XXXXXX")"
WORK="$(mktemp -d "$_TMP_BASE/gsd-dsh-pkg.XXXXXX")"
# abort-safe hygiene: every failure path still removes the staging trees, so a
# re-run starts clean and aborted attempts leave no litter behind
trap 'rm -rf "$STAGING" "$WORK"' EXIT

# ---------------------------------------------------------------------------
# 1/6 source the official package: network (npm pack) or offline (GSD_PACKAGE_DIR)
# ---------------------------------------------------------------------------
if [ -n "${GSD_PACKAGE_DIR:-}" ]; then
  banner "1/6 sourcing local package (offline: $GSD_PACKAGE_DIR)"
  PKG_DIR="$GSD_PACKAGE_DIR"
  [ -f "$PKG_DIR/bin/install.js" ] || { echo "ERROR: $PKG_DIR/bin/install.js not found"; exit 1; }
  if [ -d "$PKG_DIR/.git" ]; then
    note "WARNING: GSD_PACKAGE_DIR looks like a git clone — the installer needs a built"
    note "npm layout. Run 'npm install && npm run build:lib' there first, or drop"
    note "GSD_PACKAGE_DIR to fetch the official npm tarball."
  fi
  ACTUAL="$(node -p "require('$PKG_DIR/package.json').version")"
  if [ -z "$GSD_VERSION" ]; then
    GSD_VERSION="$ACTUAL"
    note "GSD_VERSION not set — using $ACTUAL from the offline package"
  elif [ "$ACTUAL" != "$GSD_VERSION" ]; then
    echo "ERROR: offline package version $ACTUAL != requested $GSD_VERSION"
    exit 1
  fi
else
  banner "1/6 sourcing @opengsd/gsd-core@$GSD_VERSION"
  if ! npm pack "@opengsd/gsd-core@$GSD_VERSION" --pack-destination "$WORK" --silent >"$WORK/pack.log" 2>&1; then
    note "npm pack failed, falling back to npm install --prefix:"
    mkdir -p "$WORK/npmtmp"
    if ! npm install --prefix "$WORK/npmtmp" "@opengsd/gsd-core@$GSD_VERSION" --no-save --silent >"$WORK/install.log" 2>&1; then
      echo "ERROR: could not fetch @opengsd/gsd-core@$GSD_VERSION (network/npm)."
      echo "       offline? set GSD_PACKAGE_DIR=/unpacked/gsd-core or fix npm."
      exit 1
    fi
    PKG_DIR="$WORK/npmtmp/node_modules/@opengsd/gsd-core"
  else
    tar xzf "$WORK"/opengsd-gsd-core-*.tgz -C "$WORK"
    PKG_DIR="$WORK/package"
  fi
  ACTUAL="$(node -p "require('$PKG_DIR/package.json').version")"
  if [ "$ACTUAL" != "$GSD_VERSION" ]; then
    echo "ERROR: fetched version $ACTUAL != requested $GSD_VERSION"
    exit 1
  fi
fi

banner "2/6 staging with the official installer (claude passthrough)"
INSTALLER_ARGS=(--claude --global)
[ -n "${GSD_PROFILE:-}" ] && INSTALLER_ARGS+=(--profile="$GSD_PROFILE")
CLAUDE_CONFIG_DIR="$STAGING" node "$PKG_DIR/bin/install.js" "${INSTALLER_ARGS[@]}" \
  || { echo "ERROR: official installer failed (see output above)."; \
       echo "       hint: source needs built modules — run 'npm install && npm run build:lib'"; \
       echo "       inside the package dir (GSD_PACKAGE_DIR mode), or use network mode."; exit 1; }

# ---------------------------------------------------------------------------
# 3/6 deploy (with managed-marker guards: never clobber unrelated user paths)
# ---------------------------------------------------------------------------
# Existing managed deployment => upgrade/rollback mode: refresh the FULL surface
# by default (hook patch + global CLI), so an upgrade can never be partial.
# Existing managed deployment => upgrade/rollback mode: the full surface is
# mandatory, so an upgrade can never be partial (lean opt-outs are ignored).
if [ -e "$DSH_HOME/gsd-core/$MARKER" ] || ls "$DSH_HOME"/skills/gsd-* >/dev/null 2>&1; then
  UPGRADING=1
  WITH_PATCH=1
  NPM_BIN=1
  if [ "$DECLINED_PATCH" = 1 ] || [ "$DECLINED_BIN" = 1 ]; then
    note "existing GSD deployment found — upgrade mode: full surface is mandatory"
    note "(--no-ghooks / --no-npm-bin are ignored for upgrades)."
  else
    note "existing GSD deployment found — upgrade mode: refreshing the full surface."
  fi
else
  [ "$DECLINED_PATCH" = 1 ] && WITH_PATCH=0
  [ "$DECLINED_BIN"  = 1 ] && NPM_BIN=0
fi

banner "3/6 deploy -> $DSH_HOME"
adopt_or_abort() { # $1 dir  $2 signature-path-inside
  local dir="$1" sig="$2"
  if [ -e "$dir" ]; then
    if [ -e "$dir/$MARKER" ]; then
      return 0                       # ours: replace freely
    fi
    if [ -e "$dir/$sig" ]; then
      note "$dir exists without marker but matches GSD signature — adopting it"
      return 0                       # previous version of this script: replace + mark
    fi
    echo "ERROR: refusing to overwrite $dir — it exists and is not managed by this script."
    echo "       move it aside or re-run with a different DSH_HOME."; exit 1
  fi
}
# run all collision guards BEFORE touching anything, so an abort leaves no partial deploy
adopt_or_abort "$DSH_HOME/gsd-core" "VERSION"
adopt_or_abort "$DSH_HOME/hooks" "lib/hook-exit.js"
adopt_or_abort "$DSH_HOME/scripts" "fix-slash-commands.cjs"

mkdir -p "$DSH_HOME/skills"
rm -rf "$DSH_HOME"/skills/gsd-*          # gsd-* prefix is the documented skill namespace
cp -R "$STAGING/skills/." "$DSH_HOME/skills/"

rm -rf "$DSH_HOME/gsd-core" "$DSH_HOME/hooks" "$DSH_HOME/scripts"
cp -R "$STAGING/gsd-core" "$DSH_HOME/gsd-core"
cp -R "$STAGING/hooks"    "$DSH_HOME/hooks"
cp -R "$STAGING/scripts"  "$DSH_HOME/scripts"
for d in gsd-core hooks scripts; do : > "$DSH_HOME/$d/$MARKER"; done

# The official installer rewrote every @<path> reference to the throwaway staging
# root; repoint them at the real deployment so the model's Reads resolve.
NODE_REWRITE="$(mktemp)"
cat > "$NODE_REWRITE" <<'EOF'
const fs = require('fs');
const path = require('path');
const from = process.env.GSD_FROM;
const to = process.env.GSD_TO;
let n = 0;
function walk(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p);
    else if (e.isFile()) {
      const s = fs.readFileSync(p, 'utf8');
      if (s.includes(from)) { fs.writeFileSync(p, s.split(from).join(to)); n++; }
    }
  }
}
walk(process.argv[2]);
fs.writeSync(2, 'rewrote ' + n + ' files in ' + process.argv[2] + '\n');
EOF
GSD_FROM="$STAGING" GSD_TO="$DSH_HOME" node "$NODE_REWRITE" "$DSH_HOME/skills"
GSD_FROM="$STAGING" GSD_TO="$DSH_HOME" node "$NODE_REWRITE" "$DSH_HOME/gsd-core"
rm -f "$NODE_REWRITE"

# ---------------------------------------------------------------------------
# 4/6 inject the DSH runtime-adaptation note into each SKILL.md
# ---------------------------------------------------------------------------
banner "4/6 inject DSH runtime-adaptation note"
NOTE="$(mktemp)"
cat > "$NOTE" <<'EOF'
<!-- gsd:dsh-adapter begin (regenerated by install-gsd-dsh.sh) -->

<runtime_note>
**DeepSeek Harness (DSH).** 本技能面向 Claude Code 编写;在 DSH 中按下表平移工具面:
- `Agent` / `Task`(按名派发子代理)→ 本会话的 `subagent` 工具。DSH 不注册 `agents/*.md`:
  派发某角色前先 `read` `~/.dsh/gsd-core/agents/gsd-<role>.md`(存在 `.compact.md` 优先读它),
  把其中的 `<role>` / `<required_reading>` / `<config>` 原文放进子代理 prompt。
  frontmatter 的 tools 白名单与 model 档位在 DSH 不生效,由 prompt 纪律替代。
  一条消息中并行发起多个 `subagent` 调用即“同一波并行执行”;子代理结果不会自动回传,按
  `job_output` 或直接同步调用收集,并始终按文件系统与 git 状态做完成核对(工作流已有该回退)。
- `Skill`→`skill`;`AskUserQuestion`→`ask_user_question`;`TodoWrite`→`todo_write`;
  `WebSearch`→`web_search`;`WebFetch`→`web_fetch`;`Bash`→`bash`;`Grep`→`grep`;`Glob`→`glob`;
  `Read`→`read`;`Write`→`write`;`Edit`→`edit`。
- 本文件与工作流中的 `@<path>` 不会被宿主自动展开:把它们当作需按需 `read` 的文件清单(渐进披露)。
- `$ARGUMENTS` 占位符不会被宿主替换:从本条用户消息原文解析参数。
- `mcp__*` 工具仅在用户为 DSH 配置了对应 MCP 服务时存在;否则按工作流给出的 CLI/Bash 回退执行。
- 引擎命令 `gsd_run` 可经 PATH(推荐 `npm i -g @opengsd/gsd-core`)或 `node ~/.dsh/gsd-core/bin/gsd-tools.cjs` 调用。
</runtime_note>

<!-- gsd:dsh-adapter end -->
EOF
NODE_INJECT="$(mktemp)"
cat > "$NODE_INJECT" <<'EOF'
const fs = require('fs');
let note = fs.readFileSync(process.env.GSD_DSH_NOTE, 'utf8').trim();
// pin the note to this deployment's real home (script uses ~/.dsh literals)
note = note.split('~/.dsh/gsd-core').join(process.env.GSD_DSH_CORE_DIR);
for (const f of process.argv.slice(2)) {
  const raw = fs.readFileSync(f, 'utf8');
  const begin = raw.indexOf('<!-- gsd:dsh-adapter begin -->');
  let cleaned = raw;
  if (begin >= 0) {
    const end = raw.indexOf('<!-- gsd:dsh-adapter end -->', begin);
    if (end >= 0) cleaned = raw.slice(0, begin) + raw.slice(end + '<!-- gsd:dsh-adapter end -->'.length);
  }
  // find the second "---" line (frontmatter close) and insert the note after it
  const lines = cleaned.split('\n');
  let count = 0, at = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i].replace(/\r$/, '') === '---') { count++; if (count === 2) { at = i; break; } }
  }
  if (at < 0) { console.error('no frontmatter in ' + f); process.exitCode = 1; continue; }
  lines.splice(at + 1, 0, ...note.split('\n'));
  fs.writeFileSync(f, lines.join('\n'));
}
EOF
export GSD_DSH_NOTE="$NOTE" GSD_DSH_CORE_DIR="$DSH_HOME/gsd-core"
for f in "$DSH_HOME"/skills/gsd-*/SKILL.md; do node "$NODE_INJECT" "$f"; done
rm -f "$NOTE" "$NODE_INJECT"
note "injected into $(ls -d "$DSH_HOME"/skills/gsd-* 2>/dev/null | wc -l | tr -d ' ') skills"

# ---------------------------------------------------------------------------
# 5/6 hooks suite + bridge config (used only when the bridge is mounted)
# ---------------------------------------------------------------------------
banner "5/6 write hook bridge suite + config"
mkdir -p "$DSH_HOME/hooks/dsh-gsd-suite"
cat > "$DSH_HOME/hooks/dsh-gsd-suite/run.cjs" <<'EOF'
// dsh-gsd-suite/run.cjs — DSH→Claude hook stdio adapter for GSD guard hooks.
//
// The DSH claude-code hooks bridge forwards tool calls with DSH tool names
// (lowercase: read/write/edit/bash/grep/glob/web_search/…) and Claude-shaped
// tool_input/tool_response fields. GSD's guard hooks dispatch on Claude's
// PascalCase tool vocabulary, so unknown names silently allow. This runner
// normalizes the tool_name on stdin, then execs the real hook verbatim
// (stdout/stderr inherited, exit code propagated — exit 2 still blocks).
//
// Usage: node run.cjs <command> [args…]   (stdin: hook JSON payload)
'use strict';
const fs = require('fs');
const { spawnSync } = require('child_process');

const NAME_MAP = {
  read: 'Read',
  read_image: 'Read',
  grep: 'Grep',
  glob: 'Glob',
  bash: 'Bash',
  pwsh: 'Bash',
  write: 'Write',
  edit: 'Edit',
  web_search: 'WebSearch',
  web_fetch: 'WebFetch',
  subagent: 'Agent',
  subagent_fork: 'Agent',
  workflow: 'Agent',
};

let raw = fs.readFileSync(0, 'utf8');
try {
  const j = JSON.parse(raw);
  if (j && typeof j === 'object' && typeof j.tool_name === 'string') {
    const mapped = NAME_MAP[j.tool_name];
    if (mapped) j.tool_name = mapped;
  }
  raw = JSON.stringify(j);
} catch {
  // not parseable (rare bridge payloads): forward verbatim, fail-open downstream
}

const cmd = process.argv[2];
if (!cmd) {
  process.stderr.write('run.cjs: missing hook command\n');
  process.exit(2);
}
const r = spawnSync(cmd, process.argv.slice(3), {
  input: raw,
  stdio: ['pipe', 'inherit', 'inherit'],
});
process.exit(r.status === null ? 1 : r.status);
EOF
cat > "$DSH_HOME/gsd-hooks.dsh.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      { "hooks": [
        { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-check-update.js\"", "timeout": 30 },
        { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"sh\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-session-state.sh\"", "timeout": 10 }
      ] }
    ],
    "PreToolUse": [
      { "matcher": "write|edit",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-prompt-guard.js\"", "timeout": 120 },
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-read-guard.js\"", "timeout": 5 }
        ] },
      { "matcher": "bash|write|edit",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-workflow-guard.js\"", "timeout": 120 }
        ] },
      { "matcher": "write|edit",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-worktree-path-guard.js\"", "timeout": 120 }
        ] },
      { "matcher": "subagent|subagent_fork|workflow",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-agent-isolation-guard.js\"", "timeout": 120 }
        ] },
      { "matcher": "write",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-write-guard.js\"", "timeout": 120 }
        ] },
      { "matcher": "read|grep|bash",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-secret-read-guard.js\"", "timeout": 120 }
        ] },
      { "matcher": "bash",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"sh\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-validate-commit.sh\"", "timeout": 30 }
        ] }
    ],
    "PostToolUse": [
      { "matcher": "bash|edit|write|subagent|subagent_fork|workflow",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-context-monitor.js\"", "timeout": 10 }
        ] },
      { "matcher": "read|web_fetch|web_search",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-read-injection-scanner.js\"", "timeout": 5 }
        ] },
      { "matcher": "bash",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"sh\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-graphify-update.sh\"", "timeout": 10 }
        ] },
      { "matcher": "write|edit",
        "hooks": [
          { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"sh\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-phase-boundary.sh\"", "timeout": 10 }
        ] }
    ],
    "SubagentStop": [
      { "hooks": [
        { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-context-monitor.js\"", "timeout": 10 }
      ] }
    ],
    "Stop": [
      { "hooks": [
        { "type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/dsh-gsd-suite/run.cjs\" \"node\" \"${CLAUDE_PLUGIN_ROOT}/hooks/gsd-context-monitor.js\"", "timeout": 10 }
      ] }
    ]
  }
}
EOF
: > "$DSH_HOME/gsd-hooks.dsh.json$MARKER"
note "wrote $DSH_HOME/hooks/dsh-gsd-suite/run.cjs + $DSH_HOME/gsd-hooks.dsh.json"

# ---------------------------------------------------------------------------
# 6/6 profile patch for the hooks bridge — on by default (--no-ghooks skips it
# on fresh installs); then --fix-repo / --npm-bin
# ---------------------------------------------------------------------------
if [ "$WITH_PATCH" = 1 ]; then
  banner "6/6 hooks bridge: align plugin version + profile patch"

  # DSH's version gate disables any plugin row whose package version does not
  # match the running DSH. A bridge left behind by an older DSH therefore never
  # mounts and the GSD guards silently never fire — so keep the bridge package
  # in lockstep with DSH (GSD_NO_BRIDGE_SYNC=1 opts out; failure never aborts).
  DSH_VER="$(dsh_version || true)"
  BRIDGE_VER="$(bridge_version || true)"
  if [ -n "$DSH_VER" ] && [ "${GSD_NO_BRIDGE_SYNC:-0}" != 1 ]; then
    if [ "$BRIDGE_VER" = "$DSH_VER" ]; then
      note "hooks bridge plugin matches DSH $DSH_VER — in sync."
    else
      if [ -z "$BRIDGE_VER" ]; then
        note "hooks bridge plugin not installed (DSH $DSH_VER) — installing."
      else
        note "hooks bridge $BRIDGE_VER != DSH $DSH_VER — DSH would disable the row; aligning."
      fi
      if command -v dsh >/dev/null 2>&1; then
        for pdir in "$DSH_HOME"/profiles/*/package.json; do
          [ -f "$pdir" ] || continue
          prof="$(basename "$(dirname "$pdir")")"
          # pin the bridge's load-time dependency too: a stale hoisted
          # dsh-hook-protocol makes the bridge fail to import at DSH startup.
          if DSH_HOME="$DSH_HOME" dsh plugin --profile "$prof" add --save-exact \
               "@deepseek-ai/dsh-hooks-claude-code@$DSH_VER" \
               "@deepseek-ai/dsh-hook-protocol@$DSH_VER" >/dev/null 2>&1; then
            note "installed @deepseek-ai/dsh-hooks-claude-code@$DSH_VER (+hook-protocol) into profile '$prof'"
          else
            note "WARNING: could not install the bridge into profile '$prof' (dsh plugin add failed)."
          fi
        done
        BRIDGE_VER="$(bridge_version || true)"
      fi
      if [ "$BRIDGE_VER" = "$DSH_VER" ]; then
        note "hooks bridge plugin aligned to $DSH_VER."
      else
        note "WARNING: hooks bridge not aligned to DSH $DSH_VER — DSH will keep the"
        note "gsd-hooks-bridge row disabled until it matches. Fix manually:"
        note "  dsh plugin --profile <profile> add --save-exact @deepseek-ai/dsh-hooks-claude-code@$DSH_VER @deepseek-ai/dsh-hook-protocol@$DSH_VER"
      fi
    fi
  fi

  # `dsh plugin --profile <p> add` installs the bridge into the profile's own
  # node_modules tree; the shared hoisted store (profiles/node_modules) may hold
  # a stale copy, or none at all on a fresh machine. Detect the package the same
  # profile-local-first way bridge_version() does — guarding this block on the
  # hoisted path alone left fresh machines with the package installed but the
  # mount patch never written ("installed but not mounted", cloud report
  # 2026-11). The patch below is the ONLY thing that mounts the bridge:
  # `dsh plugin add` installs; it does not mount.
  BRIDGE_VER="$(bridge_version || true)"
  if [ -z "$BRIDGE_VER" ] && [ "${GSD_FORCE_HOOKS_PATCH:-0}" != 1 ]; then
    note "bridge plugin package not found (checked every profile node_modules"
    note "plus the shared store at $BRIDGE_PKG)"
    note "this DSH version may not ship it — skipping patch (skills still work)."
    note "re-run with GSD_FORCE_HOOKS_PATCH=1 to force."
  else
    CONFIG_PATH_LINE="        configPath: '$DSH_HOME/gsd-hooks.dsh.json'"
    if [ ! -f "$DSH_HOME/gsd-hooks.dsh.json" ]; then
      echo "WARNING: $DSH_HOME/gsd-hooks.dsh.json is missing — even a mounted bridge"
      echo "         would register zero hooks. It should have been written in 5/6."
    fi
    shopt -s nullglob
    PATCHED=0
    PROFILES_LIST=""
    # Iterate every profile that has a package.json — including one without a
    # cordis.patch.yml yet. A fresh profile must get a patch layer created,
    # otherwise the mount is silently lost.
    for pd in "$DSH_HOME"/profiles/*/package.json; do
      [ -f "$pd" ] || continue
      pdir="$(dirname "$pd")"
      prof="$pdir/cordis.patch.yml"
      PROFILES_LIST="$PROFILES_LIST $pdir"
      if [ ! -f "$prof" ]; then
        : > "$prof"
        note "created $prof (profile '$(basename "$pdir")' had no patch layer)"
      fi
      if grep -q 'gsd-hooks-bridge' "$prof"; then
        # Any bridge block without BOTH canonical markers is foreign (a manual
        # insert) or historic (an older installer or a !!js configPath): strip
        # it and rewrite the canonical block so a re-run converges the patch.
        NODE_RETRO="$(mktemp)"
        cat > "$NODE_RETRO" <<'EOF'
const fs = require('fs');
const f = process.argv[2];
const B = '# GSD-DSH-bridge BEGIN', E = '# GSD-DSH-bridge END';
const NEEDLE = 'gsd-hooks-bridge';
let s = fs.readFileSync(f, 'utf8');
const before = s;
let changed = false;
if (!(s.includes(B) && s.includes(E))) {
  // remove foreign/historic entries: only top-level "- insert:" items whose
  // span contains the needle (or bare needle lines), plus any GSD comment line
  // clinging above them
  let lines = s.split('\n');
  for (let i = 0; i < lines.length; ) {
    const isInsert = lines[i].trim() === '- insert:';
    const nextTop = isInsert ? lines.findIndex((l, k) => k > i && /^- /.test(l)) : -1;
    const span = isInsert ? lines.slice(i, nextTop === -1 ? lines.length : nextTop).join('\n') : '';
    const targeted = isInsert ? span.includes(NEEDLE) : lines[i].includes(NEEDLE);
    if (targeted) {
      const endIdx = nextTop === -1 ? lines.length : nextTop;
      let startIdx = i;
      while (startIdx > 0) {
        const t = lines[startIdx - 1].trim();
        if (/^# GSD/.test(t) || /^# GSD-DSH-bridge/.test(t) || t === '') startIdx--;
        else break;
      }
      lines.splice(startIdx, endIdx - startIdx);
      changed = true;
      i = startIdx;
      continue;
    }
    i = isInsert ? (nextTop === -1 ? lines.length : nextTop) : i + 1;
  }
  s = lines.join('\n');
}
if (!(s.includes(B) && s.includes(E))) {
  s = s.replace(/\s*$/, '\n\n') + [
    B,
    '# GSD hooks bridge (added by install-gsd-dsh.sh)',
    '- insert:',
    '    - id: gsd-hooks-bridge',
    "      name: '@deepseek-ai/dsh-hooks-claude-code'",
    '      config:',
    "        configPath: '" + process.env.GSD_HOME + "/gsd-hooks.dsh.json'",
    "        pluginRoot: '" + process.env.GSD_HOME + "'",
    '        defaultTimeoutMs: 300000',
    E,
  ].join('\n') + '\n';
  changed = true;
}
if (changed) {
  fs.copyFileSync(f, f + '.bak.' + Date.now());
  fs.writeFileSync(f, s);
  console.log('bridge block rewritten to canonical form: ' + f);
} else {
  console.log('bridge block already canonical: ' + f);
}
EOF
        GSD_HOME="$DSH_HOME" node "$NODE_RETRO" "$prof"; rm -f "$NODE_RETRO"
        note "bridge block checked in $prof"
        PATCHED=1
      else
        cp "$prof" "$prof.bak.$(date +%s)"
        {
          echo ""
          echo "# GSD-DSH-bridge BEGIN"
          echo "# GSD hooks bridge (added by install-gsd-dsh.sh)"
          echo "- insert:"
          echo "    - id: gsd-hooks-bridge"
          echo "      name: '@deepseek-ai/dsh-hooks-claude-code'"
          echo "      config:"
          echo "$CONFIG_PATH_LINE"
          echo "        pluginRoot: '$DSH_HOME'"
          echo "        defaultTimeoutMs: 300000"
          echo "# GSD-DSH-bridge END"
        } >> "$prof"
        note "appended hooks bridge to $prof"
        PATCHED=1
      fi
    done
    if [ "$PATCHED" != 1 ]; then
      note "no profile package.json found under $DSH_HOME/profiles — the bridge"
      note "was not mounted. Start DSH once, then re-run this script."
    fi
    # Post-flight verification: the mount is the point of this step, so a silent
    # miss must not masquerade as success. Two checks per profile —
    # 1. the insert survives the profile merge (--dump-config);
    # 2. the bridge package actually imports from the profile tree (a stale
    #    hoisted dsh-hook-protocol breaks startup imports).
    for pdir in $PROFILES_LIST; do
      pname="$(basename "$pdir")"
      if command -v dsh >/dev/null 2>&1; then
        CFG_OUT="$(DSH_HOME="$DSH_HOME" dsh --profile "$pname" --dump-config 2>/dev/null || true)"
        if printf '%s\n' "$CFG_OUT" | grep -q 'gsd-hooks-bridge' && \
           printf '%s\n' "$CFG_OUT" | grep -A8 'gsd-hooks-bridge' | grep -qF "configPath: $DSH_HOME/gsd-hooks.dsh.json"; then
          HOOKS_OK=1
          note "verified: gsd-hooks-bridge in merged config of profile '$pname' (configPath OK)"
        else
          echo "WARNING: gsd-hooks-bridge NOT confirmed in the merged config of profile '$pname'"
          echo "         (row missing, or its configPath does not point at $DSH_HOME/gsd-hooks.dsh.json)."
          echo "         manual fix — append/replace in $pdir/cordis.patch.yml:"
          echo "           - insert:"
          echo "               - id: gsd-hooks-bridge"
          echo "                 name: '@deepseek-ai/dsh-hooks-claude-code'"
          echo "                 config:"
          echo "                   configPath: '$DSH_HOME/gsd-hooks.dsh.json'"
          echo "                   pluginRoot: '$DSH_HOME'"
        fi
      else
        note "dsh CLI not on PATH — skipped merged-config check ($pname)."
        note "restart DSH, then verify: dsh --profile $pname --dump-config | grep gsd-hooks-bridge"
      fi
      if ! (cd "$pdir" && node -e "require('@deepseek-ai/dsh-hooks-claude-code')" >/dev/null 2>&1); then
        echo "WARNING: @deepseek-ai/dsh-hooks-claude-code does not import from profile '$pname'"
        echo "         (usually a stale hoisted @deepseek-ai/dsh-hook-protocol)."
        echo "         fix: dsh plugin --profile $pname add --save-exact"
        echo "              @deepseek-ai/dsh-hooks-claude-code@<DSH-version>"
        echo "              @deepseek-ai/dsh-hook-protocol@<DSH-version>"
      fi
    done
  fi
fi

if [ "$FIX_REPO" = 1 ]; then
  if [ -d "$PWD/gsd-core/bin" ] && [ -d "$PWD/.git" ]; then
    cp -R "$DSH_HOME/gsd-core/bin/." "$PWD/gsd-core/bin/"
    git -C "$PWD" checkout -- gsd-core/bin >/dev/null 2>&1 || true
    note "refreshed in-repo build outputs under $PWD/gsd-core/bin (tracked files restored to HEAD)"
  else
    note "--fix-repo requested but no gsd-core checkout at $PWD — skipped"
  fi
fi

if [ "$NPM_BIN" = 1 ]; then
  banner "npm global bin (gsd_run / gsd-tools / gsd-mcp-server)"
  if npm install -g "@opengsd/gsd-core@$GSD_VERSION"; then
    if ! command -v gsd_run >/dev/null; then
      PREFIX="$(npm config get prefix 2>/dev/null || true)"
      note "WARNING: gsd_run not on PATH — add it: export PATH=\"${PREFIX:-<npm-prefix>}/bin:\$PATH\""
    fi
  else
    note "WARNING: 'npm i -g' failed (npm prefix not writable?) — the payload engine"
    note "is installed regardless; call it with:"
    note "  node $DSH_HOME/gsd-core/bin/gsd-tools.cjs"
    note "  (or fix your npm prefix, then: npm i -g @opengsd/gsd-core@$GSD_VERSION)"
  fi
else
  note "(skip) for gsd_run on PATH run: npm i -g @opengsd/gsd-core@$GSD_VERSION"
fi

IDENT="$(node "$DSH_HOME/gsd-core/bin/gsd-tools.cjs" runtime-identity --raw 2>/dev/null | head -c 120 || true)"
note "payload check: ${IDENT:-FAILED — see errors above}"
rm -rf "$STAGING" "$WORK"
echo ""
echo "DONE ($GSD_VERSION -> $DSH_HOME)."
echo "  - 技能目录应列出全部 gsd-* 技能;输入 /gsd-new-project 或 /gsd-onboard 开始。"
if [ "$WITH_PATCH" = 1 ]; then
  if [ "$HOOKS_OK" = 1 ]; then
    echo "  - 钩子桥:已写入每个 profile 的 cordis.patch.yml,并通过 --dump-config 验证"
    echo "    (gsd-hooks-bridge)。重启 DSH 后守卫生效。"
  else
    echo "  - 钩子桥:未生效!守卫此刻静默关闭——按上方 WARNING 修复,或重跑本脚本后再重启 DSH。"
  fi
fi