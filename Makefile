# Builds the server in release mode and puts it where the plugin's MCP entry starts it.
.PHONY: plugin test
plugin:
	swift build -c release --product container-mcp
	mkdir -p plugin/server
	# Replace the file rather than overwrite it: macOS kills a binary whose signed pages
	# change in place under its cached code signature.
	rm -f plugin/server/container-mcp
	cp .build/release/container-mcp plugin/server/container-mcp

test:
	swift test
