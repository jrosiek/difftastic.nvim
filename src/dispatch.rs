//! Asynchronous diffs: a diff runs on the thread pool, and its progress and
//! result reach Lua through a dispatcher that Lua polls.
//!
//! The Lua state belongs to Neovim's main thread, so worker threads never touch
//! it. They post closures to the [`Dispatcher`]; `poll()`, called from Lua on the
//! main thread, runs them. The dispatcher only delivers closures: what a job
//! reports, and whether it still reports anything, is decided by the closures
//! the job posts.

use crate::job::{self, DiffError, Run, Update};
use crate::processor::DisplayFile;
use crate::{DiffMode, compute_diff, files_to_lua};
use mlua::prelude::*;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};

/// Work to run on the main thread, with the Lua state.
type Task = Box<dyn FnOnce(&Lua) -> LuaResult<()> + Send>;

/// Delivers closures from any thread to the main thread. Kept in the Lua
/// state's app data.
pub struct Dispatcher {
    sender: Sender<Task>,
    receiver: Receiver<Task>,
    pending: Arc<AtomicUsize>,
}

impl Dispatcher {
    pub fn new() -> Self {
        let (sender, receiver) = channel();
        Self {
            sender,
            receiver,
            pending: Arc::new(AtomicUsize::new(0)),
        }
    }

    /// A handle for posting closures, for any thread.
    fn poster(&self) -> Sender<Task> {
        self.sender.clone()
    }

    /// Counts a job as pending until the returned guard is dropped.
    fn pending_guard(&self) -> PendingGuard {
        self.pending.fetch_add(1, Ordering::SeqCst);
        PendingGuard(Arc::clone(&self.pending))
    }
}

/// Keeps a job counted as pending. Moved into the job's last posted closure, so
/// the count drops only once that closure has run on the main thread.
struct PendingGuard(Arc<AtomicUsize>);

impl Drop for PendingGuard {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::SeqCst);
    }
}

/// Runs every closure posted so far, on the calling (main) thread. Returns the
/// number of jobs not finished yet: their last closure has not run. A Lua error
/// raised by a callback is returned after the other closures have run.
pub fn poll(lua: &Lua, _: ()) -> LuaResult<usize> {
    let tasks: Vec<Task> = {
        let dispatcher = dispatcher(lua)?;
        dispatcher.receiver.try_iter().collect()
    };
    let mut first_error = None;
    for task in tasks {
        if let Err(e) = task(lua) {
            first_error.get_or_insert(e);
        }
    }
    lua.expire_registry_values();
    if let Some(e) = first_error {
        return Err(e);
    }
    Ok(dispatcher(lua)?.pending.load(Ordering::SeqCst))
}

fn dispatcher(lua: &Lua) -> LuaResult<mlua::AppDataRef<'_, Dispatcher>> {
    lua.app_data_ref::<Dispatcher>()
        .ok_or_else(|| LuaError::RuntimeError("difftastic-nvim: no dispatcher".to_string()))
}

/// A job's state shared between its worker and the closures it posts.
struct Job {
    run: Run,
    progress_fn: LuaRegistryKey,
    complete_fn: LuaRegistryKey,
    /// The newest progress report not yet delivered, and whether a closure that
    /// will deliver it is queued. At most one such closure is queued at a time.
    progress: Mutex<(Option<Update>, bool)>,
}

/// Handle returned to Lua for a started job.
struct JobHandle(Arc<Job>);

impl LuaUserData for JobHandle {
    fn add_methods<M: LuaUserDataMethods<Self>>(methods: &mut M) {
        // Cancels the job: kills its running processes before returning. Neither
        // callback is called after this.
        methods.add_method("cancel", |_, this, ()| {
            this.0.run.cancel();
            Ok(())
        });
        methods.add_method("is_cancelled", |_, this, ()| Ok(this.0.run.is_cancelled()));
    }
}

/// Calls the job's progress function with the newest report, unless the job is
/// cancelled. A `false` result cancels the job.
fn deliver_progress(lua: &Lua, job: &Job) -> LuaResult<()> {
    let update = {
        let mut slot = job.progress.lock().unwrap_or_else(|e| e.into_inner());
        slot.1 = false;
        slot.0.take()
    };
    let Some(update) = update else {
        return Ok(());
    };
    if job.run.is_cancelled() {
        return Ok(());
    }
    let callback: LuaFunction = lua.registry_value(&job.progress_fn)?;
    let total = if update.total < 0 {
        -1
    } else {
        update.total as i64
    };
    let keep_going: LuaValue = callback.call((update.count, total, update.message))?;
    if keep_going == LuaValue::Boolean(false) {
        job.run.cancel();
    }
    Ok(())
}

/// Calls the job's completion function with `(files, nil)` or `(nil, error)`,
/// unless the job is cancelled.
fn deliver_result(
    lua: &Lua,
    job: &Job,
    result: Result<Vec<DisplayFile>, DiffError>,
) -> LuaResult<()> {
    if job.run.is_cancelled() {
        return Ok(());
    }
    let callback: LuaFunction = lua.registry_value(&job.complete_fn)?;
    match result {
        Ok(files) => callback.call::<()>((files_to_lua(lua, files)?, LuaValue::Nil)),
        Err(DiffError::Failed(message)) => callback.call::<()>((LuaValue::Nil, message)),
        Err(DiffError::Cancelled) => Ok(()),
    }
}

/// `run_diff_async(spec, on_progress, on_complete)`: starts computing a diff on
/// the thread pool and returns a job handle with `cancel()`.
///
/// `spec` is `{ mode = "range"|"unstaged"|"staged", revset = ..., vcs = ...,
/// max_parallel = ..., cwd = ... }` (`revset` only for "range"; `cwd`, a
/// directory inside the repository, defaults to the current one). Both callbacks run on the
/// main thread, from `poll()`: `on_progress(count, total, message)`, with
/// `total` -1 while unknown, cancels the job by returning `false`;
/// `on_complete(result, err)` gets the table the blocking functions return, or
/// nil and an error message. Neither is called once the job is cancelled.
pub fn run_diff_async(
    lua: &Lua,
    (spec, on_progress, on_complete): (LuaTable, LuaFunction, LuaFunction),
) -> LuaResult<LuaAnyUserData> {
    let mode = match spec.get::<String>("mode")?.as_str() {
        "range" => DiffMode::Range(spec.get::<String>("revset")?),
        "unstaged" => DiffMode::Unstaged,
        "staged" => DiffMode::Staged,
        other => {
            return Err(LuaError::RuntimeError(format!(
                "Unknown diff mode: {other}"
            )));
        }
    };
    let vcs: String = spec.get("vcs")?;
    let max_parallel = spec.get::<Option<usize>>("max_parallel")?.unwrap_or(0);
    let dir = crate::diff_dir(spec.get::<Option<String>>("cwd")?)?;

    let (post, guard) = {
        let dispatcher = dispatcher(lua)?;
        (dispatcher.poster(), dispatcher.pending_guard())
    };

    // The progress sink posts a delivery closure only when none is queued; the
    // queued one delivers whatever report is newest when it runs.
    let job_slot: Arc<Mutex<Option<std::sync::Weak<Job>>>> = Arc::new(Mutex::new(None));
    let sink_slot = Arc::clone(&job_slot);
    let sink_post = post.clone();
    let sink = move |update: Update| {
        let Some(job) = sink_slot
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .and_then(std::sync::Weak::upgrade)
        else {
            return;
        };
        let mut slot = job.progress.lock().unwrap_or_else(|e| e.into_inner());
        slot.0 = Some(update);
        if !slot.1 {
            slot.1 = true;
            let job = Arc::clone(&job);
            let _ = sink_post.send(Box::new(move |lua: &Lua| deliver_progress(lua, &job)));
        }
    };

    let job = Arc::new(Job {
        run: Run::new(Some(Box::new(sink))),
        progress_fn: lua.create_registry_value(on_progress)?,
        complete_fn: lua.create_registry_value(on_complete)?,
        progress: Mutex::new((None, false)),
    });
    *job_slot.lock().unwrap_or_else(|e| e.into_inner()) = Some(Arc::downgrade(&job));

    let worker_job = Arc::clone(&job);
    job::pool().spawn(move || {
        let result = catch_unwind(AssertUnwindSafe(|| {
            compute_diff(&dir, &mode, &vcs, max_parallel, &worker_job.run)
        }))
        .unwrap_or_else(|panic| {
            let message = panic
                .downcast_ref::<&str>()
                .map(|s| (*s).to_string())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "unknown".to_string());
            Err(DiffError::Failed(format!("panic: {message}")))
        });
        // Always posted, also for a cancelled job: it carries the pending guard.
        let _ = post.send(Box::new(move |lua: &Lua| {
            let _guard = guard;
            deliver_result(lua, &worker_job, result)
        }));
    });

    lua.create_userdata(JobHandle(job))
}
