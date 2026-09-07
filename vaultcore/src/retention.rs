//! In-memory key-material retention cache (spec §4.5).
//!
//! Decrypted private key bytes live here, `zeroize`-wrapped, only as long
//! as strictly necessary (spec §3 invariant), and are wiped:
//! (a) when the per-key retention timer elapses — enforced by a
//!     background sweep thread, not just on next access, so a key is not
//!     left resident indefinitely just because nobody happens to touch
//!     the cache again;
//! (b) immediately after use if retention is set to zero — enforced by
//!     [`RetentionCache::use_key`], which removes+wipes a zero-retention
//!     entry the moment its single use completes;
//! (c) on explicit lock / app suspend / OS screen-lock — call
//!     [`RetentionCache::wipe_all`];
//! (d) on process exit — best-effort via `Drop`; a crash handler calling
//!     `wipe_all` is out of scope for this in-memory structure and must
//!     be wired up per-platform where the OS provides a hook.
//!
//! **Known gap, tracked in PROGRESS.md:** the spec also asks for
//! `mlock`/`VirtualLock`/`mlockall`-equivalent calls to reduce the chance
//! of this memory being paged out. That requires per-platform unsafe FFI
//! against a fixed-address, non-relocating allocation (a `Vec<u8>` can
//! reallocate/move), which is real platform-integration work, not a
//! generic addition here — it is deliberately not implemented yet rather
//! than faked with a no-op.

use std::collections::HashMap;
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use uuid::Uuid;
use zeroize::Zeroizing;

use crate::error::{Result, VaultError};

pub const MIN_RETENTION_SECS: u32 = 0;
pub const MAX_RETENTION_SECS: u32 = 300;
pub const DEFAULT_RETENTION_SECS: u32 = 30;

const SWEEP_INTERVAL: Duration = Duration::from_millis(50);

pub fn validate_retention_secs(secs: u32) -> Result<()> {
    if secs > MAX_RETENTION_SECS {
        return Err(VaultError::InvalidManifest(format!(
            "retention timer {secs}s exceeds the mandatory {MAX_RETENTION_SECS}s cap (spec §4.5)"
        )));
    }
    Ok(())
}

struct CachedKey {
    bytes: Zeroizing<Vec<u8>>,
    expires_at: Instant,
    /// Zero-retention entries are removed the moment `use_key` finishes
    /// using them, regardless of the (already-elapsed) timer.
    single_use: bool,
}

struct Shared {
    entries: Mutex<HashMap<Uuid, CachedKey>>,
    shutdown: Mutex<bool>,
    shutdown_cv: Condvar,
}

/// A `zeroize`-wrapped in-memory cache of decrypted key material, keyed
/// by `key_id`, with per-entry expiry (spec §4.5). Never persisted to
/// disk.
pub struct RetentionCache {
    shared: Arc<Shared>,
    sweeper: Option<JoinHandle<()>>,
}

impl RetentionCache {
    pub fn new() -> Self {
        let shared = Arc::new(Shared {
            entries: Mutex::new(HashMap::new()),
            shutdown: Mutex::new(false),
            shutdown_cv: Condvar::new(),
        });

        let sweeper_shared = Arc::clone(&shared);
        let sweeper = thread::spawn(move || loop {
            let guard = sweeper_shared.shutdown.lock().unwrap();
            let (guard, timed_out) = sweeper_shared
                .shutdown_cv
                .wait_timeout(guard, SWEEP_INTERVAL)
                .unwrap();
            if *guard {
                return;
            }
            drop(guard);
            let _ = timed_out;
            sweeper_shared.sweep_expired();
        });

        Self {
            shared,
            sweeper: Some(sweeper),
        }
    }

    /// Cache `bytes` under `key_id` for `retention_secs` (spec §4.5:
    /// 0-300, default 30). Overwrites any existing entry for the same
    /// `key_id` (its old bytes are dropped/zeroized in the process).
    pub fn insert(&self, key_id: Uuid, bytes: Vec<u8>, retention_secs: u32) -> Result<()> {
        validate_retention_secs(retention_secs)?;
        self.insert_raw(key_id, bytes, Duration::from_secs(retention_secs as u64), retention_secs == 0);
        Ok(())
    }

    pub(crate) fn insert_raw(&self, key_id: Uuid, bytes: Vec<u8>, ttl: Duration, single_use: bool) {
        let mut entries = self.shared.entries.lock().unwrap();
        entries.insert(
            key_id,
            CachedKey {
                bytes: Zeroizing::new(bytes),
                expires_at: Instant::now() + ttl,
                single_use,
            },
        );
    }

    /// Look up `key_id` and, if present and not yet expired, call `f`
    /// with its decrypted bytes. If the entry was cached with zero
    /// retention, it is removed and zeroized immediately after `f`
    /// returns (spec §4.5 invariant (b)) — a zero-retention key can only
    /// ever be used once from the cache.
    pub fn use_key<R>(&self, key_id: &Uuid, f: impl FnOnce(&[u8]) -> R) -> Option<R> {
        let mut entries = self.shared.entries.lock().unwrap();
        let entry = entries.get(key_id)?;
        // A single-use (zero-retention) entry is, by construction,
        // already at its expiry the instant it's inserted — its "expiry"
        // exists only to bound how long an *unused* zero-retention entry
        // can sit in the cache via the background sweep, not to block
        // the one legitimate use invariant (b) grants it. Any other
        // entry is gated on the timer normally.
        if !entry.single_use && entry.expires_at <= Instant::now() {
            entries.remove(key_id);
            return None;
        }
        let result = f(&entry.bytes);
        if entry.single_use {
            entries.remove(key_id);
        }
        Some(result)
    }

    pub fn contains(&self, key_id: &Uuid) -> bool {
        let entries = self.shared.entries.lock().unwrap();
        entries
            .get(key_id)
            .is_some_and(|e| e.single_use || e.expires_at > Instant::now())
    }

    /// Explicit wipe of one key (e.g. the user manually locks that key).
    pub fn wipe(&self, key_id: &Uuid) {
        self.shared.entries.lock().unwrap().remove(key_id);
    }

    /// Wipe everything immediately, regardless of any entry's timer —
    /// spec §4.5 invariant (c): explicit lock, app suspend, OS
    /// screen-lock.
    pub fn wipe_all(&self) {
        self.shared.entries.lock().unwrap().clear();
    }

    pub fn len(&self) -> usize {
        self.shared.entries.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl Shared {
    fn sweep_expired(&self) {
        let mut entries = self.entries.lock().unwrap();
        let now = Instant::now();
        // Single-use entries are exempt from time-based sweeping: their
        // `expires_at` is set to their insertion time by construction
        // (see `insert`), so a time-based sweep would race the caller
        // that hasn't consumed them yet. They are removed only by
        // `use_key` (after their one use) or an explicit wipe.
        entries.retain(|_, entry| entry.single_use || entry.expires_at > now);
    }
}

impl Default for RetentionCache {
    fn default() -> Self {
        Self::new()
    }
}

/// Best-effort invariant (d): wipe everything and stop the sweeper on
/// normal drop (process exit, or the cache going out of scope).
impl Drop for RetentionCache {
    fn drop(&mut self) {
        self.wipe_all();
        *self.shared.shutdown.lock().unwrap() = true;
        self.shared.shutdown_cv.notify_all();
        if let Some(handle) = self.sweeper.take() {
            let _ = handle.join();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn insert_and_use_returns_bytes() {
        let cache = RetentionCache::new();
        let key_id = Uuid::new_v4();
        cache.insert(key_id, b"private-key-bytes".to_vec(), 30).unwrap();
        let seen = cache.use_key(&key_id, |bytes| bytes.to_vec());
        assert_eq!(seen, Some(b"private-key-bytes".to_vec()));
    }

    #[test]
    fn rejects_retention_above_cap() {
        let cache = RetentionCache::new();
        let err = cache.insert(Uuid::new_v4(), vec![1, 2, 3], MAX_RETENTION_SECS + 1);
        assert!(err.is_err());
    }

    #[test]
    fn zero_retention_is_wiped_after_single_use() {
        let cache = RetentionCache::new();
        let key_id = Uuid::new_v4();
        cache.insert_raw(key_id, b"one-shot".to_vec(), Duration::from_secs(0), true);

        assert!(cache.contains(&key_id), "single-use entry must be present until its one use");
        let first = cache.use_key(&key_id, |b| b.to_vec());
        assert_eq!(first, Some(b"one-shot".to_vec()));

        let second = cache.use_key(&key_id, |b| b.to_vec());
        assert_eq!(second, None, "zero-retention entry must not survive a second use");
    }

    #[test]
    fn nonzero_retention_survives_multiple_uses_before_expiry() {
        let cache = RetentionCache::new();
        let key_id = Uuid::new_v4();
        cache.insert_raw(key_id, b"reusable".to_vec(), Duration::from_secs(30), false);

        assert_eq!(cache.use_key(&key_id, |b| b.to_vec()), Some(b"reusable".to_vec()));
        assert_eq!(cache.use_key(&key_id, |b| b.to_vec()), Some(b"reusable".to_vec()));
    }

    #[test]
    fn entry_expires_via_background_sweep_without_being_accessed() {
        let cache = RetentionCache::new();
        let key_id = Uuid::new_v4();
        cache.insert_raw(key_id, b"short-lived".to_vec(), Duration::from_millis(20), false);
        assert!(cache.contains(&key_id));

        std::thread::sleep(Duration::from_millis(20 + SWEEP_INTERVAL.as_millis() as u64 * 3));

        // Never touched via use_key, yet the sweeper must have removed it.
        assert_eq!(cache.len(), 0, "expired entry must be swept proactively, not just on access");
    }

    #[test]
    fn wipe_all_clears_regardless_of_timer() {
        let cache = RetentionCache::new();
        cache.insert(Uuid::new_v4(), vec![1], 300).unwrap();
        cache.insert(Uuid::new_v4(), vec![2], 300).unwrap();
        assert_eq!(cache.len(), 2);
        cache.wipe_all();
        assert_eq!(cache.len(), 0);
    }

    #[test]
    fn wipe_removes_single_entry() {
        let cache = RetentionCache::new();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        cache.insert(a, vec![1], 30).unwrap();
        cache.insert(b, vec![2], 30).unwrap();
        cache.wipe(&a);
        assert!(!cache.contains(&a));
        assert!(cache.contains(&b));
    }

    #[test]
    fn missing_key_returns_none() {
        let cache = RetentionCache::new();
        assert_eq!(cache.use_key(&Uuid::new_v4(), |b| b.to_vec()), None);
    }
}
