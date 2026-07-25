#!/usr/bin/env bash
# Dev cache cleanup for macOS / Linux.
# Compatible with Bash 3.2+ (macOS /bin/bash).
#
# Run from your projects parent folder (or a single project root):
#
#   chmod +x cleanup-dev-caches/cleanup-dev-caches.sh
#   ./cleanup-dev-caches/cleanup-dev-caches.sh
#   ./cleanup-dev-caches/cleanup-dev-caches.sh --global
#   ./cleanup-dev-caches/cleanup-dev-caches.sh --apply --force
#   ./cleanup-dev-caches/cleanup-dev-caches.sh --root /path/to/projects
#
# See cleanup-dev-caches/README.md

set -u

ROOT="$(pwd)"
APPLY=0
FORCE=0
INCLUDE_GLOBAL=0

usage() {
  cat <<'EOF'
Usage: ./cleanup-dev-caches.sh [options]

  --root <path>   Folder to scan (default: current directory)
  --global        Also list user-level Gradle / Pub / FVM caches
  --apply         Non-interactive: delete all found targets
  --force         With --apply, skip YES confirmation
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
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

ROOT="$(cd "$ROOT" && pwd)"

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
  echo "  ./cleanup-dev-caches/cleanup-dev-caches.sh"
  echo ""
  echo "Current folder: $root"
  exit 1
}

# newline-separated list of project dirs
PROJECT_DIRS_FILE=
TARGETS_FILE=

cleanup_temp() {
  [ -n "${PROJECT_DIRS_FILE:-}" ] && [ -f "$PROJECT_DIRS_FILE" ] && rm -f "$PROJECT_DIRS_FILE"
  [ -n "${TARGETS_FILE:-}" ] && [ -f "$TARGETS_FILE" ] && rm -f "$TARGETS_FILE"
}
trap cleanup_temp EXIT

is_skipped_name() {
  case "$1" in
    .idea|.qodo|.git|.vscode|Screenshots|node_modules|build|.dart_tool|.gradle|.fvm|dist|out|Pods|coverage|.next|.nuxt|.turbo|cleanup-dev-caches)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

collect_project_dirs() {
  local root="$1" child name nest_name nested sub
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
    add_dir "$child"

    for nest_name in packages apps mobile web frontend backend client server admin functions; do
      [ -d "$child/$nest_name" ] || continue
      for nested in "$child/$nest_name"/*; do
        [ -d "$nested" ] || continue
        add_dir "$nested"
      done
    done

    for sub in "$child"/*; do
      [ -d "$sub" ] || continue
      if looks_like_project "$sub"; then
        add_dir "$sub"
      fi
    done
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
  size=$(folder_size_bytes "$path")
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

sort_targets() {
  local sorted
  sorted=$(mktemp)
  LC_ALL=C sort -t'|' -k1,1 -k2,2 -k3,3 "$TARGETS_FILE" > "$sorted"
  mv "$sorted" "$TARGETS_FILE"
}

target_count() {
  if [ ! -s "$TARGETS_FILE" ]; then
    echo 0
  else
    wc -l < "$TARGETS_FILE" | tr -d ' '
  fi
}

show_table() {
  local i=0 kind project name path size
  while IFS='|' read -r kind project name path size; do
    i=$((i + 1))
    printf "  %3d. [%-7s] %-32s %-16s %s\n" "$i" "$kind" "$project" "$name" "$(format_bytes "$size")"
  done < "$TARGETS_FILE"
}

total_bytes() {
  awk -F'|' '{ s += $5 } END { print s+0 }' "$TARGETS_FILE"
}

# Print selected lines by 1-based indexes (space-separated)
get_lines_by_indexes() {
  local indexes="$1"
  local idx line n=0
  while IFS= read -r line; do
    n=$((n + 1))
    for idx in $indexes; do
      if [ "$n" = "$idx" ]; then
        echo "$line"
      fi
    done
  done < "$TARGETS_FILE"
}

sum_lines_bytes() {
  awk -F'|' '{ s += $5 } END { print s+0 }'
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
  count=$(wc -l < "$lines_file" | tr -d ' ')
  bytes=$(sum_lines_bytes < "$lines_file")
  echo ""
  echo "About to delete ${count} item(s) (~$(format_bytes "$bytes")):"
  local kind project name path size
  while IFS='|' read -r kind project name path size; do
    printf "  [%s] %s  %s  %s\n" "$kind" "$project" "$name" "$(format_bytes "$size")"
  done < "$lines_file"
  echo ""
  printf "Type YES to permanently delete these: "
  read -r answer
  [ "$answer" = "YES" ]
}

remove_target_lines() {
  local lines_file="$1"
  local deleted=0 failed=0 freed=0
  local kind project name path size
  local failed_file
  failed_file=$(mktemp)
  : > "$failed_file"

  while IFS='|' read -r kind project name path size; do
    if [ ! -e "$path" ]; then
      echo "  Skip (gone): $path"
      continue
    fi
    if rm -rf "$path" 2>/dev/null; then
      echo "  Deleted: $path"
      deleted=$((deleted + 1))
      freed=$((freed + size))
    else
      echo "  FAILED:  $path"
      failed=$((failed + 1))
      printf '%s|%s|%s|%s|%s\n' "$kind" "$project" "$name" "$path" "$size" >> "$failed_file"
    fi
  done < "$lines_file"

  echo ""
  echo "========================================"
  if [ "$failed" -eq 0 ] && [ "$deleted" -gt 0 ]; then
    echo "  RESULT: SUCCESS"
  elif [ "$failed" -gt 0 ] && [ "$deleted" -gt 0 ]; then
    echo "  RESULT: PARTIAL SUCCESS"
  elif [ "$failed" -gt 0 ]; then
    echo "  RESULT: FAILED"
  else
    echo "  RESULT: NO CHANGES"
  fi
  echo "========================================"
  echo "  Deleted : $deleted"
  echo "  Failed  : $failed"
  echo "  Freed   : ~$(format_bytes "$freed")"
  echo "========================================"
  echo "Tip: Flutter -> flutter pub get | Node -> npm/pnpm install | FVM -> fvm install"

  if [ "$failed" -gt 0 ] && [ -s "$failed_file" ]; then
    echo ""
    printf "Retry failed items? Type YES to retry: "
    read -r answer
    if [ "$answer" = "YES" ]; then
      remove_target_lines "$failed_file"
    fi
  fi

  rm -f "$failed_file"
  echo ""
  printf "Press Enter to close: "
  read -r _
}

filter_by_kind() {
  local kind="$1" out="$2"
  awk -F'|' -v k="$kind" 'BEGIN{IGNORECASE=1} $1 == k' "$TARGETS_FILE" > "$out"
}

# awk IGNORECASE may not work on all awks for == ; use exact match from menu
filter_by_kind_exact() {
  local kind="$1" out="$2"
  awk -F'|' -v k="$kind" '$1 == k' "$TARGETS_FILE" > "$out"
}

interactive_menu() {
  local n choice raw kind indexes sel_file kinds
  n=$(target_count)

  while true; do
    echo ""
    echo "────────────────────────────────────────"
    echo "  [A] Delete ALL listed items"
    echo "  [S] Select specific (e.g. 1,3,5-8)"
    echo "  [K] Delete by kind (Flutter / Node / Gradle / FVM / Global)"
    echo "  [R] Reshow list"
    echo "  [Q] Quit without deleting"
    echo "────────────────────────────────────────"
    printf "Choice: "
    read -r choice
    choice=$(echo "$choice" | tr '[:lower:]' '[:upper:]')

    case "$choice" in
      Q)
        echo "Aborted."
        return 0
        ;;
      R)
        echo ""
        show_table
        ;;
      A)
        if confirm_delete_lines "$TARGETS_FILE"; then
          remove_target_lines "$TARGETS_FILE"
        else
          echo "Aborted."
        fi
        return 0
        ;;
      S)
        printf "Enter numbers / ranges: "
        read -r raw
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
        get_lines_by_indexes "$indexes" > "$sel_file"
        if [ ! -s "$sel_file" ]; then
          rm -f "$sel_file"
          echo "Nothing selected."
          continue
        fi
        if confirm_delete_lines "$sel_file"; then
          remove_target_lines "$sel_file"
          rm -f "$sel_file"
          return 0
        fi
        rm -f "$sel_file"
        echo "Aborted."
        return 0
        ;;
      K)
        kinds=$(awk -F'|' '{print $1}' "$TARGETS_FILE" | sort -u | tr '\n' ' ')
        echo ""
        echo "Available kinds: $kinds"
        printf "Kind to delete: "
        read -r kind
        sel_file=$(mktemp)
        filter_by_kind_exact "$kind" "$sel_file"
        if [ ! -s "$sel_file" ]; then
          rm -f "$sel_file"
          echo "No items for kind '$kind'."
          continue
        fi
        if confirm_delete_lines "$sel_file"; then
          remove_target_lines "$sel_file"
          rm -f "$sel_file"
          return 0
        fi
        rm -f "$sel_file"
        echo "Aborted."
        return 0
        ;;
      *)
        echo "Unknown choice. Use A, S, K, R, or Q."
        ;;
    esac
  done
}

# --- main ---

assert_valid_root "$ROOT"
TARGETS_FILE=$(mktemp)
: > "$TARGETS_FILE"

echo ""
echo "Dev cache cleanup"
echo "Root:  $ROOT"
scan_label="Flutter · FVM · Node · Gradle"
if [ "$INCLUDE_GLOBAL" -eq 1 ]; then
  scan_label="$scan_label · Global caches"
fi
echo "Scan:  $scan_label"
if [ "$APPLY" -eq 1 ]; then
  echo "Mode:  non-interactive (--apply)"
else
  echo "Mode:  interactive (dry-run → choose)"
fi
echo ""
echo "Scanning (sizes may take a minute)..."

collect_project_dirs "$ROOT"

while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  rel=$(rel_project "$dir" "$ROOT")
  if is_flutter_project "$dir"; then collect_flutter "$dir" "$rel"; fi
  if has_fvm "$dir"; then collect_fvm "$dir" "$rel"; fi
  if is_android_gradle_project "$dir"; then collect_gradle "$dir" "$rel"; fi
  if is_node_project "$dir"; then collect_node "$dir" "$rel"; fi
done < "$PROJECT_DIRS_FILE"

if [ "$INCLUDE_GLOBAL" -eq 1 ]; then
  collect_global
fi

if [ "$(target_count)" -eq 0 ]; then
  echo "Nothing to clean."
  exit 0
fi

sort_targets

echo ""
show_table
echo ""
echo "Targets: $(target_count)  |  Reclaimable: ~$(format_bytes "$(total_bytes)")"

if [ "$APPLY" -eq 1 ]; then
  if [ "$FORCE" -eq 0 ]; then
    printf "Delete ALL of the above? Type YES to continue: "
    read -r answer
    if [ "$answer" != "YES" ]; then
      echo "Aborted."
      exit 1
    fi
  fi
  remove_target_lines "$TARGETS_FILE"
  exit 0
fi

interactive_menu
