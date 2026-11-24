# Builds the server in release mode and puts it where the plugin's MCP entry starts it.
.PHONY: plugin test
plugin:
	swift build -c release --product container-mcp
	mkdir -p plugin/server
	cp .build/release/container-mcp plugin/server/container-mcp

test:
	swift test
