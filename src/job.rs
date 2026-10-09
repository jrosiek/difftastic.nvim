//! Running a diff: the shared thread pool, progress reports and cancellation.
//!
//! A [`Run`] is the context of one diff computation. Workers report progress
//! through it, check it for cancellation, and start every external process
//! through it, so that cancelling also kills the processes still running.

use std::collections::HashMap;
use std::io::Read;
use std::process::{Child, Command, Output, Stdio};
use std::sync::atomic::{AtomicBool, AtomicIsize, AtomicUsize, Ordering};
use std::sync::{Mutex, OnceLock};

/// Why a diff computation stopped without a result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffError {
    /// The run was cancelled.
    Cancelled,
    /// The run failed; the message says why.
    Failed(String),
}

impl From<String> for DiffError {
    fn from(message: String) -> Self {
        Self::Failed(message)
    }
}

/// A progress report: `count` steps done out of `total` (-1 while unknown).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Update {
    pub count: usize,
    pub total: isize,
    pub message: String,
}

/// Receives the progress reports of a run, from any thread.
pub type Sink = Box<dyn Fn(Update) + Send + Sync>;

/// Processes a run has started and not yet waited for.
#[derive(Default)]
struct Children {
    next_id: u64,
    running: HashMap<u64, Child>,
}

/// The context of one diff computation.
pub struct Run {
    cancelled: AtomicBool,
    // Starting a process and cancelling take this lock, so no process starts
    // after a cancellation has killed the running ones.
    children: Mutex<Children>,
    done: AtomicUsize,
    total: AtomicIsize,
    sink: Option<Sink>,
}

impl Run {
    /// A run reporting progress to `sink`, if any.
    pub fn new(sink: Option<Sink>) -> Self {
        Self {
            cancelled: AtomicBool::new(false),
            children: Mutex::new(Children::default()),
            done: AtomicUsize::new(0),
            total: AtomicIsize::new(-1),
            sink,
        }
    }

    /// Cancels the run: kills its running processes, and every later check,
    /// step or process start fails with [`DiffError::Cancelled`]. Returns once
    /// the processes are killed.
    pub fn cancel(&self) {
        let mut children = self.children.lock().unwrap_or_else(|e| e.into_inner());
        self.cancelled.store(true, Ordering::SeqCst);
        for child in children.running.values_mut() {
            let _ = child.kill();
        }
    }

    pub fn is_cancelled(&self) -> bool {
        self.cancelled.load(Ordering::SeqCst)
    }

    /// Fails once the run is cancelled.
    pub fn check(&self) -> Result<(), DiffError> {
        if self.is_cancelled() {
            Err(DiffError::Cancelled)
        } else {
            Ok(())
        }
    }

    /// Sets the number of steps the run will take.
    pub fn set_total(&self, total: usize) {
        self.total.store(
            isize::try_from(total).unwrap_or(isize::MAX),
            Ordering::SeqCst,
        );
        self.report(self.done.load(Ordering::SeqCst), String::new());
    }

    /// Reports what the run is doing without completing a step.
    pub fn note(&self, message: impl Into<String>) {
        self.report(self.done.load(Ordering::SeqCst), message.into());
    }

    /// Completes one step, described by `message`. Fails once the run is
    /// cancelled, so callers stop with `?`.
    #[must_use = "a cancelled run must stop"]
    pub fn step(&self, message: impl Into<String>) -> Result<(), DiffError> {
        let count = self.done.fetch_add(1, Ordering::SeqCst) + 1;
        self.report(count, message.into());
        self.check()
    }

    fn report(&self, count: usize, message: String) {
        if let Some(sink) = &self.sink {
            sink(Update {
                count,
                total: self.total.load(Ordering::SeqCst),
                message,
            });
        }
    }

    /// Runs `cmd` to completion like [`Command::output`], killed when the run
    /// is cancelled. Fails with [`DiffError::Cancelled`] when the run is
    /// cancelled before or while the process runs.
    pub fn output(&self, cmd: &mut Command) -> Result<Output, DiffError> {
        let program = cmd.get_program().to_string_lossy().into_owned();
        let (id, mut stdout, mut stderr) = {
            let mut children = self.children.lock().unwrap_or_else(|e| e.into_inner());
            self.check()?;
            let mut child = cmd
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .map_err(|e| format!("Failed to run {program}: {e}"))?;
            let (stdout, stderr) = (child.stdout.take(), child.stderr.take());
            let id = children.next_id;
            children.next_id += 1;
            children.running.insert(id, child);
            (id, stdout, stderr)
        };

        // Read both pipes until the process exits (or is killed), outside the
        // lock so a cancellation can kill it meanwhile.
        let (out, err) = std::thread::scope(|scope| {
            let err = scope.spawn(|| {
                let mut buf = Vec::new();
                if let Some(pipe) = stderr.as_mut() {
                    let _ = pipe.read_to_end(&mut buf);
                }
                buf
            });
            let mut out = Vec::new();
            if let Some(pipe) = stdout.as_mut() {
                let _ = pipe.read_to_end(&mut out);
            }
            (out, err.join().unwrap_or_default())
        });

        let child = self
            .children
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .running
            .remove(&id);
        let status = match child {
            Some(mut child) => child
                .wait()
                .map_err(|e| format!("Failed to wait for {program}: {e}"))?,
            None => return Err(DiffError::Failed(format!("Lost track of {program}"))),
        };
        self.check()?;
        Ok(Output {
            status,
            stdout: out,
            stderr: err,
        })
    }
}

/// The thread pool every diff runs on: asynchronous runs, their per-file work,
/// and the per-file work of synchronous runs. One thread per CPU, which bounds
/// the processes all runs start together.
pub fn pool() -> &'static rayon::ThreadPool {
    static POOL: OnceLock<rayon::ThreadPool> = OnceLock::new();
    POOL.get_or_init(|| {
        rayon::ThreadPoolBuilder::new()
            .thread_name(|i| format!("difftastic-nvim-{i}"))
            .build()
            .expect("failed to start the difftastic-nvim thread pool")
    })
}

/// Maps `f` over `items` in the current thread pool with at most `lanes` items
/// in progress at once (0: as many as the pool has threads), keeping the order.
/// Stops taking new items after the first error, and returns the first error
/// in item order.
pub fn map_limited<T, R, F>(items: Vec<T>, lanes: usize, f: F) -> Result<Vec<R>, DiffError>
where
    T: Send,
    R: Send,
    F: Fn(T) -> Result<R, DiffError> + Sync,
{
    let lanes = match lanes {
        0 => rayon::current_num_threads(),
        n => n,
    }
    .clamp(1, items.len().max(1));
    let inputs: Vec<Mutex<Option<T>>> = items.into_iter().map(|i| Mutex::new(Some(i))).collect();
    let outputs: Vec<Mutex<Option<Result<R, DiffError>>>> =
        inputs.iter().map(|_| Mutex::new(None)).collect();
    let next = AtomicUsize::new(0);
    let failed = AtomicBool::new(false);

    let (inputs_ref, outputs_ref, next_ref, failed_ref, f_ref) =
        (&inputs, &outputs, &next, &failed, &f);
    rayon::scope(|scope| {
        for _ in 0..lanes {
            scope.spawn(move |_| {
                while !failed_ref.load(Ordering::SeqCst) {
                    let i = next_ref.fetch_add(1, Ordering::SeqCst);
                    let Some(slot) = inputs_ref.get(i) else {
                        break;
                    };
                    let Some(item) = slot.lock().unwrap_or_else(|e| e.into_inner()).take() else {
                        continue;
                    };
                    let result = f_ref(item);
                    if result.is_err() {
                        failed_ref.store(true, Ordering::SeqCst);
                    }
                    *outputs_ref[i].lock().unwrap_or_else(|e| e.into_inner()) = Some(result);
                }
            });
        }
    });

    outputs
        .into_iter()
        .filter_map(|slot| slot.into_inner().unwrap_or_else(|e| e.into_inner()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::time::{Duration, Instant};

    fn recording_run() -> (Run, Arc<Mutex<Vec<Update>>>) {
        let updates = Arc::new(Mutex::new(Vec::new()));
        let sink_updates = Arc::clone(&updates);
        let run = Run::new(Some(Box::new(move |u| {
            sink_updates.lock().unwrap().push(u)
        })));
        (run, updates)
    }

    #[test]
    fn steps_count_up_and_report_the_total() {
        let (run, updates) = recording_run();
        run.note("listing");
        run.set_total(2);
        run.step("a").unwrap();
        run.step("b").unwrap();
        let updates = updates.lock().unwrap();
        let seen: Vec<_> = updates
            .iter()
            .map(|u| (u.count, u.total, u.message.as_str()))
            .collect();
        assert_eq!(
            seen,
            vec![(0, -1, "listing"), (0, 2, ""), (1, 2, "a"), (2, 2, "b")]
        );
    }

    #[test]
    fn steps_fail_once_cancelled_and_stay_failed() {
        let run = Run::new(None);
        run.step("a").unwrap();
        run.cancel();
        assert_eq!(run.step("b"), Err(DiffError::Cancelled));
        assert_eq!(run.step("c"), Err(DiffError::Cancelled));
        assert_eq!(run.check(), Err(DiffError::Cancelled));
    }

    #[test]
    fn output_returns_what_the_process_printed() {
        let run = Run::new(None);
        let out = run
            .output(Command::new("sh").args(["-c", "echo out; echo err >&2; exit 3"]))
            .unwrap();
        assert_eq!(out.stdout, b"out\n");
        assert_eq!(out.stderr, b"err\n");
        assert_eq!(out.status.code(), Some(3));
    }

    #[test]
    fn output_reports_a_missing_program() {
        let run = Run::new(None);
        let err = run
            .output(&mut Command::new("difftastic-nvim-no-such-program"))
            .unwrap_err();
        assert!(
            matches!(err, DiffError::Failed(m) if m.contains("difftastic-nvim-no-such-program"))
        );
    }

    #[test]
    fn cancel_kills_a_running_process() {
        let run = Arc::new(Run::new(None));
        let worker_run = Arc::clone(&run);
        let start = Instant::now();
        let worker = std::thread::spawn(move || worker_run.output(Command::new("sleep").arg("30")));
        // Wait until the process is running, then cancel.
        while run.children.lock().unwrap().running.is_empty() {
            std::thread::sleep(Duration::from_millis(5));
        }
        run.cancel();
        assert_eq!(worker.join().unwrap().unwrap_err(), DiffError::Cancelled);
        assert!(start.elapsed() < Duration::from_secs(10));
        assert!(run.children.lock().unwrap().running.is_empty());
    }

    #[test]
    fn no_process_starts_after_cancel() {
        let run = Run::new(None);
        run.cancel();
        assert_eq!(
            run.output(Command::new("sh").args(["-c", "exit 0"]))
                .unwrap_err(),
            DiffError::Cancelled
        );
        assert!(run.children.lock().unwrap().running.is_empty());
    }

    #[test]
    fn map_limited_keeps_order_and_bounds_concurrency() {
        let running = AtomicUsize::new(0);
        let peak = AtomicUsize::new(0);
        let out = pool()
            .install(|| {
                map_limited((0..40).collect(), 3, |i: usize| {
                    let now = running.fetch_add(1, Ordering::SeqCst) + 1;
                    peak.fetch_max(now, Ordering::SeqCst);
                    std::thread::sleep(Duration::from_millis(5));
                    running.fetch_sub(1, Ordering::SeqCst);
                    Ok(i * 2)
                })
            })
            .unwrap();
        assert_eq!(out, (0..40).map(|i| i * 2).collect::<Vec<_>>());
        assert!(
            peak.load(Ordering::SeqCst) <= 3,
            "peak {}",
            peak.load(Ordering::SeqCst)
        );
    }

    #[test]
    fn map_limited_stops_at_the_first_error() {
        let calls = AtomicUsize::new(0);
        let result = pool().install(|| {
            map_limited((0..100).collect(), 1, |i: usize| {
                calls.fetch_add(1, Ordering::SeqCst);
                if i == 3 {
                    Err(DiffError::Failed("three".into()))
                } else {
                    Ok(i)
                }
            })
        });
        assert_eq!(result, Err(DiffError::Failed("three".into())));
        assert_eq!(calls.load(Ordering::SeqCst), 4);
    }

    #[test]
    fn map_limited_handles_no_items() {
        let out: Vec<usize> = pool()
            .install(|| map_limited(Vec::new(), 0, |i: usize| Ok(i)))
            .unwrap();
        assert!(out.is_empty());
    }
}
