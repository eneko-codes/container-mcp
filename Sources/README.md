# Sources

| Target | Role |
|---|---|
| `ContainerMCPCore` | Everything that decides: configuration loading, path resolution, the `Policy` rules, the audit log, tool schemas and the `ToolDispatcher` that runs each call through the policy. It knows the container service only through the `ContainerBackend` protocol. |
| `ContainerMCPNative` | `NativeBackend`, the only `ContainerBackend` used in production. It calls apple/container's client library and adapts the CLI's run, exec, build and system-start procedures without their terminal parts. |
| `container-mcp` | The executable: protects stdout for MCP, clears its environment, loads the configuration and serves the tools over stdio. |
| `container-mcp-probe` | A development MCP client that starts the server and drives every tool. |
