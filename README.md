# collect_files.sh

A **forensic filesystem scanner** designed to extract *only the files you care about* from very large trees, while **preserving directory structure**, so the result can be **zipped and uploaded for LLM inspection**.

This tool is optimized for:
- large monorepos
- external drives
- mixed-language codebases
- robotics / ML / CV projects
- situations where uploading the full repo is impractical or unsafe

---

## 🎯 Goal

> **Scan a large filesystem, select relevant files by pattern, prune irrelevant subtrees, and produce a minimal, self-contained bundle suitable for LLM analysis.**

The output:
- preserves original relative paths
- contains *only* matched files
- includes a full manifest with timestamps, sizes, and hashes

---

## ✨ Key Features

- 🔍 **Pattern-based file selection**
  - Match by filename substring (case-insensitive)
  - Patterns from file or CLI
- 🚫 **GitHub-style ignore rules**
  - Skip entire subtrees early (`find -prune`)
  - Supports glob patterns like `GSCRAM*`, `build/`, `**/vendor/**`
- 🧭 **Live scan progress**
  - See which file is currently being scanned
  - No “hung” feeling on deep trees
- 🧾 **Forensic manifest**
  - Timestamp, size, SHA256, relative path
- 🗂 **Tree-preserving output**
  - Output mirrors the original directory layout
- 🧪 **Dry-run mode**
  - See exactly what would be collected before copying
- 🧠 **LLM-friendly**
  - Output is intentionally shaped for AI inspection, not humans browsing a repo

---

## 📦 What the Output Looks Like

Default output directory: `./output/`

```
output/
├── MANIFEST.tsv      # full metadata index (timestamps, size, sha256, paths)
├── MATCHES.txt       # list of matched source paths
└── <copied files>    # preserved directory structure from ROOT
```

This directory is **ready to zip and upload**.

---

## 🚀 Basic Usage

```bash
./collect_files.sh -r /path/to/large/tree
```

Defaults:
- output → `./output`
- patterns → `patterns.txt` (if present)
- ignores → `ignore.txt` (if present)

---

## 🧪 Dry Run (Recommended First)

```bash
./collect_files.sh -r /path/to/large/tree -n
```

- No files are copied
- Manifest and match list are still generated
- Safe for experimentation

---

## 🧩 Pattern Selection

### Option A — `patterns.txt` (recommended)

Create a file named `patterns.txt`:

```text
# minimal example
distance
range
depth
```

Then run:

```bash
./collect_files.sh -r /path/to/tree
```

The script will auto-detect `patterns.txt`.

### Option B — Explicit pattern file

```bash
./collect_files.sh -r /path/to/tree -F patterns_minimal.txt
```

### Option C — Inline patterns

```bash
./collect_files.sh -r /path/to/tree -p "distance,range,depth"
```

---

## 🚫 Ignoring Subtrees (GitHub-style)

Create an `ignore.txt` file (auto-detected):

```text
# version control
.git
.git/*

# dependencies
node_modules
build/
dist/
*.venv
miniconda3

# vendor blobs
third_party
3rdparty
opencv*

# project-specific
GSCRAM*
groundspace
```

Supported semantics:
- `foo` → ignore anything containing `foo`
- `foo/` → ignore directory subtree
- `foo*` → glob match
- `**/bar/**` → deep match (find-style)

The scanner **never descends** into ignored subtrees (fast).

---

## 🧭 Live Progress

During scanning you’ll see:

```
Scanning... 18342 src/tracking/targetDistance.cpp
```

This updates in-place (`\r`) and works even on huge trees.

---

## 📁 Output Control

Specify output directory explicitly:

```bash
./collect_files.sh -r /path/to/tree -o ./bundle
```

Default if omitted:
```
./output
```

---

## 📎 Zipping for Upload

From the directory containing `output/`:

```bash
zip -r output.zip output -x "*.DS_Store"
```

Upload `output.zip` directly for LLM inspection.

---

## 🧾 MANIFEST.tsv Format

Each line:

```
human_time  epoch  size_bytes  sha256  relative_path  full_path
```

This enables:
- integrity verification
- reproducibility
- deterministic follow-up requests

---

## 🛠 Advanced Options

| Flag | Description |
|-----|------------|
| `-i` | Interactive confirmation before copying each file |
| `-n` | Dry-run (no copying) |
| `-F` | Explicit pattern file |
| `-I` | Explicit ignore file |
| `-o` | Output directory |

---

## 🧠 Intended Workflow (Recommended)

1. Start with **minimal patterns**
2. Run with `-n`
3. Review `MATCHES.txt`
4. Expand patterns iteratively
5. Generate final `output/`
6. Zip and upload for inspection

This avoids over-collecting and keeps LLM context clean.

---

## 🧩 Why This Exists

LLMs are powerful, but:
- they don’t need your entire filesystem
- large repos exceed context limits
- irrelevant code degrades analysis quality

This tool creates a **focused, structured, auditable slice** of a codebase that an LLM can reason about deeply.

---

## ✅ Summary

**collect_files.sh** is a:
- fast
- conservative
- inspection-oriented
- AI-friendly
filesystem extraction utility.

It is not a search tool.  
It is not a backup tool.  

It is a **precision extractor for AI-assisted code analysis**.

---

