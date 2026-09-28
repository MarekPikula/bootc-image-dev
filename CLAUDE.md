# bootc Android dev VM

A custom bootc image for a KDE desktop VM used for Android development with
Claude Code. Two people run it in GNOME Boxes on Linux hosts. The VM updates
itself from an image that only CI publishes.

PLAN.md holds the roadmap, the decisions made so far and why, and the open
questions. Read it before starting work, and update it when a decision changes.

## Non-negotiables

- **Base image** is `quay.io/fedora/fedora-kinoite:44`, pinned by digest.
  Aurora was rejected for its privilege-escalation paths (see PLAN.md).
- **Accounts:**
  - `admin` (UID 1000) is in `wheel` and used only for administration.
  - `dev` (UID 1500) is used for daily work by the human and by Claude Code.
    It is not in `wheel` and must never be able to gain root.
  - Block every route to root for `dev`: sudo, pkexec, run0, su, and polkit.
    The polkit rule for `dev` is deny-by-default with a short allowlist, so an
    admin prompt never appears in dev's session.
  - Create users with sysusers.d. Don't run `useradd` into the image's
    `/etc/passwd`.
- **Credentials:** no passwords, keys, tokens or other credentials go in the
  image or the qcow2. Passwords are set at first boot by a one-shot tty1 prompt
  that runs before the display manager.
- **Network containment** (the core of the project):
  - An nftables rule (`meta skuid 1500`) lets `dev` connect only over loopback.
    That rule is the enforcement. Proxy environment variables are only for
    convenience.
  - Containment fails closed: if the rule doesn't load, users can't log in.
  - Squid on `127.0.0.1:3128`, using a `dstdomain -n` allowlist and CONNECT to
    port 443 only, is `dev`'s only way out.
  - Keep allowlist entries narrow. Never allow `.google.com` or
    `storage.googleapis.com`.
  - Every change to the allowlist goes through a PR.
- **Updates:** automatic update checks stage a new image and never reboot on
  their own. The `bootc-fetch-apply-updates.service` drop-in runs
  `bootc upgrade` without `--apply`.
- **Claude Code** comes from Anthropic's signed dnf repo and is installed under
  `/usr` at build time. `/etc/claude-code/managed-settings.json` disables
  self-updates and sets the proxy env.
- **Image signing is deferred.** Don't add it without discussing it first.
  PLAN.md has the research (key-based cosign, legacy `.sig` format).

## bootc conventions

- Third-party software goes under `/usr`, for example
  `/usr/lib/android-studio`. Never use `/opt` or `/usr/local`.
- Our executables go in `/usr/libexec/android-dev-vm/`. SELinux labels that
  `bin_t`, while scripts under `/usr/lib` get `lib_t` and run confined as
  `init_t` when systemd starts them.
- Keep our config image-owned in `/usr/lib/android-dev-vm/` and wire it in with
  drop-ins. Write to `/etc` only when a program insists, because `/etc` gets a
  3-way merge and local edits stop updates from applying.
- Create state under `/var` with tmpfiles.d, never by shipping files there.
- Pin every third-party download by version and sha256, and verify it during
  the build.
- The last Containerfile step is `RUN bootc container lint`.

## This environment

- A devcontainer with nested rootless podman, buildah, skopeo, qemu with KVM,
  pre-commit, hadolint, shellcheck, actionlint, `nft-check <file>`,
  `squid -k parse`, `gh` and git.
- Outbound network is meant to be allowlisted. If something is blocked, report
  the domain and why it's needed. Never work around the firewall.
- `.devcontainer/` is read-only. Suggest changes and the user applies them from
  the host.
- bootc-image-builder needs privileges this container doesn't have, so qcow2
  images come from CI. Download one with `gh run download` and boot it here
  with qemu.
- **Never run `git commit` (or amend, rebase or anything else that creates
  commits).** The user reviews and signs every commit. Leave changes
  uncommitted in the working tree and say what's ready.
- Only push branches or open PRs when the user asks, and only for commits the
  user made. The token can't push to `main` or change `.github/workflows/`.
  Keep workflow changes separate from other changes and point them out, so the
  user can commit them separately and push them from the host.

## Before handing changes over for review

1. Run pre-commit on tracked and untracked files with the command at the top
   of `.pre-commit-config.yaml`. `--all-files` skips untracked files, and
   don't `git add` files just to get them checked.
2. Build the image locally with `podman build`, then run
   `tests/image/checks.sh` against it.
3. Run `/simplify`, then `/code-review low`, on the uncommitted changes.
   Apply what's worth fixing and re-run steps 1–2 if anything changed.
4. Keep each change small (one PR's worth) and follow the order in PLAN.md.
5. Say how the change was tested and what still needs the CI VM test, and
   suggest a commit message the user can use.

## Before a PR is pushed or opened

Once the user has committed a patchset and asks to prepare the PR:

1. Run the handoff steps above (lint, build, image checks, `/simplify`,
   `/code-review low`) against the whole branch, then also run
   `/code-review xhigh` on it.
2. Prepare the fixes as fixups for the patchset. Don't create commits: leave
   the fixes uncommitted, grouped by the commit each one belongs to, and give
   the user the matching `git commit --fixup=<sha>` commands (for the files
   of each group) so they can commit, sign and autosquash them.
3. Report findings that weren't fixed, with the reason.
