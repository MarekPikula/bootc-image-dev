#!/usr/bin/bash
# Links Claude Code's managed instructions and skills into /etc/claude-code,
# the only place it looks for them. They're made here rather than shipped in
# system_files/: there, a file named CLAUDE.md and a .claude/ directory would
# count as this repository's own instructions for Claude Code working on it.
set -euo pipefail

mkdir -p /etc/claude-code/.claude
ln -s ../../usr/lib/android-dev-vm/claude-code/instructions.md /etc/claude-code/CLAUDE.md
ln -s ../../../usr/lib/android-dev-vm/claude-code/skills /etc/claude-code/.claude/skills
