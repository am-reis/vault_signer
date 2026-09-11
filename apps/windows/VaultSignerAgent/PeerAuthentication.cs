using System.IO.Pipes;

namespace VaultSignerAgent;

/// Gates `internal.*` calls to callers that are actually VaultSignerUI —
/// mirrors apps/macos/VaultSignerAgent/Sources/PeerAuthentication.swift's
/// role, but **materially weaker**, and this file says so rather than
/// implying parity.
///
/// macOS's check validates the connecting process's real code signature
/// via `SecCode`/`SecCodeCopySigningInformation` and compares its Team
/// Identifier against the agent's own — a signature-based check that
/// cannot be spoofed by simply naming a process "VaultSigner.app".
/// Building the Windows equivalent (Authenticode-verify the caller's
/// executable, then check the signer's certificate) needs a real code-
/// signing certificate for this project, which does not exist yet (no
/// Windows analogue of macOS's free "Personal Team" ad-hoc signing was
/// set up this session — unlike macOS item 2.7, this hasn't even been
/// checked against a real Microsoft requirement yet, so treat this as
/// unresearched, not "blocked," until someone does that research).
///
/// Until then, this checks two weaker things instead:
/// 1. The named pipe itself is created with a `PipeSecurity` that denies
///    every SID except the current Windows user (see `AgentServer`) —
///    equivalent to a Unix socket's owner-only file permissions, and the
///    actual "never accept a non-loopback/non-local caller" boundary
///    spec §7 requires. This part is as strong as macOS's socket-level
///    boundary.
/// 2. The caller's resolved executable path (`PeerIdentity`) must match
///    VaultSignerUI's real, on-disk install location next to this agent.
///    This stops an *arbitrary* other process from calling `internal.*`
///    by accident, but not a deliberately malicious co-resident process
///    that can write to the same directory or that copies itself to that
///    exact path — a real gap a signature check would close. Documented
///    here rather than silently accepted.
///
/// `#if DEBUG` bypass below mirrors PeerAuthentication.swift's own exact
/// pattern, for the same reason: the path check assumes a real packaged
/// install (agent and UI shipped side by side), which isn't how a dev
/// build works at all — each project builds to its own separate `bin/`
/// folder, never colocated. Hit for real: a Debug UI build was rejected
/// with `unauthorized_caller` until this bypass existed. Enforced fully
/// in Release, same as macOS.
internal static class PeerAuthentication
{
    /// Full path to the installed `VaultSignerUI.exe`, next to this
    /// agent's own executable — both ship in the same install directory,
    /// mirroring `VaultSigner.app` embedding `VaultSignerAgent.app`
    /// alongside it on macOS.
    private static string ExpectedUiPath =>
        Path.Combine(AppContext.BaseDirectory, "VaultSignerUI.exe");

    public static bool CallerIsVaultSignerUi(PipeStream pipe)
    {
#if DEBUG
        return true;
#else
        var callerPath = PeerIdentity.CallerExecutablePath(pipe);
        if (callerPath is null) return false;
        return string.Equals(
            Path.GetFullPath(callerPath),
            Path.GetFullPath(ExpectedUiPath),
            StringComparison.OrdinalIgnoreCase);
#endif
    }
}
