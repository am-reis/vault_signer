//! CLI to run the Argon2id per-device benchmark (spec §4.2) and print the
//! chosen parameters. Useful for sanity-checking `kdf::benchmark` timing
//! on a real machine outside the `#[ignore]`d unit test.

use std::time::Instant;

use vaultcore::kdf::{benchmark, derive, DeviceProfile};

fn main() {
    let profile = match std::env::args().nth(1).as_deref() {
        Some("mobile") => DeviceProfile::Mobile,
        _ => DeviceProfile::Desktop,
    };
    let params = benchmark(profile).expect("benchmark failed");
    let start = Instant::now();
    derive(b"probe", &params).expect("derive failed");
    let elapsed = start.elapsed();

    println!("profile: {profile:?}");
    println!("memory_kib: {}", params.memory_kib);
    println!("iterations: {}", params.iterations);
    println!("parallelism: {}", params.parallelism);
    println!("derivation time at chosen params: {elapsed:?}");
}
