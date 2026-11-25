import ContainerMCPCore
import ContainerMCPNative
import Darwin
import Foundation

// MCP speaks on stdout. Keep a private copy of the real stdout for the protocol, then point
// file descriptor 1 at stderr, so that a print() anywhere in a library lands in the
// diagnostics instead of corrupting the protocol stream.
let protocolOutput = dup(STDOUT_FILENO)
guard protocolOutput >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
    FileHandle.standardError.write(Data("container-mcp: cannot set up the protocol stream\n".utf8))
    exit(1)
}
_ = fcntl(protocolOutput, F_SETFD, FD_CLOEXEC)

// The client's environment must never reach a container or the service.
HostEnvironment.scrub()

let paths = ServerPaths.forCurrentUser()
// The desktop extension passes the user's settings as launch arguments; read them before anything else.
let configurationState = ConfigurationLoader.load(arguments: Array(CommandLine.arguments.dropFirst()))
switch configurationState {
case .loaded:
    FileHandle.standardError.write(Data("container-mcp: policy loaded from the extension settings\n".utf8))
case .missing:
    FileHandle.standardError.write(Data("container-mcp: started without policy settings; only read tools work\n".utf8))
case .writeToolsDisabled:
    FileHandle.standardError.write(Data("container-mcp: write tools are off in the extension settings; only read tools work\n".utf8))
case .invalid(let problem):
    FileHandle.standardError.write(Data("container-mcp: invalid extension settings (\(problem)); only read tools work\n".utf8))
}

let dispatcher = ToolDispatcher(
    backend: NativeBackend(), configurationState: configurationState, paths: paths,
    audit: AuditLog(path: paths.auditFile), ownedImages: OwnedImages(path: paths.stateFile))

let writer = ProtocolWriter(fileDescriptor: protocolOutput)
await serve(
    lines: FileHandle.standardInput.bytes.lines,
    handler: ContainerMCPServer.handler(tools: ContainerTools(dispatcher: dispatcher, write: writer.write)),
    write: writer.write)
