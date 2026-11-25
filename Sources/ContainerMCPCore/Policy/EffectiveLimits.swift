import Foundation

/// What the tools enforce, which is the user's setting held to what a result and a call
/// may be. A setting above these still saves, and acts as the value here; the manifest's
/// descriptions of the settings say so.
extension Configuration {

    public var effectiveLogLimits: LogLimits { logs.effective }

    public var effectiveExecLimits: ExecLimits {
        ExecLimits(
            maximumTimeoutSeconds: min(exec.maximumTimeoutSeconds, ToolCatalog.longestOperationSeconds),
            maximumOutputBytes: min(exec.maximumOutputBytes, ToolStandard.longestResult))
    }

    public var effectivePullTimeoutSeconds: Int { min(pullTimeoutSeconds, ToolCatalog.longestOperationSeconds) }

    public var effectiveBuildTimeoutSeconds: Int { min(buildTimeoutSeconds, ToolCatalog.longestOperationSeconds) }
}

extension Configuration.LogLimits {

    /// A line costs at least one byte, so a page of more lines than a result holds
    /// characters cannot exist.
    public var effective: Configuration.LogLimits {
        Configuration.LogLimits(
            maximumLines: min(maximumLines, ToolStandard.longestResult),
            maximumBytes: min(maximumBytes, ToolStandard.longestResult))
    }
}
