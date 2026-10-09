//! # difftastic-nvim
//!
//! A Neovim plugin for displaying difftastic diffs in a side-by-side viewer.
//!
//! This crate provides Lua bindings for parsing [difftastic](https://difftastic.wilfred.me.uk/)
//! JSON output and processing it into a display-ready format. It supports both
//! [jj](https://github.com/martinvonz/jj) and [git](https://git-scm.com/) version control systems.
//!
//! ## Architecture
//!
//! The crate is organized into these modules:
//!
//! - `difftastic` - Types and parsing for difftastic's JSON output format
//! - `processor` - Transforms parsed data into aligned side-by-side display rows
//! - `job` - The shared thread pool, progress reports and cancellation
//! - `dispatch` - Asynchronous diffs and delivering their callbacks to Lua
//! - `lib` (this module) - Lua bindings and VCS integration
//!
//! ## Usage from Lua
//!
//! ```lua
//! local difft = require("difftastic_nvim")
//!
//! -- Get diff for a jj revision
//! local result = difft.run_diff("@", "jj")
//!
//! -- Get diff for a git commit
//! local result = difft.run_diff("HEAD", "git")
//!
//! -- Get diff for a git commit range
//! local result = difft.run_diff("main..feature", "git")
//!
//! -- Without blocking: callbacks run from poll(), which the caller runs on a timer
//! local job = difft.run_diff_async({ mode = "range", revset = "HEAD", vcs = "git" },
//!     function(count, total, message) end, -- return false to cancel
//!     function(result, err) end)
//! local pending = difft.poll()
//! job:cancel()
//! ```
//!
//! ## Environment Variables
//!
//! This crate sets the following environment variables when invoking difftastic:
//!
//! - `DFT_DISPLAY=json` - Enables JSON output mode
//! - `DFT_UNSTABLE=yes` - Enables unstable features (required for JSON output)

use job::{DiffError, Run};
use mlua::prelude::*;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};

mod difftastic;
mod dispatch;
mod job;
mod processor;

/// Splits file content into individual lines, or empty vector if `None`.
#[inline]
fn into_lines(content: Option<String>) -> Vec<String> {
    content
        .map(|c| c.lines().map(String::from).collect())
        .unwrap_or_default()
}

/// Fetches file content from jj at a specific revision via `jj file show`.
/// Returns `None` if the command fails or the file doesn't exist.
///
/// Paths from difftastic are relative to the repo root, so the command
/// must run from the repo root for `jj file show` to resolve them correctly.
fn jj_file_content(root: &Path, revset: &str, path: &Path) -> Option<String> {
    Command::new("jj")
        .args(["file", "show", "-r", revset])
        .arg(path)
        .current_dir(root)
        .output()
        .ok()
        .filter(|output| output.status.success())
        .map(|output| String::from_utf8_lossy(&output.stdout).into_owned())
}

/// Gets the git repository root directory.
fn git_root() -> Option<PathBuf> {
    Command::new("git")
        .args(["rev-parse", "--show-toplevel"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()))
}

/// Gets the jj repository root directory.
fn jj_root() -> Option<PathBuf> {
    Command::new("jj")
        .args(["root"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| PathBuf::from(String::from_utf8_lossy(&o.stdout).trim()))
}

/// Stats for a single file: (additions, deletions).
type FileStats = HashMap<PathBuf, (u32, u32)>;

/// Gets diff stats from git using `--numstat`.
/// Output format: "additions\tdeletions\tpath"
///
/// Pass additional arguments to customize the diff:
/// - `&["HEAD^..HEAD"]` for a commit range
/// - `&[]` for unstaged changes (working tree vs index)
/// - `&["--cached"]` for staged changes (index vs HEAD)
fn git_diff_stats(extra_args: &[&str]) -> FileStats {
    let mut args = vec!["diff", "--numstat"];
    args.extend(extra_args);

    let output = Command::new("git").args(&args).output().ok();

    let Some(output) = output.filter(|o| o.status.success()) else {
        return HashMap::new();
    };

    parse_git_numstat(&String::from_utf8_lossy(&output.stdout))
}

fn parse_git_numstat(output: &str) -> FileStats {
    output
        .lines()
        .filter_map(|line| {
            let mut parts = line.split('\t');
            let add = parts.next()?.parse().ok()?;
            let del = parts.next()?.parse().ok()?;
            // A rename is reported as `old => new` (or `dir/{old => new}`); key it by
            // the new path, which is the path the diff records carry.
            let (_, new_path) = split_display_path(Path::new(parts.next()?));
            Some((new_path, (add, del)))
        })
        .collect()
}

/// Parses a jj range of the form `A..B` into `(A, B)`.
/// Returns `None` for non-range revsets.
#[inline]
fn parse_jj_range(revset: &str) -> Option<(String, String)> {
    let (old, new) = revset.split_once("..")?;
    if old.is_empty() || new.is_empty() {
        return None;
    }
    Some((old.to_string(), new.to_string()))
}

fn jj_git_commits(revset: &str) -> Option<Vec<String>> {
    let output = Command::new("jj")
        .args([
            "log",
            "-r",
            revset,
            "--no-graph",
            "-T",
            "commit_id ++ \"\n\"",
        ])
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let commits = String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();

    commits
        .iter()
        .all(|commit| commit.len() == 40 && commit.chars().all(|c| c.is_ascii_hexdigit()))
        .then_some(commits)
}

fn jj_diff_revset(mode: &DiffMode) -> &str {
    match mode {
        DiffMode::Range(revset) => revset,
        DiffMode::Unstaged | DiffMode::Staged => "@",
    }
}

fn git_range_from_jj_commits(old_revs: &[String], new_revs: &[String]) -> Option<String> {
    if old_revs.len() != 1 || new_revs.len() != 1 {
        return None;
    }

    Some(format!("{}..{}", old_revs[0], new_revs[0]))
}

fn jj_diff_git_range(mode: &DiffMode) -> Option<String> {
    let revset = jj_diff_revset(mode);
    let old_revs = jj_git_commits(&format!("roots({revset})-"))?;
    let new_revs = jj_git_commits(&format!("heads({revset})"))?;

    git_range_from_jj_commits(&old_revs, &new_revs)
}

fn jj_diff_stats(mode: &DiffMode) -> FileStats {
    let Some(git_range) = jj_diff_git_range(mode) else {
        return HashMap::new();
    };

    git_diff_stats(&[git_range.as_str()])
}

/// Runs difftastic via jj for the mode (`jj diff [-r <revset>] --tool difft`) and
/// parses the JSON output.
fn run_jj_diff(mode: &DiffMode, run: &Run) -> Result<Vec<difftastic::DifftFile>, DiffError> {
    let mut cmd = Command::new("jj");
    cmd.arg("diff");
    match mode {
        DiffMode::Range(revset) => {
            cmd.args(["-r", revset]);
        }
        DiffMode::Unstaged => {}
        // jj has no staging area: show the current revision.
        DiffMode::Staged => {
            cmd.args(["-r", "@"]);
        }
    }
    let output = run.output(
        cmd.args(["--tool", "difft"])
            .env("DFT_DISPLAY", "json")
            .env("DFT_UNSTABLE", "yes"),
    )?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("jj command failed: {stderr}").into());
    }

    difftastic::parse(&String::from_utf8_lossy(&output.stdout))
        .map_err(|e| format!("Failed to parse difftastic JSON: {e}").into())
}

/// Runs difftastic on two contents of one file and returns its entry for `path`.
///
/// The contents are written to two temporary files named like `path`, so difft
/// detects the same language as for the original file.
fn run_difft_on_contents(path: &Path, old: &str, new: &str) -> Option<difftastic::DifftFile> {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    let dir = std::env::temp_dir().join(format!("difftastic-nvim-{}-{id}", std::process::id()));
    let name = path.file_name()?;
    let old_file = dir.join("old").join(name);
    let new_file = dir.join("new").join(name);

    let run = || -> Option<difftastic::DifftFile> {
        std::fs::create_dir_all(old_file.parent()?).ok()?;
        std::fs::create_dir_all(new_file.parent()?).ok()?;
        std::fs::write(&old_file, old).ok()?;
        std::fs::write(&new_file, new).ok()?;
        let output = Command::new("difft")
            .arg(&old_file)
            .arg(&new_file)
            .env("DFT_DISPLAY", "json")
            .env("DFT_UNSTABLE", "yes")
            .output()
            .ok()
            .filter(|o| o.status.success())?;
        let mut file = difftastic::parse(&String::from_utf8_lossy(&output.stdout))
            .ok()?
            .into_iter()
            .next()?;
        file.path = path.to_path_buf();
        Some(file)
    };
    let file = run();
    let _ = std::fs::remove_dir_all(&dir);
    file
}

/// jj hands difft whole trees, so a renamed file arrives as a creation of its new
/// path that was never compared with the old one. Diffs the two contents instead;
/// keeps the entry as is when that fails.
fn pair_jj_rename(
    file: difftastic::DifftFile,
    renames: &HashMap<PathBuf, PathBuf>,
    old: Option<&str>,
    new: Option<&str>,
) -> difftastic::DifftFile {
    if file.status != difftastic::Status::Created || !renames.contains_key(&file.path) {
        return file;
    }
    let (Some(old), Some(new)) = (old, new) else {
        return file;
    };
    run_difft_on_contents(&file.path, old, new).unwrap_or(file)
}

/// A changed file as `git diff --name-status -z` lists it.
#[derive(Debug, Clone, PartialEq, Eq)]
struct GitChange {
    /// Status letter: `A`, `D`, `M`, `R`, `C`, `T`, ...
    status: char,
    /// Path before the change; `None` for an added file.
    old_path: Option<String>,
    /// Path after the change; `None` for a deleted file.
    new_path: Option<String>,
}

/// Parses `git diff --name-status -z` output: `M\0path\0` entries, with two paths
/// for renames and copies (`R100\0old\0new\0`).
fn parse_git_name_status_z(output: &[u8]) -> Vec<GitChange> {
    let mut fields = output
        .split(|&b| b == 0)
        .map(|f| String::from_utf8_lossy(f).into_owned());
    let mut changes = Vec::new();
    while let Some(status) = fields.next() {
        let Some(letter) = status.chars().next() else {
            continue;
        };
        // The output ends with a NUL, which leaves an empty last field: an empty
        // path means the entry was cut off.
        let Some(first) = fields.next().filter(|f| !f.is_empty()) else {
            break;
        };
        let change = match letter {
            'R' | 'C' => {
                let Some(second) = fields.next().filter(|f| !f.is_empty()) else {
                    break;
                };
                GitChange {
                    status: letter,
                    old_path: Some(first),
                    new_path: Some(second),
                }
            }
            'A' => GitChange {
                status: letter,
                old_path: None,
                new_path: Some(first),
            },
            'D' => GitChange {
                status: letter,
                old_path: Some(first),
                new_path: None,
            },
            _ => GitChange {
                status: letter,
                old_path: Some(first.clone()),
                new_path: Some(first),
            },
        };
        changes.push(change);
    }
    changes
}

/// Where the two sides of a git diff come from.
enum GitSide {
    /// A blob at a revision (`HEAD`, a commit, or `""` for the index).
    Rev(String),
    /// The working tree.
    WorkTree,
}

/// The sides compared for a diff mode, as `git diff` would compare them.
fn git_sides(mode: &DiffMode) -> (GitSide, GitSide, Vec<String>) {
    match mode {
        DiffMode::Range(range) => {
            let (old_ref, new_ref) = parse_git_range(range);
            let args = vec![format!("{old_ref}..{new_ref}")];
            (GitSide::Rev(old_ref), GitSide::Rev(new_ref), args)
        }
        DiffMode::Unstaged => (GitSide::Rev(String::new()), GitSide::WorkTree, Vec::new()),
        DiffMode::Staged => (
            GitSide::Rev("HEAD".to_string()),
            GitSide::Rev(String::new()),
            vec!["--cached".to_string()],
        ),
    }
}

/// The exact bytes of a file on one side, `None` when it does not exist there.
fn git_side_bytes(root: &Path, side: &GitSide, path: &str) -> Option<Vec<u8>> {
    match side {
        GitSide::Rev(rev) => Command::new("git")
            .args(["cat-file", "blob", &format!("{rev}:{path}")])
            .current_dir(root)
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| o.stdout),
        GitSide::WorkTree => {
            let full = root.join(path);
            // A symlink is diffed by its target text, as git does.
            match std::fs::symlink_metadata(&full) {
                Ok(meta) if meta.file_type().is_symlink() => std::fs::read_link(&full)
                    .ok()
                    .map(|target| target.to_string_lossy().into_owned().into_bytes()),
                Ok(_) => std::fs::read(&full).ok(),
                Err(_) => None,
            }
        }
    }
}

/// A fresh temporary directory for one difft call.
fn difft_temp_dir() -> PathBuf {
    static NEXT_ID: AtomicU64 = AtomicU64::new(0);
    let id = NEXT_ID.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("difftastic-nvim-git-{}-{id}", std::process::id()))
}

/// Runs difft on one changed file the way git's external diff does: the real
/// path first, `/dev/null` for a missing side, and the new path for a rename,
/// from the repository root. difft then picks the same language, reads the same
/// `.gitattributes` and reports the same path as under `git diff`.
fn run_difft_git_style(
    root: &Path,
    change: &GitChange,
    old: Option<&[u8]>,
    new: Option<&[u8]>,
    run: &Run,
) -> Result<difftastic::DifftFile, DiffError> {
    let dir = difft_temp_dir();
    let diff = || -> Result<difftastic::DifftFile, DiffError> {
        std::fs::create_dir_all(&dir)
            .map_err(|e| format!("Failed to create a temporary directory: {e}"))?;
        let write = |name: &str, content: Option<&[u8]>| -> Result<PathBuf, String> {
            match content {
                Some(bytes) => {
                    let file = dir.join(name);
                    std::fs::write(&file, bytes)
                        .map_err(|e| format!("Failed to write a temporary file: {e}"))?;
                    Ok(file)
                }
                None => Ok(PathBuf::from("/dev/null")),
            }
        };
        let old_file = write("old", old)?;
        let new_file = write("new", new)?;
        let path = change
            .old_path
            .as_deref()
            .or(change.new_path.as_deref())
            .unwrap_or_default();

        let mut cmd = Command::new("difft");
        cmd.arg(path)
            .arg(&old_file)
            .args([".", "."])
            .arg(&new_file)
            .args([".", "."]);
        if let ('R' | 'C', Some(new_path)) = (change.status, change.new_path.as_deref()) {
            cmd.arg(new_path)
                .arg(format!("rename from {path}\nrename to {new_path}\n"));
        }
        let output = run.output(
            cmd.current_dir(root)
                .env("DFT_DISPLAY", "json")
                .env("DFT_UNSTABLE", "yes"),
        )?;
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(format!("difft failed on {path}: {stderr}").into());
        }
        Ok(difftastic::parse(&String::from_utf8_lossy(&output.stdout))
            .map_err(|e| format!("Failed to parse difftastic JSON: {e}"))?
            .into_iter()
            .next()
            .ok_or_else(|| format!("difft reported nothing for {path}"))?)
    };
    let result = diff();
    let _ = std::fs::remove_dir_all(&dir);
    result
}

/// The display files of a git diff, and its renames (new path to old path).
///
/// Lists the changed files with `git diff --name-status -z`, then for up to
/// `max_parallel` files at a time (0: as many as the pool has threads) reads
/// both sides once, runs difftastic on them as `git -c diff.external=difft diff`
/// would, and builds the rows from the same bytes.
fn git_display_files(
    mode: &DiffMode,
    max_parallel: usize,
    run: &Run,
) -> Result<(Vec<processor::DisplayFile>, HashMap<PathBuf, PathBuf>), DiffError> {
    run.note("Listing changes");
    let root = git_root().ok_or_else(|| "Not inside a git repository".to_string())?;
    let (old_side, new_side, extra_args) = git_sides(mode);

    let output = run.output(
        Command::new("git")
            .args(["diff", "--name-status", "-M", "-z"])
            .args(&extra_args)
            .current_dir(&root),
    )?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(format!("git command failed: {stderr}").into());
    }
    // Unmerged entries have no single old and new side to compare.
    let changes: Vec<GitChange> = parse_git_name_status_z(&output.stdout)
        .into_iter()
        .filter(|c| c.status != 'U')
        .collect();
    let renames = git_renames(&changes);
    let stats = git_diff_stats(&extra_args.iter().map(String::as_str).collect::<Vec<_>>());

    run.set_total(changes.len());
    let files = job::map_limited(changes, max_parallel, |change| {
        run.check()?;
        let old = change
            .old_path
            .as_deref()
            .and_then(|p| git_side_bytes(&root, &old_side, p));
        let new = change
            .new_path
            .as_deref()
            .and_then(|p| git_side_bytes(&root, &new_side, p));
        let mut file = run_difft_git_style(&root, &change, old.as_deref(), new.as_deref(), run)?;
        let (file_stats, _, _, moved_from) = prepare_file_for_display(&mut file, &stats, &renames);
        let name = step_name(&file.path);
        let display = process_prepared_file(
            file,
            bytes_into_lines(old),
            bytes_into_lines(new),
            file_stats,
            moved_from,
        );
        run.step(name)?;
        Ok(display)
    })?;
    Ok((files, renames))
}

/// Renames among git's changes, from new path to old path.
fn git_renames(changes: &[GitChange]) -> HashMap<PathBuf, PathBuf> {
    changes
        .iter()
        .filter(|c| c.status == 'R')
        .filter_map(|c| {
            Some((
                PathBuf::from(c.new_path.as_deref()?),
                PathBuf::from(c.old_path.as_deref()?),
            ))
        })
        .collect()
}

/// The display files of a jj diff, and its renames (new path to old path).
fn jj_display_files(
    mode: &DiffMode,
    max_parallel: usize,
    run: &Run,
) -> Result<(Vec<processor::DisplayFile>, HashMap<PathBuf, PathBuf>), DiffError> {
    run.note("Running jj diff");
    let files = run_jj_diff(mode, run)?;
    let stats = jj_diff_stats(mode);
    let renames = jj_rename_map(mode);
    // Paths from difftastic are repo-root-relative, but jj file show resolves
    // relative to the current directory.
    let root = jj_root().unwrap_or_else(|| PathBuf::from("."));
    // The revisions to read each side from; no new revision means the working copy.
    let (old_ref, new_ref) = match mode {
        DiffMode::Range(range) => {
            let (old, new) = parse_jj_range(range)
                .unwrap_or_else(|| (format!("roots({range})-"), format!("heads({range})")));
            (old, Some(new))
        }
        DiffMode::Unstaged => ("@-".to_string(), None),
        DiffMode::Staged => ("@-".to_string(), Some("@".to_string())),
    };

    run.set_total(files.len());
    let files = job::map_limited(files, max_parallel, |mut file| {
        run.check()?;
        let (file_stats, old_path, new_path, moved_from) =
            prepare_file_for_display(&mut file, &stats, &renames);
        let old = jj_file_content(&root, &old_ref, &old_path);
        let new = match &new_ref {
            Some(new_ref) => jj_file_content(&root, new_ref, &new_path),
            None => std::fs::read_to_string(root.join(&new_path)).ok(),
        };
        let file = pair_jj_rename(file, &renames, old.as_deref(), new.as_deref());
        let name = step_name(&file.path);
        let display = process_prepared_file(
            file,
            into_lines(old),
            into_lines(new),
            file_stats,
            moved_from,
        );
        run.step(name)?;
        Ok(display)
    })?;
    Ok((files, renames))
}

/// A file's name as progress messages show it.
fn step_name(path: &Path) -> String {
    path.file_name()
        .unwrap_or(path.as_os_str())
        .to_string_lossy()
        .into_owned()
}

/// Splits file bytes into lines (invalid UTF-8 replaced), or none if `None`.
fn bytes_into_lines(content: Option<Vec<u8>>) -> Vec<String> {
    into_lines(content.map(|bytes| String::from_utf8_lossy(&bytes).into_owned()))
}

/// Gets the merge-base of two git refs.
fn git_merge_base(a: &str, b: &str) -> Option<String> {
    Command::new("git")
        .args(["merge-base", a, b])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

/// Expands diff display paths for renames/moves into concrete old/new paths.
///
/// Handles common formats:
/// - `old/path => new/path`
/// - `old/path -> new/path`
/// - `src/{old => new}.rs`
fn split_display_path(path: &Path) -> (PathBuf, PathBuf) {
    let raw = path.to_string_lossy();

    if let (Some(open), Some(close)) = (raw.find('{'), raw.rfind('}'))
        && close > open
    {
        let prefix = &raw[..open];
        let suffix = &raw[(close + 1)..];
        let inner = &raw[(open + 1)..close];

        for arrow in [" => ", " -> "] {
            if let Some((lhs, rhs)) = inner.split_once(arrow)
                && !lhs.trim().is_empty()
                && !rhs.trim().is_empty()
            {
                let old_path = format!("{prefix}{}{suffix}", lhs.trim());
                let new_path = format!("{prefix}{}{suffix}", rhs.trim());
                return (PathBuf::from(old_path), PathBuf::from(new_path));
            }
        }
    }

    for arrow in [" => ", " -> "] {
        if let Some((lhs, rhs)) = raw.split_once(arrow)
            && !lhs.trim().is_empty()
            && !rhs.trim().is_empty()
        {
            return (PathBuf::from(lhs.trim()), PathBuf::from(rhs.trim()));
        }
    }

    (path.to_path_buf(), path.to_path_buf())
}

fn prepare_file_for_display(
    file: &mut difftastic::DifftFile,
    stats: &FileStats,
    renames: &HashMap<PathBuf, PathBuf>,
) -> (Option<(u32, u32)>, PathBuf, PathBuf, Option<PathBuf>) {
    let (old_path, new_path) = split_display_path(&file.path);
    let file_stats = stats
        .get(&file.path)
        .or_else(|| stats.get(&new_path))
        .or_else(|| stats.get(&old_path))
        .copied();

    let moved_from = if old_path != new_path {
        file.path = new_path.clone();
        file.status = difftastic::Status::Created;
        Some(old_path.clone())
    } else {
        None
    };

    // A renamed file is reported under its new path only, yet diffed against the old
    // file (by git, or by `pair_jj_rename` for jj), so load the old content from the
    // rename source. The status is left as the diff reported it, so the rows are
    // built as a change, not as a creation.
    let old_path = match (&moved_from, renames.get(&new_path)) {
        (None, Some(renamed_from)) => renamed_from.clone(),
        _ => old_path,
    };

    (file_stats, old_path, new_path, moved_from)
}

fn process_prepared_file(
    file: difftastic::DifftFile,
    old_lines: Vec<String>,
    new_lines: Vec<String>,
    file_stats: Option<(u32, u32)>,
    moved_from: Option<PathBuf>,
) -> processor::DisplayFile {
    let mut display = processor::process_file(file, old_lines, new_lines, file_stats);
    display.moved_from = moved_from;
    display
}

fn parse_jj_summary_rename(line: &str) -> Option<(PathBuf, PathBuf)> {
    let renamed = line.trim().strip_prefix("R ")?;
    let (old_path, new_path) = split_display_path(Path::new(renamed));
    (old_path != new_path).then_some((old_path, new_path))
}

fn parse_jj_summary_renames(output: &str) -> HashMap<PathBuf, PathBuf> {
    output
        .lines()
        .filter_map(parse_jj_summary_rename)
        .map(|(old_path, new_path)| (new_path, old_path))
        .collect()
}

fn jj_rename_map(mode: &DiffMode) -> HashMap<PathBuf, PathBuf> {
    let mut cmd = Command::new("jj");
    cmd.arg("diff");

    match mode {
        DiffMode::Range(revset) => {
            cmd.arg("-r").arg(revset);
        }
        DiffMode::Unstaged => {}
        DiffMode::Staged => {
            cmd.args(["-r", "@"]); // mirror staged fallback semantics in this plugin
        }
    }

    let output = cmd.arg("--summary").output().ok();
    let Some(output) = output.filter(|o| o.status.success()) else {
        return HashMap::new();
    };

    parse_jj_summary_renames(&String::from_utf8_lossy(&output.stdout))
}

/// Parses a git commit range into `(old_commit, new_commit)` references.
///
/// Handles single commits, `A..B` ranges, and `A...B` (merge-base) ranges.
#[inline]
fn parse_git_range(range: &str) -> (String, String) {
    if let Some((a, b)) = range.split_once("...") {
        let base = git_merge_base(a, b).unwrap_or_else(|| format!("{a}^"));
        (base, b.to_string())
    } else if let Some((old, new)) = range.split_once("..") {
        (old.to_string(), new.to_string())
    } else {
        (format!("{range}^"), range.to_string())
    }
}

/// The type of diff to perform.
enum DiffMode {
    /// A commit range (e.g., "HEAD^..HEAD" for git, "@" for jj).
    Range(String),
    /// Unstaged changes: working tree vs index (git) or working copy vs @ (jj).
    Unstaged,
    /// Staged changes: index vs HEAD (git only, jj falls back to @).
    Staged,
}

/// Computes the files of a diff for the mode and VCS. Touches no Lua state, so
/// it runs on any thread; call it inside the [`job::pool`].
/// `max_parallel` caps how many files are processed at once (0: as many as the
/// pool has threads).
fn compute_diff(
    mode: &DiffMode,
    vcs: &str,
    max_parallel: usize,
    run: &Run,
) -> Result<Vec<processor::DisplayFile>, DiffError> {
    let (mut display_files, renames) = if vcs == "git" {
        git_display_files(mode, max_parallel, run)?
    } else {
        jj_display_files(mode, max_parallel, run)?
    };

    if !renames.is_empty() {
        let old_paths: HashSet<PathBuf> = renames.values().cloned().collect();

        display_files = display_files
            .into_iter()
            .filter_map(|mut file| {
                if let Some(old_path) = renames.get(&file.path) {
                    file.moved_from = Some(old_path.clone());
                    file.status = difftastic::Status::Created;
                }

                if file.status == difftastic::Status::Deleted && old_paths.contains(&file.path) {
                    return None;
                }

                Some(file)
            })
            .collect();
    }

    Ok(display_files)
}

/// Converts computed files into the table the Lua side gets: `{ files = { ... } }`.
fn files_to_lua(lua: &Lua, display_files: Vec<processor::DisplayFile>) -> LuaResult<LuaTable> {
    let files_table = lua.create_table()?;
    for (i, file) in display_files.into_iter().enumerate() {
        files_table.set(i + 1, file.into_lua(lua)?)?;
    }

    let result = lua.create_table()?;
    result.set("files", files_table)?;
    Ok(result)
}

/// Computes a diff on the calling thread (blocking) and converts it for Lua.
fn run_diff_blocking(
    lua: &Lua,
    mode: DiffMode,
    vcs: &str,
    max_parallel: usize,
) -> LuaResult<LuaTable> {
    let run = Run::new(None);
    let files = job::pool()
        .install(|| compute_diff(&mode, vcs, max_parallel, &run))
        .map_err(|e| match e {
            DiffError::Failed(message) => LuaError::RuntimeError(message),
            DiffError::Cancelled => LuaError::RuntimeError("Diff cancelled".to_string()),
        })?;
    files_to_lua(lua, files)
}

/// Runs difftastic for a commit range.
fn run_diff(
    lua: &Lua,
    (range, vcs, max_parallel): (String, String, Option<usize>),
) -> LuaResult<LuaTable> {
    run_diff_blocking(lua, DiffMode::Range(range), &vcs, max_parallel.unwrap_or(0))
}

/// Runs difftastic for unstaged changes.
fn run_diff_unstaged(
    lua: &Lua,
    (vcs, max_parallel): (String, Option<usize>),
) -> LuaResult<LuaTable> {
    run_diff_blocking(lua, DiffMode::Unstaged, &vcs, max_parallel.unwrap_or(0))
}

/// Runs difftastic for staged changes.
fn run_diff_staged(lua: &Lua, (vcs, max_parallel): (String, Option<usize>)) -> LuaResult<LuaTable> {
    run_diff_blocking(lua, DiffMode::Staged, &vcs, max_parallel.unwrap_or(0))
}

/// Creates the Lua module exports. Called by mlua when loaded via `require("difftastic_nvim")`.
#[mlua::lua_module]
fn difftastic_nvim(lua: &Lua) -> LuaResult<LuaTable> {
    let exports = lua.create_table()?;
    exports.set(
        "run_diff",
        lua.create_function(|lua, args: (String, String, Option<usize>)| run_diff(lua, args))?,
    )?;
    exports.set(
        "run_diff_unstaged",
        lua.create_function(|lua, args: (String, Option<usize>)| run_diff_unstaged(lua, args))?,
    )?;
    exports.set(
        "run_diff_staged",
        lua.create_function(|lua, args: (String, Option<usize>)| run_diff_staged(lua, args))?,
    )?;
    lua.set_app_data(dispatch::Dispatcher::new());
    exports.set(
        "run_diff_async",
        lua.create_function(dispatch::run_diff_async)?,
    )?;
    exports.set("poll", lua.create_function(dispatch::poll)?)?;
    Ok(exports)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_into_lines_with_content() {
        let lines = into_lines(Some("line1\nline2\nline3".to_string()));
        assert_eq!(lines, vec!["line1", "line2", "line3"]);
    }

    #[test]
    fn test_into_lines_empty() {
        let lines = into_lines(None);
        assert!(lines.is_empty());
    }

    #[test]
    fn test_into_lines_single_line() {
        let lines = into_lines(Some("single".to_string()));
        assert_eq!(lines, vec!["single"]);
    }

    #[test]
    fn test_parse_git_range_single_commit() {
        let (old, new) = parse_git_range("abc123");
        assert_eq!(old, "abc123^");
        assert_eq!(new, "abc123");
    }

    #[test]
    fn test_parse_git_range_double_dot() {
        let (old, new) = parse_git_range("main..feature");
        assert_eq!(old, "main");
        assert_eq!(new, "feature");
    }

    #[test]
    fn test_parse_git_range_empty_left() {
        let (old, new) = parse_git_range("..HEAD");
        assert_eq!(old, "");
        assert_eq!(new, "HEAD");
    }

    #[test]
    fn test_parse_git_numstat() {
        let stats = parse_git_numstat("3\t1\tsrc/lib.rs\n0\t2\tREADME.md\n");

        assert_eq!(stats.get(Path::new("src/lib.rs")), Some(&(3, 1)));
        assert_eq!(stats.get(Path::new("README.md")), Some(&(0, 2)));
    }

    #[test]
    fn test_parse_git_numstat_keys_renames_by_new_path() {
        let stats = parse_git_numstat("1\t1\told.rs => sub/new.rs\n2\t0\tsrc/{a => b}.rs\n");

        assert_eq!(stats.get(Path::new("sub/new.rs")), Some(&(1, 1)));
        assert_eq!(stats.get(Path::new("src/b.rs")), Some(&(2, 0)));
    }

    #[test]
    fn test_parse_git_numstat_skips_binary_files() {
        let stats = parse_git_numstat("-\t-\timage.png\n1\t0\ttext.txt\n");

        assert!(!stats.contains_key(Path::new("image.png")));
        assert_eq!(stats.get(Path::new("text.txt")), Some(&(1, 0)));
    }

    #[test]
    fn test_parse_jj_range_double_dot() {
        let (old, new) = parse_jj_range("main@origin..@").unwrap();
        assert_eq!(old, "main@origin");
        assert_eq!(new, "@");
    }

    #[test]
    fn test_parse_jj_range_non_range() {
        assert!(parse_jj_range("@").is_none());
    }

    #[test]
    fn test_jj_diff_revset_uses_range_revset() {
        let mode = DiffMode::Range("trunk()..@".to_string());
        assert_eq!(jj_diff_revset(&mode), "trunk()..@");
    }

    #[test]
    fn test_jj_diff_revset_uses_current_revision_for_unstaged() {
        assert_eq!(jj_diff_revset(&DiffMode::Unstaged), "@");
    }

    #[test]
    fn test_jj_diff_revset_uses_current_revision_for_staged_fallback() {
        assert_eq!(jj_diff_revset(&DiffMode::Staged), "@");
    }

    #[test]
    fn test_git_range_from_jj_commits_requires_one_old_and_one_new_commit() {
        let old_revs = vec!["a".repeat(40)];
        let new_revs = vec!["b".repeat(40)];

        assert_eq!(
            git_range_from_jj_commits(&old_revs, &new_revs),
            Some(format!("{}..{}", old_revs[0], new_revs[0]))
        );
    }

    #[test]
    fn test_git_range_from_jj_commits_rejects_missing_old_commit() {
        let new_revs = vec!["b".repeat(40)];

        assert_eq!(git_range_from_jj_commits(&[], &new_revs), None);
    }

    #[test]
    fn test_git_range_from_jj_commits_rejects_multiple_old_commits() {
        let old_revs = vec!["a".repeat(40), "b".repeat(40)];
        let new_revs = vec!["c".repeat(40)];

        assert_eq!(git_range_from_jj_commits(&old_revs, &new_revs), None);
    }

    #[test]
    fn test_git_range_from_jj_commits_rejects_multiple_new_commits() {
        let old_revs = vec!["a".repeat(40)];
        let new_revs = vec!["b".repeat(40), "c".repeat(40)];

        assert_eq!(git_range_from_jj_commits(&old_revs, &new_revs), None);
    }

    #[test]
    fn test_split_display_path_plain() {
        let (old, new) = split_display_path(Path::new("src/lib.rs"));
        assert_eq!(old, PathBuf::from("src/lib.rs"));
        assert_eq!(new, PathBuf::from("src/lib.rs"));
    }

    #[test]
    fn test_split_display_path_arrow() {
        let (old, new) = split_display_path(Path::new("src/old.rs => src/new.rs"));
        assert_eq!(old, PathBuf::from("src/old.rs"));
        assert_eq!(new, PathBuf::from("src/new.rs"));
    }

    #[test]
    fn test_split_display_path_brace() {
        let (old, new) = split_display_path(Path::new("src/{old => new}.rs"));
        assert_eq!(old, PathBuf::from("src/old.rs"));
        assert_eq!(new, PathBuf::from("src/new.rs"));
    }

    #[test]
    fn test_prepare_file_for_display_finds_stats_for_split_display_path() {
        let mut stats = HashMap::new();
        stats.insert(PathBuf::from("src/new.rs"), (3, 2));

        let mut file = difftastic::DifftFile {
            path: PathBuf::from("src/{old => new}.rs"),
            language: "Rust".to_string(),
            status: difftastic::Status::Changed,
            aligned_lines: Vec::new(),
            chunks: Vec::new(),
        };

        let (file_stats, old_path, new_path, moved_from) =
            prepare_file_for_display(&mut file, &stats, &HashMap::new());

        assert_eq!(file_stats, Some((3, 2)));
        assert_eq!(old_path, PathBuf::from("src/old.rs"));
        assert_eq!(new_path, PathBuf::from("src/new.rs"));
        assert_eq!(moved_from, Some(PathBuf::from("src/old.rs")));
    }

    #[test]
    fn test_prepare_file_for_display_takes_old_path_from_rename_map() {
        let mut renames = HashMap::new();
        renames.insert(PathBuf::from("src/new.rs"), PathBuf::from("src/old.rs"));

        let mut file = difftastic::DifftFile {
            path: PathBuf::from("src/new.rs"),
            language: "Rust".to_string(),
            status: difftastic::Status::Changed,
            aligned_lines: Vec::new(),
            chunks: Vec::new(),
        };

        let (_, old_path, new_path, _) =
            prepare_file_for_display(&mut file, &HashMap::new(), &renames);

        assert_eq!(old_path, PathBuf::from("src/old.rs"));
        assert_eq!(new_path, PathBuf::from("src/new.rs"));
        // Rows must be built as a change against the old content, not as a creation.
        assert_eq!(file.status, difftastic::Status::Changed);
    }

    #[test]
    fn test_parse_jj_summary_rename_simple() {
        let parsed = parse_jj_summary_rename("R src/old.rs => src/new.rs").unwrap();
        assert_eq!(parsed.0, PathBuf::from("src/old.rs"));
        assert_eq!(parsed.1, PathBuf::from("src/new.rs"));
    }

    #[test]
    fn test_parse_jj_summary_rename_brace() {
        let parsed = parse_jj_summary_rename("R src/{old => new}.rs").unwrap();
        assert_eq!(parsed.0, PathBuf::from("src/old.rs"));
        assert_eq!(parsed.1, PathBuf::from("src/new.rs"));
    }

    #[test]
    fn test_parse_jj_summary_renames_map() {
        let renames = parse_jj_summary_renames("R a.txt => b.txt\nA c.txt\n");
        assert_eq!(
            renames.get(Path::new("b.txt")),
            Some(&PathBuf::from("a.txt"))
        );
        assert!(!renames.contains_key(Path::new("c.txt")));
    }

    #[test]
    fn test_parse_jj_summary_renames_brace_forms() {
        let renames = parse_jj_summary_renames(
            "R {a.txt => b.txt}\nR dir/{old.txt => new.txt}\nR {mv.txt => sub/mv.txt}\n",
        );
        assert_eq!(
            renames.get(Path::new("b.txt")),
            Some(&PathBuf::from("a.txt"))
        );
        assert_eq!(
            renames.get(Path::new("dir/new.txt")),
            Some(&PathBuf::from("dir/old.txt"))
        );
        assert_eq!(
            renames.get(Path::new("sub/mv.txt")),
            Some(&PathBuf::from("mv.txt"))
        );
    }

    #[test]
    fn test_parse_jj_summary_renames_ignores_copies() {
        let renames = parse_jj_summary_renames("C {orig.txt => copy.txt}\nM orig.txt\n");
        assert!(renames.is_empty());
    }

    fn created(path: &str) -> difftastic::DifftFile {
        difftastic::DifftFile {
            path: PathBuf::from(path),
            language: "Text".to_string(),
            status: difftastic::Status::Created,
            aligned_lines: Vec::new(),
            chunks: Vec::new(),
        }
    }

    fn has_difft() -> bool {
        Command::new("difft").arg("--version").output().is_ok()
    }

    #[test]
    fn test_pair_jj_rename_keeps_entries_that_are_not_renames() {
        let mut renames = HashMap::new();
        renames.insert(PathBuf::from("b.txt"), PathBuf::from("a.txt"));

        let added = created("other.txt");
        assert_eq!(
            pair_jj_rename(added.clone(), &renames, None, Some("x\n")),
            added
        );

        let mut changed = created("b.txt");
        changed.status = difftastic::Status::Changed;
        assert_eq!(
            pair_jj_rename(changed.clone(), &renames, Some("x\n"), Some("y\n")),
            changed
        );
    }

    #[test]
    fn test_pair_jj_rename_keeps_entry_without_old_content() {
        let mut renames = HashMap::new();
        renames.insert(PathBuf::from("b.txt"), PathBuf::from("a.txt"));

        let file = created("b.txt");
        assert_eq!(
            pair_jj_rename(file.clone(), &renames, None, Some("x\n")),
            file
        );
    }

    #[test]
    fn test_pair_jj_rename_diffs_edited_rename() {
        if !has_difft() {
            return;
        }
        let mut renames = HashMap::new();
        renames.insert(PathBuf::from("src/new.rs"), PathBuf::from("src/old.rs"));

        let file = pair_jj_rename(
            created("src/new.rs"),
            &renames,
            Some("fn a() {}\nfn b() {}\n"),
            Some("fn a() {}\nfn c() {}\n"),
        );

        assert_eq!(file.path, PathBuf::from("src/new.rs"));
        assert_eq!(file.status, difftastic::Status::Changed);
        assert_eq!(file.language, "Rust");
        assert!(!file.chunks.is_empty());
        assert!(!file.aligned_lines.is_empty());
    }

    #[test]
    fn test_pair_jj_rename_reports_pure_rename_as_unchanged() {
        if !has_difft() {
            return;
        }
        let mut renames = HashMap::new();
        renames.insert(PathBuf::from("b.txt"), PathBuf::from("a.txt"));

        let file = pair_jj_rename(created("b.txt"), &renames, Some("x\ny\n"), Some("x\ny\n"));

        assert_eq!(file.path, PathBuf::from("b.txt"));
        assert_eq!(file.status, difftastic::Status::Unchanged);
        assert!(file.chunks.is_empty());
    }

    #[test]
    fn test_parse_git_name_status_z_statuses() {
        let out = b"M\0mod.py\0A\0new file.txt\0D\0gone.rs\0R087\0old.rs\0dir/new.rs\0T\0link\0";
        let changes = parse_git_name_status_z(out);
        let expect = |status, old: Option<&str>, new: Option<&str>| GitChange {
            status,
            old_path: old.map(String::from),
            new_path: new.map(String::from),
        };
        assert_eq!(
            changes,
            vec![
                expect('M', Some("mod.py"), Some("mod.py")),
                expect('A', None, Some("new file.txt")),
                expect('D', Some("gone.rs"), None),
                expect('R', Some("old.rs"), Some("dir/new.rs")),
                expect('T', Some("link"), Some("link")),
            ]
        );
    }

    #[test]
    fn test_parse_git_name_status_z_copy_and_unicode() {
        let out = "C100\0src/a.rs\0src/żółw é.rs\0".as_bytes();
        let changes = parse_git_name_status_z(out);
        assert_eq!(changes.len(), 1);
        assert_eq!(changes[0].status, 'C');
        assert_eq!(changes[0].old_path.as_deref(), Some("src/a.rs"));
        assert_eq!(changes[0].new_path.as_deref(), Some("src/żółw é.rs"));
    }

    #[test]
    fn test_parse_git_name_status_z_empty_and_truncated() {
        assert!(parse_git_name_status_z(b"").is_empty());
        // A rename cut off after its first path is dropped rather than misread.
        assert!(parse_git_name_status_z(b"R100\0only-old\0").is_empty());
    }

    #[test]
    fn test_git_renames_map_new_paths_to_old() {
        let changes = parse_git_name_status_z(b"R090\0a.txt\0b.txt\0M\0c.txt\0A\0d.txt\0");
        let renames = git_renames(&changes);
        assert_eq!(renames.len(), 1);
        assert_eq!(
            renames.get(Path::new("b.txt")),
            Some(&PathBuf::from("a.txt"))
        );
    }

    #[test]
    fn test_git_sides_follow_the_diff_mode() {
        let (old, new, args) = git_sides(&DiffMode::Staged);
        assert!(matches!(old, GitSide::Rev(ref r) if r == "HEAD"));
        assert!(matches!(new, GitSide::Rev(ref r) if r.is_empty()));
        assert_eq!(args, vec!["--cached".to_string()]);

        let (old, new, args) = git_sides(&DiffMode::Unstaged);
        assert!(matches!(old, GitSide::Rev(ref r) if r.is_empty()));
        assert!(matches!(new, GitSide::WorkTree));
        assert!(args.is_empty());

        let (old, new, args) = git_sides(&DiffMode::Range("a..b".to_string()));
        assert!(matches!(old, GitSide::Rev(ref r) if r == "a"));
        assert!(matches!(new, GitSide::Rev(ref r) if r == "b"));
        assert_eq!(args, vec!["a..b".to_string()]);
    }
}
