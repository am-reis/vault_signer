using VaultSigner.Core;

namespace VaultSignerAgent;

/// VaultSignerAgent entry point. See `AgentServer`'s doc comment for why
/// this is a per-user background process (started at logon, in the
/// interactive session) rather than an SCM-managed Windows Service —
/// mirrors apps/macos/VaultSignerAgent/Sources/main.swift's role and
/// startup sequence exactly:
///
/// 1. `--vault &lt;path&gt;` is for direct/manual testing (see
///    `uniffi-verify/`); the real logon-started agent has no arguments,
///    so it reads `VaultConfig` instead.
/// 2. If a vault is configured, open it, then attempt auto-unlock
///    (`DpapiAutoUnlockStore`) for whichever compartment (if any) has it
///    enabled — a `vaultsigner.list_public_keys` call works immediately
///    after logon with no human present, same as macOS.
/// 3. Start `AgentServer`'s named pipe, then block forever — this
///    process has no window of its own; `WinFormsPassphrasePrompter`
///    creates its own dialog on demand.
internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        string? vaultPath = null;
        var vaultFlagIndex = Array.IndexOf(args, "--vault");
        if (vaultFlagIndex >= 0 && args.Length > vaultFlagIndex + 1)
        {
            vaultPath = args[vaultFlagIndex + 1];
        }
        else
        {
            vaultPath = VaultConfig.LoadVaultPath();
        }

        Vault? vault = null;
        if (vaultPath is not null)
        {
            try
            {
                vault = Vault.Open(vaultPath);
                var autoUnlockCompartmentId = VaultConfig.LoadAutoUnlockCompartmentId();
                if (autoUnlockCompartmentId is not null &&
                    DpapiAutoUnlockStore.Load(autoUnlockCompartmentId) is { } passphrase)
                {
                    try
                    {
                        vault.UnlockCompartment(autoUnlockCompartmentId, passphrase);
                        Console.WriteLine($"VaultSignerAgent: auto-unlocked compartment {autoUnlockCompartmentId}");
                    }
                    catch (VaultException e)
                    {
                        Console.Error.WriteLine($"VaultSignerAgent: auto-unlock failed for {autoUnlockCompartmentId}: {e.Message}");
                    }
                }
            }
            catch (VaultException e)
            {
                // Stay alive regardless — internal.open_vault/internal.create_vault
                // can still recover from a missing/corrupt configured path.
                Console.Error.WriteLine($"VaultSignerAgent: failed to open configured vault at {vaultPath}: {e.Message}");
            }
        }

        var server = new AgentServer(vault);
        server.Start();

        Console.WriteLine("VaultSignerAgent: listening on named pipe VaultSignerAgent");

        // No window, no message loop needed for this process itself
        // (WinFormsPassphrasePrompter runs its own dedicated STA thread
        // with its own modal loop per prompt) — just block forever.
        Thread.Sleep(Timeout.Infinite);
    }
}
