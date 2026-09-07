//! Helper process for the crash-safety chaos test (spec §4.6, §10): loops
//! writing successive container versions to the path given as argv[1],
//! printing `wrote <n>` (flushed) after each version lands. The test
//! harness kills this process at a random point and then verifies the
//! container at that path is always either the pre-kill or post-kill
//! complete version — never partially written.

use std::env;
use std::io::Write;
use std::path::PathBuf;

use vaultcore::container::{write_entries_atomic, ContainerHeader};

fn main() {
    let path = PathBuf::from(env::args().nth(1).expect("usage: chaos_writer <path>"));
    let mut n: u64 = 0;
    loop {
        n += 1;
        let mut header = ContainerHeader::new();
        // Encode the version number into the label so the parent can
        // verify which complete version it observed after the kill.
        header.aead_alg = format!("xchacha20poly1305#v{n}");
        let entries = vec![("header.json".to_string(), serde_json::to_vec(&header).unwrap())];
        write_entries_atomic(&path, &entries).expect("write_entries_atomic failed");
        println!("wrote {n}");
        std::io::stdout().flush().ok();
    }
}
