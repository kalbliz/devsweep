#!/usr/bin/env bash
# devsweep - cache cleanup for macOS / Linux.
# Compatible with Bash 3.2+ (macOS /bin/bash).
# Feature parity with devsweep.ps1: interactive menu, HTML reports,
# post-action retry / return-to-menu / open report.
#
#   chmod +x devsweep/devsweep.sh
#   ./devsweep/devsweep.sh
#
# See README.md

set -u

trim_cr() {
  printf '%s' "$1" | tr -d '\r'
}

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=""
APPLY=0
FORCE=0
INCLUDE_GLOBAL=0
SHOW_EMPTY=0
LAST_REPORT=""
SCAN_ROOT=""

# Persistent result files for post-action menu (cleaned on EXIT)
DELETED_FILE=""
FAILED_FILE=""
CURRENT_FILE=""
PROJECT_DIRS_FILE=""
TARGETS_FILE=""

usage() {
  cat <<'EOF'
Usage: ./devsweep.sh [options]

  --root <path>   Folder to scan (default: current directory)
  --global        Also list user-level Gradle / Pub / FVM caches
  --apply         Non-interactive: delete all found targets
  --force         With --apply, skip YES confirmation
  --show-empty    Include 0-byte targets in the list
  -h, --help      Show this help

Prerequisite: run from a projects parent folder or a single project root.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --root)
      ROOT="${2:-}"
      if [ -z "$ROOT" ]; then echo "ERROR: --root needs a path" >&2; exit 1; fi
      shift 2
      ;;
    --global) INCLUDE_GLOBAL=1; shift ;;
    --apply) APPLY=1; shift ;;
    --force) FORCE=1; shift ;;
    --show-empty) SHOW_EMPTY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

cleanup_temp() {
  [ -n "${PROJECT_DIRS_FILE:-}" ] && [ -f "$PROJECT_DIRS_FILE" ] && rm -f "$PROJECT_DIRS_FILE"
  [ -n "${TARGETS_FILE:-}" ] && [ -f "$TARGETS_FILE" ] && rm -f "$TARGETS_FILE"
  [ -n "${DELETED_FILE:-}" ] && [ -f "$DELETED_FILE" ] && rm -f "$DELETED_FILE"
  [ -n "${FAILED_FILE:-}" ] && [ -f "$FAILED_FILE" ] && rm -f "$FAILED_FILE"
  [ -n "${CURRENT_FILE:-}" ] && [ -f "$CURRENT_FILE" ] && rm -f "$CURRENT_FILE"
}
trap cleanup_temp EXIT

wait_if_interactive() {
  if [ "$APPLY" -eq 1 ] && [ "$FORCE" -eq 1 ]; then
    return 0
  fi
  echo ""
  printf "Press Enter to close: "
  read -r _
}

resolve_scan_root() {
  local cwd parent
  cwd=$(pwd)
  if [ -n "$ROOT" ]; then
    (cd "$ROOT" && pwd)
    return
  fi
  if [ "$cwd" = "$SCRIPT_DIR" ]; then
    parent=$(dirname "$SCRIPT_DIR")
    echo "Note: running from tools folder; scanning parent: $parent" >&2
    echo "$parent"
    return
  fi
  echo "$cwd"
}

format_bytes() {
  local b=${1:-0}
  if [ "$b" -ge 1073741824 ] 2>/dev/null; then
    awk -v n="$b" 'BEGIN { printf "%.2f GB", n/1073741824 }'
  elif [ "$b" -ge 1048576 ] 2>/dev/null; then
    awk -v n="$b" 'BEGIN { printf "%.2f MB", n/1048576 }'
  elif [ "$b" -ge 1024 ] 2>/dev/null; then
    awk -v n="$b" 'BEGIN { printf "%.2f KB", n/1024 }'
  else
    echo "${b} B"
  fi
}

escape_html() {
  # stdin -> stdout
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

folder_size_bytes() {
  local path="$1" kb
  if [ ! -e "$path" ]; then
    echo 0
    return
  fi
  kb=$(du -sk "$path" 2>/dev/null | awk '{print $1}')
  kb=${kb:-0}
  echo $((kb * 1024))
}

looks_like_project() {
  local d="$1"
  [ -f "$d/pubspec.yaml" ] && return 0
  [ -f "$d/package.json" ] && return 0
  [ -f "$d/build.gradle" ] && return 0
  [ -f "$d/build.gradle.kts" ] && return 0
  [ -f "$d/settings.gradle" ] && return 0
  [ -f "$d/settings.gradle.kts" ] && return 0
  [ -d "$d/android" ] && return 0
  [ -d "$d/ios" ] && return 0
  [ -d "$d/.fvm" ] && return 0
  [ -f "$d/.fvmrc" ] && return 0
  return 1
}

is_flutter_project() {
  local d="$1"
  [ -f "$d/pubspec.yaml" ] || return 1
  if grep -Eq '^[[:space:]]*flutter[[:space:]]*:' "$d/pubspec.yaml" 2>/dev/null; then
    return 0
  fi
  [ -d "$d/android" ] || [ -d "$d/ios" ]
}

is_node_project() { [ -f "$1/package.json" ]; }

is_android_gradle_project() {
  local d="$1"
  [ -d "$d/android" ] && return 0
  [ -f "$d/build.gradle" ] && return 0
  [ -f "$d/build.gradle.kts" ] && return 0
  [ -f "$d/settings.gradle" ] && return 0
  [ -f "$d/settings.gradle.kts" ] && return 0
  return 1
}

has_fvm() { [ -d "$1/.fvm" ] || [ -f "$1/.fvmrc" ]; }

assert_valid_root() {
  local root="$1" child
  if [ ! -d "$root" ]; then
    echo "ERROR: Folder not found: $root" >&2
    wait_if_interactive
    exit 1
  fi

  if looks_like_project "$root"; then
    return 0
  fi

  for child in "$root"/*; do
    [ -d "$child" ] || continue
    if looks_like_project "$child"; then
      return 0
    fi
  done

  echo ""
  echo "ERROR: This does not look like a projects folder."
  echo ""
  echo "Run from the parent directory that contains your repos,"
  echo "or from inside a single Flutter/Node/Android project."
  echo ""
  echo "  cd <your-projects-folder>"
  echo "  ./devsweep/devsweep.sh"
  echo ""
  echo "Current folder: $root"
  wait_if_interactive
  exit 1
}

is_skipped_name() {
  case "$1" in
    .idea|.qodo|.git|.vscode|Screenshots|node_modules|build|.dart_tool|.gradle|.fvm|dist|out|Pods|coverage|.next|.nuxt|.turbo|devsweep|cleanup-dev-caches|lib|test|tests|assets|images|fonts|docs|doc|tool|tools|scripts|web|windows|linux|macos|ios|android|.stitch_inspect|ephemeral)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_nest_name() {
  case "$1" in
    packages|apps|mobile|web|frontend|backend|client|server|admin|functions|third_party)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

collect_project_dirs() {
  local root="$1" child name nest nested sub
  PROJECT_DIRS_FILE=$(mktemp)

  add_dir() {
    local d="$1"
    if ! grep -Fxq "$d" "$PROJECT_DIRS_FILE" 2>/dev/null; then
      echo "$d" >> "$PROJECT_DIRS_FILE"
    fi
  }

  if looks_like_project "$root"; then
    add_dir "$root"
  fi

  for child in "$root"/*; do
    [ -d "$child" ] || continue
    name=$(basename "$child")
    is_skipped_name "$name" && continue

    if is_nest_name "$name"; then
      for nested in "$child"/*; do
        [ -d "$nested" ] || continue
        is_skipped_name "$(basename "$nested")" && continue
        if looks_like_project "$nested"; then
          add_dir "$nested"
        fi
      done
    fi

    if looks_like_project "$child"; then
      add_dir "$child"
      for nest in "$child"/*; do
        [ -d "$nest" ] || continue
        if is_nest_name "$(basename "$nest")"; then
          for nested in "$nest"/*; do
            [ -d "$nested" ] || continue
            is_skipped_name "$(basename "$nested")" && continue
            if looks_like_project "$nested"; then
              add_dir "$nested"
            fi
          done
        fi
      done
      for sub in "$child"/*; do
        [ -d "$sub" ] || continue
        is_skipped_name "$(basename "$sub")" && continue
        if looks_like_project "$sub"; then
          add_dir "$sub"
        fi
      done
    fi
  done
}

rel_project() {
  local dir="$1" root="$2" rel
  case "$dir" in
    "$root") echo "(root)" ;;
    "$root"/*)
      rel="${dir#$root/}"
      echo "$rel"
      ;;
    *) echo "$dir" ;;
  esac
}

# Targets file: kind|project|name|path|size
add_target() {
  local kind="$1" project="$2" path="$3" size name
  [ -e "$path" ] || return 0
  if awk -F'|' -v p="$path" '$4 == p { found=1 } END { exit !found }' "$TARGETS_FILE" 2>/dev/null; then
    return 0
  fi
  echo "  sizing: [$kind] $project/$(basename "$path")"
  size=$(folder_size_bytes "$path")
  if [ "$SHOW_EMPTY" -eq 0 ] && [ "$size" -le 0 ]; then
    return 0
  fi
  name=$(basename "$path")
  printf '%s|%s|%s|%s|%s\n' "$kind" "$project" "$name" "$path" "$size" >> "$TARGETS_FILE"
}

collect_flutter() {
  local d="$1" rel="$2" p
  for p in \
    "$d/build" "$d/.dart_tool" \
    "$d/android/app/build" "$d/android/build" \
    "$d/ios/Pods" "$d/ios/.symlinks" "$d/macos/Pods" \
    "$d/linux/flutter/ephemeral" "$d/windows/flutter/ephemeral" \
    "$d/.cxx"
  do
    add_target "Flutter" "$rel" "$p"
  done
}

collect_fvm() {
  local d="$1" rel="$2" ver
  add_target "FVM" "$rel" "$d/.fvm/flutter_sdk"
  add_target "FVM" "$rel" "$d/.fvm/versions"
  if [ -d "$d/.fvm/versions" ]; then
    for ver in "$d/.fvm/versions"/*; do
      [ -d "$ver" ] || continue
      add_target "FVM" "$rel" "$ver"
    done
  fi
}

collect_gradle() {
  local d="$1" rel="$2"
  add_target "Gradle" "$rel" "$d/.gradle"
  add_target "Gradle" "$rel" "$d/android/.gradle"
}

collect_node() {
  local d="$1" rel="$2" name
  for name in \
    node_modules .next .nuxt .turbo .vercel .parcel-cache .cache \
    coverage .output storybook-static dist out .svelte-kit
  do
    add_target "Node" "$rel" "$d/$name"
  done
}

collect_global() {
  local home="${HOME:-}"
  [ -n "$home" ] || return 0
  add_target "Global" "(user)" "$home/.gradle/caches"
  add_target "Global" "(user)" "$home/.gradle/daemon"
  add_target "Global" "(user)" "$home/.pub-cache/hosted"
  add_target "Global" "(user)" "$home/fvm/versions"
}

sort_targets_file() {
  local src="$1" sorted
  sorted=$(mktemp)
  LC_ALL=C sort -t'|' -k1,1 -k2,2 -k3,3 "$src" > "$sorted"
  mv "$sorted" "$src"
}

line_count() {
  local f="$1"
  if [ ! -s "$f" ]; then
    echo 0
  else
    wc -l < "$f" | tr -d ' '
  fi
}

show_table_file() {
  local f="$1"
  local i=0 kind project name path size
  while IFS='|' read -r kind project name path size; do
    i=$((i + 1))
    printf "  %3d. [%-7s] %-32s %-16s %s\n" "$i" "$kind" "$project" "$name" "$(format_bytes "$size")"
  done < "$f"
}

sum_bytes_file() {
  awk -F'|' '{ s += $5 } END { print s+0 }' "$1"
}

get_lines_by_indexes() {
  local src="$1" indexes="$2"
  local idx line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    for idx in $indexes; do
      if [ "$n" = "$idx" ]; then
        echo "$line"
      fi
    done
  done < "$src"
}

parse_selection() {
  local input="$1" max="$2"
  local part a b n tmp list out
  out=$(mktemp)
  list=$(echo "$input" | sed 's/,/ /g')
  for part in $list; do
    if echo "$part" | grep -Eq '^[0-9]+$'; then
      n=$part
      if [ "$n" -lt 1 ] || [ "$n" -gt "$max" ]; then
        echo "Index out of range: $n (valid 1-$max)" >&2
        rm -f "$out"
        return 1
      fi
      echo "$n" >> "$out"
    elif echo "$part" | grep -Eq '^[0-9]+-[0-9]+$'; then
      a=$(echo "$part" | cut -d- -f1)
      b=$(echo "$part" | cut -d- -f2)
      if [ "$a" -gt "$b" ]; then tmp=$a; a=$b; b=$tmp; fi
      if [ "$a" -lt 1 ] || [ "$b" -gt "$max" ]; then
        echo "Range out of bounds: $part (valid 1-$max)" >&2
        rm -f "$out"
        return 1
      fi
      n=$a
      while [ "$n" -le "$b" ]; do
        echo "$n" >> "$out"
        n=$((n + 1))
      done
    else
      echo "Invalid token: '$part' (use numbers like 1,3,5-8)" >&2
      rm -f "$out"
      return 1
    fi
  done
  sort -n "$out" | uniq
  rm -f "$out"
}

confirm_delete_lines() {
  local lines_file="$1"
  local count bytes
  count=$(line_count "$lines_file")
  bytes=$(sum_bytes_file "$lines_file")
  echo ""
  echo "About to delete ${count} item(s) (~$(format_bytes "$bytes")):"
  show_table_file "$lines_file"
  echo ""
  printf "Type YES to permanently delete these: "
  read -r answer
  answer=$(trim_cr "$answer")
  [ "$answer" = "YES" ]
}

html_rows_from_file() {
  local f="$1" row_class="$2"
  local kind project name path size ek ep epath esz
  if [ ! -s "$f" ]; then
    echo "<tr class='empty'><td colspan='4'>None</td></tr>"
    return
  fi
  while IFS='|' read -r kind project name path size; do
    ek=$(printf '%s' "$kind" | escape_html)
    ep=$(printf '%s' "$project" | escape_html)
    epath=$(printf '%s' "$path" | escape_html)
    esz=$(printf '%s' "$(format_bytes "$size")" | escape_html)
    printf "<tr class='%s'><td>%s</td><td>%s</td><td>%s</td><td class='size'>%s</td></tr>\n" \
      "$row_class" "$ek" "$ep" "$epath" "$esz"
  done < "$f"
}

write_html_report() {
  local deleted="$1" failed="$2" skipped="$3" freed="$4"
  local deleted_file="$5" failed_file="$6"
  local status status_class when stamp report_dir latest archived
  local deleted_rows failed_rows scan_esc when_esc status_esc freed_esc

  if [ "$failed" -eq 0 ] && [ "$deleted" -gt 0 ]; then
    status="SUCCESS"; status_class="ok"
  elif [ "$failed" -gt 0 ] && [ "$deleted" -gt 0 ]; then
    status="PARTIAL SUCCESS"; status_class="warn"
  elif [ "$failed" -gt 0 ]; then
    status="FAILED"; status_class="bad"
  elif [ "$deleted" -eq 0 ] && [ "$skipped" -gt 0 ]; then
    status="NOTHING TO DELETE"; status_class="muted"
  else
    status="NO CHANGES"; status_class="muted"
  fi

  when=$(date '+%Y-%m-%d %H:%M:%S')
  stamp=$(date '+%Y%m%d-%H%M%S')
  report_dir="$SCRIPT_DIR/reports"
  mkdir -p "$report_dir"
  latest="$SCRIPT_DIR/last-report.html"
  archived="$report_dir/report-$stamp.html"

  deleted_rows=$(html_rows_from_file "$deleted_file" "deleted")
  failed_rows=$(html_rows_from_file "$failed_file" "failed")
  scan_esc=$(printf '%s' "$SCAN_ROOT" | escape_html)
  when_esc=$(printf '%s' "$when" | escape_html)
  status_esc=$(printf '%s' "$status" | escape_html)
  freed_esc=$(printf '%s' "$(format_bytes "$freed")" | escape_html)

  cat > "$latest" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>devsweep report</title>
  <style>
    :root {
      --bg: #f6f7f9; --card: #ffffff; --text: #1c1f24; --muted: #5c6570; --line: #e4e7ec;
      --ok: #0f7a43; --ok-bg: #e8f7ee; --warn: #9a6700; --warn-bg: #fff6e0;
      --bad: #b42318; --bad-bg: #fef3f2;
    }
    * { box-sizing: border-box; }
    body { margin: 0; font-family: system-ui, -apple-system, "Segoe UI", sans-serif; color: var(--text); background: var(--bg); line-height: 1.45; }
    main { max-width: 960px; margin: 0 auto; padding: 2rem 1.25rem 3rem; }
    h1 { margin: 0 0 0.25rem; font-size: 1.6rem; font-weight: 650; }
    .meta { color: var(--muted); margin-bottom: 1.5rem; font-size: 0.95rem; }
    .badge { display: inline-block; padding: 0.35rem 0.7rem; border-radius: 999px; font-size: 0.85rem; font-weight: 650; margin-bottom: 1rem; }
    .badge.ok { color: var(--ok); background: var(--ok-bg); }
    .badge.warn { color: var(--warn); background: var(--warn-bg); }
    .badge.bad { color: var(--bad); background: var(--bad-bg); }
    .badge.muted { color: var(--muted); background: #eef1f4; }
    .stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 0.75rem; margin-bottom: 1.5rem; }
    .stat { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 0.9rem 1rem; }
    .stat .label { color: var(--muted); font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.04em; }
    .stat .value { font-size: 1.25rem; font-weight: 650; margin-top: 0.2rem; }
    section { background: var(--card); border: 1px solid var(--line); border-radius: 10px; padding: 1rem 1rem 0.5rem; margin-bottom: 1rem; }
    section h2 { margin: 0 0 0.75rem; font-size: 1.05rem; }
    table { width: 100%; border-collapse: collapse; font-size: 0.92rem; margin-bottom: 0.75rem; }
    th, td { text-align: left; padding: 0.55rem 0.4rem; border-bottom: 1px solid var(--line); vertical-align: top; }
    th { color: var(--muted); font-weight: 600; font-size: 0.8rem; text-transform: uppercase; letter-spacing: 0.03em; }
    td.size { white-space: nowrap; font-variant-numeric: tabular-nums; }
    tr.failed td { color: var(--bad); }
    tr.empty td { color: var(--muted); font-style: italic; }
    footer { margin-top: 1.5rem; color: var(--muted); font-size: 0.85rem; }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.9em; }
  </style>
</head>
<body>
  <main>
    <h1>devsweep report</h1>
    <p class="meta">
      Generated <strong>${when_esc}</strong><br />
      Scan root: <code>${scan_esc}</code>
    </p>
    <div class="badge ${status_class}">${status_esc}</div>
    <div class="stats">
      <div class="stat"><div class="label">Deleted</div><div class="value">${deleted}</div></div>
      <div class="stat"><div class="label">Failed</div><div class="value">${failed}</div></div>
      <div class="stat"><div class="label">Skipped</div><div class="value">${skipped}</div></div>
      <div class="stat"><div class="label">Space freed</div><div class="value">${freed_esc}</div></div>
    </div>
    <section>
      <h2>Deleted items</h2>
      <table>
        <thead><tr><th>Kind</th><th>Project</th><th>Path</th><th>Size</th></tr></thead>
        <tbody>
${deleted_rows}
        </tbody>
      </table>
    </section>
    <section>
      <h2>Failed items</h2>
      <table>
        <thead><tr><th>Kind</th><th>Project</th><th>Path</th><th>Size</th></tr></thead>
        <tbody>
${failed_rows}
        </tbody>
      </table>
    </section>
    <footer>
      Report files:
      <code>last-report.html</code> (latest) and
      <code>reports/report-${stamp}.html</code>
    </footer>
  </main>
</body>
</html>
EOF

  cp "$latest" "$archived"
  LAST_REPORT="$latest"
  echo "$latest"
}

show_operation_result() {
  local deleted="$1" failed="$2" skipped="$3" freed="$4"
  local deleted_file="$5" failed_file="$6"
  local report_path

  echo ""
  echo "========================================"
  if [ "$failed" -eq 0 ] && [ "$deleted" -gt 0 ]; then
    echo "  RESULT: SUCCESS"
  elif [ "$failed" -gt 0 ] && [ "$deleted" -gt 0 ]; then
    echo "  RESULT: PARTIAL SUCCESS"
  elif [ "$failed" -gt 0 ]; then
    echo "  RESULT: FAILED"
  elif [ "$deleted" -eq 0 ] && [ "$skipped" -gt 0 ]; then
    echo "  RESULT: NOTHING TO DELETE (already gone)"
  else
    echo "  RESULT: NO CHANGES"
  fi
  echo "========================================"
  echo "  Deleted : $deleted"
  echo "  Failed  : $failed"
  echo "  Skipped : $skipped"
  echo "  Freed   : ~$(format_bytes "$freed")"
  echo "========================================"

  if report_path=$(write_html_report "$deleted" "$failed" "$skipped" "$freed" "$deleted_file" "$failed_file"); then
    echo "  HTML report: $report_path"
  else
    echo "  Could not write HTML report"
  fi
  echo "Tip: Flutter -> flutter pub get | Node -> npm/pnpm install | FVM -> fvm install"
}

open_html_report() {
  if [ -z "$LAST_REPORT" ] || [ ! -f "$LAST_REPORT" ]; then
    echo "No report file found yet."
    return 1
  fi
  if command -v open >/dev/null 2>&1; then
    open "$LAST_REPORT"
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$LAST_REPORT" >/dev/null 2>&1 &
  elif command -v sensible-browser >/dev/null 2>&1; then
    sensible-browser "$LAST_REPORT" >/dev/null 2>&1 &
  else
    echo "Open manually: $LAST_REPORT"
    return 0
  fi
  echo "Opened: $LAST_REPORT"
}

# Removes lines from $1; writes deleted/failed into global DELETED_FILE / FAILED_FILE (append mode controlled by caller)
# Sets globals: LAST_DELETED LAST_FAILED LAST_SKIPPED LAST_FREED
remove_target_lines() {
  local lines_file="$1"
  local deleted=0 failed=0 skipped=0 freed=0
  local kind project name path size
  local run_deleted run_failed
  run_deleted=$(mktemp)
  run_failed=$(mktemp)
  : > "$run_deleted"
  : > "$run_failed"

  while IFS='|' read -r kind project name path size; do
    if [ ! -e "$path" ]; then
      echo "  Skip (gone): $path"
      skipped=$((skipped + 1))
      continue
    fi
    if rm -rf "$path" 2>/dev/null; then
      echo "  Deleted: $path"
      deleted=$((deleted + 1))
      freed=$((freed + size))
      printf '%s|%s|%s|%s|%s\n' "$kind" "$project" "$name" "$path" "$size" >> "$run_deleted"
    else
      echo "  FAILED:  $path"
      failed=$((failed + 1))
      printf '%s|%s|%s|%s|%s\n' "$kind" "$project" "$name" "$path" "$size" >> "$run_failed"
    fi
  done < "$lines_file"

  cat "$run_deleted" >> "$DELETED_FILE"
  cat "$run_failed" > "$FAILED_FILE"

  LAST_DELETED=$deleted
  LAST_FAILED=$failed
  LAST_SKIPPED=$skipped
  LAST_FREED=$freed
  LAST_RUN_DELETED_FILE=$run_deleted
  LAST_RUN_FAILED_FILE=$run_failed

  show_operation_result "$deleted" "$failed" "$skipped" "$freed" "$run_deleted" "$run_failed"
  rm -f "$run_deleted" "$run_failed"
}

compute_remaining() {
  # remaining = CURRENT_FILE paths still on disk and not in DELETED_FILE
  local out="$1"
  : > "$out"
  local kind project name path size
  while IFS='|' read -r kind project name path size; do
    if awk -F'|' -v p="$path" '$4 == p { found=1 } END { exit !found }' "$DELETED_FILE" 2>/dev/null; then
      continue
    fi
    if [ -e "$path" ]; then
      printf '%s|%s|%s|%s|%s\n' "$kind" "$project" "$name" "$path" "$size" >> "$out"
    fi
  done < "$CURRENT_FILE"
}

post_action_menu() {
  local remaining choice
  remaining=$(mktemp)

  while true; do
    compute_remaining "$remaining"
    echo ""
    echo "----------------------------------------"
    if [ "$(line_count "$FAILED_FILE")" -gt 0 ]; then
      echo "  [R] Retry $(line_count "$FAILED_FILE") failed item(s)"
    fi
    if [ "$(line_count "$remaining")" -gt 0 ]; then
      echo "  [M] Return to menu ($(line_count "$remaining") item(s) still present)"
    fi
    echo "  [O] Open HTML report in browser"
    echo "  [Q] Quit"
    echo "----------------------------------------"
    printf "Choice: "
    read -r choice
    choice=$(trim_cr "$choice")
    choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')

    case "$choice" in
      Q)
        echo ""
        if [ "${LAST_FAILED:-0}" -eq 0 ] && [ "${LAST_DELETED:-0}" -gt 0 ]; then
          echo "Cleanup finished successfully. Goodbye."
        elif [ "${LAST_FAILED:-0}" -gt 0 ]; then
          echo "Cleanup finished with failures. You can re-run the script to retry."
        else
          echo "Goodbye."
        fi
        if [ -n "$LAST_REPORT" ]; then
          echo "Report saved at: $LAST_REPORT"
        fi
        rm -f "$remaining"
        wait_if_interactive
        return 1
        ;;
      O)
        open_html_report
        ;;
      R)
        if [ "$(line_count "$FAILED_FILE")" -eq 0 ]; then
          echo "No failed items to retry."
          continue
        fi
        echo ""
        echo "Retrying failed items..."
        remove_target_lines "$FAILED_FILE"
        ;;
      M)
        if [ "$(line_count "$remaining")" -eq 0 ]; then
          echo "Nothing left on the list. Use Q to quit."
          continue
        fi
        cp "$remaining" "$CURRENT_FILE"
        sort_targets_file "$CURRENT_FILE"
        rm -f "$remaining"
        return 0
        ;;
      *)
        echo "Unknown choice. Use R, M, O, or Q."
        ;;
    esac
  done
}

interactive_menu() {
  local n choice raw kind indexes sel_file kinds

  while true; do
    n=$(line_count "$CURRENT_FILE")
    if [ "$n" -eq 0 ]; then
      echo ""
      echo "No remaining targets."
      wait_if_interactive
      return 0
    fi

    echo ""
    echo "Current list: $n item(s), ~$(format_bytes "$(sum_bytes_file "$CURRENT_FILE")")"
    echo "----------------------------------------"
    echo "  [A] Delete ALL listed items"
    echo "  [S] Select specific (e.g. 1,3,5-8)"
    echo "  [K] Delete by kind (Flutter / Node / Gradle / FVM / Global)"
    echo "  [L] List targets"
    echo "  [Q] Quit"
    echo "----------------------------------------"
    printf "Choice: "
    read -r choice
    choice=$(trim_cr "$choice")
    choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')

    case "$choice" in
      Q)
        echo ""
        echo "Quit without further deletes. Goodbye."
        wait_if_interactive
        return 0
        ;;
      L|R)
        echo ""
        show_table_file "$CURRENT_FILE"
        ;;
      A)
        if confirm_delete_lines "$CURRENT_FILE"; then
          : > "$DELETED_FILE"
          : > "$FAILED_FILE"
          remove_target_lines "$CURRENT_FILE"
          if ! post_action_menu; then
            return 0
          fi
          echo ""
          echo "Updated list:"
          show_table_file "$CURRENT_FILE"
        else
          echo "Delete cancelled."
        fi
        ;;
      S)
        printf "Enter numbers / ranges: "
        read -r raw
        raw=$(trim_cr "$raw")
        if [ -z "$raw" ]; then
          echo "Nothing selected."
          continue
        fi
        sel_file=$(mktemp)
        if ! indexes=$(parse_selection "$raw" "$n"); then
          rm -f "$sel_file"
          echo "Invalid selection."
          continue
        fi
        if [ -z "$indexes" ]; then
          rm -f "$sel_file"
          echo "Nothing selected."
          continue
        fi
        get_lines_by_indexes "$CURRENT_FILE" "$indexes" > "$sel_file"
        if [ ! -s "$sel_file" ]; then
          rm -f "$sel_file"
          echo "Nothing selected."
          continue
        fi
        if confirm_delete_lines "$sel_file"; then
          : > "$DELETED_FILE"
          : > "$FAILED_FILE"
          remove_target_lines "$sel_file"
          rm -f "$sel_file"
          if ! post_action_menu; then
            return 0
          fi
          echo ""
          echo "Updated list:"
          show_table_file "$CURRENT_FILE"
        else
          rm -f "$sel_file"
          echo "Delete cancelled."
        fi
        ;;
      K)
        kinds=$(awk -F'|' '{print $1}' "$CURRENT_FILE" | sort -u | tr '\n' ' ')
        echo ""
        echo "Available kinds: $kinds"
        printf "Kind to delete: "
        read -r kind
        kind=$(trim_cr "$kind")
        sel_file=$(mktemp)
        awk -F'|' -v k="$kind" '$1 == k' "$CURRENT_FILE" > "$sel_file"
        if [ ! -s "$sel_file" ]; then
          rm -f "$sel_file"
          echo "No items for kind '$kind'."
          continue
        fi
        if confirm_delete_lines "$sel_file"; then
          : > "$DELETED_FILE"
          : > "$FAILED_FILE"
          remove_target_lines "$sel_file"
          rm -f "$sel_file"
          if ! post_action_menu; then
            return 0
          fi
          echo ""
          echo "Updated list:"
          show_table_file "$CURRENT_FILE"
        else
          rm -f "$sel_file"
          echo "Delete cancelled."
        fi
        ;;
      *)
        echo "Unknown choice. Use A, S, K, L, or Q."
        ;;
    esac
  done
}

# --- main ---

ROOT=$(resolve_scan_root)
SCAN_ROOT="$ROOT"
assert_valid_root "$ROOT"

TARGETS_FILE=$(mktemp)
DELETED_FILE=$(mktemp)
FAILED_FILE=$(mktemp)
CURRENT_FILE=$(mktemp)
: > "$TARGETS_FILE"
: > "$DELETED_FILE"
: > "$FAILED_FILE"
: > "$CURRENT_FILE"

echo ""
echo "devsweep"
echo "Root:  $ROOT"
scan_label="Flutter / FVM / Node / Gradle"
if [ "$INCLUDE_GLOBAL" -eq 1 ]; then
  scan_label="$scan_label / Global caches"
fi
echo "Scan:  $scan_label"
if [ "$APPLY" -eq 1 ]; then
  echo "Mode:  non-interactive (--apply)"
else
  echo "Mode:  interactive (dry-run -> choose)"
fi
echo ""
echo "Scanning projects (this can take a few minutes on large folders)..."

collect_project_dirs "$ROOT"
proj_count=$(line_count "$PROJECT_DIRS_FILE")
echo "Found $proj_count project folder(s) to inspect."

i=0
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  i=$((i + 1))
  rel=$(rel_project "$dir" "$ROOT")
  echo "[$i/$proj_count] $rel"
  if is_flutter_project "$dir"; then collect_flutter "$dir" "$rel"; fi
  if has_fvm "$dir"; then collect_fvm "$dir" "$rel"; fi
  if is_android_gradle_project "$dir"; then collect_gradle "$dir" "$rel"; fi
  if is_node_project "$dir"; then collect_node "$dir" "$rel"; fi
done < "$PROJECT_DIRS_FILE"

if [ "$INCLUDE_GLOBAL" -eq 1 ]; then
  echo "Scanning global caches..."
  collect_global
fi

if [ "$(line_count "$TARGETS_FILE")" -eq 0 ]; then
  echo "Nothing to clean."
  wait_if_interactive
  exit 0
fi

sort_targets_file "$TARGETS_FILE"
cp "$TARGETS_FILE" "$CURRENT_FILE"

echo ""
show_table_file "$CURRENT_FILE"
echo ""
echo "Targets: $(line_count "$CURRENT_FILE")  |  Reclaimable: ~$(format_bytes "$(sum_bytes_file "$CURRENT_FILE")")"

if [ "$APPLY" -eq 1 ]; then
  if [ "$FORCE" -eq 0 ]; then
    printf "Delete ALL of the above? Type YES to continue: "
    read -r answer
    answer=$(trim_cr "$answer")
    if [ "$answer" != "YES" ]; then
      echo "Aborted."
      wait_if_interactive
      exit 1
    fi
  fi
  : > "$DELETED_FILE"
  : > "$FAILED_FILE"
  remove_target_lines "$CURRENT_FILE"
  if [ "$FORCE" -eq 0 ] && [ -n "$LAST_REPORT" ]; then
    printf "Open HTML report in browser? Type YES to open: "
    read -r open_ans
    open_ans=$(trim_cr "$open_ans")
    if [ "$open_ans" = "YES" ]; then
      open_html_report
    fi
  fi
  if [ "${LAST_FAILED:-0}" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
    printf "Retry failed items? Type YES to retry: "
    read -r retry
    retry=$(trim_cr "$retry")
    if [ "$retry" = "YES" ] && [ "$(line_count "$FAILED_FILE")" -gt 0 ]; then
      remove_target_lines "$FAILED_FILE"
    fi
  fi
  wait_if_interactive
  if [ "${LAST_FAILED:-0}" -gt 0 ]; then
    exit 1
  fi
  exit 0
fi

interactive_menu

