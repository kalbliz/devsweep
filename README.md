# devsweep

Interactive cleanup for **Flutter**, **Node**, **Gradle**, and **FVM** caches across a folder of projects — on **Windows**, **macOS**, and **Linux**.

**Read the story:** [Your SSD Isn't Small. Your Projects Are Hoarding It.](./ARTICLE.md)

| Platform | Script |
|----------|--------|
| Windows | `devsweep.ps1` |
| macOS / Linux | `devsweep.sh` |

Both scripts support the same workflow: dry-run list → choose what to delete → confirm with `YES` → result banner → HTML report → retry / menu / quit.

---

## Prerequisite

**Run from your projects parent folder** (the directory that contains your repos), or from inside a single project:

```text
StudioProjects/          ← cd here, then run the script
  kodak/
  my-api/
  devsweep/              ← this folder
    devsweep.ps1
    devsweep.sh
    README.md
    ARTICLE.md
```

The script exits if the folder does not look like a project root (no `pubspec.yaml`, `package.json`, `android/`, `.fvm`, Gradle files, etc. in itself or its children).

If you launch from inside `devsweep/`, it automatically scans the **parent** folder.

---

## What it cleans

| Kind | Typical targets |
|------|-----------------|
| **Flutter** | `build/`, `.dart_tool/`, `android/**/build`, `ios/Pods`, platform `ephemeral/` |
| **FVM** | `.fvm/flutter_sdk`, `.fvm/versions` (keeps `.fvmrc` / `fvm_config.json`) |
| **Node** | `node_modules/`, `.next/`, `.nuxt/`, `.turbo/`, `dist/`, `out/`, coverage caches |
| **Gradle** | Project-local `.gradle/` and `android/.gradle/` only |
| **Global** (opt-in) | `~/.gradle/caches`, pub cache, global FVM versions |

Source code, lockfiles, and FVM config are **not** deleted.

---

## Windows (PowerShell)

```powershell
cd <your-projects-folder>
.\devsweep\devsweep.ps1
```

```powershell
# Also list shared machine caches (use with care)
.\devsweep\devsweep.ps1 -IncludeGlobalCaches

# Non-interactive (CI / scripts)
.\devsweep\devsweep.ps1 -Apply -Force

# Include 0-byte targets
.\devsweep\devsweep.ps1 -ShowEmpty
```

If execution is blocked:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
# or one-shot:
powershell -ExecutionPolicy Bypass -File .\devsweep\devsweep.ps1
```

---

## macOS / Linux (Bash)

Requires Bash 3.2+ (works with macOS `/bin/bash`) and standard `du` / `rm`.

```bash
cd <your-projects-folder>
chmod +x devsweep/devsweep.sh   # once
./devsweep/devsweep.sh
```

```bash
# Also list shared machine caches (use with care)
./devsweep/devsweep.sh --global

# Non-interactive (CI / scripts)
./devsweep/devsweep.sh --apply --force

# Scan a specific folder
./devsweep/devsweep.sh --root /path/to/projects

# Include 0-byte targets
./devsweep/devsweep.sh --show-empty
```

Open the HTML report from the menu with **O** (uses `open` on macOS, `xdg-open` on Linux).

---

## Interactive menu (all platforms)

After the scan, you see reclaimable folders with sizes, then:

| Key | Action |
|-----|--------|
| **A** | Delete **all** listed items |
| **S** | Delete **specific** rows (`1,3,5-8`) |
| **K** | Delete by **kind** (`Flutter`, `Node`, `Gradle`, `FVM`, `Global`) |
| **L** | List targets again |
| **Q** | Quit |

Deletion always requires typing **`YES`**.

### After a delete

| Result | Meaning |
|--------|---------|
| **SUCCESS** | All selected items deleted |
| **PARTIAL SUCCESS** | Some deleted, some failed |
| **FAILED** | Nothing deleted |

Then:

| Key | Action |
|-----|--------|
| **R** | Retry only the failed items |
| **M** | Return to the menu with whatever is still on disk |
| **O** | Open the HTML report in your browser |
| **Q** | Quit (waits for Enter so the window does not close immediately) |

---

## HTML report (Windows, macOS, Linux)

After each delete, both scripts write:

- `devsweep/last-report.html` — always the latest run  
- `devsweep/reports/report-YYYYMMDD-HHMMSS.html` — timestamped copy  

Open `last-report.html` in a browser to see status, space freed, and every deleted/failed path.

---

## After cleanup

| Stack | Restore |
|-------|---------|
| Flutter | `flutter pub get` then build/run |
| FVM | `fvm install` |
| Node | `npm install` / `pnpm install` / `yarn` |
| Gradle | Next Android/Flutter build re-downloads |

---

## Safety notes

- Default mode is **interactive**; nothing is deleted until you confirm with `YES`.
- **Global caches are off by default** — they are shared across all projects on the machine.
- Prefer cleaning project folders first; only use `--global` / `-IncludeGlobalCaches` when you need the space.
- First rebuild after a cleanup will be slower (dependencies re-download).

---

## Sharing with a team

Clone or copy the whole `devsweep/` folder into your projects parent directory:

```bash
git clone https://github.com/kalbliz/devsweep.git
```

- `devsweep.ps1` — Windows  
- `devsweep.sh` — macOS / Linux  
- `README.md` — this file  
- `ARTICLE.md` — background story  
