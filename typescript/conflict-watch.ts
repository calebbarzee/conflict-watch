#!/usr/bin/env node
/**
 * Conflict watch — TypeScript engine (runs directly on Node >= 23.6, no build step).
 *
 * Fetches <remote>/<baseBranch> for the configured repo and, for every worktree
 * of that repo, flags files that changed upstream AND are changed locally
 * (uncommitted, untracked, or committed on that worktree's branch but not yet in
 * the base). Report-only: never touches any working tree, index, or branch.
 *
 * Usage: conflict-watch.ts [--config PATH] [--force]
 *   --config  defaults to $CONFLICT_WATCH_CONFIG, else ../config.json
 *   --force   run even if disabled, outside active hours, or not yet due
 *
 * Behaviour matches ../python/conflict_watch.py; keep the two in sync.
 */

import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

type ActiveHours = { enabled: boolean; start: string; end: string; weekdaysOnly: boolean };
type Config = {
  name: string;
  enabled: boolean;
  intervalMinutes: number;
  repoPath: string;
  remote: string;
  baseBranch: string;
  dataDir: string;
  notifierApp: string;
  retainDays: number;
  notifyMode: "new" | "every" | "off";
  sound: boolean;
  includeUntracked: boolean;
  ignorePatterns: string[];
  activeHours: ActiveHours;
};

const DEFAULTS: Config = {
  name: "repo",
  enabled: true,
  intervalMinutes: 60,
  repoPath: ".",
  remote: "origin",
  baseBranch: "main",
  dataDir: "./data",
  notifierApp: "", // blank = $CONFLICT_WATCH_NOTIFIER, ~/Applications, /Applications
  retainDays: 60,
  notifyMode: "new",
  sound: true,
  includeUntracked: true,
  ignorePatterns: [],
  activeHours: { enabled: false, start: "08:00", end: "18:00", weekdaysOnly: true },
};

const argv = process.argv.slice(2);

function configPath(): string {
  const i = argv.indexOf("--config");
  if (i >= 0) return path.resolve(expandHome(argv[i + 1]));
  if (process.env.CONFLICT_WATCH_CONFIG) return path.resolve(expandHome(process.env.CONFLICT_WATCH_CONFIG));
  return path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "config.json");
}

function loadConfig(p: string): Config {
  let user: Partial<Config> = {};
  try {
    user = JSON.parse(fs.readFileSync(p, "utf8"));
  } catch {}
  return { ...DEFAULTS, ...user, activeHours: { ...DEFAULTS.activeHours, ...(user.activeHours ?? {}) } };
}

function expandHome(p: string): string {
  return p === "~" || p.startsWith("~/") ? path.join(os.homedir(), p.slice(1)) : p;
}

function resolvePath(p: string, relativeTo: string): string {
  return path.resolve(relativeTo, expandHome(p));
}

// Data layout (under config.dataDir), set in main().
let LOG = ""; //       running list, appended each time overlaps are found
let STATE_DIR = ""; // latest overlap set per worktree (used to detect what's new)
let SNAP_DIR = ""; //  plain-text diff snapshot per run that notifies
let RUNLOG = ""; //    one line per worktree per run
let LAST_RUN = "";

const pad = (n: number) => String(n).padStart(2, "0");
const ymd = (d = new Date()) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
const hm = (d = new Date()) => `${pad(d.getHours())}:${pad(d.getMinutes())}`;
const nowStr = (d = new Date()) => `${ymd(d)} ${hm(d)}:${pad(d.getSeconds())}`;

function runlog(line: string): void {
  fs.appendFileSync(RUNLOG, `${nowStr()} ${line}\n`);
}

function git(cwd: string, args: string[], check = true): string {
  const r = spawnSync("git", args, { cwd, encoding: "utf8", maxBuffer: 256 * 1024 * 1024 });
  if (check && r.status !== 0) throw new Error(`git ${args.join(" ")}: ${(r.stderr ?? "").trim()}`);
  return r.stdout ?? "";
}

const lines = (s: string) => s.split("\n").filter(Boolean);

function notifierBinary(app: string): string | null {
  const r = spawnSync("/usr/bin/plutil", ["-extract", "CFBundleExecutable", "raw", path.join(app, "Contents/Info.plist")], {
    encoding: "utf8",
  });
  if (r.status !== 0) return null;
  const exe = path.join(app, "Contents/MacOS", r.stdout.trim());
  return fs.existsSync(exe) ? exe : null;
}

function findNotifier(cfg: Config, root: string): string | null {
  const candidates = [cfg.notifierApp, process.env.CONFLICT_WATCH_NOTIFIER ?? "",
    "~/Applications/Conflict Watch.app", "/Applications/Conflict Watch.app"];
  for (const c of candidates.filter(Boolean)) {
    const exe = notifierBinary(resolvePath(c, root));
    if (exe) return exe;
  }
  return null;
}

function notify(cfg: Config, exe: string | null, title: string, body: string, file: string | null): void {
  if (exe) {
    const args = ["notify", "--title", title, "--body", body];
    if (file) args.push("--file", file);
    if (cfg.sound) args.push("--sound");
    const r = spawnSync(exe, args, { encoding: "utf8", timeout: 120_000 });
    if (r.status === 0) return;
    runlog(`notifier failed: ${(r.stderr ?? "").trim()}`);
  }
  const script = "on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run";
  spawnSync("osascript", ["-e", script, title, body]);
}

function inActiveHours(ah: ActiveHours): boolean {
  if (!ah.enabled) return true;
  const now = new Date();
  if (ah.weekdaysOnly && (now.getDay() === 0 || now.getDay() === 6)) return false;
  const cur = hm(now);
  return ah.start <= ah.end ? ah.start <= cur && cur < ah.end : cur >= ah.start || cur < ah.end;
}

function due(cfg: Config): boolean {
  let last: number;
  try {
    last = parseFloat(fs.readFileSync(LAST_RUN, "utf8").trim()) * 1000;
  } catch {
    return true;
  }
  if (Number.isNaN(last)) return true;
  // Small slack so a 60-minute interval on a 5-minute launchd tick doesn't drift to 65.
  return Date.now() - last >= cfg.intervalMinutes * 60_000 - 30_000;
}

/** Drop running-list sections, run.log lines, and snapshots older than retainDays. */
function prune(retainDays: number): void {
  const cutoff = ymd(new Date(Date.now() - retainDays * 86_400_000));
  if (fs.existsSync(LOG)) {
    let keep = true;
    const out: string[] = [];
    for (const line of fs.readFileSync(LOG, "utf8").split(/(?<=\n)/)) {
      if (line.startsWith("## ") && /^\d{4}-\d{2}-\d{2}$/.test(line.slice(3, 13))) keep = line.slice(3, 13) >= cutoff;
      if (keep) out.push(line);
    }
    fs.writeFileSync(LOG, out.join(""));
  }
  if (fs.existsSync(RUNLOG)) {
    const kept = fs.readFileSync(RUNLOG, "utf8").split(/(?<=\n)/).filter((l) => l.slice(0, 10) >= cutoff);
    fs.writeFileSync(RUNLOG, kept.join(""));
  }
  const limit = Date.now() - retainDays * 86_400_000;
  for (const f of fs.readdirSync(SNAP_DIR)) {
    const p = path.join(SNAP_DIR, f);
    if (f.endsWith(".txt") && fs.statSync(p).mtimeMs < limit) fs.unlinkSync(p);
  }
}

function listWorktrees(repo: string): string[] {
  const out: string[] = [];
  let cur: string | null = null;
  for (const line of [...git(repo, ["worktree", "list", "--porcelain"]).split("\n"), ""]) {
    if (line.startsWith("worktree ")) cur = line.slice("worktree ".length);
    else if (line === "bare") cur = null;
    else if (line === "" && cur) {
      if (fs.existsSync(cur) && fs.statSync(cur).isDirectory()) out.push(cur);
      cur = null;
    }
  }
  return out;
}

const stateFile = (wt: string) => path.join(STATE_DIR, wt.replaceAll("/", "_") + ".txt");

type Result = { wt: string; branch: string; mergeBase: string; overlap: string[]; real: Set<string>; fresh: string[] };

function checkWorktree(wt: string, base: string, cfg: Config): Result | null {
  let branch = git(wt, ["branch", "--show-current"]).trim();
  if (!branch) branch = `(detached ${git(wt, ["rev-parse", "--short", "HEAD"]).trim()})`;
  let mergeBase: string;
  try {
    mergeBase = git(wt, ["merge-base", "HEAD", base]).trim();
  } catch (e) {
    runlog(`worktree=${wt} skipped: ${(e as Error).message}`);
    return null;
  }

  const keep = (f: string) =>
    !cfg.ignorePatterns.some((p) => path.matchesGlob(f, p) || path.matchesGlob(path.basename(f), p));

  // Files changed on the base since this branch diverged.
  const upstream = new Set(lines(git(wt, ["diff", "--name-only", mergeBase, base])).filter(keep));
  // Local changes: commits on this branch not in base + staged + unstaged (+ untracked).
  const local = new Set([
    ...lines(git(wt, ["diff", "--name-only", mergeBase, "HEAD"])),
    ...lines(git(wt, ["diff", "--name-only", "--cached"])),
    ...lines(git(wt, ["diff", "--name-only"])),
    ...(cfg.includeUntracked ? lines(git(wt, ["ls-files", "--others", "--exclude-standard"])) : []),
  ]);
  const overlap = [...upstream].filter((f) => local.has(f)).sort();

  // For branch commits, also ask git whether a real merge would conflict.
  const mt = git(wt, ["merge-tree", "--write-tree", "--name-only", "--no-messages", "HEAD", base], false);
  const real = new Set(lines(mt).slice(1));

  runlog(`worktree=${wt} branch=${branch} upstream=${upstream.size} local=${local.size} overlap=${overlap.length}`);

  const sf = stateFile(wt);
  const prev = new Set(fs.existsSync(sf) ? lines(fs.readFileSync(sf, "utf8")) : []);
  fs.writeFileSync(sf, overlap.map((f) => f + "\n").join(""));
  return { wt, branch, mergeBase, overlap, real, fresh: overlap.filter((f) => !prev.has(f)) };
}

function logEntry(r: Result, base: string, baseShort: string): string {
  const out = [`## ${ymd()} ${hm()} — \`${r.wt}\` on \`${r.branch}\` vs \`${base}\` (${baseShort})`, ""];
  for (const f of r.overlap) {
    const tag = r.real.has(f) ? " **(merge conflict)**" : "";
    const last = git(r.wt, ["log", "--format=%h %an: %s", "-1", `${r.mergeBase}..${base}`, "--", f]).trim();
    out.push(`- \`${f}\`${tag} — upstream: ${last}`);
  }
  return out.join("\n") + "\n\n";
}

function isKnownPath(wt: string, mergeBase: string, f: string): boolean {
  return (
    spawnSync("git", ["ls-files", "--error-unmatch", "--", f], { cwd: wt }).status === 0 ||
    spawnSync("git", ["cat-file", "-e", `${mergeBase}:${f}`], { cwd: wt }).status === 0
  );
}

/** Both sides of every overlapping file, relative to the merge base. */
function snapshotSection(r: Result, base: string, baseShort: string): string {
  const bar = "#".repeat(80);
  const rule = "=".repeat(80);
  const out = [
    bar,
    `# Worktree: ${r.wt}`,
    `# Branch:   ${r.branch}`,
    `# Upstream: ${base} @ ${baseShort}   Merge base: ${r.mergeBase.slice(0, 11)}`,
    bar,
  ];
  for (const f of r.overlap) {
    const tag = (r.real.has(f) ? "  [MERGE CONFLICT]" : "") + (r.fresh.includes(f) ? "  [NEW]" : "");
    const mine = isKnownPath(r.wt, r.mergeBase, f)
      ? git(r.wt, ["--no-pager", "diff", "--no-color", r.mergeBase, "--", f])
      : git(r.wt, ["--no-pager", "diff", "--no-color", "--no-index", "/dev/null", f], false);
    const commits = git(r.wt, ["--no-pager", "log", "--format=  %h %an %ad: %s", "--date=short", `${r.mergeBase}..${base}`, "--", f]);
    const theirs = git(r.wt, ["--no-pager", "diff", "--no-color", r.mergeBase, base, "--", f]);
    out.push(
      "",
      rule,
      `FILE: ${f}${tag}`,
      rule,
      "",
      "----- YOUR CHANGES (merge base -> working tree) -----",
      mine.replace(/\n+$/, ""),
      "",
      `----- UPSTREAM CHANGES (merge base -> ${base}) -----`,
      commits.replace(/\n+$/, ""),
      "",
      theirs.replace(/\n+$/, ""),
    );
  }
  return out.join("\n") + "\n\n";
}

function main(): number {
  const force = argv.includes("--force");
  const cfgPath = configPath();
  const cfg = loadConfig(cfgPath);
  const root = path.dirname(cfgPath);
  const dataDir = resolvePath(cfg.dataDir, root);
  const notifier = findNotifier(cfg, root);
  LOG = path.join(dataDir, "conflicts.md");
  STATE_DIR = path.join(dataDir, "state");
  SNAP_DIR = path.join(dataDir, "snapshots");
  RUNLOG = path.join(dataDir, "run.log");
  LAST_RUN = path.join(dataDir, ".last-run");
  for (const d of [dataDir, STATE_DIR, SNAP_DIR]) fs.mkdirSync(d, { recursive: true });

  if (!force && (!cfg.enabled || !inActiveHours(cfg.activeHours) || !due(cfg))) return 0;
  fs.writeFileSync(LAST_RUN, String(Date.now() / 1000));
  prune(Number(cfg.retainDays));

  const name = cfg.name;
  const repo = resolvePath(cfg.repoPath, root);
  if (!fs.existsSync(repo)) {
    runlog(`repo not found: ${repo}`);
    return 1;
  }
  const base = `${cfg.remote}/${cfg.baseBranch}`;
  try {
    git(repo, ["fetch", "--quiet", cfg.remote, cfg.baseBranch]);
  } catch (e) {
    runlog(`fetch failed: ${(e as Error).message}`);
    notify(cfg, notifier, `${name}: conflict watch`, `git fetch ${cfg.remote} ${cfg.baseBranch} failed — see run.log`, RUNLOG);
    return 1;
  }
  const baseShort = git(repo, ["rev-parse", "--short", base]).trim();

  const worktrees = listWorktrees(repo);
  const results = worktrees.map((wt) => checkWorktree(wt, base, cfg)).filter((r): r is Result => r !== null);

  // Forget state for worktrees that have been removed.
  const active = new Set(worktrees.map(stateFile));
  for (const f of fs.readdirSync(STATE_DIR)) {
    const p = path.join(STATE_DIR, f);
    if (f.endsWith(".txt") && !active.has(p)) fs.unlinkSync(p);
  }

  const flagged = results.filter((r) => r.overlap.length);
  if (flagged.length) fs.appendFileSync(LOG, flagged.map((r) => logEntry(r, base, baseShort)).join(""));

  const mode = cfg.notifyMode;
  const toNotify = mode === "new" ? flagged.filter((r) => r.fresh.length) : mode === "every" ? flagged : [];
  if (toNotify.length) {
    const d = new Date();
    const snapshot = path.join(SNAP_DIR, `${ymd(d)}_${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}.txt`);
    const body = flagged.map((r) => snapshotSection(r, base, baseShort)).join("");
    fs.writeFileSync(snapshot, `${name} conflict watch snapshot — ${nowStr(d)}\n\n${body}`);
    const files = toNotify.flatMap((r) => (mode === "new" ? r.fresh : r.overlap));
    const first = `${path.basename(toNotify[0].wt)}: ${files[0]}`;
    const more = files.length > 1 ? ` +${files.length - 1} more` : "";
    const label = mode === "new" ? "new potential conflict" : "potential conflict";
    notify(cfg, notifier, `${name}: ${files.length} ${label}${files.length > 1 ? "s" : ""}`, `${first}${more} — click for diff`, snapshot);
  }
  return 0;
}

process.exit(main());
