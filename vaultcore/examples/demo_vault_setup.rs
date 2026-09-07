//! Convenience setup tool for demos/rpc-demo-client/: creates a vault
//! with one compartment and one Ed25519 signing key at known
//! passphrases, so that demo can be exercised against a real
//! VaultSignerAgent without touching any real vault or needing the
//! user's own passphrases. See demos/rpc-demo-client/README.md.
use vaultcore::vault::{FacadeDeviceProfile, FacadeKeyType, FacadePurpose, Vault};

fn main() {
    let path = std::env::args().nth(1).expect("usage: demo_vault_setup <path>");
    let vault = Vault::create(path.clone(), "Demo".into(), "demo-master-pw".into(), FacadeDeviceProfile::Desktop).expect("create vault");
    let compartment_id = vault.list_compartments().into_iter().next().unwrap().compartment_id;
    let key = vault
        .create_key(
            compartment_id.clone(),
            FacadeKeyType::Ed25519,
            FacadePurpose::CustomSigning,
            "Demo Signing Key".into(),
            "Created for the cross-language RPC protocol demo".into(),
            "demo.example.com".into(),
            vec![],
            "demo-key-pw".into(),
            None,
            None,
        )
        .expect("create key");
    println!("vault_path={path}");
    println!("compartment_id={compartment_id}");
    println!("key_id={}", key.key_id);
    println!("master_passphrase=demo-master-pw");
    println!("key_passphrase=demo-key-pw");
}
