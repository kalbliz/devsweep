# devsweep

Frees disk space by removing rebuildable Flutter, Node, Gradle, and FVM caches across a folder of projects.

**Read the story:** [Your SSD Isn't Small. Your Projects Are Hoarding It.](./ARTICLE.md)

## Prerequisite

**Run from your projects parent folder** (the directory that contains your repos), or from inside a single project:

```text
StudioProjects/                 ← cd here, then run the script
  kodak/
  my-api/
  devsweep/           ← this folder
    devsweep.ps1
    devsweep.sh
    README.md
```

The script exits with an error if the current folder does not look like a project root (no `pubspec.yaml`, `package.json`, `android/`, `.fvm`, Gradle files, etc. in itself or its children).

## What it cleans

| Kind | Typical targets |
|------|-----------------|
| **Flutter** | `build/`, `.dart_tool/`, `android/**/build`, `ios/Pods`, platform `ephemeral/` |
| **FVM** | `.fvm/flutter_sdk`, `.fvm/versions` (keeps `.fvmrc` / `fvm_config.json`) |
| **Node** | `node_modules/`, `.next/`, `.nuxt/`, `.turbo/`, `dist/`, `out/`, coverage caches |
| **Gradle** | Project-local `.gradle/` and `android/.gradle/` only |
| **Global** (opt-in) | `~/.gradle/caches`, pub cache, global FVM versions |

Source code, lockfiles, and FVM config are not deleted.

## Windows (PowerShell)

```powershell
cd <your-projects-folder>
.\devsweep\devsweep.ps1
```

Interactive flow: dry-run list → choose **A** (all), **S** (specific numbers), **K** (by kind), or **Q** (quit). Deletion always asks you to type `YES`.

```powershell
# Also list shared machine caches (use with care)
.\devsweep\devsweep.ps1 -IncludeGlobalCaches

# Non-interactive (CI / scripts)
.\devsweep\devsweep.ps1 -Apply -Force
```

If execution is blocked:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
# or one-shot:
powershell -ExecutionPolicy Bypass -File .\devsweep\devsweep.ps1
```

## macOS / Linux (Bash)

```bash
cd <your-projects-folder>
chmod +x devsweep/devsweep.sh   # once
./devsweep/devsweep.sh
```

```bash
./devsweep/devsweep.sh --global
./devsweep/devsweep.sh --apply --force
./devsweep/devsweep.sh --root /path/to/projects
```

Requires `du` (standard). Deep trees are removed with `rm -rf`.

## After a delete

The script prints a clear result banner:

- **SUCCESS** – all selected items deleted  
- **PARTIAL SUCCESS** – some deleted, some failed  
- **FAILED** – nothing deleted  

Then you can choose:

- **R** – retry only the failed items  
- **M** – return to the menu with whatever is still on disk  
- **O** – open the HTML report in your browser  
- **Q** – quit (waits for Enter so the window does not close immediately)

## HTML report

After each delete, the script writes:

- `devsweep/last-report.html` – always the latest run  
- `devsweep/reports/report-YYYYMMDD-HHMMSS.html` – timestamped copy  

Open `last-report.html` in a browser to see status, space freed, and every deleted/failed path.

## After cleanup

| Stack | Restore |
|-------|---------|
| Flutter | `flutter pub get` then build/run |
| FVM | `fvm install` |
| Node | `npm install` / `pnpm install` / `yarn` |
| Gradle | Next Android/Flutter build re-downloads |


## Safety notes

- Default mode is **interactive**; nothing is deleted until you confirm with `YES`.
- **Global caches are off by default** — they are shared across all projects on the machine.
- Prefer cleaning project folders first; only use `--global` / `-IncludeGlobalCaches` when you know you need the space.
- First rebuild after a cleanup will be slower (dependencies re-download).

## Sharing with a team

Copy the whole `devsweep/` folder into your projects parent directory (or a shared tooling repo):

- `devsweep.ps1` — Windows
- `devsweep.sh` — macOS / Linux
- `README.md` — this file
