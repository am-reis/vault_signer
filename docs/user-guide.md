---
title: User Guide
---

# VaultSigner — a guide for using it

This guide is for people *using* VaultSigner, not building it. It won't explain how the encryption works or what FIDO2 is — you don't need to know that to use this safely. It just tells you what to do, and what happens when you do it.

If a screen mentioned here looks slightly different on your device, that's expected — the steps are the same across Mac, Windows, Android, iPhone/iPad, and Linux, even where the exact button names differ a little.

---

## The one idea worth understanding: two locks, not one

VaultSigner protects things in two separate layers:

1. **Your vault password** unlocks the *list* of your keys — their names, what they're for, when you made them. Think of it like the password on a filing cabinet: it tells you what folders are inside, but not what's written on the pages.
2. **Each key's own passphrase** unlocks that specific key so it can actually be used to sign in somewhere or sign something.

That means knowing your vault password alone is never enough to use any key — you (or whoever borrowed your laptop) would still need that key's own passphrase too. This is deliberate, and it's why VaultSigner sometimes asks you for a passphrase twice in different places. It's not a bug or a repeat question — they're two different locks.

---

## Getting started: your first vault

The first time you open VaultSigner, you'll choose to **Create a New Vault** or **Open an Existing Vault** (if you already have a vault file from another device).

Creating one asks for:
- **A label** — just a name for this set of keys, like "Personal" or "Work."
- **A location to save the vault file.**
- **A master passphrase** — this is the vault password described above. Make it something you'll remember; there is no way to reset it (more on that below).

That's it — your vault is created empty, ready for you to add keys to it.

**You won't be asked where it is again.** VaultSigner remembers every vault you create or open, and shows them under **Recent Vaults** on that same opening screen — click one to unlock it directly, no browsing to the file again. If you use more than one vault (say, a personal one and a work one), switch between them with **Close This Vault** in Settings, which takes you back to that same list without quitting the app.

If a listed vault shows a warning triangle, its file couldn't be found where VaultSigner last saw it — it may have moved or been deleted. Use **Manage Known Vaults…** (from either the opening screen or Settings) to add a vault you keep somewhere without opening it right away, or to **Forget** an entry you no longer want listed. Forgetting only removes it from this list — it never touches or deletes the actual file.

---

## Adding a key

From your key list, choose **New Key**. You'll fill in:
- **A label** — what this key is for ("GitHub login," "Work email").
- Optionally, a **description** and the **website or service** it's for, just to help you find it later.
- **A key passphrase.** This is the *key's own* passphrase — separate from your vault password (see "two locks" above). You'll need to type this again any time you want to sign in with this key, sign something with it, or view its raw contents.

You can leave the key type on its default setting unless you have a specific reason to change it.

---

## Using a key day to day

Once a key exists, you don't usually go looking for it — it comes to you:

- **Signing in somewhere with a passkey:** your browser or an app will show its own "choose a passkey" prompt, and VaultSigner will be offered as an option. Pick it, and VaultSigner will ask for that key's passphrase (unless you've used it recently — see "staying unlocked" below), then hand back a signed response. You never see or copy anything yourself.
- **An app asking VaultSigner to sign something directly:** some apps that aren't websites can also ask VaultSigner to sign on their behalf. VaultSigner will always show you which app is asking and which key it wants, before asking for that key's passphrase. If you don't recognize the app or didn't expect the request, decline it.

**Staying unlocked for a little while:** after you type a key's passphrase once, VaultSigner keeps that key ready to use for a short time (up to five minutes, and you can set it shorter) so you're not retyping it for every single action in a row. After that time, or as soon as you lock your vault, it's forgotten again.

---

## Viewing a key's raw contents ("Reveal Raw Key")

Every key has a "Reveal Raw Key" option in its details. **Treat this as a genuine danger zone, not a curiosity.** Anyone who sees what this reveals can act as that key, anywhere, without needing your device or your passphrase again. VaultSigner won't copy it to your clipboard automatically, on purpose — so a pasted copy sitting in some other app's history can't quietly leak it later. Only use this if you specifically need to move a key's raw material somewhere yourself, and know what you're going to do with it.

---

## Sending a key to another device, or backing up

VaultSigner calls this "export" and "import." A few things worth knowing before you use it:

**Sending a single key** ("Export This Key") makes a small file containing just that one key, still protected by its own passphrase. Send the file however you like; the recipient will still need that key's passphrase to use it.

**Sending several keys at once, or backing up your whole vault**, gives you a choice of three ways to protect the file you're creating:

| Choice | What it means in practice |
|---|---|
| **Just package the keys as-is** | Fastest, but the *labels and descriptions* of the keys travel unprotected inside the file — anyone who gets hold of the file can see what each key is for (just not use the keys themselves, since those still need their own passphrases). Only choose this if you trust wherever the file is going. |
| **Protect it for the other vault's password** | Only someone who already knows the master password of the vault you're sending it to can open it. Use this if you're moving keys to a vault whose password you personally know. |
| **Protect it with a one-time password** | You set a brand-new, one-time password just for this file, then tell the recipient that password some other way (a phone call, a different app) — never in the same message as the file itself. This is the safest general-purpose choice, and the recommended one for backups you're storing somewhere like cloud storage. |

**Backing up "master key only"** is a narrower option for people who like to keep a small recovery file somewhere separate (like a printed QR code in a safe). On its own, this backup does not protect your actual keys — you'd still need your regular key files too. Don't rely on it alone.

### Bringing in someone else's keys

When you import a file, VaultSigner checks whether it came with its *own* vault password attached (this happens when the sender chose to include it — most single-key or select-keys exports won't). If it did, VaultSigner will stop and ask you to choose, before anything is added to your vault:

- **Use my existing vault password for these new keys too** (the usual choice) — your imported keys join your current vault, and you'll keep using the password you already know. The other vault's password is discarded and never kept.
- **Keep them completely separate** — the imported keys form their own separate section of your vault, with their own separate password. Nothing from your existing keys is touched.
- **Replace my current password with theirs** — the more drastic option: your entire vault, including keys you didn't just import, switches to the *other* vault's password. Only choose this if you're sure, and you'll be asked to type a confirmation phrase before it happens.

If a key you're importing turns out to be a duplicate of one you already have, VaultSigner keeps both rather than silently overwriting anything — the imported copy is just labeled so you can tell them apart.

---

## Settings: starting automatically, and auto-unlock

Two separate switches, each with a real tradeoff:

- **Start VaultSigner automatically** — so it's ready to answer sign-in requests even when you haven't opened the app yourself. This is on by default, and is what most people want.
- **Auto-unlock on startup** — off by default, and worth thinking about before turning on. Normally, your vault stays locked (showing nothing but a password prompt) until you type your master password. Turning this on stores that password on your device so the vault unlocks itself automatically. That's convenient, but it does mean your device itself now holds a way to unlock your vault without you — so it's only as safe as your device's own login security. It does **not** expose your individual keys; those still need their own passphrases regardless of this setting.

---

## If you forget a password

There is no "forgot password" recovery for either your vault password or a key's passphrase — that is what makes them meaningful protection in the first place. If you forget your vault password, you lose access to that vault's key list (though the underlying keys, if you remember their own passphrases and still have the vault file, aren't destroyed). If you forget a specific key's passphrase, that key cannot be used or recovered.

The practical takeaway: **write your master password down somewhere safe when you create a vault**, and consider using the "master key only" backup (above) as an extra safety net — but remember that backup alone still isn't enough on its own.

---

## A note for iPhone/iPad users

Because of how iOS works, VaultSigner can't sit in the background waiting for other apps to ask it to sign something the way it can on a computer. Instead, an app has to specifically support "asking VaultSigner" before that hand-off works at all — so on iOS, only apps that have added that support will be able to use your VaultSigner keys directly (regular website sign-ins with passkeys still work normally). This isn't a bug; it's a genuine limit of what iOS allows.
