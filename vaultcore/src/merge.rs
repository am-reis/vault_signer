//! Three-way master-key merge logic (spec §5.3): the import flow's
//! master-key duality decision. Implemented once here and invoked
//! identically by every platform's UI — "No platform-specific merge
//! logic is permitted" (spec §5.3.6).
//!
//! This module is pure manifest/compartment bookkeeping: it decides
//! *which keys end up in which compartment, under which label,* and
//! flags/resolves duplicates. It does not touch passphrases or
//! ciphertext — encrypting the resulting compartments (via
//! `master_blob::encrypt`, with whichever passphrase and KDF params the
//! chosen option implies) and discarding the blobs this module says to
//! discard is the caller's job, once the vault is actually unlocked.
//!
//! Duplicate detection (spec §5.3.5) runs for every option: an incoming
//! key matching an existing one by `key_id`, or by FIDO2 `rp_id` +
//! `credential_id_b64`, is never silently overwritten — it is kept
//! alongside the existing entry, renamed. For a `key_id` collision this
//! is not just a UX nicety: two entries can't share a `key_id` in one
//! [`Manifest`] ([`Manifest::validate`] rejects it), so a fresh
//! `key_id` is assigned and the caller is told via `id_remap` — the
//! renamed entry's on-disk blob must be copied from the old `key_id`'s
//! path to the new one, bytes unchanged (§5.3.4: the per-key encryption
//! layer is independent of any master key).

use std::collections::HashMap;

use uuid::Uuid;

use crate::error::{Result, VaultError};
use crate::manifest::{KeyEntry, Manifest};

/// One local compartment: a labeled, independently-keyed manifest
/// sub-tree (spec §4.1's `kdf_params_master[]` / `encrypted_master_blob[]`
/// pairing, at the plaintext-manifest level this module operates on).
#[derive(Debug, Clone)]
pub struct VaultCompartment {
    pub id: Uuid,
    pub label: String,
    pub manifest: Manifest,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DuplicateReason {
    KeyId,
    Fido2Credential { rp_id: String, credential_id_b64: String },
}

#[derive(Debug, Clone)]
pub struct DuplicateWarning {
    /// The incoming key's *original* key_id (before any rename).
    pub incoming_key_id: Uuid,
    pub matched_local_key_id: Uuid,
    pub matched_in_compartment: Uuid,
    pub reason: DuplicateReason,
}

/// The pure-logic outcome of a merge operation. `updated_compartments`
/// is the local vault's full compartment list after applying the
/// chosen option; the two `discard_*` fields tell the caller which
/// encrypted master-key material must be discarded once it re-encrypts
/// `updated_compartments` (spec §5.3 options 1 and 3 both discard one
/// side's old master key — never both, and option 2 discards neither).
#[derive(Debug, Clone)]
pub struct MergeResult {
    pub updated_compartments: Vec<VaultCompartment>,
    pub warnings: Vec<DuplicateWarning>,
    /// Incoming key_id -> the fresh key_id it was renamed to, for every
    /// entry a duplicate key_id forced a rename on. Blob files must be
    /// copied under the new key_id (spec §5.3.4).
    pub id_remap: HashMap<Uuid, Uuid>,
    pub discard_incoming_master_key: bool,
    pub discard_local_master_key_for: Option<Uuid>,
}

pub const REPLACE_CONFIRMATION_PHRASE: &str = "REPLACE MY MASTER KEY";

fn find_duplicates(local: &[VaultCompartment], incoming: &[KeyEntry]) -> Vec<DuplicateWarning> {
    let mut warnings = Vec::new();
    for incoming_key in incoming {
        'outer: for compartment in local {
            for local_key in &compartment.manifest.keys {
                if local_key.key_id == incoming_key.key_id {
                    warnings.push(DuplicateWarning {
                        incoming_key_id: incoming_key.key_id,
                        matched_local_key_id: local_key.key_id,
                        matched_in_compartment: compartment.id,
                        reason: DuplicateReason::KeyId,
                    });
                    break 'outer;
                }
                if let (Some(incoming_fido2), Some(local_fido2)) = (&incoming_key.fido2, &local_key.fido2) {
                    if incoming_fido2.rp_id == local_fido2.rp_id
                        && incoming_fido2.credential_id_b64 == local_fido2.credential_id_b64
                    {
                        warnings.push(DuplicateWarning {
                            incoming_key_id: incoming_key.key_id,
                            matched_local_key_id: local_key.key_id,
                            matched_in_compartment: compartment.id,
                            reason: DuplicateReason::Fido2Credential {
                                rp_id: local_fido2.rp_id.clone(),
                                credential_id_b64: local_fido2.credential_id_b64.clone(),
                            },
                        });
                        break 'outer;
                    }
                }
            }
        }
    }
    warnings
}

/// Applies the spec §5.3.5 default ("keep both, rename incoming") to
/// every flagged entry: a `key_id` collision gets a fresh `key_id`
/// (recorded in the returned remap) plus an updated `blob_file`; any
/// duplicate (key_id or FIDO2 credential) gets an "(imported)" label
/// suffix so the user can see it landed as a second, distinct entry.
fn rename_incoming_duplicates(
    mut incoming: Vec<KeyEntry>,
    warnings: &[DuplicateWarning],
) -> (Vec<KeyEntry>, HashMap<Uuid, Uuid>) {
    let mut id_remap = HashMap::new();
    let flagged: std::collections::HashSet<Uuid> = warnings.iter().map(|w| w.incoming_key_id).collect();

    for key in &mut incoming {
        if !flagged.contains(&key.key_id) {
            continue;
        }
        let is_key_id_collision = warnings
            .iter()
            .any(|w| w.incoming_key_id == key.key_id && w.reason == DuplicateReason::KeyId);

        if !key.label.ends_with("(imported)") {
            key.label = format!("{} (imported)", key.label);
        }

        if is_key_id_collision {
            let old_id = key.key_id;
            let new_id = Uuid::new_v4();
            key.key_id = new_id;
            key.blob_file = format!("key_blobs/{new_id}.kblob");
            id_remap.insert(old_id, new_id);
        }
    }
    (incoming, id_remap)
}

fn find_compartment_mut(local: &mut [VaultCompartment], id: Uuid) -> Result<&mut VaultCompartment> {
    local
        .iter_mut()
        .find(|c| c.id == id)
        .ok_or_else(|| VaultError::InvalidManifest(format!("no local compartment with id {id}")))
}

/// **Option 1 — Re-encrypt & discard incoming master key** (spec §5.3
/// option 1, default-emphasis UI choice). The incoming manifest's keys
/// are merged into `target_compartment_id`'s manifest, which stays
/// protected by the local vault's existing master key; the caller must
/// discard the incoming master-key blob entirely per
/// `discard_incoming_master_key`.
pub fn merge_reencrypt_discard_incoming(
    mut local: Vec<VaultCompartment>,
    target_compartment_id: Uuid,
    incoming: &Manifest,
) -> Result<MergeResult> {
    let warnings = find_duplicates(&local, &incoming.keys);
    let (renamed_incoming, id_remap) = rename_incoming_duplicates(incoming.keys.clone(), &warnings);

    let target = find_compartment_mut(&mut local, target_compartment_id)?;
    target.manifest.keys.extend(renamed_incoming);
    target.manifest.validate()?;

    Ok(MergeResult {
        updated_compartments: local,
        warnings,
        id_remap,
        discard_incoming_master_key: true,
        discard_local_master_key_for: None,
    })
}

/// **Option 2 — Keep both master keys side by side** (spec §5.3 option
/// 2). The incoming manifest becomes its own new compartment,
/// unaffected by and not merged into any existing one; both master
/// keys survive, so neither `discard_*` field fires.
pub fn merge_side_by_side(
    local: Vec<VaultCompartment>,
    incoming: &Manifest,
    new_compartment_id: Uuid,
    new_compartment_label: String,
) -> Result<MergeResult> {
    let warnings = find_duplicates(&local, &incoming.keys);
    let (renamed_incoming, id_remap) = rename_incoming_duplicates(incoming.keys.clone(), &warnings);

    let mut new_manifest = incoming.clone();
    new_manifest.keys = renamed_incoming;
    new_manifest.validate()?;

    let new_compartment = VaultCompartment {
        id: new_compartment_id,
        label: new_compartment_label,
        manifest: new_manifest,
    };

    let mut updated_compartments = local;
    updated_compartments.push(new_compartment);

    Ok(MergeResult {
        updated_compartments,
        warnings,
        id_remap,
        discard_incoming_master_key: false,
        discard_local_master_key_for: None,
    })
}

/// **Option 3 — Replace local master key with incoming master key**
/// (spec §5.3 option 3). Combines `target_compartment_id`'s existing
/// keys with the incoming ones into one manifest that the caller must
/// re-encrypt under the *incoming* master key's parameters; the old
/// local master-key blob for that compartment is discarded
/// (`discard_local_master_key_for`). This is the most destructive of
/// the three options, so it requires the exact spec-mandated
/// confirmation phrase — a mistyped or missing confirmation is a hard
/// error, not a silent no-op, so a caller can't accidentally skip the
/// UI-level "type to confirm" gate the spec requires.
pub fn merge_replace_local_with_incoming(
    mut local: Vec<VaultCompartment>,
    target_compartment_id: Uuid,
    incoming: &Manifest,
    confirmation_phrase: &str,
) -> Result<MergeResult> {
    if confirmation_phrase != REPLACE_CONFIRMATION_PHRASE {
        return Err(VaultError::InvalidManifest(
            "master-key replacement requires the exact confirmation phrase".into(),
        ));
    }

    let warnings = find_duplicates(&local, &incoming.keys);
    let (renamed_incoming, id_remap) = rename_incoming_duplicates(incoming.keys.clone(), &warnings);

    let target = find_compartment_mut(&mut local, target_compartment_id)?;
    target.manifest.keys.extend(renamed_incoming);
    target.manifest.validate()?;

    Ok(MergeResult {
        updated_compartments: local,
        warnings,
        id_remap,
        discard_incoming_master_key: false,
        discard_local_master_key_for: Some(target_compartment_id),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::manifest::{Fido2Info, KeyType, Purpose};
    use time::OffsetDateTime;

    fn key(label: &str, purpose: Purpose, fido2: Option<Fido2Info>) -> KeyEntry {
        let key_id = Uuid::new_v4();
        KeyEntry {
            key_id,
            label: label.to_string(),
            description: String::new(),
            resource: String::new(),
            key_type: KeyType::Ed25519,
            purpose,
            fido2,
            created_at: OffsetDateTime::now_utc(),
            last_used_at: None,
            tags: vec![],
            blob_file: format!("key_blobs/{key_id}.kblob"),
            blob_sha256: "a".repeat(64),
            public_key_hex: String::new(),
        }
    }

    fn fido2(rp_id: &str, cred: &str) -> Fido2Info {
        Fido2Info {
            rp_id: rp_id.to_string(),
            credential_id_b64: cred.to_string(),
            user_handle_b64: "handle".into(),
            sign_count: 0,
            discoverable: true,
        }
    }

    fn compartment(label: &str, keys: Vec<KeyEntry>) -> VaultCompartment {
        let mut manifest = Manifest::new(Uuid::new_v4());
        manifest.keys = keys;
        VaultCompartment {
            id: Uuid::new_v4(),
            label: label.to_string(),
            manifest,
        }
    }

    #[test]
    fn option1_merges_incoming_into_target_compartment() {
        let personal = compartment("Personal", vec![key("Existing key", Purpose::CustomSigning, None)]);
        let personal_id = personal.id;
        let local = vec![personal];

        let mut incoming = Manifest::new(Uuid::new_v4());
        incoming.keys.push(key("Imported key", Purpose::CustomSigning, None));

        let result = merge_reencrypt_discard_incoming(local, personal_id, &incoming).unwrap();

        assert_eq!(result.updated_compartments.len(), 1, "option 1 must not create a new compartment");
        assert_eq!(result.updated_compartments[0].manifest.keys.len(), 2);
        assert!(result.discard_incoming_master_key);
        assert!(result.discard_local_master_key_for.is_none());
        assert!(result.warnings.is_empty());
    }

    #[test]
    fn option2_creates_new_compartment_and_keeps_both_master_keys() {
        let personal = compartment("Personal", vec![key("Existing key", Purpose::CustomSigning, None)]);
        let local = vec![personal];

        let mut incoming = Manifest::new(Uuid::new_v4());
        incoming.keys.push(key("Alice's key", Purpose::CustomSigning, None));

        let new_id = Uuid::new_v4();
        let result = merge_side_by_side(local, &incoming, new_id, "Imported from Alice's laptop".into()).unwrap();

        assert_eq!(result.updated_compartments.len(), 2);
        assert_eq!(result.updated_compartments[0].manifest.keys.len(), 1, "original compartment untouched");
        let new_compartment = result.updated_compartments.iter().find(|c| c.id == new_id).unwrap();
        assert_eq!(new_compartment.label, "Imported from Alice's laptop");
        assert_eq!(new_compartment.manifest.keys.len(), 1);
        assert!(!result.discard_incoming_master_key);
        assert!(result.discard_local_master_key_for.is_none());
    }

    #[test]
    fn option3_requires_exact_confirmation_phrase() {
        let personal = compartment("Personal", vec![]);
        let personal_id = personal.id;
        let local = vec![personal];
        let incoming = Manifest::new(Uuid::new_v4());

        let err = merge_replace_local_with_incoming(local.clone(), personal_id, &incoming, "replace my master key");
        assert!(err.is_err(), "lowercase/mistyped confirmation must be rejected");

        let ok = merge_replace_local_with_incoming(local, personal_id, &incoming, REPLACE_CONFIRMATION_PHRASE);
        assert!(ok.is_ok());
    }

    #[test]
    fn option3_combines_local_and_incoming_and_discards_local_master_key() {
        let personal = compartment("Personal", vec![key("Local key", Purpose::CustomSigning, None)]);
        let personal_id = personal.id;
        let local = vec![personal];

        let mut incoming = Manifest::new(Uuid::new_v4());
        incoming.keys.push(key("Incoming key", Purpose::CustomSigning, None));

        let result = merge_replace_local_with_incoming(local, personal_id, &incoming, REPLACE_CONFIRMATION_PHRASE).unwrap();

        assert_eq!(result.updated_compartments.len(), 1);
        assert_eq!(result.updated_compartments[0].manifest.keys.len(), 2);
        assert_eq!(result.discard_local_master_key_for, Some(personal_id));
        assert!(!result.discard_incoming_master_key);
    }

    #[test]
    fn key_id_collision_is_renamed_not_overwritten() {
        let existing = key("Existing", Purpose::CustomSigning, None);
        let existing_id = existing.key_id;
        let personal = compartment("Personal", vec![existing]);
        let personal_id = personal.id;
        let local = vec![personal];

        // Incoming key deliberately shares the same key_id as an
        // existing one (e.g. a re-import of a previously exported key).
        let mut colliding = key("Existing", Purpose::CustomSigning, None);
        colliding.key_id = existing_id;
        let mut incoming = Manifest::new(Uuid::new_v4());
        incoming.keys.push(colliding);

        let result = merge_reencrypt_discard_incoming(local, personal_id, &incoming).unwrap();

        assert_eq!(result.warnings.len(), 1);
        assert_eq!(result.warnings[0].reason, DuplicateReason::KeyId);
        assert_eq!(result.id_remap.len(), 1);
        let new_id = *result.id_remap.get(&existing_id).unwrap();
        assert_ne!(new_id, existing_id);

        let compartment_after = &result.updated_compartments[0];
        assert_eq!(compartment_after.manifest.keys.len(), 2, "both entries must be kept, not overwritten");
        let renamed = compartment_after.manifest.keys.iter().find(|k| k.key_id == new_id).unwrap();
        assert!(renamed.label.contains("(imported)"));
        assert_eq!(renamed.blob_file, format!("key_blobs/{new_id}.kblob"));
        // The original entry is untouched.
        assert!(compartment_after.manifest.keys.iter().any(|k| k.key_id == existing_id && k.label == "Existing"));
    }

    #[test]
    fn fido2_credential_collision_across_different_key_ids_is_flagged() {
        let existing = key("Existing passkey", Purpose::Fido2, Some(fido2("example.com", "cred-1")));
        let personal = compartment("Personal", vec![existing]);
        let personal_id = personal.id;
        let local = vec![personal];

        let mut incoming = Manifest::new(Uuid::new_v4());
        incoming
            .keys
            .push(key("Same site, different device", Purpose::Fido2, Some(fido2("example.com", "cred-1"))));

        let result = merge_reencrypt_discard_incoming(local, personal_id, &incoming).unwrap();
        assert_eq!(result.warnings.len(), 1);
        assert!(matches!(result.warnings[0].reason, DuplicateReason::Fido2Credential { .. }));
        // Different key_id already, so no rename/remap is required to
        // avoid a manifest collision, but the label still flags it.
        assert!(result.id_remap.is_empty());
        let compartment_after = &result.updated_compartments[0];
        assert_eq!(compartment_after.manifest.keys.len(), 2);
        assert!(compartment_after.manifest.keys.iter().any(|k| k.label.contains("(imported)")));
    }

    #[test]
    fn duplicate_detection_spans_all_local_compartments_not_just_the_target() {
        let other_existing = key("In another compartment", Purpose::CustomSigning, None);
        let other_id = other_existing.key_id;
        let work = compartment("Work", vec![other_existing]);
        let personal = compartment("Personal", vec![]);
        let personal_id = personal.id;
        let local = vec![work, personal];

        let mut colliding = key("In another compartment", Purpose::CustomSigning, None);
        colliding.key_id = other_id;
        let mut incoming = Manifest::new(Uuid::new_v4());
        incoming.keys.push(colliding);

        // Importing into "Personal" while the collision actually lives
        // in "Work" must still be caught.
        let result = merge_reencrypt_discard_incoming(local, personal_id, &incoming).unwrap();
        assert_eq!(result.warnings.len(), 1);
        assert_eq!(result.warnings[0].matched_in_compartment, result.updated_compartments[0].id);
    }

    #[test]
    fn non_conflicting_import_produces_no_warnings_or_remap() {
        let local = vec![compartment("Personal", vec![key("Existing", Purpose::CustomSigning, None)])];
        let personal_id = local[0].id;
        let mut incoming = Manifest::new(Uuid::new_v4());
        incoming.keys.push(key("Brand new", Purpose::CustomSigning, None));

        let result = merge_reencrypt_discard_incoming(local, personal_id, &incoming).unwrap();
        assert!(result.warnings.is_empty());
        assert!(result.id_remap.is_empty());
    }

    #[test]
    fn missing_target_compartment_is_an_error() {
        let local = vec![compartment("Personal", vec![])];
        let incoming = Manifest::new(Uuid::new_v4());
        let result = merge_reencrypt_discard_incoming(local, Uuid::new_v4(), &incoming);
        assert!(result.is_err());
    }
}
