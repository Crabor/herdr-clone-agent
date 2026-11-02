#!/usr/bin/env bash
# clone-agent.sh <right|down>
# Clone the agent occupying the source pane into a new sibling pane.
# Source pane resolution order:
#   $HERDR_PANE_ID (plugin/keybinding action context)
#   $HERDR_ACTIVE_PANE_ID (custom shell command context)
#   HERDR_PLUGIN_CONTEXT_JSON .focused_pane_id
#   auto-detect via herdr pane list (fallback for stale env vars)
# Agent kind + session come from `herdr agent get`, then a per-kind dispatch
# builds the clone argv (pi --fork / claude --resume --fork-session / codex fork).
set -euo pipefail

err() { printf 'clone-agent: %s\n' "$*" >&2; exit 1; }

DIR="${1:-right}"
case "$DIR" in right|down) ;; *) err "direction must be right|down" ;; esac

HERDR="${HERDR_BIN_PATH:-herdr}"
command -v jq >/dev/null || err "jq not found in PATH"

# --- Resolve source pane ID with staleness detection ---
validate_pane() {
  local pid="$1"
  [[ -n "$pid" ]] || return 1
  "$HERDR" pane get "$pid" >/dev/null 2>&1
}

SRC="${HERDR_PANE_ID:-${HERDR_ACTIVE_PANE_ID:-}}"
if [[ -z "$SRC" && -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ]]; then
  SRC="$(jq -r '.focused_pane_id // empty' <<<"$HERDR_PLUGIN_CONTEXT_JSON")"
fi

if ! validate_pane "$SRC"; then
  PANE_LIST="$("$HERDR" pane list 2>/dev/null)" || true
  _detect_kind=""
  if [[ -n "${PI_SESSION_FILE:-}" ]]; then _detect_kind="pi"
  elif [[ -n "${CODEX_THREAD_ID:-}" ]]; then _detect_kind="codex"
  elif [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then _detect_kind="claude"
  fi

  if [[ -n "$_detect_kind" && -n "$PANE_LIST" ]]; then
    SRC="$(jq -r --arg kind "$_detect_kind" '
      [.result.panes[] | select(.agent == $kind)] |
      sort_by(if .agent_status == "working" then 0 else 1 end) |
      last | .pane_id // empty
    ' <<<"$PANE_LIST" 2>/dev/null)" || true
  fi

  validate_pane "$SRC" || err "cannot locate current pane (env says ${HERDR_PANE_ID:-unset}, auto-detection failed)"
fi

AGENT_JSON="$("$HERDR" agent get "$SRC")" \
  || err "pane $SRC has no recognized agent (nothing to clone)"
KIND="$(jq -r '.result.agent.agent // empty' <<<"$AGENT_JSON")"
SESS_KIND="$(jq -r '.result.agent.agent_session.kind // empty' <<<"$AGENT_JSON")"
SESS_VAL="$(jq -r '.result.agent.agent_session.value // empty' <<<"$AGENT_JSON")"
SRC_CWD="$(jq -r '.result.agent.cwd // empty' <<<"$AGENT_JSON")"
[[ -n "$KIND" ]] || err "pane $SRC has no recognized agent (nothing to clone)"

# --- Codex session recovery ---
# herdr does not track codex agent_session. Recovery chain:
#   1. agent_session from herdr (usually null for codex)
#   2. /proc/<pid>/environ CODEX_THREAD_ID
#   3. $CODEX_THREAD_ID env var (only available inside codex's own shell)
#   4. ~/.codex/history.jsonl most recent session_id
#   5. codex fork --last (let codex CLI resolve it)
if [[ "$KIND" == "codex" && -z "$SESS_VAL" ]]; then
  # Try /proc/<pid>/environ
  FG_PID="$(jq -r '.result.process_info.foreground_processes[0].pid // empty' \
    <<<"$("$HERDR" pane process-info --pane "$SRC" 2>/dev/null)")"
  if [[ -n "$FG_PID" && -r "/proc/$FG_PID/environ" ]]; then
    SESS_VAL="$(tr '\0' '\n' < "/proc/$FG_PID/environ" \
      | sed -n 's/^CODEX_THREAD_ID=//p' | head -1)"
    SESS_KIND="id"
  fi

  # Try $CODEX_THREAD_ID from calling shell environment
  if [[ -z "$SESS_VAL" && -n "${CODEX_THREAD_ID:-}" ]]; then
    SESS_VAL="$CODEX_THREAD_ID"
    SESS_KIND="id"
  fi

  # Try ~/.codex/history.jsonl — most recent session_id
  if [[ -z "$SESS_VAL" ]]; then
    CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"
    HIST_FILE="$CODEX_HOME/history.jsonl"
    if [[ -r "$HIST_FILE" ]]; then
      SESS_VAL="$(tail -1 "$HIST_FILE" 2>/dev/null \
        | jq -r '.session_id // empty' 2>/dev/null)" || true
      SESS_KIND="id"
    fi
  fi

  # Final fallback: use --last flag and let codex CLI pick
  if [[ -z "$SESS_VAL" ]]; then
    SESS_VAL="--last"
    SESS_KIND="flag"
  fi
fi

[[ -n "$SESS_VAL" ]] || err "pane $SRC agent '$KIND' reports no session reference"

# Per-kind clone dispatch
case "$KIND:${SESS_KIND:-unknown}" in
  pi:path|pi:id)           CLONE_ARGS=(--fork "$SESS_VAL") ;;
  claude:id|claude:path)   CLONE_ARGS=(--resume "$SESS_VAL" --fork-session) ;;
  codex:id|codex:path)     CLONE_ARGS=(fork "$SESS_VAL") ;;
  codex:flag)              CLONE_ARGS=(fork "$SESS_VAL") ;;  # --last
  codex:unknown)           CLONE_ARGS=(fork --last) ;;
  *) err "agent '$KIND' (session kind '${SESS_KIND:-unknown}') has no supported clone command yet; supported: pi, claude, codex" ;;
esac

# Unique agent name among live agents
live_names() { "$HERDR" agent list | jq -r '.result.agents[]?.name // empty'; }
NAME=""
for _ in 1 2 3 4 5; do
  cand="${KIND}-c$(head -c2 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  if ! live_names | grep -qx "$cand"; then NAME="$cand"; break; fi
done
[[ -n "$NAME" ]] || err "could not allocate a unique agent name"

SPLIT_JSON="$("$HERDR" pane split "$SRC" --direction "$DIR" --cwd "${SRC_CWD:-$PWD}" --no-focus)" \
  || err "herdr pane split failed"
PANE_ID="$(jq -r '.result.pane.pane_id // empty' <<<"$SPLIT_JSON")"
[[ -n "$PANE_ID" ]] || err "could not parse pane_id from split response"

if ! "$HERDR" agent start "$NAME" --kind "$KIND" --pane "$PANE_ID" -- "${CLONE_ARGS[@]}"; then
  printf 'clone-agent: agent start not confirmed ready; pane %s kept. Inspect:\n' "$PANE_ID" >&2
  printf '  herdr agent get %s && herdr agent read %s --source recent-unwrapped --lines 60\n' "$PANE_ID" "$PANE_ID" >&2
  exit 1
fi

jq -n --arg pane "$PANE_ID" --arg name "$NAME" --arg dir "$DIR" \
      --arg kind "$KIND" --arg src "$SRC" --arg sess "$SESS_VAL" \
  '{pane: $pane, agent: $name, direction: $dir, kind: $kind, source_pane: $src, cloned_session: $sess}'
