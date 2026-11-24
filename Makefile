.PHONY: mcpb plugin-zip test

# The server as a Claude desktop extension. The desktop app runs it on this Mac and relays
# tool calls to it from chat, Cowork and the Code tab; chats run in a Linux VM, where a
# plugin's local server could never reach the container service.
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

# The skills plugin, which carries no server, as a zip for Customize > Plugins > Upload.
plugin-zip:
	mkdir -p dist
	rm -f dist/container-mcp-skills.zip
	cd plugin && zip -qrX ../dist/container-mcp-skills.zip . -x '.DS_Store' '*/.DS_Store'
	@echo "Built dist/container-mcp-skills.zip"

test:
	swift test
