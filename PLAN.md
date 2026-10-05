# Plan

This is the roadmap for the bootc Android dev VM. CLAUDE.md lists the
constraints that don't change.

- Status: PRs 1–4 and the bootc-install qcow2 build merged, PR 5 (Android
  tooling) in review.
- Research checked against upstream docs on 2026-09-28.

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Base image | The rolling `quay.io/fedora/fedora-kinoite:44` tag, set in `versions.env` | A real bootc image (`containers.bootc=1`) with no third-party privilege helpers. [Why not Aurora](#why-not-aurora). A digest pin broke within two days because Fedora deletes superseded manifests. `quay.io/fedora-ostree-desktops/kinoite` keeps dated tags, but only for about four weeks. Each image records the base digest it was built from in its `org.opencontainers.image.base.*` annotations. |
| Repo visibility | Public | Branch-restricted Environments and required checks work on the free plan, VMs pull from GHCR without credentials, and Actions minutes and storage for multi-GB qcow2 artifacts are free. |
| Accounts | `admin` = UID 1000 (`wheel`), `dev` = UID 1500 (no extra groups), via sysusers.d | This is the approach bootc recommends. Fixed UIDs keep the nftables rule stable. |
| Passwords | One-shot tty1 prompt at first boot, before the display manager (Plasma Login Manager on Kinoite 44) | Nothing is baked in, there's no window where accounts have no password, and it works in the Boxes console. |
| polkit | Deny-by-default rule for `dev`, with a short allowlist | Removes every admin prompt from dev's session, so Claude Code can't trigger a password dialog that the human might fill in. |
| Claude Code | RPM from Anthropic's signed dnf repo, installed under `/usr` | Updates arrive with the image, and `dev` can't replace the binary. It needs no extra runtime hosts. |
| Signing | **Deferred** | Keyless identity pinning isn't possible in `policy.json` yet. [Details](#signing-future-pr) |
| Linting | pre-commit: the linters as local hooks that run the sha256-pinned binaries, plus `pre-commit/pre-commit-hooks` pinned by commit | One config for the devcontainer, CI and an optional git hook. pre-commit can't hash-pin PyPI packages, so the hooks' `ruamel.yaml` dependency is pinned by version only. That gap is limited to lint tooling and never reaches the image. |
| DNS exfiltration | Documented in v1, hardened later | [Open questions](#open-questions) |

## Repository layout

```
Containerfile              FROM kinoite:44; RUN android-studio.sh; RUN packages.sh; COPY system_files/ /; RUN build.sh; RUN bootc container lint
versions.env               build inputs: base image tag, Android Studio URL + sha256
build_files/
  packages.sh              every package install, in one layer before COPY system_files/
                           (see the Containerfile): squid, JDK 25, git, later Claude Code, ...
  android-studio.sh        download, sha256 check, unpack to /usr/lib/android-studio, updates
                           off. Its own RUN, see the Containerfile
  build.sh                 runs the numbered steps in order
  15-su.sh                 su for wheel only (pam_wheel requisite)
  30-claude-code.sh        managed settings (the RPM itself is installed by packages.sh)
  40-services.sh           enable (symlinks in /usr) and mask units
  50-caps.sh               drops file capabilities that could undo the network rule
system_files/              overlay copied to / (paths below are relative to /)
  usr/lib/sysusers.d/android-dev-vm.conf
  usr/lib/tmpfiles.d/android-dev-vm.conf
  usr/lib/android-dev-vm/
    nftables/dev-egress.nft
    proxy.env              dev's proxy variables, read by the generator and profile.d
    squid/squid.conf
    squid/allowlist.txt
  usr/libexec/android-dev-vm/
    set-passwords          first-boot prompt (bin_t, so it may run passwd)
  usr/lib/systemd/system/
    dev-egress-firewall.service
    systemd-user-sessions.service.d/10-dev-egress.conf
    squid.service.d/10-android-dev-vm.conf
    bootc-fetch-apply-updates.service.d/10-stage-only.conf
    android-dev-firstboot.service
    multi-user.target.wants/android-dev-firstboot.service   image-owned enablement
    systemd-sysusers.service.d/50-android-dev-vm.conf       imports admin/dev password credentials
  usr/lib/bootc/kargs.d/10-console.toml   serial console too, for headless logs
  usr/lib/bootc/install/50-android-dev-vm.toml   bootc install defaults (btrfs root)
  usr/lib/systemd/user-environment-generators/60-dev-proxy
  usr/share/polkit-1/rules.d/00-android-dev.rules
  usr/share/applications/android-studio.desktop
  usr/bin/android-studio             symlink to /usr/lib/android-studio/bin/studio
  usr/bin/android-dev-denied         lists recent TCP_DENIED domains from the Squid log
  etc/profile.d/dev-proxy.sh
  etc/xdg/kioslaverc
  usr/lib/android-dev-vm/firefox/policies.json   Firefox policy: background services off
  etc/firefox/policies/policies.json             symlink to it, where Firefox looks first
  etc/claude-code/managed-settings.json
  etc/security/pwquality.conf.d/50-android-dev-vm.conf    enforce_for_root
.pre-commit-config.yaml    hadolint, shellcheck, actionlint, file hygiene
disk/build-qcow2.sh        builds the qcow2 (bootc install to-disk, from the image itself), root and CI only
tests/lib.sh               check/indent/finish helpers shared by image and VM checks
tests/image/checks.sh      assertions run inside the built image with podman (no VM)
tests/image/polkit.sh      runs polkitd in the image and checks dev against every registered action
tests/image/firstboot.sh   drives the first-boot prompt with typed input in a throwaway container
tests/image/privileged-files.txt   reviewed setuid/setgid files and file capabilities
tests/vm/run-vm.sh         boots a qcow2 with qemu/KVM (UEFI), per-run SSH key via SMBIOS credentials
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
  traffic on `oif "lo"`, and stops everything else whose socket owner is
  UID 1500. This covers IPv4, IPv6, TCP, UDP, ICMP and raw IP sockets.
  Packet sockets (AF_PACKET) bypass the inet hooks, which is why no binary
  dev can run keeps `cap_net_raw` for them (see Privileged files).
  - TCP gets a reset, so `connect()` fails at once with "Connection refused".
    A dropped SYN only fails `connect()` after the kernel's retries time out,
    and programs would hang for minutes.
  - Everything else is dropped. UDP sends then fail at once with EPERM.
  - Squid runs as `squid`, so its own connections aren't matched.
  - It assumes dev has no subordinate UIDs or GIDs, which the image checks
    assert. With a range, dev could run processes under other UIDs
    (`podman unshare`, `podman run --user`) that the rule wouldn't match.
    Rootless containers for dev would need the rule widened to dev's range
    first.
- **Coexisting with firewalld.** The rule lives in its own table and is keyed
  on the numeric UID. A drop in any base chain is final, so firewalld can't
  re-allow dev's traffic. `nftables.service` stays disabled.
- **Failing closed.**
  - `dev-egress-firewall.service` loads the table before `network-pre.target`.
  - `systemd-user-sessions.service` gets `Requires=` and `After=` on that
    service.
  - If the table fails to load, `/run/nologin` stays in place and no non-root
    user can log in. pam_nologin is in the `account` stack of plasmalogin,
    `login` and `sshd`, which the image checks assert.
  - Stopping the unit leaves the rule loaded, but stops
    `systemd-user-sessions.service` too, which puts `/run/nologin` back.
  - Checked in a VM with the unit masked: no table, `systemd-user-sessions`
    never starts, and dev's SSH login gets pam_nologin's message. The system
    still reports `running`, because a dependency failure marks no unit as
    failed. admin is locked out too, so the way back is the previous
    deployment in the boot menu.
  - Both units are enabled by symlinks in `/usr`, like the first-boot unit.
- **Squid:**
  - Listens on `http_port 127.0.0.1:3128`.
  - `acl allowed dstdomain -n "/usr/lib/android-dev-vm/squid/allowlist.txt"`.
    The `-n` flag skips reverse DNS on IP-literal requests, which an attacker's
    PTR record could otherwise match.
  - Only CONNECT to port 443, then `http_access deny all`, which also closes
    the cache manager. No plain HTTP, which anyone on the path could read or
    tamper with.
  - Nothing is cached, and `forwarded_for delete` keeps the client address
    out of requests.
  - A `squid.service` drop-in replaces `ExecStart` to use our config, because
    Fedora's unit takes the path from `/etc/sysconfig/squid`.
  - The image checks run `squid -k parse` in the image and fail on any
    warning, since Squid only warns about ignored lines.
- **Squid logging.**
  - The access log is `/var/log/squid/access.log`.
  - A tmpfiles.d ACL on `/var/log/squid`, with a default entry for files
    Squid creates later, makes it readable by `dev`, so Claude can see which
    domains were denied.
  - `android-dev-denied` summarises them.
- **Allowlist.** `squid/allowlist.txt` is the list, with a comment per group:
  Claude, the Android SDK and Google's Maven repository, Android Studio
  (Google's download CDN, developer.android.com, JetBrains' plugin
  marketplace), Gradle and its toolchain resolver, Maven Central and JitPack,
  GitHub, Google's static files and fonts for docs pages, and Firefox's
  remote settings and add-ons.
  - `.gvt1.com` is the broadest entry: Google's download CDN serves far more
    than Android tooling, but only downloads.
  - Claude Code's own updates need nothing extra, because the binary comes
    from the image.
  - Gradle distributions and toolchain JDKs come from GitHub.
  - `resources.jetbrains.com` is there because Studio asked for it in one
    longer run in a container, though not in the VM.
  - A Firefox policy switches off what would only be refused: updates (they
    come with the image), telemetry, studies, sponsored content, DNS over
    HTTPS, DRM and codec downloads, push, location, and the new-tab page with
    its remote content (the new tab and the home page are blank). It also
    turns on tracking protection in all windows, which dev can change.
    - The file is `/usr/lib/android-dev-vm/firefox/policies.json`, linked
      from `/etc/firefox/policies/`. Firefox looks there first, whatever
      Fedora's per-user-policy setting says, and wherever Firefox is
      installed.
    - Normandy (Mozilla's remote configuration) has no policy switch, so its
      two hosts are allowed.
    - The image checks assert that this Firefox knows every policy key.
      `Preferences` entries aren't covered.
    - Codec downloads being off means no OpenH264, so some H.264 video won't
      play.
  - Checked in a VM, each with a fresh profile and no direct attempt:
    - Studio for 7 minutes (SDK lists, marketplace, docs index). Squid
      refused only its plain-HTTP connectivity check (open question 7).
    - A Gradle build that downloads a JDK 17 toolchain. Nothing refused.
    - Firefox for 4 minutes on developer.android.com. Squid refused one
      request to Mozilla's suggestion service (`merino.services.mozilla.com`)
      and the page's third-party content: analytics
      (`www.googletagmanager.com`) and Google's sign-in widget
      (`apis.google.com`).

### Proxy configuration for dev

| Consumer | Mechanism |
|---|---|
| Shells | `/etc/profile.d/dev-proxy.sh` sets upper- and lowercase `HTTP(S)_PROXY` and `NO_PROXY=localhost,127.0.0.1,::1`, only when the UID is 1500. |
| Apps launched by Plasma or systemd --user | A user-environment generator sets the same variables. |
| Gradle daemon and other JVMs | `JAVA_TOOL_OPTIONS` with `-Dhttp(s).proxyHost/Port` and `-Dhttp.nonProxyHosts`. |
| Claude Code | The `env` block in managed settings. This also covers background agents, which don't inherit the login shell. |
| KDE apps | `/etc/xdg/kioslaverc` with `ProxyType=4` (take the proxy from the environment). |
| Firefox | Nothing extra: its default "use system proxy settings" picks up the variables (checked in a VM). |
| Android Studio | Nothing extra: its runtime picks up `JAVA_TOOL_OPTIONS`, and its IDE settings default to auto-detect (the VM test checks it). |
| sdkmanager | Uses the proxy from Studio. On the command line it's a JVM too, so probably `JAVA_TOOL_OPTIONS` (not checked). Otherwise pass `--proxy=http --proxy_host=127.0.0.1 --proxy_port=3128`. |

### Privilege

- **Accounts.** sysusers.d creates `admin` (1000, `wheel`) and `dev` (1500, no
  extra groups), both locked.
  - Homes (`/var/home/<user>`, from `/etc/skel`) are created by the first-boot
    unit with `mkhomedir_helper`.
- **First boot.** `android-dev-firstboot.service` runs on tty1 before the
  display manager and asks for both passwords.
  - Each password is typed twice, and dev's must differ from admin's. It's set
    with `passwd --stdin`, so pwquality still applies, and `enforce_for_root`
    makes it reject weak passwords instead of only warning.
  - `passwd --stdin` exits 0 even when PAM rejects the password
    (shadow-utils 4.19), so the script checks shadow for a hash instead.
  - After 5 failed attempts per account it gives up. It ignores Ctrl+C, logs
    failures to the journal, and marks itself done only on success, so the
    next boot asks again. Until then the login screen appears, but nobody can
    log in.
  - `systemd-mute-console` keeps kernel and systemd status messages off the
    prompt while it runs.
  - The script lives in `/usr/libexec` so SELinux labels it `bin_t` and it may
    run `passwd`. Under `/usr/lib` it would be `lib_t`, run as `init_t`, and
    fail. The homes it creates with `mkhomedir_helper` get `restorecon`.
  - The unit is pulled in by a `multi-user.target.wants` symlink in `/usr`, so
    neither `systemctl disable` nor a preset reset turns it off.
  - A password that's already set is skipped. Fedora's `systemd-sysusers`
    imports password credentials for root only, so a drop-in adds
    `passwd.hashed-password.<user>` and `passwd.plaintext-password.<user>` for
    admin and dev. That makes a headless boot possible.
  - `tests/image/firstboot.sh` drives the prompt with typed input in a
    throwaway container, including the rejection paths and the give-up path.
- **KDE's own first-boot flow is off.** Kinoite's `plasma-setup.service`
  (autologin plus a wizard that creates an admin user) is masked.
  `systemd-firstboot` still asks for locale, keymap and timezone, so the
  passwords are typed with the right layout. It skips its root-password
  prompt because root already has a locked shadow entry (`*`), which the image
  checks assert. Root stays locked.
- **Sudo.** `dev` isn't in `wheel`. The image checks assert that
  `sudo -l -U dev` grants nothing.
- **su.** `pam_wheel.so use_uid` is `requisite` in `/etc/pam.d/su`, so non-wheel
  users are refused before any password prompt.
- **polkit.** `00-android-dev.rules` returns `NO` for every action dev asks for,
  except these, and only from dev's active local session (as upstream's
  `allow_active`, but `NO` instead of an admin prompt everywhere else):
  - login1 power-off, reboot, suspend and set-wall-message (implied by
    power-off and reboot)
  - login1 inhibitors
  - RealtimeKit (audio)
  - udisks2 removable-media mount and eject

  It sorts first, ahead of Kinoite's `empower.rules`, which grants everything
  to the `empower` group. `tests/image/polkit.sh` runs polkitd in the image and
  checks dev against every registered action. Its subjects have no login
  session, like a background service, so every answer must be `NO`. The
  allowlist's `YES` needs a real desktop session and is a manual check.
  Without the rule,
  dev would get silent `YES` for systemd's mount and namespace helpers, and
  admin prompts (`CHALLENGE`) for rpm-ostree, firewalld and more.
- **Root-side services dev could drive.** avahi, cups/cups-browsed and geoclue
  are masked. NetworkManager, the flatpak system helper and rpm-ostree are
  covered by the polkit rule. `usermode` (the setuid `userhelper`, which asks
  for root's password) is removed.
  Remaining channels are listed in [Open questions](#open-questions).
- **Privileged files.** `tests/image/privileged-files.txt` lists the reviewed
  setuid/setgid files and file capabilities, and the image checks fail on any
  difference. `mtr-packet` and `clockdiff` keep `cap_net_raw` for raw IP
  sockets, which are still owned by dev and matched by the rule (the VM test
  covers ICMP). `50-caps.sh` removes the capabilities that get around the
  rule, from helpers nothing here needs:
  - `gst-ptp-helper` (`cap_net_admin`, enough to delete the nftables rule).
  - `arping` and `ksgrd_network_helper` (`cap_net_raw` for packet sockets,
    which bypass the inet hooks. arping sends frames of the caller's
    choosing onto the VM's network).
- **Emulator access.** Fedora's udev rules make `/dev/kvm` mode 0666, so `dev`
  needs no `kvm` membership (the image checks assert the rule). Membership
  would also be a trap: Kinoite keeps `kvm` only in `/usr/lib/group`
  (nss-altfiles), where sysusers' `m dev kvm` silently does nothing.

### Updates

- **Timer.** The stock `bootc-fetch-apply-updates.service` runs
  `bootc upgrade --apply`, which reboots. Our drop-in replaces it with
  `bootc upgrade --quiet`, which stages only. The new image applies at the
  user's next reboot.
- **Rollback.** `bootc rollback` swaps to the previous deployment and discards
  any staged one. The README explains that the next timer run will stage the
  newer image again.
- **Weekly rebuild.** The CI rebuild picks up the current Kinoite 44 image and
  the latest `claude-code` RPM.
- **Other bumps.** Android Studio and the Fedora major version change through
  PRs that edit `versions.env`.

### CI

- **`_build-test.yml`** (reusable) has two jobs:
  - `lint`: pre-commit in a Fedora 44 container.
  - `build`: builds the image in rootful podman, runs `bootc container lint`
    and the image checks, builds the qcow2, boots it with
    `tests/vm/run-vm.sh`, and uploads the console log and journal as
    `vm-logs` and the qcow2 as `android-dev-vm-qcow2` (zstd-compressed, kept
    14 days, also when the VM test fails).
  - The VM test runs in the build job so the qcow2 (5.3 GB with Android
    Studio) doesn't go through artifact storage between jobs (that took about
    4.5 minutes per run when it was 3.8 GB).
- **`pr.yml`** calls it as job `ci`, so the checks are `ci / lint` and
  `ci / build`. Both are required.
- **`publish.yml`** (push to `main`, weekly, dispatch):
  - Runs the same build and test, then exports an oci-archive.
  - A `publish` job bound to the `release` Environment (deployment branches:
    `main` only) is the only job with `packages: write`.
  - That job pushes with skopeo and checks that the pushed config digest equals
    the tested one.
  - Tags: `stable` (what VMs track), `44.<yyyymmdd>`, `sha-<git>`.
- **qcow2.** `disk/build-qcow2.sh` runs the image itself in
  `sudo podman run --privileged` against rootful storage, and its bootc
  installs it into a sparse 64 GiB raw file
  (`bootc install to-disk --via-loopback --generic-image`, every bootloader
  for BIOS and UEFI). One `qemu-img convert` then makes the zstd-compressed
  qcow2.
  - The root filesystem is btrfs, because Kinoite names no default. The image
    sets it in `/usr/lib/bootc/install/50-android-dev-vm.toml`, so every
    install path uses it.
  - `--target-imgref` sets what the installed system tracks for updates. CI
    tags the image `ghcr.io/marekpikula/bootc-image-dev:stable` and builds
    from that name, so a downloaded qcow2 updates from GHCR once publishing
    exists.
  - It replaced bootc-image-builder (archived): the same bootc install, about
    3 minutes faster, and one less pinned third-party image.
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
2. **Accounts and privilege.** sysusers.d, first-boot password
   unit, polkit rule, sudoers assertions, masked services.
3. **VM test harness.**
   - `disk/` (qcow2 build), `tests/vm/*`, `tests/lib.sh`, serial console in
     `kargs.d`.
   - ⚙ `_build-test.yml` with the qcow2 build, the `vm-test` job and the
     artifact upload. `pr.yml` calls it.
   - You then make the checks required in a branch ruleset. Since PR 4 the
     VM test runs in `ci / build`, so those are `ci / lint` and `ci / build`.
   - Moved ahead of network containment so every later PR gets tested in a
     real VM from the start.
4. **Network containment.** nftables table plus the fail-closed unit, Squid
   config, allowlist, log access and helper, proxy environment for `dev`,
   `docs/security-model.md`. The nft rule and Squid config are validated in
   the image checks, with the image's own versions, instead of pre-commit
   hooks (`nft -c` needs `CAP_NET_ADMIN`, which the lint container lacks).
   Its VM assertions go into `tests/vm/checks.sh`. Package installs moved to
   their own layer ahead of `system_files/`.
5. **Android tooling.** Android Studio (sha256-verified, desktop entry,
   platform updater disabled), JDK 25 (Fedora 44 has no older one, and
   Studio's runtime is 25 too), git.
   Also remove `vpnc`, `usermode` and `open-vm-tools-desktop`: nothing needs
   them in a QEMU VM, and they bring the setuid `userhelper` and
   `vmware-user-suid-wrapper`.
6. **Claude Code.** dnf repo with a GPG fingerprint check, installed from
   `packages.sh` so every package shares one layer, managed settings,
   bubblewrap and socat for its optional sandbox.
7. **Updates and publishing.**
   - Stage-only drop-in.
   - A reproducible Android Studio layer, so a `bootc upgrade` doesn't fetch
     Studio again (about 1.6 GB) when only the base changed: unpack it in its
     own stage, `COPY --from` it, and build with `--timestamp` so the layer's
     digest stays the same. Check with two builds.
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
| Static | devcontainer and CI, via pre-commit | hadolint, shellcheck, actionlint, plus whitespace, YAML/JSON and private-key checks from `pre-commit-hooks`. |
| Image | `podman run` against the built image, after `systemd-sysusers` | Accounts, UIDs and groups. No password hashes, `authorized_keys` or SSH host keys. No sudo for `dev`, and `su` is wheel-only. polkit: our rule sorts first, and dev gets `NO` for every registered action outside its allowlist. setuid/setgid files and capabilities match the reviewed list. `/dev/kvm` is world-accessible. The first-boot unit is enabled, root is locked (so there's no root-password prompt), and the expected units are masked. Network: the nft rule and Squid config parse with the image's own `nft` and `squid` (no Squid warnings), the allowlist has no forbidden entries, the rule and Squid are enabled from `/usr`, user sessions require the rule, pam_nologin guards the login stacks, and dev (not admin) gets the proxy environment. Android Studio: the launcher, a valid desktop entry and platform updates off. JDK 25. Later: `claude --version`, no `--apply` in the update unit. |
| VM | CI (required), or locally on a `gh run download`ed qcow2 | See below. |
| Manual | documented in README | SDK download through the proxy, emulator with nested virtualization, Claude login, first-boot password flow in Boxes, and in dev's desktop session: power off, reboot and mount a USB stick without any password prompt. |

VM test assertions (`tests/vm/checks.sh`):

- **Accounts and privilege.**
  - Boot finishes with no failed units, SELinux is enforcing, the `kargs.d`
    console arguments are applied, and bootc tracks the GHCR image.
  - `android-dev-firstboot.service` ran and succeeded, sysusers created the
    accounts, both passwords were set from credentials, and the homes exist,
    are private and are labelled `user_home_dir_t`. Root is still locked.
  - dev: `sudo`, `run0` and `pkexec` are denied (non-zero, no hang waiting for
    a password), `su` is refused before any prompt, and `pkcheck` on a real
    dev process says no to managing units.
  - `/dev/kvm` is mode 0666 and dev isn't refused when opening it. Without
    nested virtualization the node still exists (udev `static_node`) but the
    open fails with a different error, which the check accepts.
- **Network containment.**
  - The rule is loaded and survives `firewall-cmd --reload`.
  - Control: root can connect directly, which proves the negative checks
    below actually test something.
  - dev directly: TCP over IPv4 and IPv6, UDP 53 to a public resolver, and
    ICMP all fail without hanging, and the rule's counters go up. The
    counters show it was the rule and not a missing route (CI has no IPv6
    upstream, so there's no IPv6 control).
  - dev through the proxy, with a clean login environment (profile.d):
    `https://dl.google.com` and `https://api.anthropic.com` get CONNECT 200,
    and `https://example.com` gets 403, which `android-dev-denied` lists.
  - dev's systemd --user environment has the proxy variables and
    `JAVA_TOOL_OPTIONS`, parsed whole from the generator.
- **Android tooling.**
  - Command-line Java as dev gets `dl.google.com` through Squid.
  - Android Studio, started as dev in a headless KWin
    (`kwin_wayland --virtual`), fetches the SDK lists through Squid, makes no
    direct connection attempt, and in that first minute gets nothing refused
    except its plain-HTTP connectivity check. The test VM has 6 GiB for it.
- **With updates.** The stage-only drop-in is in effect.

The test harness reaches the guest over SSH without shipping any test users or
keys in the image:

- `run-vm.sh` generates a key for each run.
- It passes SMBIOS type-11 system credentials: `ssh.listen`, which
  systemd-ssh-generator (systemd ≥ 256) picks up, and `tmpfiles.extra`, which
  writes the key to `/var/roothome/.ssh/authorized_keys`.
  - `ssh.authorized_keys.root` doesn't work on bootc: tmpfiles writes it
    through the `/root` symlink before `/var/roothome` exists.
  - `ssh.ephemeral-authorized_keys-all` is refused by SELinux
    (`sshd-session` may not read `/run/credentials`).
- The connection goes through a qemu user-net port forward. The VM boots with
  UEFI (OVMF) from a throwaway overlay, so the qcow2 stays untouched.
- First-boot prompts are skipped with credentials too: `firstboot.locale`,
  `firstboot.keymap` and `firstboot.timezone` for systemd-firstboot, and
  `passwd.plaintext-password.admin` / `.dev` (random per run) for the password
  prompt.
- `systemd-sysusers.service`'s `ConditionNeedsUpdate=/etc` may skip it on later
  updates, which matters only when a future image adds accounts.
- Locally: `gh run download <run> -n android-dev-vm-qcow2`, then
  `tests/vm/run-vm.sh android-dev-vm.qcow2`. The script's mechanics were
  checked against a stock Fedora Cloud image in the devcontainer.

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
7. **Studio's plain-HTTP connectivity check.** Android Studio sends a
   `HEAD http://play.google.com/` at start. Squid refuses it (HTTPS only),
   so it's the one refusal Studio leaves in `android-dev-denied`. Nothing
   else depends on it.
   - *Recommendation:* leave it refused. Allowing it means plain HTTP, which
     CLAUDE.md rules out.

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
  containers/image#2235 was closed unmerged, and container-libs#625
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
- bootc install to-disk, `--via-loopback`:
  <https://bootc.dev/bootc/bootc-installation.7.html>
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
