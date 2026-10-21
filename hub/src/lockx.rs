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

use std::sync::{Mutex, MutexGuard};

/// Take a lock, recovering the guard if the mutex was poisoned.
pub trait LockExt<T> {
    fn lock_or_recover(&self) -> MutexGuard<'_, T>;
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
}
