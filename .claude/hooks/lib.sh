#!/usr/bin/env bash
# Shared helpers for Vocab Claude hooks. Source only.

# Paths whose changes require Auditor approval before commit.
VOCAB_GATED_PATHS='^(Vocab/|VocabIOS/|VocabTests/|Vocab\.xcodeproj/|script/|\.claude/|CLAUDE\.md$|\.gitignore$)'

vocab_root() {
  if [[ -n "${CLAUDE_PROJECT_DIR:-}" ]]; then
    printf '%s\n' "$CLAUDE_PROJECT_DIR"
  else
    git rev-parse --show-toplevel
  fi
}

vocab_audit_dir() {
  printf '%s/claude-audit\n' "$(git -C "$1" rev-parse --absolute-git-dir)"
}

# Paths that differ from HEAD (staged, unstaged or untracked), one per line.
vocab_changed_paths() {
  local root="$1"
  {
    git -C "$root" -c core.quotepath=off diff --name-only HEAD 2>/dev/null \
      || git -C "$root" -c core.quotepath=off diff --name-only --cached
    git -C "$root" -c core.quotepath=off ls-files --others --exclude-standard
  } | LC_ALL=C sort -u
}

# Git tree ID of the complete working tree (tracked + untracked, ignore rules
# applied), built in a scratch index. Independent of HEAD and staging, so an
# approval survives `git add` and splitting the change into several commits,
# but any content, mode or file-set change invalidates it.
vocab_worktree_fingerprint() {
  local root="$1"
  # Start from an empty index: a copied index would inherit racily-clean stat
  # data and could miss a same-size edit made within the same second.
  local scratch_dir status=0
  scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/vocab-fingerprint.XXXXXX")"
  GIT_INDEX_FILE="$scratch_dir/index" git -C "$root" add -A > /dev/null \
    && GIT_INDEX_FILE="$scratch_dir/index" git -C "$root" write-tree || status=$?
  rm -rf "$scratch_dir"
  return "$status"
}
