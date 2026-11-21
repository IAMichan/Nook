//! Session concurrency cap and queueing (`SessionCapacity` and `CapacityScheduler` on macOS) — AG-75.
//!
//! Every working session runs an agent process with its own model calls. Past `max_working_sessions`, a new turn waits
//! in FIFO order instead of spawning immediately, and starts automatically as soon as another session's turn ends or
//! the limit is raised. Off (`0`, no limit) by default.

use std::collections::{HashMap, VecDeque};
use std::sync::atomic::{AtomicU32, Ordering};

use uuid::Uuid;

/// The choices offered in Settings › Agents › Sessions › Behavior (`0` = no limit).
pub const CHOICES: &[u32] = &[0, 2, 3, 4, 6, 8];

static MAX_WORKING_SESSIONS: AtomicU32 = AtomicU32::new(0);

/// Current global limit from `WorkspaceSettings` (`0` = unlimited).
pub fn max_working_sessions() -> u32 {
    MAX_WORKING_SESSIONS.load(Ordering::Relaxed)
}

/// Updates the global limit when `WorkspaceSettings` loads or saves.
pub fn set_max_working_sessions(limit: u32) {
    MAX_WORKING_SESSIONS.store(limit, Ordering::Relaxed);
}

/// Whether a new turn must wait: `others_working` counts the sessions actively working right now, excluding this
/// session and excluding sessions that are themselves waiting for a free slot.
pub fn must_wait(limit: u32, others_working: usize) -> bool {
    limit > 0 && others_working >= limit as usize
}

/// How many waiting turns may start now, oldest first.
pub fn startable(limit: u32, working: usize, waiting: usize) -> usize {
    if waiting == 0 {
        return 0;
    }
    if limit == 0 {
        return waiting;
    }
    waiting.min((limit as usize).saturating_sub(working))
}

/// Payload kept for a turn waiting for a concurrency slot.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WaitingTurn {
    pub prompt: String,
    pub executable: String,
}

/// Strict FIFO queue of sessions waiting for a free working slot (`CapacityScheduler` on macOS).
#[derive(Debug, Default)]
pub struct CapacityScheduler {
    waiting: HashMap<Uuid, WaitingTurn>,
    order: VecDeque<Uuid>,
}

impl CapacityScheduler {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn is_empty(&self) -> bool {
        self.order.is_empty()
    }

    pub fn len(&self) -> usize {
        self.order.len()
    }

    pub fn is_waiting(&self, id: Uuid) -> bool {
        self.waiting.contains_key(&id)
    }

    /// 0-based queue position of `id`, if waiting.
    pub fn position(&self, id: Uuid) -> Option<usize> {
        self.order.iter().position(|&item| item == id)
    }

    /// Enqueues `id` at the tail (FIFO). If `id` is already waiting, updates its payload in place without moving it.
    pub fn add(&mut self, id: Uuid, prompt: String, executable: String) {
        let already = self.waiting.contains_key(&id);
        self.waiting.insert(id, WaitingTurn { prompt, executable });
        if !already {
            self.order.push_back(id);
        }
    }

    /// Removes and returns a specific waiting turn; `None` if it was not waiting.
    pub fn remove(&mut self, id: Uuid) -> Option<WaitingTurn> {
        let entry = self.waiting.remove(&id)?;
        self.order.retain(|&item| item != id);
        Some(entry)
    }

    /// Pops the oldest waiting turn.
    pub fn pop_next(&mut self) -> Option<(Uuid, WaitingTurn)> {
        while let Some(id) = self.order.pop_front() {
            if let Some(entry) = self.waiting.remove(&id) {
                return Some((id, entry));
            }
        }
        None
    }

    /// Returns up to `count` oldest waiting session IDs without removing them.
    pub fn first(&self, count: usize) -> Vec<Uuid> {
        self.order.iter().copied().take(count).collect()
    }

    /// Dequeues as many waiting turns (oldest first) as can start given `limit` and currently `working` sessions.
    pub fn dequeue_ready(&mut self, limit: u32, working: usize) -> Vec<(Uuid, WaitingTurn)> {
        let count = startable(limit, working, self.len());
        let mut ready = Vec::with_capacity(count);
        for _ in 0..count {
            let Some(item) = self.pop_next() else { break };
            ready.push(item);
        }
        ready
    }

    /// Drops waiting entries whose session no longer exists.
    pub fn prune(&mut self, mut exists: impl FnMut(Uuid) -> bool) {
        self.waiting.retain(|&id, _| exists(id));
        self.order.retain(|id| self.waiting.contains_key(id));
    }

    /// Forgets a deleted session.
    pub fn forget(&mut self, id: Uuid) {
        self.waiting.remove(&id);
        self.order.retain(|&item| item != id);
    }

    /// Clears all waiting turns (for shutdown).
    pub fn clear(&mut self) {
        self.waiting.clear();
        self.order.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_limit_never_waits() {
        assert!(!must_wait(0, 0));
        assert!(!must_wait(0, 50));
        assert_eq!(startable(0, 50, 3), 3);
        assert_eq!(startable(0, 0, 0), 0);
        assert_eq!(CHOICES.first(), Some(&0), "no limit is the default choice");
    }

    #[test]
    fn turn_waits_once_limit_is_reached() {
        assert!(!must_wait(3, 0));
        assert!(!must_wait(3, 2));
        assert!(must_wait(3, 3));
        assert!(must_wait(3, 5), "a lower limit set while more work lets none in");
    }

    #[test]
    fn waiting_turns_start_as_slots_free_up() {
        assert_eq!(startable(3, 3, 2), 0);
        assert_eq!(startable(3, 2, 2), 1);
        assert_eq!(startable(4, 0, 2), 2);
        assert_eq!(startable(2, 5, 2), 0);
        assert_eq!(startable(2, 0, 0), 0);
    }

    #[test]
    fn scheduler_preserves_fifo_order_and_deduplicates() {
        let mut q = CapacityScheduler::new();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let c = Uuid::new_v4();

        assert!(q.is_empty());
        q.add(a, "first".into(), "/bin/claude".into());
        q.add(b, "second".into(), "/bin/codex".into());
        q.add(c, "third".into(), "/bin/gemini".into());
        // Updating an already-waiting session keeps its FIFO position.
        q.add(a, "first-updated".into(), "/bin/claude".into());

        assert_eq!(q.len(), 3);
        assert!(q.is_waiting(a));
        assert_eq!(q.position(a), Some(0));
        assert_eq!(q.position(b), Some(1));
        assert_eq!(q.position(c), Some(2));
        assert_eq!(q.first(2), vec![a, b]);

        let (id1, turn1) = q.pop_next().unwrap();
        assert_eq!(id1, a);
        assert_eq!(turn1.prompt, "first-updated");
        assert!(!q.is_waiting(a));
        assert_eq!(q.len(), 2);
    }

    #[test]
    fn dequeue_ready_starts_oldest_when_slots_open() {
        let mut q = CapacityScheduler::new();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let c = Uuid::new_v4();

        q.add(a, "p1".into(), "claude".into());
        q.add(b, "p2".into(), "claude".into());
        q.add(c, "p3".into(), "claude".into());

        // Full capacity (limit 2, 2 working): none dequeued.
        assert!(q.dequeue_ready(2, 2).is_empty());
        assert_eq!(q.len(), 3);

        // One slot opens (limit 2, 1 working): oldest dequeued.
        let batch1 = q.dequeue_ready(2, 1);
        assert_eq!(batch1.len(), 1);
        assert_eq!(batch1[0].0, a);
        assert_eq!(q.len(), 2);

        // Limit removed (0 = unlimited): all remaining dequeued in FIFO order.
        let batch2 = q.dequeue_ready(0, 2);
        assert_eq!(batch2.iter().map(|(id, _)| *id).collect::<Vec<_>>(), vec![b, c]);
        assert!(q.is_empty());
    }

    #[test]
    fn remove_forget_and_prune_drop_stale_entries() {
        let mut q = CapacityScheduler::new();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let c = Uuid::new_v4();

        q.add(a, "a".into(), "claude".into());
        q.add(b, "b".into(), "claude".into());
        q.add(c, "c".into(), "claude".into());

        assert_eq!(q.remove(b).map(|t| t.prompt), Some("b".into()));
        assert!(!q.is_waiting(b));
        assert_eq!(q.remove(b), None);

        q.prune(|id| id != a);
        assert!(!q.is_waiting(a));
        assert_eq!(q.first(5), vec![c]);

        q.forget(c);
        assert!(q.is_empty());
    }
}
