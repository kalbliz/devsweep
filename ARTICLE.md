# Your SSD Isn't Small. Your Projects Are Hoarding It.

Modern development does not fail loudly when the disk fills up.
It fails mid-build, with an error that looks like a dependency bug,
a Gradle mystery, or a plugin that suddenly cannot resolve
`com.android.tools:sdk-common`.

Then you scroll far enough and find the real line:

```text
java.io.IOException: There is not enough space on the disk
```

That message is honest. Everything above it is noise.

This article is about why developer machines quietly fill up,
what is actually safe to delete, and a small tool that makes
cleaning a whole projects folder practical instead of painful.

---

## The quiet economics of a coding machine

A product repo is rarely just source code.

Around every app you keep a temporary city of rebuildable debris:

| What | Why it exists | Typical size |
|------|----------------|--------------|
| Flutter / Android `build/` | Compiled artifacts for the last device/ABI you targeted | Hundreds of MB to **10+ GB** per app |
| `.dart_tool/` | Package config, build graphs, codegen caches | Tens to hundreds of MB |
| `node_modules/` | Exact dependency tree for one package manager lockfile | **200 MB–4 GB** per JS app |
| `.next/`, `dist/`, `.turbo/` | Framework and bundler outputs | Tens to hundreds of MB |
| Project `.gradle/` | Android plugin caches local to that repo | Tens to hundreds of MB |
| FVM SDK copies | Pinned Flutter versions per project | **500 MB–1.5 GB** each |

None of that is "your product" in the git sense.
Almost all of it can be regenerated with `flutter pub get`,
`npm install`, `fvm install`, or the next Android build.

The problem is not that caches exist.
The problem is that **caches multiply by the number of projects on disk**.

If you keep twenty Flutter apps and ten Node services under one parent folder —
a `StudioProjects`, `repos`, `work`, or `code` directory —
you are not managing twenty apps.
You are managing twenty independent cache economies that never talk to each other
and never volunteer to leave.

---

## A real failure mode

On one Windows machine, a Flutter debug build failed while configuring
`:sensors_plus`. The stack blamed Android Gradle Plugin artifacts.
Flutter even printed an AGP 9 DSL warning that looked important.

The decisive error was simpler: the Gradle cache could not write a descriptor
because **C: had no free space**.

After a structured cleanup across the projects parent folder,
that same machine reclaimed on the order of **~50+ GB** from:

- orphaned Flutter `build/` trees (some over 8–12 GB alone)
- stale `node_modules`
- local Gradle folders
- leftover framework outputs

The AGP warning was a distraction.
The disk was the bug.

---

## Why "just delete build" does not scale

Every experienced developer already knows the manual ritual:

```bash
rm -rf build node_modules .next
flutter clean
```

That works for the repo you are staring at.

It fails as a habit when:

1. **You have dozens of repos**, and only one of them is currently angry.
2. **Windows path length** turns `Remove-Item` into cryptic failures on deep Android trees.
3. **You are not sure what is safe** — is `.dart_tool` disposable? Is `.fvm`?
4. **You need proof** after the fact: what was deleted, how much came back, what failed.

So people either:

- delete nothing and buy a bigger drive, or
- delete too aggressively and spend the afternoon reinstalling the wrong SDK.

What we need is a boring, reviewable cleanup pass over the whole projects folder —
interactive, cross-platform, and biased toward safety.

---

## Introducing **devsweep**

[`devsweep`](https://github.com/kalbliz/devsweep) is a small
PowerShell + Bash toolkit you drop beside your repos.

```text
StudioProjects/
  kodak/
  my-api/
  devsweep/
    devsweep.ps1
    devsweep.sh
    README.md
```

You run it from the **projects parent folder** (or a single project root).

### What it does

1. **Scans** for Flutter, Node, Gradle, and FVM cache/output folders.
2. **Shows sizes** before anything is deleted.
3. Lets you choose:
   - **A** — delete all listed targets
   - **S** — delete specific rows (`1,3,5-8`)
   - **K** — delete by kind (`Flutter`, `Node`, `Gradle`, `FVM`, …)
4. Asks you to type **YES** before permanent deletion.
5. Prints a **SUCCESS / PARTIAL SUCCESS / FAILED** summary.
6. Writes an **HTML report** you can open later:
   - `last-report.html`
   - `reports/report-YYYYMMDD-HHMMSS.html`

### What it refuses to treat casually

- Source trees, lockfiles, and app config stay untouched.
- FVM **config** stays; only cached SDK copies under `.fvm` are candidates.
- **Global** caches (`~/.gradle`, pub cache, machine-wide FVM versions)
  are **opt-in**, because those are shared across every project on the machine.

### Platforms

| OS | Entry point |
|----|-------------|
| Windows | `.\devsweep\devsweep.ps1` |
| macOS / Linux | `./devsweep/devsweep.sh` |

---

## A mental model that keeps you safe

Think in three layers:

### 1. Project outputs (delete freely)

`build/`, `dist/`, `.next/`, `android/app/build`, framework `ephemeral/` folders.

These are pure regenerate-on-demand artifacts.

### 2. Project dependency installs (delete when idle)

`node_modules/`, local `.dart_tool/`, local `.gradle/`.

Deleting them costs a reinstall/rebuild later.
That cost is fine for repos you are not actively shipping today.

### 3. Machine-wide caches (delete with intent)

User Gradle caches, pub hosted cache, global FVM versions.

Clean these when the disk is critical and you understand the rebuild tax
will hit *every* project, not just one.

`devsweep` defaults to layers 1–2.
Layer 3 requires an explicit flag.

---

## How to use it

### Windows

```powershell
cd C:\Users\You\StudioProjects
.\devsweep\devsweep.ps1
```

### macOS / Linux

```bash
cd ~/StudioProjects
chmod +x devsweep/devsweep.sh
./devsweep/devsweep.sh
```

Review the dry-run list.
Delete all, by kind, or by row.
Open the HTML report with **O** when you want a shareable summary.

Afterward, restore only what you need:

| Stack | Restore |
|-------|---------|
| Flutter | `flutter pub get` then run/build |
| Node | `npm install` / `pnpm i` / `yarn` |
| FVM | `fvm install` |
| Android | next Gradle/Flutter build rehydrates caches |

---

## What this is not

It is not antivirus.
It is not a substitute for moving large media off your system drive.
It is not a license to wipe `~/.gradle` every Monday "just in case."

It is a **projects-folder janitor** for people who keep many active
(and many abandoned) codebases on one machine — which is most of us.

---

## The habit worth keeping

Disk pressure on a developer laptop is usually not mysterious.
It is compound interest on unfinished cleanup.

A useful cadence:

1. When a build fails with I/O or "no space" errors, **believe the disk first**.
2. Run a reviewable cleanup on the projects parent folder.
3. Keep the HTML report so you know what came back.
4. Only escalate to global caches if project-level cleanup is not enough.

Space is part of your toolchain.
Treat it like dependency debt: invisible until it blocks the next ship.

---

## Get the tool

- GitHub: [https://github.com/kalbliz/devsweep](https://github.com/kalbliz/devsweep)
- Clone it into your projects parent folder, or copy the directory beside your repos.
- Read `README.md` for flags, safety notes, and team sharing.

If this saves you from one false chase through AGP warnings while the real problem
was a full SSD, it has already paid for itself.
