#!/usr/bin/env python3
"""Conflict watch — Python engine.

Fetches <remote>/<baseBranch> for the configured repo and, for every worktree
of that repo, flags files that changed upstream AND are changed locally
(uncommitted, untracked, or committed on that worktree's branch but not yet in
the base). Report-only: never touches any working tree, index, or branch.

Usage: conflict_watch.py [--config PATH] [--force]
  --config  defaults to $CONFLICT_WATCH_CONFIG, else ../config.json
  --force   run even if disabled, outside active hours, or not yet due

launchd runs this every few minutes; it skips unless intervalMinutes has
elapsed since the last run. Relative paths in the config are resolved against
the config file's directory.
"""

from __future__ import annotations

import fnmatch
import json
import os
import plistlib
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path

DEFAULTS = {
    "name": "repo",
    "enabled": True,
    "intervalMinutes": 60,
    "repoPath": ".",
    "remote": "origin",
    "baseBranch": "main",
    "dataDir": "./data",
    "notifierApp": "",  # blank = $CONFLICT_WATCH_NOTIFIER, ~/Applications, /Applications
    "retainDays": 60,
    "notifyMode": "new",  # new | every | off
    "sound": True,
    "includeUntracked": True,
    "ignorePatterns": [],
    "activeHours": {"enabled": False, "start": "08:00", "end": "18:00", "weekdaysOnly": True},
}


def config_path() -> Path:
    if "--config" in sys.argv:
        return Path(sys.argv[sys.argv.index("--config") + 1]).expanduser().resolve()
    if env := os.environ.get("CONFLICT_WATCH_CONFIG"):
        return Path(env).expanduser().resolve()
    return Path(__file__).resolve().parent.parent / "config.json"


def load_config(path: Path) -> dict:
    cfg = json.loads(json.dumps(DEFAULTS))
    try:
        user = json.loads(path.read_text())
    except (OSError, ValueError):
        user = {}
    cfg.update({k: v for k, v in user.items() if k != "activeHours"})
    cfg["activeHours"].update(user.get("activeHours") or {})
    return cfg


def resolve(p: str, relative_to: Path) -> Path:
    path = Path(os.path.expanduser(p))
    return path if path.is_absolute() else (relative_to / path).resolve()


@dataclass
class Paths:
    data: Path

    @property
    def log(self) -> Path:  # running list, appended each time overlaps are found
        return self.data / "conflicts.md"

    @property
    def state(self) -> Path:  # latest overlap set per worktree (used to detect what's new)
        return self.data / "state"

    @property
    def snapshots(self) -> Path:  # plain-text diff snapshot per run that notifies
        return self.data / "snapshots"

    @property
    def runlog(self) -> Path:  # one line per worktree per run
        return self.data / "run.log"

    @property
    def last_run(self) -> Path:
        return self.data / ".last-run"


P: Paths  # set in main()


def now_str() -> str:
    return datetime.now().strftime("%Y-%m-%d %H:%M:%S")


def runlog(line: str) -> None:
    with P.runlog.open("a") as f:
        f.write(f"{now_str()} {line}\n")


def git(cwd: str | Path, *args: str, check: bool = True) -> str:
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout


def lines(s: str) -> list[str]:
    return [l for l in s.splitlines() if l]


def notifier_binary(app: Path) -> Path | None:
    try:
        with (app / "Contents/Info.plist").open("rb") as f:
            exe = app / "Contents/MacOS" / plistlib.load(f)["CFBundleExecutable"]
        return exe if exe.exists() else None
    except (OSError, KeyError, plistlib.InvalidFileException):
        return None


def find_notifier(cfg: dict, root: Path) -> Path | None:
    candidates = [cfg["notifierApp"], os.environ.get("CONFLICT_WATCH_NOTIFIER", ""),
                  "~/Applications/Conflict Watch.app", "/Applications/Conflict Watch.app"]
    for c in filter(None, candidates):
        if exe := notifier_binary(resolve(c, root)):
            return exe
    return None


def notify(cfg: dict, title: str, body: str, file: Path | None) -> None:
    if exe := cfg["_notifier"]:
        args = [str(exe), "notify", "--title", title, "--body", body]
        if file:
            args += ["--file", str(file)]
        if cfg["sound"]:
            args.append("--sound")
        r = subprocess.run(args, capture_output=True, text=True, timeout=120)
        if r.returncode == 0:
            return
        runlog(f"notifier failed: {r.stderr.strip()}")
    script = "on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run"
    subprocess.run(["osascript", "-e", script, title, body], capture_output=True)


def in_active_hours(ah: dict) -> bool:
    if not ah.get("enabled"):
        return True
    now = datetime.now()
    if ah.get("weekdaysOnly") and now.weekday() >= 5:
        return False
    cur, start, end = now.strftime("%H:%M"), ah.get("start", "00:00"), ah.get("end", "23:59")
    return start <= cur < end if start <= end else (cur >= start or cur < end)


def due(cfg: dict) -> bool:
    try:
        last = datetime.fromtimestamp(float(P.last_run.read_text().strip()))
    except (OSError, ValueError):
        return True
    # Small slack so a 60-minute interval on a 5-minute launchd tick doesn't drift to 65.
    return datetime.now() - last >= timedelta(minutes=cfg["intervalMinutes"]) - timedelta(seconds=30)


def prune(retain_days: int) -> None:
    """Drop running-list sections, run.log lines, and snapshots older than retain_days."""
    cutoff = (datetime.now() - timedelta(days=retain_days)).strftime("%Y-%m-%d")
    if P.log.exists():
        out, keep = [], True
        for line in P.log.read_text().splitlines(keepends=True):
            if line.startswith("## ") and line[3:13].count("-") == 2:
                keep = line[3:13] >= cutoff
            if keep:
                out.append(line)
        P.log.write_text("".join(out))
    if P.runlog.exists():
        P.runlog.write_text("".join(l for l in P.runlog.read_text().splitlines(keepends=True) if l[:10] >= cutoff))
    limit = datetime.now().timestamp() - retain_days * 86400
    for snap in P.snapshots.glob("*.txt"):
        if snap.stat().st_mtime < limit:
            snap.unlink()


def list_worktrees(repo: Path) -> list[str]:
    out, path = [], None
    for line in git(repo, "worktree", "list", "--porcelain").splitlines() + [""]:
        if line.startswith("worktree "):
            path = line[len("worktree "):]
        elif line == "bare":
            path = None
        elif line == "" and path:
            if os.path.isdir(path):
                out.append(path)
            path = None
    return out


def state_file(wt: str) -> Path:
    return P.state / (wt.replace("/", "_") + ".txt")


@dataclass
class Result:
    wt: str
    branch: str
    merge_base: str
    overlap: list[str]
    real: set[str]
    new: list[str] = field(default_factory=list)


def check_worktree(wt: str, base: str, cfg: dict) -> Result | None:
    branch = git(wt, "branch", "--show-current").strip()
    if not branch:
        branch = f"(detached {git(wt, 'rev-parse', '--short', 'HEAD').strip()})"
    try:
        merge_base = git(wt, "merge-base", "HEAD", base).strip()
    except RuntimeError as e:
        runlog(f"worktree={wt} skipped: {e}")
        return None

    ignore = cfg["ignorePatterns"]
    keep = lambda f: not any(fnmatch.fnmatch(f, p) or fnmatch.fnmatch(os.path.basename(f), p) for p in ignore)

    # Files changed on the base since this branch diverged.
    upstream = set(filter(keep, lines(git(wt, "diff", "--name-only", merge_base, base))))
    # Local changes: commits on this branch not in base + staged + unstaged (+ untracked).
    local = set(lines(git(wt, "diff", "--name-only", merge_base, "HEAD")))
    local |= set(lines(git(wt, "diff", "--name-only", "--cached")))
    local |= set(lines(git(wt, "diff", "--name-only")))
    if cfg["includeUntracked"]:
        local |= set(lines(git(wt, "ls-files", "--others", "--exclude-standard")))
    overlap = sorted(upstream & local)

    # For branch commits, also ask git whether a real merge would conflict.
    mt = git(wt, "merge-tree", "--write-tree", "--name-only", "--no-messages", "HEAD", base, check=False)
    real = set(lines(mt)[1:])

    runlog(f"worktree={wt} branch={branch} upstream={len(upstream)} local={len(local)} overlap={len(overlap)}")

    sf = state_file(wt)
    prev = set(lines(sf.read_text())) if sf.exists() else set()
    sf.write_text("".join(f + "\n" for f in overlap))
    return Result(wt, branch, merge_base, overlap, real, [f for f in overlap if f not in prev])


def log_entry(r: Result, base: str, base_short: str) -> str:
    out = [f"## {datetime.now():%Y-%m-%d %H:%M} — `{r.wt}` on `{r.branch}` vs `{base}` ({base_short})", ""]
    for f in r.overlap:
        tag = " **(merge conflict)**" if f in r.real else ""
        last = git(r.wt, "log", "--format=%h %an: %s", "-1", f"{r.merge_base}..{base}", "--", f).strip()
        out.append(f"- `{f}`{tag} — upstream: {last}")
    return "\n".join(out) + "\n\n"


def is_known_path(wt: str, merge_base: str, f: str) -> bool:
    tracked = subprocess.run(["git", "ls-files", "--error-unmatch", "--", f], cwd=wt, capture_output=True)
    in_base = subprocess.run(["git", "cat-file", "-e", f"{merge_base}:{f}"], cwd=wt, capture_output=True)
    return tracked.returncode == 0 or in_base.returncode == 0


def snapshot_section(r: Result, base: str, base_short: str) -> str:
    """Both sides of every overlapping file, relative to the merge base."""
    bar, rule = "#" * 80, "=" * 80
    out = [
        bar,
        f"# Worktree: {r.wt}",
        f"# Branch:   {r.branch}",
        f"# Upstream: {base} @ {base_short}   Merge base: {r.merge_base[:11]}",
        bar,
    ]
    for f in r.overlap:
        tag = ("  [MERGE CONFLICT]" if f in r.real else "") + ("  [NEW]" if f in r.new else "")
        mine = (
            git(r.wt, "--no-pager", "diff", "--no-color", r.merge_base, "--", f)
            if is_known_path(r.wt, r.merge_base, f)
            else git(r.wt, "--no-pager", "diff", "--no-color", "--no-index", "/dev/null", f, check=False)
        )
        commits = git(r.wt, "--no-pager", "log", "--format=  %h %an %ad: %s", "--date=short", f"{r.merge_base}..{base}", "--", f)
        theirs = git(r.wt, "--no-pager", "diff", "--no-color", r.merge_base, base, "--", f)
        out += [
            "",
            rule,
            f"FILE: {f}{tag}",
            rule,
            "",
            "----- YOUR CHANGES (merge base -> working tree) -----",
            mine.rstrip("\n"),
            "",
            f"----- UPSTREAM CHANGES (merge base -> {base}) -----",
            commits.rstrip("\n"),
            "",
            theirs.rstrip("\n"),
        ]
    return "\n".join(out) + "\n\n"


def main() -> int:
    global P
    force = "--force" in sys.argv
    cfg_path = config_path()
    cfg = load_config(cfg_path)
    root = cfg_path.parent
    P = Paths(resolve(cfg["dataDir"], root))
    cfg["_notifier"] = find_notifier(cfg, root)
    for d in (P.data, P.state, P.snapshots):
        d.mkdir(parents=True, exist_ok=True)

    if not force and (not cfg["enabled"] or not in_active_hours(cfg["activeHours"]) or not due(cfg)):
        return 0
    P.last_run.write_text(str(datetime.now().timestamp()))
    prune(int(cfg["retainDays"]))

    name = cfg["name"]
    repo = resolve(cfg["repoPath"], root)
    if not repo.is_dir():
        runlog(f"repo not found: {repo}")
        return 1
    remote, branch = cfg["remote"], cfg["baseBranch"]
    base = f"{remote}/{branch}"
    try:
        git(repo, "fetch", "--quiet", remote, branch)
    except RuntimeError as e:
        runlog(f"fetch failed: {e}")
        notify(cfg, f"{name}: conflict watch", f"git fetch {remote} {branch} failed — see run.log", P.runlog)
        return 1
    base_short = git(repo, "rev-parse", "--short", base).strip()

    worktrees = list_worktrees(repo)
    results = [r for wt in worktrees if (r := check_worktree(wt, base, cfg))]

    # Forget state for worktrees that have been removed.
    active = {state_file(wt) for wt in worktrees}
    for sf in P.state.glob("*.txt"):
        if sf not in active:
            sf.unlink()

    flagged = [r for r in results if r.overlap]
    if flagged:
        with P.log.open("a") as f:
            f.writelines(log_entry(r, base, base_short) for r in flagged)

    mode = cfg["notifyMode"]
    to_notify = [r for r in flagged if r.new] if mode == "new" else flagged if mode == "every" else []
    if to_notify:
        snapshot = P.snapshots / f"{datetime.now():%Y-%m-%d_%H%M%S}.txt"
        body = "".join(snapshot_section(r, base, base_short) for r in flagged)
        snapshot.write_text(f"{name} conflict watch snapshot — {now_str()}\n\n{body}")
        files = [f for r in to_notify for f in (r.new if mode == "new" else r.overlap)]
        first = f"{os.path.basename(to_notify[0].wt)}: {files[0]}"
        more = f" +{len(files) - 1} more" if len(files) > 1 else ""
        label = "new potential conflict" if mode == "new" else "potential conflict"
        title = f"{name}: {len(files)} {label}{'s' if len(files) > 1 else ''}"
        notify(cfg, title, f"{first}{more} — click for diff", snapshot)
    return 0


if __name__ == "__main__":
    sys.exit(main())
