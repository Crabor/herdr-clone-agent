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
# HERDR_PANE_ID can become stale when an agent is migrated to a new pane.
# We validate the candidate and fall back to searching the pane list.
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
  # Candidate is empty or stale. Search pane list for the real source pane.
  PANE_LIST="$("$HERDR" pane list 2>/dev/null)" || true

  # Detect agent kind from environment for targeted search
  _detect_kind=""
  if [[ -n "${PI_SESSION_FILE:-}" ]]; then
    _detect_kind="pi"
  elif [[ -n "${CODEX_THREAD_ID:-}" ]]; then
    _detect_kind="codex"
  elif [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
    _detect_kind="claude"
  fi

  if [[ -n "$_detect_kind" && -n "$PANE_LIST" ]]; then
    # Prefer "working" panes (active session) over "idle" ones.
    # Sort: working first, then take last match (most recently created).
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
# Codex does not always report agent_session to herdr (returns null), and the
# node process may not expose CODEX_THREAD_ID in /proc/<pid>/environ.
# Recovery chain: agent_session → /proc environ → $CODEX_THREAD_ID env var.
if [[ "$KIND" == "codex" && -z "$SESS_VAL" ]]; then
  # Try /proc/<pid>/environ first
  FG_PID="$(jq -r '.result.process_info.foreground_processes[0].pid // empty' \
    <<<"$("$HERDR" pane process-info --pane "$SRC" 2>/dev/null)")"
  if [[ -n "$FG_PID" && -r "/proc/$FG_PID/environ" ]]; then
    SESS_VAL="$(tr '\0' '\n' < "/proc/$FG_PID/environ" \
      | sed -n 's/^CODEX_THREAD_ID=//p' | head -1)"
    SESS_KIND="id"
  fi

  # Final fallback: $CODEX_THREAD_ID from the calling shell environment.
  # This works when clone-to is invoked from within the codex agent's own shell.
  if [[ -z "$SESS_VAL" && -n "${CODEX_THREAD_ID:-}" ]]; then
    SESS_VAL="$CODEX_THREAD_ID"
    SESS_KIND="id"
  fi

  [[ -n "$SESS_VAL" ]] || err "codex agent in pane $SRC has no session (checked: agent_session, /proc/${FG_PID:-?}/environ, \$CODEX_THREAD_ID)"
fi

[[ -n "$SESS_VAL" ]] || err "pane $SRC agent '$KIND' reports no session reference"

# Per-kind clone dispatch. Only include kinds with true fork/clone semantics;
# a plain resume would make two live panes share one session.
case "$KIND:${SESS_KIND:-unknown}" in
  pi:path|pi:id)           CLONE_ARGS=(--fork "$SESS_VAL") ;;
  claude:id|claude:path)   CLONE_ARGS=(--resume "$SESS_VAL" --fork-session) ;;
  codex:id|codex:path|codex:unknown) CLONE_ARGS=(fork "$SESS_VAL") ;;
  *) err "agent '$KIND' (session kind '${SESS_KIND:-unknown}') has no supported clone command yet; supported: pi, claude, codex" ;;
esac

# Unique agent name among live agents.
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
