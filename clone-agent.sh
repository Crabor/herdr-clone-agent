#!/usr/bin/env bash
# clone-agent.sh <right|down>
# Clone the agent occupying the source pane into a new sibling pane.
# Source pane resolution order:
#   $HERDR_PANE_ID (plugin/keybinding action context)
#   $HERDR_ACTIVE_PANE_ID (custom shell command context)
#   HERDR_PLUGIN_CONTEXT_JSON .focused_pane_id
# Agent kind + session come from `herdr agent get`, then a per-kind dispatch
# builds the clone argv (pi --fork / claude --resume --fork-session).
set -euo pipefail

err() { printf 'clone-agent: %s\n' "$*" >&2; exit 1; }

DIR="${1:-right}"
case "$DIR" in right|down) ;; *) err "direction must be right|down" ;; esac

HERDR="${HERDR_BIN_PATH:-herdr}"
command -v jq >/dev/null || err "jq not found in PATH"

SRC="${HERDR_PANE_ID:-${HERDR_ACTIVE_PANE_ID:-}}"
if [[ -z "$SRC" && -n "${HERDR_PLUGIN_CONTEXT_JSON:-}" ]]; then
  SRC="$(jq -r '.focused_pane_id // empty' <<<"$HERDR_PLUGIN_CONTEXT_JSON")"
fi
[[ -n "$SRC" ]] || err "no source pane in invocation context"

AGENT_JSON="$("$HERDR" agent get "$SRC")" \
  || err "pane $SRC has no recognized agent (nothing to clone)"
KIND="$(jq -r '.result.agent.agent // empty' <<<"$AGENT_JSON")"
SESS_KIND="$(jq -r '.result.agent.agent_session.kind // empty' <<<"$AGENT_JSON")"
SESS_VAL="$(jq -r '.result.agent.agent_session.value // empty' <<<"$AGENT_JSON")"
SRC_CWD="$(jq -r '.result.agent.cwd // empty' <<<"$AGENT_JSON")"
[[ -n "$KIND" && -n "$SESS_VAL" ]] || err "pane $SRC agent '$KIND' reports no session reference"

# Per-kind clone dispatch. Only include kinds with true fork/clone semantics;
# a plain resume would make two live panes share one session.
case "$KIND:$SESS_KIND" in
  pi:path|pi:id)   CLONE_ARGS=(--fork "$SESS_VAL") ;;
  claude:id|claude:path) CLONE_ARGS=(--resume "$SESS_VAL" --fork-session) ;;
  *) err "agent '$KIND' (session kind '$SESS_KIND') has no supported clone command yet; supported: pi, claude" ;;
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
