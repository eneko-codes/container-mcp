import Darwin
import Foundation

/// The server's own environment comes from the MCP client and may hold secrets. Parts of the
/// container library read the process environment directly (`SSH_AUTH_SOCK`, `BUILDKIT_COLORS`,
/// `NO_COLOR`, key-only `--env`), so at startup the server removes every variable it does not
/// need. Nothing the library reads later can then reach a container or a service.
public enum HostEnvironment {
    /// Variables Foundation and the system frameworks need to find the user's folders.
    public static let kept: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "PATH"]

    public static func scrub() {
        for name in namesToRemove(from: currentNames()) {
            unsetenv(name)
        }
        // A client-supplied PATH could point at anything; the server only ever runs /bin/launchctl.
        setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin", 1)
    }

    static func namesToRemove(from names: [String]) -> [String] {
        names.filter { !kept.contains($0) }
    }

    static func currentNames() -> [String] {
        var names: [String] = []
        var pointer = environ
        while let entry = pointer.pointee {
            let text = String(cString: entry)
            if let equals = text.firstIndex(of: "=") { names.append(String(text[..<equals])) }
            pointer += 1
        }
        return names
    }
}
