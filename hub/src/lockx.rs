//! Poison-tolerant mutex locking.
//!
//! WHY THIS EXISTS
//! ===============
//!
//! Every shared table in this hub lives behind one `Mutex<HubState>`, and the
//! code used to take it with `.lock().unwrap()` in ~100 places. That is the
//! idiomatic spelling, and it is correct about what it says: a poisoned mutex
//! means some thread panicked while holding the lock, so the data it guarded
//! may be inconsistent. Refusing to continue is a defensible choice for a
//! library.
//!
//! It is the WRONG choice for this process. A hub that panics once - a slice
//! index in a parser, an arithmetic overflow in a stats counter, anything that
//! a malformed frame from an untrusted peer can reach - poisons the mutex, and
//! from that moment EVERY subsequent request panics on the unwrap. One bug
//! becomes a permanently dead hub that has to be restarted by hand, and the
//! operator sees a process that is running, listening, and answering nothing.
//!
//! The data behind the lock is a cache of what the nodes last reported, not a
//! ledger. If a writer panicked mid-update the worst case is one stale or
//! half-updated entry, which the next heartbeat or snapshot overwrites within
//! seconds. Trading safety does not depend on it: the EAs own the orders, the
//! hub only observes and relays, and the config store writes are
//! write-temp-then-rename.
//!
//! So: recover the guard, log nothing here (the panic itself was already
//! logged by the panicking thread), and keep serving. Availability beats a
//! consistency guarantee that this process does not actually need.

use std::sync::{Mutex, MutexGuard, RwLock, RwLockReadGuard, RwLockWriteGuard};
use std::time::{Duration, Instant};

/// Take a lock, recovering the guard if the mutex was poisoned.
pub trait LockExt<T> {
    fn lock_or_recover(&self) -> MutexGuard<'_, T>;
    #[allow(dead_code)]
    fn lock_timeout(&self, timeout: Duration) -> Option<MutexGuard<'_, T>>;
}

impl<T> LockExt<T> for Mutex<T> {
    fn lock_or_recover(&self) -> MutexGuard<'_, T> {
        match self.lock() {
            Ok(g) => g,
            //--- the guard is still valid; only the "somebody panicked"
            //--- flag is set. `into_inner` hands back the data as-is.
            Err(poisoned) => poisoned.into_inner(),
        }
    }

    fn lock_timeout(&self, timeout: Duration) -> Option<MutexGuard<'_, T>> {
        let start = Instant::now();
        loop {
            match self.try_lock() {
                Ok(g) => return Some(g),
                Err(std::sync::TryLockError::Poisoned(p)) => return Some(p.into_inner()),
                Err(std::sync::TryLockError::WouldBlock) => {
                    if start.elapsed() >= timeout {
                        eprintln!("[hub] WARN: Mutex lock acquisition timed out after {:?}", timeout);
                        return None;
                    }
                    std::thread::sleep(Duration::from_millis(1));
                }
            }
        }
    }
}

#[allow(dead_code)]
pub trait RwLockExt<T> {
    fn read_or_recover(&self) -> RwLockReadGuard<'_, T>;
    fn write_or_recover(&self) -> RwLockWriteGuard<'_, T>;
}

#[allow(dead_code)]
impl<T> RwLockExt<T> for RwLock<T> {
    fn read_or_recover(&self) -> RwLockReadGuard<'_, T> {
        match self.read() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
    fn write_or_recover(&self) -> RwLockWriteGuard<'_, T> {
        match self.write() {
            Ok(g) => g,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lock_or_recover_recovers_poisoned() {
        let m = std::sync::Arc::new(Mutex::new(42));
        let m_clone = m.clone();
        let _ = std::thread::spawn(move || {
            let _g = m_clone.lock().unwrap();
            panic!("deliberate panic to poison mutex");
        }).join();

        assert!(m.is_poisoned());
        let g = m.lock_or_recover();
        assert_eq!(*g, 42);
    }

    #[test]
    fn test_lock_timeout_success_and_timeout() {
        let m = std::sync::Arc::new(Mutex::new(100));
        let g1 = m.lock_timeout(Duration::from_millis(50));
        assert!(g1.is_some());

        // Contended lock should timeout
        let m_clone = m.clone();
        let handle = std::thread::spawn(move || {
            let g2 = m_clone.lock_timeout(Duration::from_millis(20));
            assert!(g2.is_none());
        });
        handle.join().unwrap();
        drop(g1);

        // Now should succeed again
        let g3 = m.lock_timeout(Duration::from_millis(50));
        assert!(g3.is_some());
    }
}
