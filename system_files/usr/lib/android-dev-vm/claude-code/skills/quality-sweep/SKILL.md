---
name: quality-sweep
description: Sweeps the whole Android or Flutter codebase for code-quality problems the diff-based reviews miss (dead code, duplication, layering, test gaps, stale docs) with parallel subagents, verifies each finding, and fixes or reports them. Use after each larger batch of work, before a release, or when asked for a quality review.
---

# Quality sweep

`/simplify` and `/code-review` look at a diff. This looks at the whole
codebase, for problems that build up across changes.

## 1. Baseline

Run the check first. If it fails, fix that before sweeping, so findings
aren't mixed up with a broken build. Read the project's `CLAUDE.md` for its
architecture and rules: findings are measured against those.

## 2. Sweep in parallel

Start one subagent per area, all at once. Ask each for findings as: file and
line, what's wrong, what it costs (a bug it invites, work it wastes, a reader
it misleads), and the fix.

1. **Dead code.** Unused declarations, parameters, resources, strings,
   dependencies, feature flags that are always on or off, and code only tests
   reach.
2. **Duplication.** Logic written twice with small differences, helpers that
   re-implement the platform or an existing dependency, copy-pasted UI.
3. **Structure.** Layering the project's `CLAUDE.md` describes and the code
   breaks (UI calling data sources directly, platform types in pure logic),
   oversized classes and functions, state held in two places, wider
   visibility than needed.
4. **Errors and edge cases.** Swallowed exceptions, errors shown to nobody,
   `!!` and unchecked casts, coroutines or isolates without cancellation,
   work on the main thread, resources never closed.
5. **Tests.** Behavior without tests (compare the features with the test
   names), tests that can't fail, flaky waits (`sleep`, fixed delays), and
   logic that lives where it can't be unit-tested.
6. **Docs.** `CLAUDE.md`, README and comments that no longer match the code,
   and public APIs without the docs the project's rules ask for.

## 3. Verify

Every finding gets a second subagent that tries to refute it: is the code
really unused (reflection, the manifest, generated code), is the duplication
real or only similar, does a test already cover it? Keep only findings that
survive.

## 4. Fix and report

- Fix confirmed findings that don't change behavior, grouped into commits by
  kind, following the review rules.
- Describe, don't make, changes that alter behavior or the architecture.
- Report what was fixed, what wasn't and why, and the areas that need more
  than a sweep (a missing test strategy, for example).
