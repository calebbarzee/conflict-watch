# Conflict Watch

A macOS background helper that tells you, before you open a PR, which files
you're changing that have **also** changed on your base branch.

On a schedule it fetches `origin/main` (or whatever you configure) and compares
it against every worktree of your repo — branch commits, staged, unstaged, and
untracked files. Overlaps go into a running list, and you get a Notification
Center banner; click it to open a plain-text diff snapshot showing both sides
of every overlapping file.

It is **report-only**: it never pulls, merges, or touches a working tree,
index, or branch.

## Install (prebuilt)

1. Download `Conflict-Watch-<version>-macos.zip` from
   [Releases](../../releases) and unzip it.
2. Move **Conflict Watch.app** to `/Applications` (or `~/Applications`).
3. The app is ad-hoc signed, not notarized, so clear the download quarantine
   once:
   ```bash
   xattr -dr com.apple.quarantine "/Applications/Conflict Watch.app"
   ```
4. Open the app. Set **Repo path** (and remote / base branch if not
   `origin/main`), click **Save**, then **Install** next to *Background agent*.
5. Click **Send test notification** and allow notifications when macOS asks.

Requirements: macOS 14+, git ≥ 2.38 (for `merge-tree --write-tree`), and
Python 3 (Xcode Command Line Tools) or Node ≥ 23.6 for the TypeScript engine.

Settings live in `~/Library/Application Support/Conflict Watch/config.json`;
output (running list, snapshots, logs) in the `data/` folder next to it.

## Install (from source)

```bash
git clone <this repo> && cd conflict-watch
./install.sh            # creates config.json from config.example.json, builds the app into ~/Applications, loads the agent
```

A source install uses this checkout's `config.json` and engines, so edits take
effect immediately. `./package.sh` builds the standalone release zip into
`dist/`.

## What you get

- **Running list** — `data/conflicts.md`, one dated section per check that
  found overlaps. Each file shows the latest upstream commit touching it, and
  is tagged **(merge conflict)** when `git merge-tree` says your branch commits
  would actually conflict.
- **Snapshots** — `data/snapshots/<timestamp>.txt`, written whenever a
  notification fires: your diff and the upstream diff (plus commit list) for
  every overlapping file, frozen at that moment.
- **Retention** — the running list, run log, and snapshots are pruned after
  `retainDays`.

## Settings

Everything is editable in the app's settings window or directly in
`config.json`:

| Key | Meaning |
| --- | --- |
| `name` | Label used in notification titles and snapshot headers |
| `repoPath`, `remote`, `baseBranch` | Repo to watch and the branch to compare against (`remote/baseBranch`) |
| `engine` | `python` or `typescript` — two equivalent implementations |
| `enabled`, `intervalMinutes`, `activeHours` | Schedule (launchd wakes every 5 min; a check runs only when due and within active hours) |
| `notifyMode` | `new` (only when new files start overlapping), `every`, or `off` |
| `sound`, `openWith` | Notification sound; app used to open snapshots (blank = default text editor) |
| `includeUntracked`, `ignorePatterns` | What counts as a local change; globs to ignore (also matched against the basename) |
| `retainDays` | History retention in days |
| `dataDir`, `notifierApp` | Output folder; path to the app (blank = auto-detect) |

Relative paths resolve against the config file's folder. Point any piece at a
different config with `--config PATH` or `CONFLICT_WATCH_CONFIG=PATH`.

## Layout

| Path | What |
| --- | --- |
| `run.sh` | launchd entry point; runs the engine named in `config.engine` |
| `python/conflict_watch.py` | Python engine |
| `typescript/conflict-watch.ts` | TypeScript engine (runs directly on Node ≥ 23.6, no build step) |
| `macos/ConflictWatch.swift` | The app: notifications, click → open snapshot, settings window, agent install |
| `macos/build.sh`, `install.sh`, `package.sh` | Build the app / source install / release zip |

The app also has a small CLI:

```bash
APP="/Applications/Conflict Watch.app/Contents/MacOS/ConflictWatch"
"$APP" install-agent       # or uninstall-agent
"$APP" notify --title T --body B --file F --sound
"$APP" auth                # notification permission status
```

## License

MIT — see [LICENSE](LICENSE).
