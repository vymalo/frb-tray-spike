//! Shared agent state for every Flutter engine in the process.
//!
//! The Rust library is loaded once per process, so the statics below are the
//! single source of truth. Each engine subscribes with [`watch_state`] and gets
//! every change pushed to its own `StreamSink`, whichever engine (or the mock
//! remote driver thread) caused it.

use std::sync::{Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::Duration;

use crate::frb_generated::StreamSink;

const STEP_INTERVAL: Duration = Duration::from_millis(450);
const MEMORY_REFRESH: Duration = Duration::from_secs(1);
const TOKENS_PER_STEP: u32 = 1_250;

/// One line of the conversation: a prompt from an engine or the phone, or the
/// mock agent's reply (updated in place while its run progresses).
#[derive(Clone, Debug, PartialEq)]
pub struct ChatMessage {
    pub id: u32,
    pub from_user: bool,
    /// Where a prompt came from ("main", "tray", "iPhone"), or "agent".
    pub author: String,
    pub text: String,
}

/// Process RSS captured at a labelled moment, e.g. right before the tray engine starts.
#[derive(Clone, Debug, PartialEq)]
pub struct MemoryMark {
    pub label: String,
    pub rss_kb: u32,
}

#[derive(Clone, Debug, PartialEq)]
pub struct AgentSnapshot {
    pub task: String,
    pub done: u32,
    pub total: u32,
    pub running: bool,
    /// Who is steering the current run: "iPhone" for the mock remote, otherwise the local engine name.
    pub driver: String,
    pub tokens_used: u32,
    pub tokens_budget: u32,
    pub engines: Vec<String>,
    pub memory_marks: Vec<MemoryMark>,
    pub rss_kb: u32,
    pub messages: Vec<ChatMessage>,
    /// Bumped on every broadcast so engines can show they see the same revision.
    pub revision: u32,
}

pub(crate) const REMOTE_DRIVER: &str = "iPhone";
const AGENT_AUTHOR: &str = "agent";

struct Core {
    snap: AgentSnapshot,
    run_id: u64,
    next_message_id: u32,
    /// The agent message that reports on the current run.
    reply_id: Option<u32>,
}

impl Core {
    fn new() -> Self {
        Self {
            snap: AgentSnapshot {
                task: "checkout".into(),
                done: 0,
                total: 40,
                running: false,
                driver: String::new(),
                tokens_used: 0,
                tokens_budget: 100_000,
                engines: Vec::new(),
                memory_marks: Vec::new(),
                rss_kb: 0,
                messages: Vec::new(),
                revision: 0,
            },
            run_id: 0,
            next_message_id: 0,
            reply_id: None,
        }
    }

    fn push_message(&mut self, from_user: bool, author: &str, text: String) -> u32 {
        self.next_message_id += 1;
        let id = self.next_message_id;
        self.snap.messages.push(ChatMessage { id, from_user, author: author.into(), text });
        id
    }

    fn set_reply(&mut self, text: String) {
        let id = self.reply_id;
        if let Some(m) = self.snap.messages.iter_mut().find(|m| Some(m.id) == id) {
            m.text = text;
        }
    }

    /// Starts a run for `prompt`, sent by `driver`, superseding any active run.
    fn start_run(&mut self, prompt: String, task: String, total: u32, driver: String) -> u64 {
        eprintln!("[core] run started: {task} ({total} steps) driven by {driver}");
        if self.snap.running {
            self.stop();
        }
        self.run_id += 1;
        self.snap.task = task;
        self.snap.done = 0;
        self.snap.total = total.max(1);
        self.snap.running = true;
        self.push_message(true, &driver, prompt);
        self.snap.driver = driver;
        self.reply_id = Some(self.push_message(false, AGENT_AUTHOR, String::new()));
        self.set_reply(format!("Working on {}…", self.snap.task));
        self.run_id
    }

    /// Advances the run; returns false once `run_id` is finished or superseded.
    fn step(&mut self, run_id: u64) -> bool {
        if run_id != self.run_id || !self.snap.running {
            return false;
        }
        self.snap.done += 1;
        self.snap.tokens_used =
            (self.snap.tokens_used + TOKENS_PER_STEP).min(self.snap.tokens_budget);
        let (task, done, total) = (self.snap.task.clone(), self.snap.done, self.snap.total);
        if done >= total {
            self.snap.running = false;
            self.set_reply(format!(
                "Done with {task}: {total} steps. This is a mock agent, so nothing was changed."
            ));
        } else {
            self.set_reply(format!("Working on {task}… step {done} of {total}"));
        }
        self.snap.running
    }

    fn stop(&mut self) {
        if self.snap.running {
            let (task, done, total) = (self.snap.task.clone(), self.snap.done, self.snap.total);
            self.set_reply(format!("Stopped {task} at step {done} of {total}."));
        }
        self.snap.running = false;
        self.run_id += 1;
    }
}

fn core() -> MutexGuard<'static, Core> {
    static CORE: OnceLock<Mutex<Core>> = OnceLock::new();
    CORE.get_or_init(|| Mutex::new(Core::new()))
        .lock()
        .unwrap_or_else(|e| e.into_inner())
}

fn sinks() -> MutexGuard<'static, Vec<StreamSink<AgentSnapshot>>> {
    static SINKS: Mutex<Vec<StreamSink<AgentSnapshot>>> = Mutex::new(Vec::new());
    SINKS.lock().unwrap_or_else(|e| e.into_inner())
}

fn broadcast() {
    let snap = {
        let mut core = core();
        core.snap.revision += 1;
        core.snap.rss_kb = process_rss_kb();
        core.snap.clone()
    };
    // A sink whose engine has gone away fails to add; drop it.
    sinks().retain(|sink| sink.add(snap.clone()).is_ok());
}

fn spawn_run(run_id: u64) {
    thread::spawn(move || loop {
        thread::sleep(STEP_INTERVAL);
        let more = core().step(run_id);
        broadcast();
        if !more {
            break;
        }
    });
}

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// Registers the calling engine and returns how many engines share this state.
pub fn attach_engine(name: String) -> u32 {
    let count = {
        let mut core = core();
        core.snap.engines.push(name);
        core.snap.engines.len() as u32
    };
    broadcast();
    count
}

/// Subscribes the calling engine to every state change. The current state is sent immediately.
pub fn watch_state(sink: StreamSink<AgentSnapshot>) {
    let first = sinks().is_empty();
    sinks().push(sink);
    if first {
        // Keeps the RSS readout live even when no run is active.
        thread::spawn(|| loop {
            thread::sleep(MEMORY_REFRESH);
            broadcast();
        });
    }
    broadcast();
}

/// A local prompt from either engine starts a new run driven by that engine.
pub fn submit_prompt(text: String, from_engine: String) {
    let task = task_name(&text);
    let total = 10 + (text.len() as u32 % 20);
    let run_id = core().start_run(text, task, total, from_engine);
    broadcast();
    spawn_run(run_id);
}

/// Simulates a phone taking over the agent: the `checkout` task runs from 0 to 40.
pub fn start_remote_session() {
    let run_id = core().start_run(
        "Finish the checkout flow".into(),
        "checkout".into(),
        40,
        REMOTE_DRIVER.into(),
    );
    broadcast();
    spawn_run(run_id);
}

pub fn stop_run() {
    core().stop();
    broadcast();
}

pub fn record_memory_mark(label: String) {
    let rss_kb = process_rss_kb();
    core().snap.memory_marks.push(MemoryMark { label, rss_kb });
    broadcast();
}

fn task_name(prompt: &str) -> String {
    let name: String = prompt
        .split_whitespace()
        .take(2)
        .collect::<Vec<_>>()
        .join("-")
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '-')
        .take(18)
        .collect();
    if name.is_empty() {
        "task".into()
    } else {
        name
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn process_rss_kb() -> u32 {
    platform_rss_kb().unwrap_or(0)
}

#[cfg(target_os = "linux")]
fn platform_rss_kb() -> Option<u32> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    status
        .lines()
        .find_map(|l| l.strip_prefix("VmRSS:"))?
        .split_whitespace()
        .next()?
        .parse()
        .ok()
}

#[cfg(target_os = "macos")]
#[allow(deprecated)]
fn platform_rss_kb() -> Option<u32> {
    let mut info: libc::mach_task_basic_info = unsafe { std::mem::zeroed() };
    let mut count = (std::mem::size_of::<libc::mach_task_basic_info>()
        / std::mem::size_of::<libc::natural_t>()) as libc::mach_msg_type_number_t;
    let kr = unsafe {
        libc::task_info(
            libc::mach_task_self(),
            libc::MACH_TASK_BASIC_INFO,
            &mut info as *mut _ as libc::task_info_t,
            &mut count,
        )
    };
    (kr == libc::KERN_SUCCESS).then(|| (info.resident_size / 1024) as u32)
}

// The working set: the process's pages currently in physical memory.
#[cfg(windows)]
fn platform_rss_kb() -> Option<u32> {
    #[repr(C)]
    struct ProcessMemoryCounters {
        cb: u32,
        page_fault_count: u32,
        peak_working_set_size: usize,
        working_set_size: usize,
        quota_peak_paged_pool_usage: usize,
        quota_paged_pool_usage: usize,
        quota_peak_non_paged_pool_usage: usize,
        quota_non_paged_pool_usage: usize,
        pagefile_usage: usize,
        peak_pagefile_usage: usize,
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetCurrentProcess() -> *mut std::ffi::c_void;
        fn K32GetProcessMemoryInfo(
            process: *mut std::ffi::c_void,
            counters: *mut ProcessMemoryCounters,
            size: u32,
        ) -> i32;
    }
    let size = std::mem::size_of::<ProcessMemoryCounters>() as u32;
    let mut counters: ProcessMemoryCounters = unsafe { std::mem::zeroed() };
    counters.cb = size;
    let ok = unsafe { K32GetProcessMemoryInfo(GetCurrentProcess(), &mut counters, size) };
    (ok != 0).then_some((counters.working_set_size / 1024) as u32)
}

#[cfg(not(any(target_os = "linux", target_os = "macos", windows)))]
fn platform_rss_kb() -> Option<u32> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_completes_after_total_steps() {
        let mut core = Core::new();
        let id = core.start_run("demo it".into(), "demo".into(), 3, "main".into());
        assert!(core.step(id));
        assert!(core.step(id));
        assert!(!core.step(id));
        assert_eq!(core.snap.done, 3);
        assert!(!core.snap.running);
    }

    #[test]
    fn newer_run_supersedes_older_one() {
        let mut core = Core::new();
        let old = core.start_run("a".into(), "a".into(), 10, "main".into());
        let new = core.start_run("b".into(), "b".into(), 10, REMOTE_DRIVER.into());
        assert!(!core.step(old));
        assert!(core.step(new));
        assert_eq!(core.snap.done, 1);
        assert_eq!(core.snap.driver, REMOTE_DRIVER);
    }

    #[test]
    fn stop_ends_the_active_run() {
        let mut core = Core::new();
        let id = core.start_run("a".into(), "a".into(), 10, "tray".into());
        core.stop();
        assert!(!core.step(id));
        assert!(!core.snap.running);
    }

    #[test]
    fn tokens_never_exceed_budget() {
        let mut core = Core::new();
        core.snap.tokens_budget = 2_000;
        let id = core.start_run("a".into(), "a".into(), 10, "main".into());
        for _ in 0..5 {
            core.step(id);
        }
        assert_eq!(core.snap.tokens_used, 2_000);
    }

    #[test]
    fn prompt_and_reply_become_chat_messages() {
        let mut core = Core::new();
        let id = core.start_run("Fix login".into(), "fix-login".into(), 2, "tray".into());
        let user = &core.snap.messages[0];
        assert!(user.from_user);
        assert_eq!((user.author.as_str(), user.text.as_str()), ("tray", "Fix login"));

        core.step(id);
        assert_eq!(core.snap.messages[1].text, "Working on fix-login… step 1 of 2");
        core.step(id);
        assert!(core.snap.messages[1].text.starts_with("Done with fix-login"));
        assert_eq!(core.snap.messages.len(), 2);
    }

    #[test]
    fn superseded_run_reply_says_it_stopped() {
        let mut core = Core::new();
        let first = core.start_run("a".into(), "a".into(), 10, "main".into());
        core.step(first);
        core.start_run("b".into(), "b".into(), 10, REMOTE_DRIVER.into());
        assert_eq!(core.snap.messages[1].text, "Stopped a at step 1 of 10.");
        assert_eq!(core.snap.messages.len(), 4);
    }

    #[test]
    fn task_name_is_a_short_slug() {
        assert_eq!(task_name("Fix the Checkout flow"), "fix-the");
        assert_eq!(task_name("   "), "task");
        assert_eq!(task_name("refactor!!! payments"), "refactor-payments");
    }

    #[test]
    fn rss_is_readable_on_supported_platforms() {
        if cfg!(any(target_os = "linux", target_os = "macos", windows)) {
            assert!(process_rss_kb() > 0);
        }
    }
}
