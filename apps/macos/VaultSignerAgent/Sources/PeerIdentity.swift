import Darwin
import Foundation

/// Resolves a Unix domain socket peer's identity via OS-level means only
/// (spec §7: "Determine the caller's identity via OS-level means (peer
/// credentials on Unix sockets) ... never trust a self-reported name in
/// the JSON payload for this confirmation text"). Uses the macOS-specific
/// `LOCAL_PEERPID` socket option to get the connecting process's PID,
/// then `proc_pidpath` (libproc) to resolve that PID to an executable
/// name for display, e.g. "App 'Foo' wants to sign...".
enum PeerIdentity {
    /// `SOL_LOCAL`/`LOCAL_PEERPID` are macOS's Unix-domain-socket
    /// peer-credential constants (not exposed as named symbols in
    /// Swift's Darwin module), from `<sys/un.h>`.
    private static let SOL_LOCAL: Int32 = 0
    private static let LOCAL_PEERPID: Int32 = 0x002

    static func callerDisplayName(forSocket fd: Int32) -> String {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let result = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)
        guard result == 0, pid > 0 else { return "Unknown app" }

        var pathBuffer = [Int8](repeating: 0, count: Int(4 * 1024))
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        guard pathLen > 0 else { return "Unknown app (pid \(pid))" }
        let fullPath = String(cString: pathBuffer)
        let executableName = (fullPath as NSString).lastPathComponent
        return executableName
    }
}
