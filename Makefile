# Builds the server in release mode and puts it where the plugin's MCP entry starts it.
.PHONY: plugin plugin-zip mcpb test
plugin:
	swift build -c release --product container-mcp
	mkdir -p plugin/server
	# Replace the file rather than overwrite it: macOS kills a binary whose signed pages
	# change in place under its cached code signature.
	rm -f plugin/server/container-mcp
	cp .build/release/container-mcp plugin/server/container-mcp

test:
	swift test

# The plugin folder with its built server, as a zip for Customize > Plugins > Upload plugin.
plugin-zip: plugin
	mkdir -p dist
	rm -f dist/container-mcp-plugin.zip
	cd plugin && zip -qr -X ../dist/container-mcp-plugin.zip . -x '.DS_Store' '*/.DS_Store'

# The same server as a Claude desktop extension: chat runs on Anthropic's servers and cannot
# start a plugin's program on this Mac, but the desktop app runs an extension locally and
# relays chat's tool calls to it.
mcpb:
	swift build -c release --product container-mcp
	rm -rf extension/server
	mkdir -p extension/server dist
	cp .build/release/container-mcp extension/server/container-mcp
	chmod +x extension/server/container-mcp
	rm -f dist/container-mcp.mcpb
	cd extension && zip -qrX ../dist/container-mcp.mcpb manifest.json server
	unzip -Z dist/container-mcp.mcpb server/container-mcp | awk 'NR==1 && $$1 !~ /x/ { print "executable bit lost"; exit 1 }'
	@echo "Built dist/container-mcp.mcpb"
