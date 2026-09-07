//! Crash-safety chaos test (spec §4.6, §10): kill the writer process
//! mid-write, at a random point, many times over, and verify the
//! container always opens afterward to a single complete version —
//! never a partially-written or unreadable state.
//!
//! `#[ignore]`d by default since it is deliberately slow/nondeterministic
//! by nature (random kill timing); run explicitly with
//! `cargo test --test crash_safety -- --ignored`.

use std::io::{BufRead, BufReader};
use std::process::{Command, Stdio};
use std::time::Duration;

use vaultcore::container::Container;

#[test]
#[ignore]
fn repeated_random_kill_mid_write_never_corrupts_container() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("chaos.vlt");

    // Seed an initial valid container so there is always something on
    // disk before the first kill, matching the real-world case of an
    // existing vault being mutated.
    Container::new().write_atomic(&path).unwrap();

    let writer_bin = env!("CARGO_BIN_EXE_chaos-writer");

    for round in 0..20 {
        let mut child = Command::new(writer_bin)
            .arg(&path)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("failed to spawn chaos-writer");

        let stdout = child.stdout.take().unwrap();
        let mut reader = BufReader::new(stdout);

        // Let it complete a random, small number of full writes first so
        // the kill has a realistic chance of landing mid-write rather
        // than always before the first one.
        let warmup = (round % 5) + 1;
        let mut line = String::new();
        for _ in 0..warmup {
            line.clear();
            if reader.read_line(&mut line).unwrap() == 0 {
                break;
            }
        }

        // Kill after a short, jittered delay so the process is
        // interrupted at varying points inside write_entries_atomic
        // across rounds (before/during temp-file write, fsync, or
        // rename).
        std::thread::sleep(Duration::from_micros((round as u64 % 7) * 200));
        let _ = child.kill();
        let _ = child.wait();

        // The container must still open, every single round.
        let container = Container::open(&path)
            .unwrap_or_else(|e| panic!("round {round}: container failed to open after kill: {e}"));
        assert!(
            container.header.aead_alg.starts_with("xchacha20poly1305"),
            "round {round}: header content is not a complete, valid version: {:?}",
            container.header.aead_alg
        );
    }
}
