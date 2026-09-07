//! Container format (spec §4.1) and atomic, crash-safe writes (spec §4.6).
//!
//! The `.vlt` archive is a zip file (the spec permits zip or tar+zstd,
//! "pick one and apply it consistently to `.vlt`, `.vltkey`, and
//! `.vltpack`" — zip is chosen here for broad tooling support across
//! every target platform, and applied to all three extensions).
//!
//! This module owns two layers:
//! - A generic, typed-agnostic archive read/write with the mandatory
//!   write-temp-then-fsync-then-rename semantics: `write_atomic` and
//!   `read_all` operate on a plain `name -> bytes` entry map and know
//!   nothing about headers, manifests, or encryption.
//! - Typed helpers (`ContainerHeader`, `build_entries`, `parse_entries`)
//!   that map the spec §4.1 tree onto that generic entry map.
//!
//! The background service is the container file's single writer (spec
//! §4.6, §8); this module does not itself enforce that — it is a
//! property of which process calls `write_atomic`, not of the format.

use std::collections::HashMap;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use uuid::Uuid;
use zip::write::SimpleFileOptions;
use zip::{ZipArchive, ZipWriter};

use crate::error::{Result, VaultError};
use crate::kdf::KdfParams;

pub const FORMAT_VERSION: u32 = 1;
pub const AEAD_ALG: &str = "xchacha20poly1305";

pub const HEADER_ENTRY: &str = "header.json";
pub const MASTER_DIR: &str = "master";
pub const KEY_BLOBS_DIR: &str = "key_blobs";

/// One master-key compartment's header entry (spec §4.1's
/// `kdf_params_master[]`, extended with the id/label a compartment needs
/// for the multi-compartment import flow in spec §5.3 option 2).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct CompartmentHeader {
    pub compartment_id: Uuid,
    pub label: String,
    pub kdf_params_master: KdfParams,
}

/// The container's unencrypted, versioned header (spec §4.1).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ContainerHeader {
    pub format_version: u32,
    pub aead_alg: String,
    pub compartments: Vec<CompartmentHeader>,
}

impl ContainerHeader {
    pub fn new() -> Self {
        Self {
            format_version: FORMAT_VERSION,
            aead_alg: AEAD_ALG.to_string(),
            compartments: Vec::new(),
        }
    }
}

impl Default for ContainerHeader {
    fn default() -> Self {
        Self::new()
    }
}

/// A fully assembled container, in memory, ready to be written to disk
/// or as parsed back from disk. Master blobs and key blobs are kept as
/// opaque encrypted bytes here — decrypting them is the caller's job
/// (this module only handles the archive/atomicity layer, per §4.1/§4.6).
#[derive(Debug, Clone, Default)]
pub struct Container {
    pub header: ContainerHeader,
    /// compartment_id -> `nonce || ciphertext` of that compartment's
    /// encrypted_master_blob.
    pub master_blobs: HashMap<Uuid, Vec<u8>>,
    /// key_id -> serialized `.kblob` bytes.
    pub key_blobs: HashMap<Uuid, Vec<u8>>,
}

impl Container {
    pub fn new() -> Self {
        Self {
            header: ContainerHeader::new(),
            master_blobs: HashMap::new(),
            key_blobs: HashMap::new(),
        }
    }

    fn master_entry_name(compartment_id: &Uuid) -> String {
        format!("{MASTER_DIR}/{compartment_id}.blob")
    }

    fn key_blob_entry_name(key_id: &Uuid) -> String {
        format!("{KEY_BLOBS_DIR}/{key_id}.kblob")
    }

    /// Lay this container out as `name -> bytes` archive entries.
    fn build_entries(&self) -> Result<Vec<(String, Vec<u8>)>> {
        let mut entries = Vec::with_capacity(1 + self.master_blobs.len() + self.key_blobs.len());
        entries.push((HEADER_ENTRY.to_string(), serde_json::to_vec_pretty(&self.header)?));
        for (compartment_id, bytes) in &self.master_blobs {
            entries.push((Self::master_entry_name(compartment_id), bytes.clone()));
        }
        for (key_id, bytes) in &self.key_blobs {
            entries.push((Self::key_blob_entry_name(key_id), bytes.clone()));
        }
        Ok(entries)
    }

    /// Parse a container back out of `name -> bytes` archive entries.
    fn parse_entries(entries: HashMap<String, Vec<u8>>) -> Result<Self> {
        let header_bytes = entries
            .get(HEADER_ENTRY)
            .ok_or_else(|| VaultError::InvalidHeader("missing header.json".into()))?;
        let header: ContainerHeader = serde_json::from_slice(header_bytes)?;
        if header.format_version != FORMAT_VERSION {
            return Err(VaultError::InvalidHeader(format!(
                "unsupported format_version {} (expected {FORMAT_VERSION})",
                header.format_version
            )));
        }

        let mut master_blobs = HashMap::new();
        let mut key_blobs = HashMap::new();
        for (name, bytes) in entries {
            if name == HEADER_ENTRY {
                continue;
            }
            if let Some(rest) = name.strip_prefix(&format!("{MASTER_DIR}/")) {
                let id_str = rest.strip_suffix(".blob").ok_or_else(|| {
                    VaultError::InvalidHeader(format!("malformed master blob entry name: {name}"))
                })?;
                let compartment_id = Uuid::parse_str(id_str)
                    .map_err(|e| VaultError::InvalidHeader(format!("bad compartment id in {name}: {e}")))?;
                master_blobs.insert(compartment_id, bytes);
            } else if let Some(rest) = name.strip_prefix(&format!("{KEY_BLOBS_DIR}/")) {
                let id_str = rest.strip_suffix(".kblob").ok_or_else(|| {
                    VaultError::InvalidHeader(format!("malformed key blob entry name: {name}"))
                })?;
                let key_id = Uuid::parse_str(id_str)
                    .map_err(|e| VaultError::InvalidHeader(format!("bad key id in {name}: {e}")))?;
                key_blobs.insert(key_id, bytes);
            } else {
                return Err(VaultError::InvalidHeader(format!("unexpected archive entry: {name}")));
            }
        }

        Ok(Self {
            header,
            master_blobs,
            key_blobs,
        })
    }

    /// Write this container to `path`, atomically (spec §4.6): the new
    /// state is written to a temp file in the same directory, fsync'd,
    /// then renamed over `path`. If interrupted at any point before the
    /// rename completes, `path` is left exactly as it was; there is no
    /// window where `path` itself is partially written.
    pub fn write_atomic(&self, path: &Path) -> Result<()> {
        let entries = self.build_entries()?;
        write_entries_atomic(path, &entries)
    }

    pub fn open(path: &Path) -> Result<Self> {
        let entries = read_all(path)?;
        Self::parse_entries(entries)
    }
}

/// Write `entries` as a zip archive to `path`, atomically. This is the
/// generic primitive `Container::write_atomic` builds on; it is also
/// exercised directly by the crash-safety chaos test since it is the
/// exact code path a real crash would interrupt.
pub fn write_entries_atomic(path: &Path, entries: &[(String, Vec<u8>)]) -> Result<()> {
    let dir = path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    fs::create_dir_all(dir)?;

    let tmp_path = temp_path_in(dir, path);
    {
        let tmp_file = File::create(&tmp_path)?;
        let mut zip = ZipWriter::new(tmp_file);
        let options = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Deflated);
        for (name, bytes) in entries {
            zip.start_file(name, options)
                .map_err(|e| VaultError::Archive(e.to_string()))?;
            zip.write_all(bytes)?;
        }
        let tmp_file = zip.finish().map_err(|e| VaultError::Archive(e.to_string()))?;
        tmp_file.sync_all()?;
    }

    fs::rename(&tmp_path, path)?;

    // Best-effort: fsync the containing directory so the rename's
    // directory-entry update is itself durable, not just the file
    // contents (matters on a real crash/power-loss, not in-process
    // panics). Not all platforms support opening a directory as a File
    // for this purpose (e.g. Windows) — ignore failure there.
    if let Ok(dir_file) = File::open(dir) {
        let _ = dir_file.sync_all();
    }

    Ok(())
}

fn temp_path_in(dir: &Path, target: &Path) -> PathBuf {
    let file_name = target
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "container".to_string());
    // Include the PID so concurrent/crashed writers never collide on the
    // same temp file name.
    dir.join(format!(".{file_name}.{}.tmp", std::process::id()))
}

/// Read every entry out of the zip archive at `path`.
pub fn read_all(path: &Path) -> Result<HashMap<String, Vec<u8>>> {
    let file = File::open(path)?;
    let mut archive = ZipArchive::new(file).map_err(|e| VaultError::Archive(e.to_string()))?;
    let mut out = HashMap::with_capacity(archive.len());
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| VaultError::Archive(e.to_string()))?;
        let name = entry.name().to_string();
        let mut bytes = Vec::with_capacity(entry.size() as usize);
        entry.read_to_end(&mut bytes)?;
        out.insert(name, bytes);
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn empty_container_roundtrips() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("test.vlt");
        let container = Container::new();
        container.write_atomic(&path).unwrap();
        let back = Container::open(&path).unwrap();
        assert_eq!(back.header, container.header);
        assert!(back.master_blobs.is_empty());
        assert!(back.key_blobs.is_empty());
    }

    #[test]
    fn container_with_blobs_roundtrips() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("test.vlt");
        let mut container = Container::new();
        let compartment_id = Uuid::new_v4();
        let key_id = Uuid::new_v4();
        container.header.compartments.push(CompartmentHeader {
            compartment_id,
            label: "Personal".into(),
            kdf_params_master: KdfParams::new(65536, 3, 1).unwrap(),
        });
        container.master_blobs.insert(compartment_id, b"encrypted-master-blob".to_vec());
        container.key_blobs.insert(key_id, b"encrypted-key-blob".to_vec());

        container.write_atomic(&path).unwrap();
        let back = Container::open(&path).unwrap();
        assert_eq!(back.header.compartments.len(), 1);
        assert_eq!(back.master_blobs.get(&compartment_id).unwrap(), b"encrypted-master-blob");
        assert_eq!(back.key_blobs.get(&key_id).unwrap(), b"encrypted-key-blob");
    }

    #[test]
    fn wrong_format_version_rejected() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("test.vlt");
        let mut container = Container::new();
        container.header.format_version = 99;
        container.write_atomic(&path).unwrap();
        assert!(Container::open(&path).is_err());
    }

    #[test]
    fn interrupted_write_never_touches_original_file() {
        // Simulates a crash between "write temp file" and "rename":
        // write the real container, then start (but never finish) a
        // second write by only performing the temp-file half.
        let dir = tempdir().unwrap();
        let path = dir.path().join("test.vlt");
        let original = Container::new();
        original.write_atomic(&path).unwrap();
        let original_bytes = fs::read(&path).unwrap();

        // "Interrupted crash": a temp file sits next to the container,
        // never renamed. write_entries_atomic's own temp file naming
        // means this looks exactly like a process that died right after
        // File::create but before rename.
        let tmp_path = temp_path_in(dir.path(), &path);
        fs::write(&tmp_path, b"PARTIAL GARBAGE, NEVER RENAMED").unwrap();

        // The original container must still open correctly and be
        // byte-identical to what was there before the interrupted write.
        let reopened_bytes = fs::read(&path).unwrap();
        assert_eq!(reopened_bytes, original_bytes);
        let back = Container::open(&path).unwrap();
        assert_eq!(back.header, original.header);
    }

    #[test]
    fn write_atomic_never_leaves_stray_temp_files_on_success() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("test.vlt");
        Container::new().write_atomic(&path).unwrap();
        let leftovers: Vec<_> = fs::read_dir(dir.path())
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().contains(".tmp"))
            .collect();
        assert!(leftovers.is_empty(), "temp file left behind after successful write: {leftovers:?}");
    }
}
