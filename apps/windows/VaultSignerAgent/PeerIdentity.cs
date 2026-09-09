using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;

namespace VaultSignerAgent;

/// Resolves a named-pipe peer's identity via OS-level means (spec §7:
/// "Determine the caller's identity via OS-level means ... never trust a
/// self-reported name in the JSON payload"). Mirrors
/// apps/macos/VaultSignerAgent/Sources/PeerIdentity.swift, using
/// `GetNamedPipeClientProcessId` (the Windows equivalent of macOS's
/// `LOCAL_PEERPID`) instead of a Unix-socket peer-credential call.
internal static class PeerIdentity
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint clientProcessId);

    public static uint? PeerProcessId(PipeStream pipe)
    {
        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var pid)) return null;
        return pid;
    }

    /// Best-effort display name for the passphrase-prompt UI, e.g.
    /// "python.exe wants to sign with a VaultSigner key". Falls back to
    /// a PID-only description rather than throwing: a protected/elevated
    /// caller process can make `Process.MainModule` throw
    /// `Win32Exception` even though the PID itself resolved fine.
    public static string CallerDisplayName(PipeStream pipe)
    {
        var pid = PeerProcessId(pipe);
        if (pid is not uint validPid) return "Unknown app";
        try
        {
            using var process = Process.GetProcessById((int)validPid);
            return process.MainModule?.ModuleName ?? $"Unknown app (pid {validPid})";
        }
        catch
        {
            return $"Unknown app (pid {validPid})";
        }
    }

    /// Best-effort executable path for `PeerAuthentication`'s caller
    /// check. Same fallback behavior as above.
    public static string? CallerExecutablePath(PipeStream pipe)
    {
        var pid = PeerProcessId(pipe);
        if (pid is not uint validPid) return null;
        try
        {
            using var process = Process.GetProcessById((int)validPid);
            return process.MainModule?.FileName;
        }
        catch
        {
            return null;
        }
    }
}
