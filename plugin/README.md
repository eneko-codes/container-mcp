# container-mcp skills plugin

The two skills for working with container-mcp, packaged as a Claude plugin with no server.
The server itself ships separately as the **Apple container** desktop extension
(`make mcpb` at the repository root), which the desktop app runs on this Mac for chat,
Cowork and the Code tab.

| Path | Contents |
|---|---|
| `.claude-plugin/plugin.json` | Manifest ("Apple container skills") |
| `skills/container-management` | Running and managing containers through the server's tools |
| `skills/container-image-build` | Building an image from a project folder |

## Install

- Claude app: `make plugin-zip` at the repository root, then Customize → Plugins → Upload
  `dist/container-mcp-skills.zip`.
- Claude Code in a terminal: `claude plugin marketplace add <repository folder>`, then
  `claude plugin install container-mcp@container-mcp`.

Without the extension the skills still load, but there are no container tools for them to use.
