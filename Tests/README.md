# Tests

- `ContainerMCPCoreTests`: the policy and the tool surface against `FakeBackend`, which records every call that reaches it. Files are grouped by the numbered limits in the top-level README. `MCPProtocolTests` covers the MCP layer copied unchanged from the owner's other servers, and `ProgressNotificationTests` the progress notifications as a client receives them. Run with `swift test`.
- `ContainerMCPIntegrationTests`: one live test that calls every tool against the real container service. It runs only with `CONTAINER_MCP_INTEGRATION=1`, creates only labelled `container-mcp-it-…` resources and removes them.
