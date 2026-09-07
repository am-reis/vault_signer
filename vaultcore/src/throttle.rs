//! Passphrase attempt throttling (spec §5.5), implemented once and
//! shared by every passphrase-entry surface: master-password unlock,
//! per-key passphrase entry (FIDO2 assertion, the custom protocol, or
//! reveal-raw-key), and export/import transfer-password entry.
//!
//! Attempt counts are tracked per secret — per `key_id`, or for the
//! master key, per compartment — identified here by an opaque
//! `SecretId(String)` the caller constructs (e.g. `SecretId::key(key_id)`
//! or `SecretId::compartment(compartment_id)`), so a lockout on one key
//! never blocks unrelated operations.
//!
//! There is deliberately no `reset`/`clear` method: the only ways a
//! secret's failure count and lockout are lifted are a *successful*
//! unlock ([`ThrottleTracker::record_success`]) or the backoff period
//! elapsing on its own. This is what makes the tracker safe to hand to
//! the custom-protocol server (spec §7): a calling app cannot reset its
//! own lockout by any request shape, only by waiting or by supplying the
//! correct passphrase.
//!
//! State is held in memory by the background service and is not
//! required to survive a service restart (spec §5.5) — this type has no
//! persistence of its own by design.

use std::collections::HashMap;
use std::fmt;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use uuid::Uuid;

use crate::error::{Result, VaultError};

pub const DEFAULT_FAILURE_THRESHOLD: u32 = 5;
pub const DEFAULT_BASE_DELAY: Duration = Duration::from_secs(1);
pub const DEFAULT_MAX_DELAY: Duration = Duration::from_secs(300);

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct SecretId(String);

impl SecretId {
    pub fn key(key_id: Uuid) -> Self {
        Self(format!("key:{key_id}"))
    }

    pub fn compartment(compartment_id: Uuid) -> Self {
        Self(format!("compartment:{compartment_id}"))
    }

    pub fn transfer_password(packet_id: Uuid) -> Self {
        Self(format!("transfer:{packet_id}"))
    }
}

impl fmt::Display for SecretId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

#[derive(Debug, Default)]
struct State {
    consecutive_failures: u32,
    locked_until: Option<Instant>,
}

pub struct ThrottleTracker {
    failure_threshold: u32,
    base_delay: Duration,
    max_delay: Duration,
    states: Mutex<HashMap<SecretId, State>>,
}

impl ThrottleTracker {
    pub fn new() -> Self {
        Self::with_params(DEFAULT_FAILURE_THRESHOLD, DEFAULT_BASE_DELAY, DEFAULT_MAX_DELAY)
    }

    pub fn with_params(failure_threshold: u32, base_delay: Duration, max_delay: Duration) -> Self {
        Self {
            failure_threshold,
            base_delay,
            max_delay,
            states: Mutex::new(HashMap::new()),
        }
    }

    /// Call before attempting to verify a passphrase against `secret`.
    /// Returns `Err(VaultError::LockedOut)` if this secret is currently
    /// backed off; the caller must not even attempt verification in that
    /// case (spec §5.5: no entry point is exempt from this check).
    pub fn check(&self, secret: &SecretId) -> Result<()> {
        let states = self.states.lock().unwrap();
        if let Some(state) = states.get(secret) {
            if let Some(locked_until) = state.locked_until {
                if Instant::now() < locked_until {
                    return Err(VaultError::LockedOut);
                }
            }
        }
        Ok(())
    }

    /// Record a wrong-passphrase attempt against `secret`. Once
    /// `consecutive_failures` reaches the threshold (default 5), imposes
    /// an increasing backoff delay before the next attempt is permitted.
    pub fn record_failure(&self, secret: &SecretId) {
        let mut states = self.states.lock().unwrap();
        let state = states.entry(secret.clone()).or_default();
        state.consecutive_failures += 1;
        if state.consecutive_failures >= self.failure_threshold {
            let over = state.consecutive_failures - self.failure_threshold;
            let delay = self
                .base_delay
                .checked_mul(1u32.checked_shl(over.min(30)).unwrap_or(u32::MAX))
                .unwrap_or(self.max_delay)
                .min(self.max_delay);
            state.locked_until = Some(Instant::now() + delay);
        }
    }

    /// Record a correct-passphrase verification against `secret`. This
    /// is the only way (besides the backoff period elapsing) that a
    /// secret's failure count and lockout are lifted.
    pub fn record_success(&self, secret: &SecretId) {
        let mut states = self.states.lock().unwrap();
        states.remove(secret);
    }

    /// Time remaining before `secret` may be attempted again, if locked.
    pub fn remaining_lockout(&self, secret: &SecretId) -> Option<Duration> {
        let states = self.states.lock().unwrap();
        let state = states.get(secret)?;
        let locked_until = state.locked_until?;
        let now = Instant::now();
        if locked_until > now {
            Some(locked_until - now)
        } else {
            None
        }
    }
}

impl Default for ThrottleTracker {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fast_tracker() -> ThrottleTracker {
        // Small threshold/delays so tests run in milliseconds, not
        // minutes, while exercising the same logic as production
        // defaults.
        ThrottleTracker::with_params(3, Duration::from_millis(20), Duration::from_millis(200))
    }

    #[test]
    fn allows_attempts_below_threshold() {
        let tracker = fast_tracker();
        let secret = SecretId::key(Uuid::new_v4());
        tracker.record_failure(&secret);
        tracker.record_failure(&secret);
        assert!(tracker.check(&secret).is_ok());
    }

    #[test]
    fn locks_out_at_threshold() {
        let tracker = fast_tracker();
        let secret = SecretId::key(Uuid::new_v4());
        for _ in 0..3 {
            tracker.record_failure(&secret);
        }
        assert!(tracker.check(&secret).is_err());
    }

    #[test]
    fn lockout_expires_after_backoff_elapses() {
        let tracker = fast_tracker();
        let secret = SecretId::key(Uuid::new_v4());
        for _ in 0..3 {
            tracker.record_failure(&secret);
        }
        assert!(tracker.check(&secret).is_err());
        std::thread::sleep(Duration::from_millis(40));
        assert!(tracker.check(&secret).is_ok());
    }

    #[test]
    fn backoff_increases_with_further_failures() {
        let tracker = fast_tracker();
        let secret = SecretId::key(Uuid::new_v4());
        for _ in 0..3 {
            tracker.record_failure(&secret);
        }
        let first_lockout = tracker.remaining_lockout(&secret).unwrap();
        tracker.record_failure(&secret); // one more failure past threshold
        let second_lockout = tracker.remaining_lockout(&secret).unwrap();
        assert!(
            second_lockout >= first_lockout,
            "backoff must not shrink after another failure: {first_lockout:?} -> {second_lockout:?}"
        );
    }

    #[test]
    fn backoff_never_exceeds_max_delay() {
        let tracker = fast_tracker();
        let secret = SecretId::key(Uuid::new_v4());
        for _ in 0..30 {
            tracker.record_failure(&secret);
        }
        let lockout = tracker.remaining_lockout(&secret).unwrap();
        assert!(lockout <= Duration::from_millis(200));
    }

    #[test]
    fn success_clears_failure_count_and_lockout() {
        let tracker = fast_tracker();
        let secret = SecretId::key(Uuid::new_v4());
        for _ in 0..3 {
            tracker.record_failure(&secret);
        }
        assert!(tracker.check(&secret).is_err());
        tracker.record_success(&secret);
        assert!(tracker.check(&secret).is_ok());
        assert_eq!(tracker.remaining_lockout(&secret), None);
    }

    #[test]
    fn lockout_on_one_secret_does_not_block_another() {
        let tracker = fast_tracker();
        let locked = SecretId::key(Uuid::new_v4());
        let other = SecretId::key(Uuid::new_v4());
        for _ in 0..3 {
            tracker.record_failure(&locked);
        }
        assert!(tracker.check(&locked).is_err());
        assert!(tracker.check(&other).is_ok());
    }

    #[test]
    fn master_and_key_secrets_are_independent_even_with_same_uuid() {
        let tracker = fast_tracker();
        let id = Uuid::new_v4();
        let key_secret = SecretId::key(id);
        let compartment_secret = SecretId::compartment(id);
        for _ in 0..3 {
            tracker.record_failure(&key_secret);
        }
        assert!(tracker.check(&key_secret).is_err());
        assert!(tracker.check(&compartment_secret).is_ok());
    }
}
