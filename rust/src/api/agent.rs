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
    /// Whether the tray popover (engine B) is on screen; either engine may change it.
    pub popover_visible: bool,
    /// Bumped on every broadcast so engines can show they see the same revision.
    pub revision: u32,
}

pub(crate) const REMOTE_DRIVER: &str = "iPhone";

struct Core {
    snap: AgentSnapshot,
    run_id: u64,
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
                popover_visible: false,
                revision: 0,
            },
            run_id: 0,
        }
    }

    fn start_run(&mut self, task: String, total: u32, driver: String) -> u64 {
        eprintln!("[core] run started: {task} ({total} steps) driven by {driver}");
        self.run_id += 1;
        self.snap.task = task;
        self.snap.done = 0;
        self.snap.total = total.max(1);
        self.snap.running = true;
        self.snap.driver = driver;
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
        if self.snap.done >= self.snap.total {
            self.snap.running = false;
        }
        self.snap.running
    }

    fn stop(&mut self) {
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
    let run_id = core().start_run(task, total, from_engine);
    broadcast();
    spawn_run(run_id);
}

/// Simulates a phone taking over the agent: the `checkout` task runs from 0 to 40.
pub fn start_remote_session() {
    let run_id = core().start_run("checkout".into(), 40, REMOTE_DRIVER.into());
    broadcast();
    spawn_run(run_id);
}

pub fn stop_run() {
    core().stop();
    broadcast();
}

pub fn set_popover_visible(visible: bool) {
    core().snap.popover_visible = visible;
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

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
fn platform_rss_kb() -> Option<u32> {
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_completes_after_total_steps() {
        let mut core = Core::new();
        let id = core.start_run("demo".into(), 3, "main".into());
        assert!(core.step(id));
        assert!(core.step(id));
        assert!(!core.step(id));
        assert_eq!(core.snap.done, 3);
        assert!(!core.snap.running);
    }

    #[test]
    fn newer_run_supersedes_older_one() {
        let mut core = Core::new();
        let old = core.start_run("a".into(), 10, "main".into());
        let new = core.start_run("b".into(), 10, REMOTE_DRIVER.into());
        assert!(!core.step(old));
        assert!(core.step(new));
        assert_eq!(core.snap.done, 1);
        assert_eq!(core.snap.driver, REMOTE_DRIVER);
    }

    #[test]
    fn stop_ends_the_active_run() {
        let mut core = Core::new();
        let id = core.start_run("a".into(), 10, "tray".into());
        core.stop();
        assert!(!core.step(id));
        assert!(!core.snap.running);
    }

    #[test]
    fn tokens_never_exceed_budget() {
        let mut core = Core::new();
        core.snap.tokens_budget = 2_000;
        let id = core.start_run("a".into(), 10, "main".into());
        for _ in 0..5 {
            core.step(id);
        }
        assert_eq!(core.snap.tokens_used, 2_000);
    }

    #[test]
    fn task_name_is_a_short_slug() {
        assert_eq!(task_name("Fix the Checkout flow"), "fix-the");
        assert_eq!(task_name("   "), "task");
        assert_eq!(task_name("refactor!!! payments"), "refactor-payments");
    }

    #[test]
    fn rss_is_readable_on_supported_platforms() {
        if cfg!(any(target_os = "linux", target_os = "macos")) {
            assert!(process_rss_kb() > 0);
        }
    }
}
