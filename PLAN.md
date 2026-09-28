# Plan

This is the roadmap for the bootc Android dev VM. CLAUDE.md lists the
constraints that don't change.

- Status: Phase 1 (planning).
- Research checked against upstream docs on 2026-09-28.

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Base image | `quay.io/fedora/fedora-kinoite:44`, pinned by digest in `versions.env` | A real bootc image (`containers.bootc=1`) with no third-party privilege helpers. [Why not Aurora](#why-not-aurora) |
| Repo visibility | Public | Branch-restricted Environments and required checks work on the free plan, VMs pull from GHCR without credentials, and Actions minutes and storage for multi-GB qcow2 artifacts are free. |
| Accounts | `admin` = UID 1000 (`wheel`), `dev` = UID 1500 (`kvm`, not `wheel`), via sysusers.d | This is the approach bootc recommends. Fixed UIDs keep the nftables rule stable. |
| Passwords | One-shot tty1 prompt at first boot, before SDDM | Nothing is baked in, there's no window where accounts have no password, and it works in the Boxes console. |
| polkit | Deny-by-default rule for `dev`, with a short allowlist | Removes every admin prompt from dev's session, so Claude Code can't trigger a password dialog that the human might fill in. |
| Claude Code | RPM from Anthropic's signed dnf repo, installed under `/usr` | Updates arrive with the image, and `dev` can't replace the binary. It needs no extra runtime hosts. |
| Signing | **Deferred** | Keyless identity pinning isn't possible in `policy.json` yet. [Details](#signing-future-pr) |
| Linting | pre-commit: the linters as local hooks that run the sha256-pinned binaries, plus `pre-commit/pre-commit-hooks` pinned by commit | One config for the devcontainer, CI and an optional git hook. pre-commit can't hash-pin PyPI packages, so the hooks' `ruamel.yaml` dependency is pinned by version only. That gap is limited to lint tooling and never reaches the image. |
| DNS exfiltration | Documented in v1, hardened later | [Open questions](#open-questions) |

## Repository layout

```
Containerfile              FROM kinoite@digest; COPY system_files/ /; RUN build_files/build.sh; RUN bootc container lint
versions.env               pinned: base image digest, Android Studio version + sha256, BIB image digest
build_files/
  build.sh                 runs the numbered steps in order
  10-packages.sh           JDK 21, git, unzip, squid, bubblewrap, socat, ...
  20-android-studio.sh     download, sha256 check, unpack to /usr/lib/android-studio
  30-claude-code.sh        dnf repo, GPG fingerprint check, install
  40-services.sh           enable/disable/mask units
system_files/              overlay copied to / (paths below are relative to /)
  usr/lib/sysusers.d/android-dev-vm.conf
  usr/lib/tmpfiles.d/android-dev-vm.conf
  usr/lib/android-dev-vm/
    nftables/dev-egress.nft
    squid/squid.conf
    squid/allowlist.txt
    firstboot/set-passwords.sh
  usr/lib/systemd/system/
    dev-egress-firewall.service
    systemd-user-sessions.service.d/10-dev-egress.conf
    squid.service.d/10-android-dev-vm.conf
    bootc-fetch-apply-updates.service.d/10-stage-only.conf
    android-dev-firstboot.service
  usr/lib/systemd/user-environment-generators/60-dev-proxy
  usr/share/polkit-1/rules.d/00-android-dev.rules
  usr/share/applications/android-studio.desktop
  usr/bin/android-studio             wrapper: seeds IDE proxy settings, then execs studio
  usr/bin/android-dev-denied         lists recent TCP_DENIED domains from the Squid log
  etc/profile.d/dev-proxy.sh
  etc/xdg/kioslaverc
  etc/claude-code/managed-settings.json
.pre-commit-config.yaml    hadolint, shellcheck, actionlint, nft-check, squid -k parse, file hygiene
tests/image/checks.sh      assertions run inside the built image with podman (no VM)
tests/vm/run-vm.sh         boots a qcow2 with qemu/KVM; per-run SSH key via SMBIOS credentials
tests/vm/checks.sh         in-guest assertions, run as root and as dev
.github/workflows/
  _build-test.yml          reusable: lint, build, image checks, qcow2, VM test
  pr.yml                   pull requests
  publish.yml              push to main, weekly schedule, manual dispatch
docs/security-model.md     what is contained, and the residual gaps
docs/allowlist.md          how to change the allowlist
README.md                  for the people running the VM
```

## Design

### Network containment

- **The rule.** `table inet dev_egress` has an `output` hook chain. It accepts
  traffic on `oif "lo"`, and rejects everything else whose socket owner is
  UID 1500. This covers IPv4, IPv6, TCP, UDP and ICMP.
- **Coexisting with firewalld.** The rule lives in its own table and is keyed
  on the numeric UID. A drop in any base chain is final, so firewalld can't
  re-allow dev's traffic. `nftables.service` stays disabled.
- **Failing closed.**
  - `dev-egress-firewall.service` loads the table before `network-pre.target`.
  - `systemd-user-sessions.service` gets `Requires=` and `After=` on that
    service.
  - If the table fails to load, `/run/nologin` stays in place and no non-root
    user can log in.
- **Squid:**
  - Listens on `http_port 127.0.0.1:3128`.
  - `acl allowed dstdomain -n "/usr/lib/android-dev-vm/squid/allowlist.txt"`.
    The `-n` flag skips reverse DNS on IP-literal requests, which an attacker's
    PTR record could otherwise match.
  - CONNECT is allowed only to port 443, then `http_access deny all`, and the
    cache manager is off.
- **Squid logging.**
  - The access log is `/var/log/squid/access.log`.
  - A tmpfiles.d ACL makes it readable by `dev`, so Claude can see which
    domains were denied.
  - `android-dev-denied` summarises them.
- **Starting allowlist:**
  - Anthropic: `.anthropic.com`, `.claude.ai`, `.claude.com`
  - Android: `dl.google.com`, `dl-ssl.google.com`, `maven.google.com`
  - Gradle: `.gradle.org`
  - Maven: `repo.maven.apache.org`, `repo1.maven.org`
  - GitHub: `github.com`, `.githubusercontent.com`
  - Claude Code's own updates need nothing extra, because the binary comes from
    the image.
  - `services.gradle.org` redirects Gradle distributions to `github.com` and
    `release-assets.githubusercontent.com`, which the list already covers.

### Proxy configuration for dev

| Consumer | Mechanism |
|---|---|
| Shells | `/etc/profile.d/dev-proxy.sh` sets upper- and lowercase `HTTP(S)_PROXY` and `NO_PROXY=localhost,127.0.0.1,::1`, only when the UID is 1500. |
| Apps launched by Plasma or systemd --user | A user-environment generator sets the same variables. |
| Gradle daemon and other JVMs | `JAVA_TOOL_OPTIONS` with `-Dhttp(s).proxyHost/Port` and `-Dhttp.nonProxyHosts`. |
| Claude Code | The `env` block in managed settings. This also covers background agents, which don't inherit the login shell. |
| KDE apps | `/etc/xdg/kioslaverc` with `ProxyType=4` (take the proxy from the environment). |
| Android Studio | The wrapper seeds `options/proxy.settings.xml` in the versioned config dir when it's missing, with `STUDIO_VM_OPTIONS` as a fallback. |
| sdkmanager | Uses the proxy from Studio. On the command line, pass `--proxy=http --proxy_host=127.0.0.1 --proxy_port=3128`. |

### Privilege

- **Sudo.** `dev` isn't in `wheel`, and the image checks assert that no
  sudoers entry names `dev` or `ALL` users.
- **polkit.** `00-android-dev.rules` returns `polkit.Result.NO` for any action
  requested by UID 1500, except a small allowlist:
  - `org.freedesktop.login1` power-off and reboot
  - `udisks2` removable-media mount
  - rtkit
  - colord
- **What that rule shuts off.** It covers the Kinoite defaults that grant
  active sessions root-side actions without authentication:
  - NetworkManager `settings.modify.own` and `network-control`
  - flatpak system updates
  - udisks loop-setup
  - pkexec
  - run0
- **Root-side services dev could drive.** avahi, cups/cups-browsed and geoclue
  are masked. PackageKit/Discover and the flatpak system helper are covered by
  the polkit rule. Remaining channels are listed in
  [Open questions](#open-questions).
- **Emulator access.** `dev` is in `kvm` so the Android emulator can use
  `/dev/kvm`. That grants no root.

### Updates

- **Timer.** The stock `bootc-fetch-apply-updates.service` runs
  `bootc upgrade --apply`, which reboots. Our drop-in replaces it with
  `bootc upgrade --quiet`, which stages only. The new image applies at the
  user's next reboot.
- **Rollback.** `bootc rollback` swaps to the previous deployment and discards
  any staged one. The README explains that the next timer run will stage the
  newer image again.
- **Weekly rebuild.** The CI rebuild picks up the current Kinoite 44 digest and
  the latest `claude-code` RPM.
- **Other bumps.** Android Studio and the Fedora major version change through
  PRs that edit `versions.env`.

### CI

- **`pr.yml`** runs pre-commit, builds without pushing, runs
  `bootc container lint` and the image checks, builds the qcow2, and runs the
  VM test.
- **`publish.yml`** (push to `main`, weekly, dispatch):
  - Runs the same build and test, then exports an oci-archive.
  - A `publish` job bound to the `release` Environment (deployment branches:
    `main` only) is the only job with `packages: write`.
  - That job pushes with skopeo and checks that the pushed config digest equals
    the tested one.
  - Tags: `stable` (what VMs track), `44.<yyyymmdd>`, `sha-<git>`.
- **qcow2.** Built with `quay.io/centos-bootc/bootc-image-builder` (pinned by
  digest), run directly with `sudo podman run --privileged` against rootful
  storage.
  - The bootc-image-builder repo is archived (merged into osbuild/image-builder),
    but the container is still the documented tool.
  - We don't use the thin GitHub Action, so there's one less third-party action
    in the pipeline.
  - The qcow2 is uploaded as an artifact.
- **Pinning.** Third-party actions are pinned by commit SHA.

## Build order

Each step is one small PR. Claude prepares the changes uncommitted, and you
review, commit and sign them. ⚙ marks workflow changes, which Claude keeps
separate so you can commit them on their own and push them from the host.

1. **Skeleton.**
   - `Containerfile`, `versions.env`, `.pre-commit-config.yaml`,
     `bootc container lint`.
   - ⚙ `pr.yml`: lint, build (no push), bootc lint.
2. **Accounts and privilege.** sysusers.d/tmpfiles.d, first-boot password
   unit, polkit rule, sudoers assertions, masked services.
3. **Network containment.** nftables table plus the fail-closed unit, Squid
   config, allowlist, log access and helper, proxy environment for `dev`,
   `docs/security-model.md`, and `nft-check` and `squid -k parse` pre-commit
   hooks.
4. **VM test harness.**
   - `tests/vm/*`.
   - ⚙ `_build-test.yml` with the qcow2 build, the `vm-test` job and the
     artifact upload.
   - You then make `vm-test` a required check in a branch ruleset.
5. **Android tooling.** Android Studio (sha256-verified, desktop entry, proxy
   seeding, platform updater disabled), JDK 21, build tools.
6. **Claude Code.** dnf repo with a GPG fingerprint check, managed settings,
   bubblewrap and socat for its optional sandbox.
7. **Updates and publishing.**
   - Stage-only drop-in.
   - ⚙ `publish.yml` with the `release`-bound publish job.
   - You create the `release` Environment first.
8. **Docs.**
   - `README.md`:
     - creating the VM in GNOME Boxes from the qcow2
     - first boot (passwords, their own Claude login)
     - nested virtualization on the host for the emulator
     - updates and rollback
   - `docs/allowlist.md`: edit → PR → CI → staged update → reboot.
9. **Later, each after discussion:** image signing, a DNS filtering resolver,
   narrower GitHub hosts, automated Android Studio bump PRs.

## Testing

| Layer | Where | What |
|---|---|---|
| Static | devcontainer and CI, via pre-commit | hadolint, shellcheck, actionlint, `nft-check`, `squid -k parse`, plus whitespace, YAML/JSON and private-key checks from `pre-commit-hooks`. `nft-check` and `squid -k parse` also run inside the built image, so they match its package versions. |
| Image | `podman run` against the built image | sysusers entries present; no password hashes or `authorized_keys` in shipped `/etc`; no sudoers grant to `dev`; polkit rules parse; `desktop-file-validate`; Android Studio present; `claude --version`; no `--apply` in the update unit; expected units masked. |
| VM | CI (required), or locally on a `gh run download`ed qcow2 | See below. |
| Manual | documented in README | SDK download through the proxy, emulator with nested virtualization, Claude login, first-boot password flow in Boxes. |

VM test assertions:

- **Control.** Root can connect directly, which proves the negative checks
  below actually test something.
- **dev through the proxy.**
  - `https://dl.google.com` and `https://api.anthropic.com` succeed.
  - `https://example.com` gets a 403, and the access log shows it as
    `TCP_DENIED`.
- **dev directly.** Blocked for TCP 443 over IPv4 and IPv6, UDP 53 to a public
  resolver, and ICMP.
- **dev's login environment.** Proxy variables and `JAVA_TOOL_OPTIONS` are set.
- **dev's privileges.**
  - `sudo -n true` fails, and so does `run0 true`.
  - `pkcheck` reports "not authorized" for systemd manage-units,
    NetworkManager settings and flatpak install.
  - `id` doesn't show `wheel`.
- **Updates.** The stage-only drop-in is in effect.

The test harness reaches the guest over SSH without shipping any test users or
keys in the image:

- `run-vm.sh` generates a key for each run.
- It passes `ssh.authorized_keys.root` and `ssh.listen` as SMBIOS type-11 system
  credentials; systemd-ssh-generator (systemd ≥ 256) picks those up.
- The connection goes through a qemu user-net port forward.

## Open questions

Each question has a recommendation.

1. **DNS exfiltration.**
   - `dev` can still resolve any name through systemd-resolved, which runs as a
     system service and forwards queries upstream. That makes DNS a
     low-bandwidth data channel.
   - *Recommendation:* document this in v1. Later, point resolved at a local
     resolver that forwards only allowlisted zones, and give Squid its own
     upstream resolver.
2. **General-purpose upload channels.**
   - `github.com`, `.githubusercontent.com` and the Anthropic API can all carry
     data out.
   - *Recommendation:* narrow `.githubusercontent.com` to `raw.`, `objects.` and
     `release-assets.` once the VM test shows that's enough. Document the rest
     as accepted risk.
3. **Other channels to document.**
   - Boxes clipboard and file sharing (spice-vdagent).
   - Phones attached over USB, via adb.
   - Root-side daemons generally.
   - Emulator guests only get proxied HTTP(S) to allowlisted domains, so Play
     Store and similar won't work.
4. **Claude Code bypass-permissions mode.**
   - *Recommendation:* leave it available, because the VM is the sandbox.
   - Managed settings set `DISABLE_TELEMETRY` and `DISABLE_ERROR_REPORTING`,
     so denied telemetry hosts don't clutter the Squid log.
5. **Trust in the published image until signing lands.**
   - VMs trust whatever reaches the GHCR `stable` tag over TLS: any workflow run
     with `packages: write`, or the owner's credentials.
   - *Recommendation:* keep `packages: write` confined to the `release` job,
     protect `main` with a ruleset, and do signing next.
6. **UIDs.** 1000 for `admin` and 1500 for `dev`, unless you'd prefer others.

## Reference

### Why not Aurora

Aurora adds several things that break the `dev` threat model:

- A polkit policy (`org.ublue.privileged.user.setup`, `allow_any=yes`) lets
  any user run `/usr/bin/ublue-privileged-setup` as root with no password.
  - Among other things, that makes the caller a Tailscale operator.
  - `tailscaled` runs as root and is enabled by default, so its traffic isn't
    matched by the dev UID rule.
- A uupd polkit rule lets any user start the updater.
- Homebrew is chowned to UID 1000.
- input-remapper exposes a root D-Bus service to all users.

Removing all of this and auditing each weekly upstream change costs more than
starting from plain Kinoite.

### Signing (future PR)

- **Keyless doesn't fit.** containers/image's `sigstoreSigned.fulcio` matches
  only `oidcIssuer` and `subjectEmail`, so it can't pin a GitHub workflow URI.
  containers/image#2235 was closed unmerged; container-libs#625
  (`buildSignerURI`) is still open.
- **Realistic design: key-based cosign.** This is also what Universal Blue
  does.
  - The private key is a secret of the `release` Environment, which is limited
    to `main`.
  - The VM pins the public key in `policy.json`, using `default: reject` plus an
    explicit entry for our repository.
  - `registries.d` sets `use-sigstore-attachments: true`.
  - A keyless build-provenance attestation lets humans verify the workflow
    identity.
- **cosign v3.** It must sign with
  `--new-bundle-format=false --use-signing-config=false`. containers/image only
  finds legacy `.sig` tags, and GHCR has no referrers API.
- **The VM must track a signed ref.** The deployment has to track
  `ostree-image-signed:docker://…`: set `enforce-container-sigpolicy` in the
  bootc install config, or run a one-time
  `bootc switch --enforce-container-sigpolicy`. The VM test should assert this.
- **Devcontainer.** Add `cosign` to the devcontainer so it can be verified
  locally.

### Sources

- bootc: <https://bootc.dev/bootc/> (users and groups, filesystem, upgrades,
  `bootc container lint`, `bootc rollback`)
- bootc-image-builder: <https://github.com/osbuild/bootc-image-builder>
  (archived); <https://github.com/osbuild/image-builder>
- containers-policy.json(5):
  <https://github.com/containers/image/blob/main/docs/containers-policy.json.5.md>
- cosign bundle-format issue: <https://github.com/projectbluefin/common/issues/977>
- Universal Blue image template: <https://github.com/ublue-os/image-template>
- Claude Code: <https://code.claude.com/docs/en/setup>,
  <https://code.claude.com/docs/en/network-config>,
  <https://code.claude.com/docs/en/managed-settings>
- Android Studio: <https://developer.android.com/studio>,
  <https://developer.android.com/studio/intro/studio-config>
- systemd-ssh-generator(8):
  <https://www.freedesktop.org/software/systemd/man/latest/systemd-ssh-generator.html>
