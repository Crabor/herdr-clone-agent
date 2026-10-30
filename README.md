# Clone Agent (herdr-clone-agent)

Clone the coding agent of a Herdr pane into a new sibling pane — like "split", but the new pane resumes a **fork/copy of the source agent's session** instead of an empty shell.

The plugin auto-detects which agent occupies the source pane via Herdr's agent state and calls that agent's own clone mechanism:

| Agent | Clone command | Status |
|---|---|---|
| [pi](https://github.com/earendil-works/pi) | `pi --fork <session>` | ✅ tested |
| Claude Code | `claude --resume <id> --fork-session` | ✅ wired, community-tested welcome |
| others (codex, gemini, …) | rejected with a clear error | only resume semantics exist today; two live panes sharing one session would fight, so cloning is intentionally unsupported until the agent ships a fork |

![demo](docs/demo.mp4)

## Requirements

- Herdr ≥ 0.9.2 (uses `herdr agent get` session references and plugin actions)
- `jq` on PATH
- The cloned agent CLI (`pi` / `claude`) installed

## Install

```bash
herdr plugin install Crabor/herdr-clone-agent
```

Or for local development:

```bash
git clone https://github.com/Crabor/herdr-clone-agent.git && herdr plugin link ./herdr-clone-agent
```

## Usage

### Keybindings (recommended)

Add to `~/.config/herdr/config.toml`, then `herdr server reload-config`:

```toml
[[keys.command]]
key = "prefix+shift+v"          # mirrors split_vertical (prefix+v)
type = "plugin_action"
command = "herdr-clone-agent.clone-right"
description = "clone agent to right pane"

[[keys.command]]
key = "prefix+shift+j"          # vim j = down
type = "plugin_action"
command = "herdr-clone-agent.clone-down"
description = "clone agent to down pane"
```

With the default prefix: `ctrl+b` `shift+v` clones right, `ctrl+b` `shift+j` clones down.

> Avoid `alt+<arrow>` and `shift+minus` bindings: many terminals do not deliver them reliably. `shift+<letter>` and function keys are the dependable choices.

### CLI

```bash
herdr plugin action invoke herdr-clone-agent.clone-right
herdr plugin action invoke herdr-clone-agent.clone-down
```

The source pane is the focused pane (or the pane you invoked from, when the action surfaces in a pane context menu).

## How it works

1. Resolve the source pane from the invocation context (`HERDR_PANE_ID` → `HERDR_ACTIVE_PANE_ID` → `HERDR_PLUGIN_CONTEXT_JSON.focused_pane_id`).
2. `herdr agent get <pane>` → agent kind + `agent_session` reference (`path` or `id`).
3. Dispatch to the kind's clone argv (see table above); unsupported kinds exit with an error before touching any layout.
4. `herdr pane split <src> --direction <dir> --cwd <src-cwd> --no-focus` (same project, focus stays put).
5. `herdr agent start <kind>-c<rand> --kind <kind> --pane <new> -- <clone-argv>`, so the clone is a first-class named Herdr agent you can `agent prompt` / `agent read`.

The clone contains all history flushed to the source session file at invoke time; both sides then continue independently as separate sessions.

## Notes

- If `agent start` cannot confirm readiness (e.g. the agent shows an unfamiliar startup dialog), the new pane is kept and inspect commands are printed — the script never auto-closes panes.
- Agent names are randomized (`pi-c1a2b`) and checked for uniqueness among live agents.
- Only `right` / `down` directions are supported, matching `herdr pane split`.

## License

MIT
