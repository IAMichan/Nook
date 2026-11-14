//! Scheduled tasks: when a task runs next, which runs are skipped, and the guards that keep a task from overlapping
//! itself (`ScheduledTasks.swift` on the Mac). No timers, processes or files here; [`super::scheduler`] owns those.
//!
//! Decoding is tolerant: a missing field falls back to a safe default, an unknown rule becomes `Webhook` (which never
//! fires by itself) and a row without `enabled` stays off, so a row written by a newer version never starts running by
//! surprise.

use std::collections::{HashMap, HashSet, VecDeque};

use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveTime, TimeZone, Utc};
use serde::{Deserialize, Deserializer, Serialize};
use serde_json::Value;
use uuid::Uuid;

use super::models::{PermissionPolicy, RunProvider};

/// When a task runs.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ScheduleRule {
    /// Every `seconds` after the previous run finished.
    Interval { seconds: i64 },
    /// At `hour:minute` local time on these weekdays (1 = Sunday … 7 = Saturday, like the Mac); empty = every day.
    #[serde(rename = "fixedTime")]
    FixedTime { hour: u32, minute: u32, weekdays: Vec<u32> },
    /// Only when its webhook receives a signed request.
    Webhook,
    /// One run at this moment, then done. A run the computer slept through runs as soon as it is awake again.
    Once { at: DateTime<Utc> },
}

/// The shortest interval. Rows saved with less still load, but run at this rate.
pub const MINIMUM_INTERVAL_SECONDS: i64 = 60;
/// A fixed-time run that is more than this late (the computer slept through it) is skipped instead of run late.
pub const MISSED_GRACE_SECONDS: i64 = 10 * 60;

impl ScheduleRule {
    pub fn is_webhook(&self) -> bool {
        matches!(self, Self::Webhook)
    }

    pub fn is_once(&self) -> bool {
        matches!(self, Self::Once { .. })
    }

    fn from_value(v: &Value) -> Self {
        let int = |key: &str| v.get(key).and_then(Value::as_i64);
        match v.get("type").and_then(Value::as_str).unwrap_or_default() {
            "interval" => Self::Interval { seconds: int("seconds").unwrap_or(MINIMUM_INTERVAL_SECONDS) },
            "fixedTime" => Self::FixedTime {
                hour: int("hour").unwrap_or(9).clamp(0, 99) as u32,
                minute: int("minute").unwrap_or(0).clamp(0, 99) as u32,
                weekdays: v
                    .get("weekdays")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(Value::as_i64).map(|d| d.clamp(0, 99) as u32).collect())
                    .unwrap_or_default(),
            },
            // Without its moment it can never run: a webhook rule, which never fires by itself.
            "once" => match v.get("at").and_then(Value::as_str).and_then(|s| DateTime::parse_from_rfc3339(s).ok()) {
                Some(at) => Self::Once { at: at.with_timezone(&Utc) },
                None => Self::Webhook,
            },
            _ => Self::Webhook,
        }
    }
}

impl<'de> Deserialize<'de> for ScheduleRule {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Self::from_value(&Value::deserialize(d)?))
    }
}

/// The wall-clock moment `hour:minute` on `day` in `tz`. A time inside a spring-forward gap runs just after the gap
/// instead of never; a repeated time (autumn) takes the first one.
fn wall_clock<Tz: TimeZone>(tz: &Tz, day: NaiveDate, hour: u32, minute: u32) -> Option<DateTime<Utc>> {
    let time = NaiveTime::from_hms_opt(hour, 0, 0)? + Duration::minutes(minute.into());
    let mut local = day.and_time(time);
    for _ in 0..=180 {
        if let Some(first) = tz.from_local_datetime(&local).earliest() {
            return Some(first.with_timezone(&Utc));
        }
        local += Duration::minutes(1);
    }
    None
}

/// 1 = Sunday … 7 = Saturday.
pub fn weekday_number(date: NaiveDate) -> u32 {
    date.weekday().num_days_from_sunday() + 1
}

/// The next run. Intervals count from when the previous run FINISHED, so a slow run moves the schedule and runs never
/// pile up. A fixed time is the next matching weekday and wall-clock time after `now`. Webhooks have none. Once is its
/// moment until it ran, then none. A result at or before `now` means "due".
pub fn next_run<Tz: TimeZone>(
    rule: &ScheduleRule,
    last_finished: Option<DateTime<Utc>>,
    now: DateTime<Utc>,
    tz: &Tz,
) -> Option<DateTime<Utc>> {
    match rule {
        ScheduleRule::Webhook => None,
        ScheduleRule::Once { at } => last_finished.is_none().then_some(*at),
        ScheduleRule::Interval { seconds } => {
            Some(last_finished.unwrap_or(now) + Duration::seconds((*seconds).max(MINIMUM_INTERVAL_SECONDS)))
        }
        ScheduleRule::FixedTime { hour, minute, weekdays } => {
            if *hour > 23 || *minute > 59 {
                return None;
            }
            let valid: HashSet<u32> = weekdays.iter().copied().filter(|d| (1..=7).contains(d)).collect();
            // Only invalid days were given: nothing can match, which is not the same as "every day".
            if !weekdays.is_empty() && valid.is_empty() {
                return None;
            }
            let from = last_finished.map_or(now, |f| f.max(now));
            let start = from.with_timezone(tz).date_naive();
            // Day by day with wall-clock times, so DST shifts, month ends and leap days come out right.
            (0..=8).filter_map(|offset| start.checked_add_signed(Duration::days(offset))).find_map(|day| {
                let candidate = wall_clock(tz, day, *hour, *minute)?;
                let local_day = candidate.with_timezone(tz).date_naive();
                (candidate > from && (valid.is_empty() || valid.contains(&weekday_number(local_day)))).then_some(candidate)
            })
        }
    }
}

/// True when the run is older than the grace period: skip it and plan the next one.
pub fn is_missed(scheduled_for: DateTime<Utc>, now: DateTime<Utc>) -> bool {
    (now - scheduled_for).num_seconds() > MISSED_GRACE_SECONDS
}

/// Only fixed times can be missed; an overdue interval simply runs once, now, and a once-task runs when awake again.
pub fn should_skip(rule: &ScheduleRule, scheduled_for: DateTime<Utc>, now: DateTime<Utc>) -> bool {
    matches!(rule, ScheduleRule::FixedTime { .. }) && is_missed(scheduled_for, now)
}

/// Where a run goes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum ScheduledTaskTarget {
    /// Every run starts a new session in this folder with this agent and account.
    #[serde(rename_all = "camelCase")]
    NewSession { project_path: String, provider: RunProvider, profile_id: Option<String> },
    /// Every run goes to this session. `fresh`: each run tells the agent to start over on the task alone; otherwise it
    /// continues the conversation.
    #[serde(rename_all = "camelCase")]
    ExistingSession { id: Uuid, fresh: bool },
}

impl ScheduledTaskTarget {
    fn from_value(v: &Value) -> Self {
        let id = v.get("id").and_then(Value::as_str).and_then(|s| Uuid::parse_str(s).ok());
        if let (Some(id), Some("existingSession")) = (id, v.get("type").and_then(Value::as_str)) {
            return Self::ExistingSession { id, fresh: v.get("fresh").and_then(Value::as_bool).unwrap_or(false) };
        }
        Self::NewSession {
            project_path: v.get("projectPath").and_then(Value::as_str).unwrap_or_default().into(),
            provider: v.get("provider").and_then(|p| serde_json::from_value(p.clone()).ok()).unwrap_or(RunProvider::Claude),
            profile_id: v.get("profileId").and_then(Value::as_str).map(str::to_string),
        }
    }
}

impl<'de> Deserialize<'de> for ScheduledTaskTarget {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Self, D::Error> {
        Ok(Self::from_value(&Value::deserialize(d)?))
    }
}

impl Default for ScheduledTaskTarget {
    fn default() -> Self {
        Self::NewSession { project_path: String::new(), provider: RunProvider::Claude, profile_id: None }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScheduledRunStatus {
    Running,
    Succeeded,
    Failed,
    /// Missed, overlapping or disabled when it came due.
    Skipped,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ScheduleTrigger {
    Schedule,
    Manual,
    Webhook,
}

impl ScheduleTrigger {
    pub fn id(self) -> &'static str {
        match self {
            Self::Schedule => "schedule",
            Self::Manual => "manual",
            Self::Webhook => "webhook",
        }
    }
}

/// Codes stored in `last_error` that the interface turns into its own text (other errors are shown as they are).
pub mod reason {
    pub const MISSED: &str = "sched.skip.missed";
    pub const OVERLAP: &str = "sched.skip.overlap";
    pub const INTERRUPTED: &str = "sched.error.interrupted";
    pub const NO_SESSION: &str = "sched.error.noSession";
    pub const BAD_TARGET: &str = "sched.error.badTarget";
    pub const WEBHOOK_RIGHTS: &str = "sched.error.webhookRights";
}

fn rule_or_webhook<'de, D: Deserializer<'de>>(d: D) -> Result<ScheduleRule, D::Error> {
    Ok(Option::<Value>::deserialize(d)?.map_or(ScheduleRule::Webhook, |v| ScheduleRule::from_value(&v)))
}

fn ask() -> PermissionPolicy {
    PermissionPolicy::Ask
}

fn webhook_rule() -> ScheduleRule {
    ScheduleRule::Webhook
}

/// One scheduled task, as stored in `scheduled-tasks.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScheduledTask {
    #[serde(default = "Uuid::new_v4")]
    pub id: Uuid,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub prompt: String,
    #[serde(default = "webhook_rule", deserialize_with = "rule_or_webhook")]
    pub rule: ScheduleRule,
    #[serde(default)]
    pub target: ScheduledTaskTarget,
    /// A row without the flag stays off: an unknown state must not start running.
    #[serde(default)]
    pub enabled: bool,
    /// The rights the user chose for its sessions; "ask" when none was stored.
    #[serde(default = "ask")]
    pub permission: PermissionPolicy,
    #[serde(default)]
    pub last_run: Option<DateTime<Utc>>,
    #[serde(default)]
    pub last_status: Option<ScheduledRunStatus>,
    #[serde(default)]
    pub last_error: Option<String>,
    #[serde(default)]
    pub next_run: Option<DateTime<Utc>>,
    /// The session the latest run started or went to, so the list can open it.
    #[serde(default)]
    pub last_session: Option<Uuid>,
    #[serde(default = "epoch")]
    pub created_at: DateTime<Utc>,
}

fn epoch() -> DateTime<Utc> {
    DateTime::<Utc>::from_timestamp(0, 0).unwrap_or_default()
}

impl ScheduledTask {
    pub fn new(title: &str, prompt: &str, rule: ScheduleRule, target: ScheduledTaskTarget, now: DateTime<Utc>) -> Self {
        Self {
            id: Uuid::new_v4(),
            title: title.into(),
            prompt: prompt.into(),
            rule,
            target,
            enabled: true,
            permission: PermissionPolicy::Ask,
            last_run: None,
            last_status: None,
            last_error: None,
            next_run: None,
            last_session: None,
            created_at: now,
        }
    }

    /// The next run when the task is (re)planned now: a once-task that already ran stays done, any other rule counts
    /// from now. `keeps_history` is false when the schedule itself changed, so a new moment for a once-task runs again.
    pub fn planned_run<Tz: TimeZone>(&self, now: DateTime<Utc>, keeps_history: bool, tz: &Tz) -> Option<DateTime<Utc>> {
        if !self.enabled {
            return None;
        }
        let finished = if self.rule.is_once() && keeps_history { self.last_run } else { None };
        next_run(&self.rule, finished, now, tz)
    }

    /// A once-task that has run: nothing more to do.
    pub fn is_done(&self) -> bool {
        self.rule.is_once() && self.last_run.is_some() && self.last_status != Some(ScheduledRunStatus::Running)
    }

    /// One key per task, due time and trigger: a retry of the same firing is recognised and does not start twice.
    pub fn fire_key(task: Uuid, scheduled_for: DateTime<Utc>, trigger: ScheduleTrigger) -> String {
        format!("scheduled-task:{task}:{}:{}", scheduled_for.timestamp_millis(), trigger.id())
    }

    /// The row after a run ended: records the outcome and plans the next run from the finish time.
    pub fn finishing<Tz: TimeZone>(
        &self,
        status: ScheduledRunStatus,
        error: Option<String>,
        finished: DateTime<Utc>,
        tz: &Tz,
    ) -> Self {
        let mut copy = self.clone();
        copy.last_run = Some(finished);
        copy.last_status = Some(status);
        copy.last_error = error;
        copy.next_run = if self.enabled { next_run(&self.rule, Some(finished), finished, tz) } else { None };
        copy
    }

    /// Rows left `running` by a restart become failed and are planned again, so a crashed run neither blocks the task
    /// forever nor counts as a success. Other rows come back unchanged.
    pub fn recover_interrupted<Tz: TimeZone>(tasks: Vec<Self>, now: DateTime<Utc>, tz: &Tz) -> Vec<Self> {
        tasks
            .into_iter()
            .map(|task| {
                if task.last_status != Some(ScheduledRunStatus::Running) {
                    return task;
                }
                let mut copy = task.finishing(ScheduledRunStatus::Failed, Some(reason::INTERRUPTED.into()), now, tz);
                copy.last_run = task.last_run.or(Some(now));
                copy
            })
            .collect()
    }
}

/// The rights a run gets: what the user stored on the task, and always "ask" for a webhook run, whose payload is not
/// from the user. Nothing unattended runs with full rights, whatever an old row says. A policy the agent does not offer
/// falls back to "ask".
pub fn effective_permission(stored: PermissionPolicy, provider: RunProvider, trigger: ScheduleTrigger) -> PermissionPolicy {
    let capped = if stored == PermissionPolicy::Bypass { PermissionPolicy::Ask } else { stored };
    let wanted = if trigger == ScheduleTrigger::Webhook { PermissionPolicy::Ask } else { capped };
    let offered = provider.capabilities().policies;
    if offered.contains(&wanted) {
        wanted
    } else if offered.contains(&PermissionPolicy::Ask) {
        PermissionPolicy::Ask
    } else {
        offered.first().copied().unwrap_or(PermissionPolicy::Ask)
    }
}

/// Remembers fire keys so a firing that is delivered twice runs once. Bounded.
#[derive(Debug, Clone)]
pub struct FireLedger {
    order: VecDeque<String>,
    seen: HashSet<String>,
    capacity: usize,
}

impl Default for FireLedger {
    fn default() -> Self {
        Self::new(500)
    }
}

impl FireLedger {
    pub fn new(capacity: usize) -> Self {
        Self { order: VecDeque::new(), seen: HashSet::new(), capacity: capacity.max(1) }
    }

    /// True the first time `key` is seen.
    pub fn claim(&mut self, key: &str) -> bool {
        if !self.seen.insert(key.to_string()) {
            return false;
        }
        self.order.push_back(key.to_string());
        if self.order.len() > self.capacity {
            if let Some(old) = self.order.pop_front() {
                self.seen.remove(&old);
            }
        }
        true
    }
}

/// No overlap: one active run per task.
#[derive(Debug, Clone, Default)]
pub struct RunGate(HashSet<Uuid>);

impl RunGate {
    pub fn is_running(&self, task: Uuid) -> bool {
        self.0.contains(&task)
    }

    /// False when the task already runs.
    pub fn begin(&mut self, task: Uuid) -> bool {
        self.0.insert(task)
    }

    pub fn finish(&mut self, task: Uuid) {
        self.0.remove(&task);
    }
}

/// Bounds the deliveries a task holds (waiting plus running) at 20 and refuses the next one; it never drops an older
/// delivery, which the sender was already told was accepted.
#[derive(Debug, Clone, Default)]
pub struct WebhookQueue(HashMap<Uuid, usize>);

pub const MAX_QUEUED_PER_TASK: usize = 20;

impl WebhookQueue {
    pub fn count(&self, task: Uuid) -> usize {
        self.0.get(&task).copied().unwrap_or(0)
    }

    /// False when the task's queue is full.
    pub fn admit(&mut self, task: Uuid) -> bool {
        let n = self.count(task);
        if n >= MAX_QUEUED_PER_TASK {
            return false;
        }
        self.0.insert(task, n + 1);
        true
    }

    pub fn release(&mut self, task: Uuid) {
        let n = self.count(task).saturating_sub(1);
        if n == 0 {
            self.0.remove(&task);
        } else {
            self.0.insert(task, n);
        }
    }

    pub fn forget(&mut self, task: Uuid) {
        self.0.remove(&task);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;
    use chrono_tz::Europe::Amsterdam;

    fn utc(s: &str) -> DateTime<Utc> {
        DateTime::parse_from_rfc3339(s).unwrap().with_timezone(&Utc)
    }

    #[test]
    fn interval_counts_from_the_end_of_the_previous_run() {
        let rule = ScheduleRule::Interval { seconds: 600 };
        let now = utc("2026-03-02T10:00:00Z");
        assert_eq!(next_run(&rule, None, now, &Utc), Some(utc("2026-03-02T10:10:00Z")));
        let finished = utc("2026-03-02T10:17:30Z");
        assert_eq!(next_run(&rule, Some(finished), now, &Utc), Some(utc("2026-03-02T10:27:30Z")));
    }

    #[test]
    fn interval_has_a_one_minute_floor() {
        let rule = ScheduleRule::Interval { seconds: 5 };
        let now = utc("2026-03-02T10:00:00Z");
        assert_eq!(next_run(&rule, None, now, &Utc), Some(utc("2026-03-02T10:01:00Z")));
    }

    #[test]
    fn fixed_time_is_today_or_tomorrow() {
        let rule = ScheduleRule::FixedTime { hour: 9, minute: 30, weekdays: vec![] };
        let tz = FixedOffset::east_opt(3600).unwrap();
        // 08:00 local: today at 09:30 local (08:30 UTC).
        assert_eq!(next_run(&rule, None, utc("2026-03-02T07:00:00Z"), &tz), Some(utc("2026-03-02T08:30:00Z")));
        // 10:00 local: tomorrow.
        assert_eq!(next_run(&rule, None, utc("2026-03-02T09:00:00Z"), &tz), Some(utc("2026-03-03T08:30:00Z")));
        // Exactly the time: not again now, the next day.
        assert_eq!(next_run(&rule, None, utc("2026-03-02T08:30:00Z"), &tz), Some(utc("2026-03-03T08:30:00Z")));
    }

    #[test]
    fn fixed_time_honours_weekdays() {
        // 2026-03-02 is a Monday. Only Fridays (6).
        let rule = ScheduleRule::FixedTime { hour: 9, minute: 0, weekdays: vec![6] };
        assert_eq!(next_run(&rule, None, utc("2026-03-02T12:00:00Z"), &Utc), Some(utc("2026-03-06T09:00:00Z")));
        // Sunday is 1.
        let sunday = ScheduleRule::FixedTime { hour: 9, minute: 0, weekdays: vec![1] };
        assert_eq!(next_run(&sunday, None, utc("2026-03-02T12:00:00Z"), &Utc), Some(utc("2026-03-08T09:00:00Z")));
        // Only invalid days: never.
        let invalid = ScheduleRule::FixedTime { hour: 9, minute: 0, weekdays: vec![0, 9] };
        assert_eq!(next_run(&invalid, None, utc("2026-03-02T12:00:00Z"), &Utc), None);
        let bad_hour = ScheduleRule::FixedTime { hour: 24, minute: 0, weekdays: vec![] };
        assert_eq!(next_run(&bad_hour, None, utc("2026-03-02T12:00:00Z"), &Utc), None);
    }

    #[test]
    fn fixed_time_follows_the_wall_clock_over_dst() {
        let rule = ScheduleRule::FixedTime { hour: 9, minute: 0, weekdays: vec![] };
        // Amsterdam goes to summer time on 2026-03-29: 09:00 is 08:00 UTC before and 07:00 UTC after.
        assert_eq!(next_run(&rule, None, utc("2026-03-28T10:00:00Z"), &Amsterdam), Some(utc("2026-03-29T07:00:00Z")));
        // A time inside the gap (02:30 does not exist that night) runs right after it, at 03:00 local.
        let gap = ScheduleRule::FixedTime { hour: 2, minute: 30, weekdays: vec![] };
        assert_eq!(next_run(&gap, None, utc("2026-03-28T22:00:00Z"), &Amsterdam), Some(utc("2026-03-29T01:00:00Z")));
        // A repeated time (02:30 twice on 2026-10-25) takes the first.
        assert_eq!(next_run(&gap, None, utc("2026-10-24T22:00:00Z"), &Amsterdam), Some(utc("2026-10-25T00:30:00Z")));
    }

    #[test]
    fn fixed_time_counts_from_the_last_finish_when_later() {
        let rule = ScheduleRule::FixedTime { hour: 9, minute: 0, weekdays: vec![] };
        // A run that ended after today's slot: tomorrow, also when "now" is earlier (a clock that went back).
        assert_eq!(
            next_run(&rule, Some(utc("2026-03-02T09:05:00Z")), utc("2026-03-02T08:00:00Z"), &Utc),
            Some(utc("2026-03-03T09:00:00Z"))
        );
    }

    #[test]
    fn once_runs_until_it_ran_and_webhooks_never_by_themselves() {
        let at = utc("2026-03-05T12:00:00Z");
        let rule = ScheduleRule::Once { at };
        assert_eq!(next_run(&rule, None, utc("2026-03-02T00:00:00Z"), &Utc), Some(at));
        // Slept through it: still due (at or before now), not skipped.
        let late = utc("2026-03-06T00:00:00Z");
        assert_eq!(next_run(&rule, None, late, &Utc), Some(at));
        assert!(!should_skip(&rule, at, late));
        assert_eq!(next_run(&rule, Some(late), late, &Utc), None);
        assert_eq!(next_run(&ScheduleRule::Webhook, None, late, &Utc), None);
    }

    #[test]
    fn a_missed_fixed_time_is_skipped_but_an_overdue_interval_runs() {
        let due = utc("2026-03-02T09:00:00Z");
        let fixed = ScheduleRule::FixedTime { hour: 9, minute: 0, weekdays: vec![] };
        assert!(!should_skip(&fixed, due, utc("2026-03-02T09:09:59Z")));
        assert!(should_skip(&fixed, due, utc("2026-03-02T09:10:01Z")));
        let interval = ScheduleRule::Interval { seconds: 3600 };
        assert!(!should_skip(&interval, due, utc("2026-03-03T09:00:00Z")));
    }

    #[test]
    fn finishing_plans_the_next_run_and_once_is_done() {
        let now = utc("2026-03-02T10:00:00Z");
        let task = ScheduledTask::new("t", "p", ScheduleRule::Interval { seconds: 3600 }, Default::default(), now);
        let done = task.finishing(ScheduledRunStatus::Succeeded, None, now, &Utc);
        assert_eq!(done.next_run, Some(utc("2026-03-02T11:00:00Z")));
        assert_eq!(done.last_status, Some(ScheduledRunStatus::Succeeded));

        let once = ScheduledTask::new("t", "p", ScheduleRule::Once { at: now }, Default::default(), now);
        assert!(!once.is_done());
        let ran = once.finishing(ScheduledRunStatus::Succeeded, None, now, &Utc);
        assert!(ran.is_done());
        assert_eq!(ran.next_run, None);
        assert_eq!(ran.planned_run(now, true, &Utc), None);
        // A new moment (the schedule changed) runs again.
        assert_eq!(ran.planned_run(now, false, &Utc), Some(now));
    }

    #[test]
    fn a_run_cut_off_by_a_restart_becomes_failed_and_is_planned_again() {
        let now = utc("2026-03-02T10:00:00Z");
        let mut task = ScheduledTask::new("t", "p", ScheduleRule::Interval { seconds: 3600 }, Default::default(), now);
        task.last_status = Some(ScheduledRunStatus::Running);
        task.last_run = Some(utc("2026-03-02T09:00:00Z"));
        let other = ScheduledTask::new("u", "p", ScheduleRule::Webhook, Default::default(), now);
        let out = ScheduledTask::recover_interrupted(vec![task, other.clone()], now, &Utc);
        assert_eq!(out[0].last_status, Some(ScheduledRunStatus::Failed));
        assert_eq!(out[0].last_error.as_deref(), Some(reason::INTERRUPTED));
        assert_eq!(out[0].last_run, Some(utc("2026-03-02T09:00:00Z")));
        assert_eq!(out[0].next_run, Some(utc("2026-03-02T11:00:00Z")));
        assert_eq!(out[1], other);
    }

    #[test]
    fn decoding_is_tolerant_and_safe() {
        let row: ScheduledTask = serde_json::from_str(r#"{"title":"x","rule":{"type":"fromTheFuture"}}"#).unwrap();
        assert!(!row.enabled);
        assert_eq!(row.rule, ScheduleRule::Webhook);
        assert_eq!(row.permission, PermissionPolicy::Ask);
        let once: ScheduleRule = serde_json::from_str(r#"{"type":"once"}"#).unwrap();
        assert_eq!(once, ScheduleRule::Webhook);
        let rule = ScheduleRule::FixedTime { hour: 7, minute: 5, weekdays: vec![2, 6] };
        let back: ScheduleRule = serde_json::from_str(&serde_json::to_string(&rule).unwrap()).unwrap();
        assert_eq!(back, rule);
        let target = ScheduledTaskTarget::ExistingSession { id: Uuid::new_v4(), fresh: true };
        let back: ScheduledTaskTarget = serde_json::from_str(&serde_json::to_string(&target).unwrap()).unwrap();
        assert_eq!(back, target);
        let target = ScheduledTaskTarget::NewSession { project_path: "/p".into(), provider: RunProvider::Codex, profile_id: None };
        let back: ScheduledTaskTarget = serde_json::from_str(&serde_json::to_string(&target).unwrap()).unwrap();
        assert_eq!(back, target);
    }

    #[test]
    fn unattended_runs_never_get_full_rights() {
        use PermissionPolicy::*;
        assert_eq!(effective_permission(Bypass, RunProvider::Claude, ScheduleTrigger::Schedule), Ask);
        assert_eq!(effective_permission(AcceptEdits, RunProvider::Codex, ScheduleTrigger::Schedule), AcceptEdits);
        assert_eq!(effective_permission(AcceptEdits, RunProvider::Claude, ScheduleTrigger::Webhook), Ask);
    }

    #[test]
    fn ledger_gate_and_queue() {
        let mut ledger = FireLedger::new(2);
        assert!(ledger.claim("a"));
        assert!(!ledger.claim("a"));
        assert!(ledger.claim("b"));
        assert!(ledger.claim("c"));
        assert!(ledger.claim("a"), "the oldest key is forgotten once the ledger is full");

        let id = Uuid::new_v4();
        let mut gate = RunGate::default();
        assert!(gate.begin(id));
        assert!(!gate.begin(id));
        gate.finish(id);
        assert!(!gate.is_running(id));

        let mut queue = WebhookQueue::default();
        for _ in 0..MAX_QUEUED_PER_TASK {
            assert!(queue.admit(id));
        }
        assert!(!queue.admit(id));
        queue.release(id);
        assert!(queue.admit(id));
        queue.forget(id);
        assert_eq!(queue.count(id), 0);
    }

    #[test]
    fn fire_keys_differ_per_trigger_and_moment() {
        let id = Uuid::new_v4();
        let at = utc("2026-03-02T10:00:00Z");
        assert_ne!(
            ScheduledTask::fire_key(id, at, ScheduleTrigger::Schedule),
            ScheduledTask::fire_key(id, at, ScheduleTrigger::Manual)
        );
        assert_eq!(ScheduledTask::fire_key(id, at, ScheduleTrigger::Schedule), ScheduledTask::fire_key(id, at, ScheduleTrigger::Schedule));
    }
}
