//! Fuzz target for the container archive parser (spec §10: "Fuzz-test
//! the container-file parser ... malformed or truncated inputs must
//! fail closed, never crash the background service").
//!
//! Feeds arbitrary bytes straight to `Container::from_bytes`, which
//! parses the zip archive and then the container header/entry naming
//! scheme on top of it — the exact code path a real, on-disk `.vlt`
//! file goes through, minus the filesystem read. A crash, panic, or
//! unbounded resource use here is a bug; an `Err` is the correct,
//! expected outcome for non-container input.

#![no_main]

use libfuzzer_sys::fuzz_target;
use vaultcore::container::Container;

fuzz_target!(|data: &[u8]| {
    let _ = Container::from_bytes(data);
});
