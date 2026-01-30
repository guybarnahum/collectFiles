#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  collect_files.sh -r ROOT_DIR [-o OUT_DIR] [-p "pattern1,pattern2,..."] [-F PATTERN_FILE] [-I IGNORE_FILE] [-i] [-n]

Options:
  -r ROOT_DIR   Root directory to scan (required)
  -o OUT_DIR    Output directory to copy matches into (default: ./output)

  -p PATTERNS   Comma-separated list of patterns (case-insensitive substring match).
               Example: -p "flight_cockpit,rangeSensor,get_range,camUtils,depth"

  -F FILE       Text file with one pattern per line (case-insensitive substring match).
               Blank lines ignored. Lines starting with # are comments.

  -I FILE       Ignore file: one entry per line. Any matching directory name/path segment
               causes its whole subtree to be skipped by the scanner.
               Blank lines ignored. Lines starting with # are comments.
               Examples: .git  node_modules  build  dist  venv  third_party

  -i           Interactive: prompt before copying each file
  -n           Dry-run: do not copy, only print and generate manifest

Notes:
  - Patterns are treated as substrings matched against the BASE filename.
  - Output preserves relative paths rooted at ROOT_DIR.
  - Only matched files are copied (no other files in the same folders).
EOF
}

ROOT=""
OUT=""
PATTERNS=""
INTERACTIVE=0
DRYRUN=0
PATTERN_FILE=""
IGNORE_FILE=""

while getopts ":r:o:p:F:I:in" opt; do
  case "$opt" in
    r) ROOT="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    p) PATTERNS="$OPTARG" ;;
    F) PATTERN_FILE="$OPTARG" ;;
    I) IGNORE_FILE="$OPTARG" ;;
    i) INTERACTIVE=1 ;;
    n) DRYRUN=1 ;;
    *) usage; exit 1 ;;
  esac
done

# Resolve script directory (works on macOS & Linux)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default pattern.txt if not explicitly provided
if [[ -z "${PATTERN_FILE}" ]]; then
  if [[ -f "./patterns.txt" ]]; then
    PATTERN_FILE="./patterns.txt"
  elif [[ -f "${SCRIPT_DIR}/patterns.txt" ]]; then
    PATTERN_FILE="${SCRIPT_DIR}/patterns.txt"
  fi
fi

# Default ignore.txt if not explicitly provided
if [[ -z "${IGNORE_FILE}" ]]; then
  if [[ -f "./ignore.txt" ]]; then
    IGNORE_FILE="./ignore.txt"
  elif [[ -f "${SCRIPT_DIR}/ignore.txt" ]]; then
    IGNORE_FILE="${SCRIPT_DIR}/ignore.txt"
  fi
fi

if [[ -z "${ROOT}" ]]; then
  usage
  exit 1
fi

# Default OUT if not provided
if [[ -z "${OUT}" ]]; then
  OUT="./output"
fi

if [[ -n "${PATTERNS}" && -n "${PATTERN_FILE}" ]]; then
  echo "ERROR: Use either -p or -F, not both." >&2
  exit 1
fi

if [[ ! -d "${ROOT}" ]]; then
  echo "ERROR: ROOT_DIR does not exist or is not a directory: ${ROOT}" >&2
  exit 2
fi

# Ensure output dir exists BEFORE we try to absolutize it
mkdir -p "${OUT}"

# Normalize to absolute paths (works on macOS & Linux)
ROOT="$(cd "$ROOT" && pwd)"
OUT="$(cd "$OUT" && pwd)"

MANIFEST="${OUT}/MANIFEST.tsv"
MATCHLIST="${OUT}/MATCHES.txt"
: > "${MANIFEST}"
: > "${MATCHLIST}"

# Platform stat helpers
stat_line() {
  local f="$1"
  if stat -f "%m" "$f" >/dev/null 2>&1; then
    # macOS/BSD
    local epoch size
    epoch="$(stat -f "%m" "$f")"
    size="$(stat -f "%z" "$f")"
    printf "%s\t%s\t%s\n" "$epoch" "$size" "$f"
  else
    # Linux/GNU
    local epoch size
    epoch="$(stat -c "%Y" "$f")"
    size="$(stat -c "%s" "$f")"
    printf "%s\t%s\t%s\n" "$epoch" "$size" "$f"
  fi
}

epoch_to_date() {
  local epoch="$1"
  if date -r 0 >/dev/null 2>&1; then
    date -r "$epoch" "+%Y-%m-%d %H:%M:%S"
  else
    date -d "@$epoch" "+%Y-%m-%d %H:%M:%S"
  fi
}

sha256_file() {
  local f="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" | awk '{print $1}'
  else
    echo "NO_SHA_TOOL"
  fi
}

# Build ALL_PATTERNS robustly (no unbound arrays on macOS bash 3.2)
ALL_PATTERNS=()

if [[ -n "${PATTERNS}" ]]; then
  # Split comma-separated patterns and append (trim whitespace)
  OLDIFS="$IFS"
  IFS=',' read -r -a _TMP <<< "${PATTERNS}"
  IFS="$OLDIFS"
  for pat in "${_TMP[@]}"; do
    pat="$(echo "$pat" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$pat" ]] && ALL_PATTERNS+=("$pat")
  done
fi

if [[ -n "${PATTERN_FILE}" ]]; then
  if [[ ! -f "${PATTERN_FILE}" ]]; then
    echo "ERROR: Pattern file does not exist: ${PATTERN_FILE}" >&2
    exit 2
  fi
  while IFS= read -r pat || [[ -n "$pat" ]]; do
    pat="$(echo "$pat" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$pat" ]] && continue
    [[ "$pat" == \#* ]] && continue
    ALL_PATTERNS+=("$pat")
  done < "${PATTERN_FILE}"
fi

if [[ ${#ALL_PATTERNS[@]} -eq 0 ]]; then
  echo "ERROR: No patterns provided. Use -F patterns.txt (one per line) or -p \"a,b,c\"." >&2
  exit 1
fi

# Build IGNORE_PATTERNS from ignore file (optional)
IGNORE_PATTERNS=()
if [[ -n "${IGNORE_FILE}" ]]; then
  if [[ ! -f "${IGNORE_FILE}" ]]; then
    echo "ERROR: Ignore file does not exist: ${IGNORE_FILE}" >&2
    exit 2
  fi
  while IFS= read -r ip || [[ -n "$ip" ]]; do
    ip="$(echo "$ip" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$ip" ]] && continue
    [[ "$ip" == \#* ]] && continue
    IGNORE_PATTERNS+=("$ip")
  done < "${IGNORE_FILE}"
fi

echo "ROOT: ${ROOT}"
echo "OUT:  ${OUT}"
echo
echo "Patterns (case-insensitive substring match on base filename):"
for p in "${ALL_PATTERNS[@]}"; do
  echo " - $p"
done
echo

# Precompute lowercase patterns (bash 3.2-safe)
LOWER_PATTERNS=()
for p in "${ALL_PATTERNS[@]}"; do
  LOWER_PATTERNS+=("$(printf "%s" "$p" | tr '[:upper:]' '[:lower:]')")
done

echo "Scanning..."
FOUND=()
_scan_i=0
_last_len=0

# Build find args with optional subtree pruning from IGNORE_PATTERNS
FIND_SCAN_ARGS=( "$ROOT" )
if [[ ${#IGNORE_PATTERNS[@]} -gt 0 ]]; then
  FIND_SCAN_ARGS+=( "(" )
  first_ig=1
  for ig in "${IGNORE_PATTERNS[@]}"; do
    [[ -z "$ig" ]] && continue

    # GitHub-style glob patterns for ignores (e.g., GSCRAM*, build/, **/third_party/**)
    pat="$ig"
    if [[ "$pat" == */ ]]; then
      pat="${pat%/}"
      pat="*/${pat}/*"
    elif [[ "$pat" != *"/"* ]]; then
      pat="*/${pat}*"
    fi

    if [[ $first_ig -eq 0 ]]; then
      FIND_SCAN_ARGS+=( "-o" )
    fi
    FIND_SCAN_ARGS+=( "-path" "$pat" )
    first_ig=0
  done
  FIND_SCAN_ARGS+=( ")" "-prune" "-o" )
fi
FIND_SCAN_ARGS+=( "-type" "f" "-print" )

# Single-pass scan over files with live progress (no pre-count)
while IFS= read -r f; do
  _scan_i=$((_scan_i + 1))

  rel="${f#$ROOT/}"
  msg="Scanning... ${_scan_i} ${rel}"
  pad=""
  if [[ ${#msg} -lt $_last_len ]]; then
    pad="$(printf "%*s" $((_last_len - ${#msg})) "")"
  fi
  printf "\r%s%s" "$msg" "$pad" >&2
  _last_len=${#msg}

  base="$(basename "$f")"
  base_lc="$(printf "%s" "$base" | tr '[:upper:]' '[:lower:]')"

  matched=0
  for lp in "${LOWER_PATTERNS[@]}"; do
    [[ -z "$lp" ]] && continue
    case "$base_lc" in
      *"$lp"*) matched=1; break ;;
    esac
  done

  if [[ $matched -eq 1 ]]; then
    FOUND+=("$f")
  fi
done < <(find "${FIND_SCAN_ARGS[@]}" 2>/dev/null)

# finish progress line
printf "\rScanning... %d (done)%s\n" "$_scan_i" " " >&2

# Keep original behavior: sort results
if [[ ${#FOUND[@]} -gt 0 ]]; then
  FOUND_SORTED=()
  while IFS= read -r line; do
    FOUND_SORTED+=("$line")
  done < <(printf "%s\n" "${FOUND[@]}" | sort)
  FOUND=("${FOUND_SORTED[@]}")
fi

if [[ ${#FOUND[@]} -eq 0 ]]; then
  echo "No matches found."
  echo "Tip: provide additional patterns with -p \"foo,bar\""
  exit 0
fi

echo "Found ${#FOUND[@]} matching files."
echo
echo -e "MODIFIED\t\t\tSIZE(B)\tPATH"
echo "--------------------------------------------------------------------------"

# Copy function: copies only the file, but creates enclosing dirs
copy_one() {
  local src="$1"
  local rel="${src#$ROOT/}"
  local dst="${OUT}/${rel}"
  local dstdir
  dstdir="$(dirname "$dst")"

  if [[ $INTERACTIVE -eq 1 ]]; then
    read -r -p "Copy? $rel (y/N) " ans
    [[ "$ans" != "y" && "$ans" != "Y" ]] && return 0
  fi

  if [[ $DRYRUN -eq 1 ]]; then
    echo "[dry-run] would copy: $src -> $dst"
    return 0
  fi

  mkdir -p "$dstdir"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a "$src" "$dst"
  else
    cp -p "$src" "$dst"
  fi
}

for f in "${FOUND[@]}"; do
  line="$(stat_line "$f")"
  epoch="$(echo "$line" | awk -F'\t' '{print $1}')"
  size="$(echo "$line" | awk -F'\t' '{print $2}')"
  dt="$(epoch_to_date "$epoch")"
  rel="${f#$ROOT/}"
  sha="$(sha256_file "$f")"

  printf "%s\t%s\t%s\n" "$dt" "$size" "$f"
  echo "$f" >> "$MATCHLIST"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$dt" "$epoch" "$size" "$sha" "$rel" "$f" >> "$MANIFEST"
done

echo
echo "Wrote:"
echo " - ${MATCHLIST}"
echo " - ${MANIFEST}"
echo

echo "Copying matched files (enclosing folders only; no siblings)..."
for f in "${FOUND[@]}"; do
  copy_one "$f"
done

echo
echo "Done."
echo "Bundle directory: ${OUT}"
echo "Upload the OUT directory (or zip it) along with MANIFEST.tsv."
