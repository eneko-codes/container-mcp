# container-mcp plugin

The Claude plugin for this repository: the container-mcp server, started over stdio, and two
skills.

| Path | Contents |
|---|---|
| `.claude-plugin/plugin.json` | Manifest |
| `.mcp.json` | Starts `${CLAUDE_PLUGIN_ROOT}/server/container-mcp` as the MCP server `container` |
| `server/` | The release binary, built locally and never committed |
| `skills/container-management` | Running and managing containers through the server |
| `skills/container-image-build` | Building an image from a project folder |

The plugin holds no value and no path of the user's: its settings (`userConfig` in the
manifest) are filled in by the user, and `.mcp.json` passes them to the server as launch
arguments. The options are described in the top-level README.

## Install in Claude Code

From the repository root:

```bash
make plugin
claude plugin marketplace add "$PWD"
claude plugin install container-mcp@container-mcp
```

Then set the policy with `/plugin configure container-mcp@container-mcp` in a session and
restart Claude Code. Write tools stay off until **Allow write tools** is on.

`make plugin` builds the server and copies it into `plugin/server/`. The marketplace is
added from a local path, so Claude Code loads the plugin in place from this folder: after
rebuilding, `/reload-plugins` or a new session picks up the new binary. Rerun `make plugin`
after every `git pull`.

The tools appear as `mcp__plugin_container-mcp_container__<tool>`.

## Other Claude apps

Plugins installed from the command line stay on this Mac. In the desktop app's Code tab
they load like in the terminal. For chat and Cowork, the plugin is added to the claude.ai
account through Customize → Plugins (upload a zip of this folder with `server/` built in),
and whether those surfaces start a plugin's local server is to be checked there: the
current documentation says Cowork starts it when the session runs on this Mac and chat does
not.
