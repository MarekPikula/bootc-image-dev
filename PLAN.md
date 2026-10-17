# Plan

This is the roadmap for the bootc Android dev VM. CLAUDE.md lists the
constraints that don't change.

- Status: PRs 1–8 merged. Fixes from the first full review in progress.
- Research checked against upstream docs on 2026-09-28.

## Decisions

| Topic | Decision | Why |
|---|---|---|
| Base image | The rolling `quay.io/fedora/fedora-kinoite:44` tag, set in `versions.env` | A real bootc image (`containers.bootc=1`) with no third-party privilege helpers. [Why not Aurora](#why-not-aurora). A digest pin broke within two days because Fedora deletes superseded manifests. `quay.io/fedora-ostree-desktops/kinoite` keeps dated tags, but only for about four weeks. Each image records the base digest it was built from in its `org.opencontainers.image.base.*` annotations. |
| Repo visibility | Public | Branch-restricted Environments and required checks work on the free plan, VMs pull from GHCR without credentials, and Actions minutes and storage for multi-GB qcow2 artifacts are free. |
| Accounts | `admin` = UID 1000 (`wheel`), `dev` = UID 1500 (no extra groups), via sysusers.d | This is the approach bootc recommends. Fixed UIDs keep the nftables rule stable. |
| Passwords | One-shot tty1 prompt at first boot, before the display manager (Plasma Login Manager on Kinoite 44) | Nothing is baked in, there's no window where accounts have no password, and it works in the Boxes console. |
| polkit | Deny-by-default rule for `dev`, with a short allowlist | Removes every admin prompt from dev's session, so Claude Code can't trigger a password dialog that the human might fill in. |
| Claude Code | RPM from Anthropic's signed dnf repo (stable channel), installed under `/usr` | Updates arrive with the image, and `dev` can't replace the system's binary. It needs no extra runtime hosts. [Details](#claude-code) |
| Signing | **Deferred** | Keyless identity pinning isn't possible in `policy.json` yet. [Details](#signing-future-pr) |
| Linting | pre-commit: the linters as local hooks that run the sha256-pinned binaries, plus `pre-commit/pre-commit-hooks` pinned by commit | One config for the devcontainer, CI and an optional git hook. pre-commit can't hash-pin PyPI packages, so the hooks' `ruamel.yaml` dependency is pinned by version only. That gap is limited to lint tooling and never reaches the image. |
| DNS exfiltration | Documented in v1, hardened later | [Open questions](#open-questions) |

## Repository layout

```
Containerfile              FROM kinoite:44; RUN android-studio.sh; RUN packages.sh; RUN studio-plugins.sh; COPY system_files/ /; RUN build.sh; RUN bootc container lint --fatal-warnings
versions.env               build inputs: base image tag, Android Studio URL + sha256,
                           Claude Code's dnf repo and signing-key fingerprint
build_files/
  packages.sh              every package install, in one layer before COPY system_files/
                           (see the Containerfile): squid, JDK 25, git, Claude Code
  claude-code.asc          Anthropic's public signing key for the claude-code repo
  android-studio.sh        download, sha256 check, unpack to /usr/lib/android-studio, updates
                           off. Its own RUN, see the Containerfile
  studio-plugins.txt       Studio's plugins (Claude Code, Flutter, Dart): ID, sha256, URL
  studio-plugins.sh        download, sha256 check, unpack each into Studio's plugins
                           directory. Its own RUN too
  build.sh                 runs the numbered steps in order
  15-su.sh                 su for wheel only (pam_wheel requisite)
  16-polkit-helper.sh      polkit's password helper for wheel only (4750 root:wheel)
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
    avahi/avahi-daemon.conf        lo only, no wide-area DNS: only for spice-webdavd
    emulator/advancedFeatures.ini  Vulkan and GLDirectMem off, copied to dev's ~/.android
  usr/libexec/android-dev-vm/
    set-passwords          first-boot prompt (bin_t, so it may run passwd)
    clipboard-to-x11       puts the Wayland clipboard's text on X11's, for spice-vdagent
  usr/lib/systemd/system/
    dev-egress-firewall.service
    systemd-user-sessions.service.d/10-dev-egress.conf
    plymouth-quit.service.d/10-android-dev-vm.conf          kills a plymouthd that hung
    squid.service.d/10-android-dev-vm.conf
    bootc-fetch-apply-updates.service.d/10-android-dev-vm.conf   stage only
    android-dev-firstboot.service
    multi-user.target.wants/android-dev-firstboot.service   image-owned enablement
    systemd-sysusers.service.d/50-android-dev-vm.conf       imports admin/dev password credentials
    systemd-firstboot.service.d/10-android-dev-vm.conf      runs it on our first boot (machine-id is empty), no header and footer
    avahi-daemon.service.d/10-android-dev-vm.conf           our avahi config
    user@1500.service.d/10-dev-egress.conf                  dev's user manager needs the rule too
  usr/lib/bootc/kargs.d/10-console.toml   serial console too, for headless logs, kernel errors only
  usr/lib/bootc/kargs.d/10-ssh.toml       no automatic sshd sockets (systemd.ssh_auto=no)
  usr/lib/systemd/resolved.conf.d/10-android-dev-vm.conf   LLMNR off
  usr/lib/systemd/user/android-dev-clipboard.service   runs clipboard-to-x11 in every graphical session
  usr/share/user-tmpfiles.d/android-dev-vm.conf        copies the emulator defaults into each profile
  usr/lib/bootc/install/50-android-dev-vm.toml   bootc install defaults (btrfs root)
  usr/lib/systemd/user-environment-generators/60-dev-proxy
  usr/share/polkit-1/rules.d/00-android-dev.rules
  usr/share/applications/android-studio.desktop
  usr/bin/android-studio             symlink to the launcher below
  usr/libexec/android-dev-vm/android-studio   starts Studio, turns on plugin updates in a new profile
  usr/bin/android-dev-denied         lists recent TCP_DENIED domains from the Squid log
  etc/profile.d/dev-proxy.sh
  etc/xdg/kioslaverc
  usr/lib/android-dev-vm/firefox/policies.json   Firefox policy: background services off
  etc/firefox/policies/policies.json             symlink to it, where Firefox looks first
  usr/lib/android-dev-vm/claude-code/managed-settings.json   updates off, dev's proxy
  usr/lib/android-dev-vm/claude-code/CLAUDE.md   instructions for every project
  usr/lib/android-dev-vm/claude-code/skills/     security-sweep, quality-sweep, ux-audit, emulator-test
  etc/claude-code/managed-settings.json          symlink to it, the only place Claude Code reads
  etc/claude-code/CLAUDE.md                      symlink, Claude Code's managed-policy file
  etc/claude-code/.claude/skills                 symlink, Claude Code's managed skills
  etc/security/pwquality.conf.d/50-android-dev-vm.conf    enforce_for_root
.pre-commit-config.yaml    hadolint, shellcheck, actionlint, file hygiene
disk/build-qcow2.sh        builds the qcow2 (bootc install to-disk, from the image itself), root and CI only
tests/lib.sh               check/indent/finish helpers shared by image and VM checks
tests/image/checks.sh      assertions run inside the built image with podman (no VM)
tests/image/polkit.sh      runs polkitd in the image and checks dev against every registered action
tests/image/claude-context.sh   runs Claude Code against a fake API and checks what it sends
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
  - systemd-nsresourced and systemd-mountfsd hand out transient UID ranges
    to unprivileged users, with the same effect. The polkit rule says no to
    them, and both are masked, since nothing here uses them.
- **Coexisting with firewalld.** The rule lives in its own table and is keyed
  on the numeric UID. A drop in any base chain is final, so firewalld can't
  re-allow dev's traffic. `nftables.service` is masked: its reload and stop
  run `nft flush ruleset`, which would delete dev's table while sessions keep
  running.
- **No LLMNR.** systemd-resolved's LLMNR responder (port 5355 on every
  interface) is off through a `resolved.conf.d` drop-in in `/usr`. Nothing
  here needs it, and it answers on the VM's network.
- **Failing closed.**
  - `dev-egress-firewall.service` loads the table before `network-pre.target`.
  - `systemd-user-sessions.service` gets `Requires=` and `After=` on that
    service.
  - If the table fails to load, `/run/nologin` stays in place and no non-root
    user can log in. pam_nologin is in the `account` stack of plasmalogin,
    `login` and `sshd`, which the image checks assert.
  - Stopping the unit leaves the rule loaded, but stops
    `systemd-user-sessions.service` too, which puts `/run/nologin` back.
  - `user@1500.service` (dev's user manager) gets the same `Requires=` and
    `After=`. It doesn't go through pam_nologin, and with lingering on it
    starts at boot without a login.
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
  - `shutdown_lifetime 1 seconds`: on stop, Squid waits that long for open
    connections, 30 s by default, which held up every shutdown. Its clients
    are all on the VM, going down with it.
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
  Claude, Google, Android Studio
  (Google's download CDN, developer.android.com, JetBrains' plugin
  marketplace), Gradle and its toolchain resolver, Maven Central and JitPack,
  GitHub, Google's static files and fonts for docs pages, and Firefox's
  remote settings and add-ons.
  - `.google.com` and `.googleapis.com` are the broadest entries, allowed
    whole on purpose. The Android SDK, Google's Maven repository, the
    Flutter SDK (`storage.googleapis.com`), Google Play in the emulator and
    Google sign-in all live there, and listing hosts one by one made every
    new Google tool a firewall exception. The price: Cloud Storage, Drive,
    Apps Script and the rest of Google's APIs can carry data out
    (`docs/security-model.md`), which is no worse than GitHub.
  - `.gvt1.com`: Google's download CDN serves far more than Android tooling,
    but only downloads.
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
      (`apis.google.com`, allowed since with all of Google).

### Proxy configuration for dev

| Consumer | Mechanism |
|---|---|
| Shells | `/etc/profile.d/dev-proxy.sh` sets upper- and lowercase `HTTP(S)_PROXY` and `NO_PROXY=localhost,127.0.0.1,::1`, only when the UID is 1500. |
| Apps launched by Plasma or systemd --user | A user-environment generator sets the same variables. |
| Gradle daemon and other JVMs | `JAVA_TOOL_OPTIONS` with `-Dhttp(s).proxyHost/Port` and `-Dhttp.nonProxyHosts`. |
| Claude Code | The `env` block in managed settings, with the same values as `proxy.env` (the image checks compare them). This also covers background agents, which don't inherit the login shell. Its sandbox proxy forwards to the same proxy, according to its docs (not tested: that needs a signed-in session). |
| KDE apps | `/etc/xdg/kioslaverc` with `ProxyType=4` (take the proxy from the environment). |
| Firefox | Nothing extra: its default "use system proxy settings" picks up the variables (checked in a VM). |
| Android Studio | Nothing extra: its runtime picks up `JAVA_TOOL_OPTIONS`, and its IDE settings default to auto-detect (the VM test checks it). |
| sdkmanager | Uses the proxy from Studio. On the command line it's a JVM too, so probably `JAVA_TOOL_OPTIONS` (not checked). Otherwise pass `--proxy=http --proxy_host=127.0.0.1 --proxy_port=3128`. |

### Claude Code

- **Install.** `packages.sh` installs the `claude-code` RPM from Anthropic's
  dnf repo. It's one binary, `/usr/bin/claude`, that needs only glibc.
  - The stable channel, about a week behind `latest` and without releases
    that had major regressions. The version isn't pinned: every build takes
    the channel's current release.
  - Anthropic's public key is in the repo (`build_files/claude-code.asc`),
    so a new key comes through a PR. The build stops unless the file holds
    exactly the key whose fingerprint is in `versions.env`, because dnf
    imports every key in it. dnf then checks the package's signature and
    the repo metadata's (`repo_gpgcheck`).
  - The key stays in rpm's keyring in the image. Only root installs
    packages, and root already trusts what this key signs.
  - That dnf call sees only Anthropic's repo (`--repo`), and the build stops
    if the transaction changed any package but claude-code (an `Obsoletes:`
    could, or a dependency pulling a newer glibc from Anthropic's repo). It
    compares name, version, arch and header digest, so upgrades and
    reinstalls count. The pinned key's `gpg-pubkey` entry is expected. The
    repo isn't left configured in the image.
  - The image checks assert the installed package carries that key's
    signature, and that it's the only key besides Fedora's that rpm trusts.
- **Managed settings.** Claude Code reads them only from `/etc/claude-code`:
  `managed-settings.json` and a `managed-settings.d/` drop-in directory.
  The image ships the file, a symlink to the image-owned one under
  `/usr/lib/android-dev-vm/claude-code/`, and nothing else there but the
  links to the instructions and skills below. Nothing a
  user or project sets overrides them. They apply to admin too.
  - `DISABLE_UPDATES`: no update checks, no hint to run `dnf upgrade`, which
    can't work here, and `claude install` no longer puts a self-updating
    copy in the user's home, ahead of `/usr/bin/claude` on PATH.
  - The variables from `proxy.env`. The VM test runs Claude Code with an
    empty environment and expects its API call in Squid's log.
  - `DISABLE_ERROR_REPORTING`: the error tracker's host isn't allowlisted.
  - Not `DISABLE_TELEMETRY`: it also switches off feature flags, and with
    them Remote Control and other features that roll out behind flags. The
    price is one refused request per session to
    `http-intake.logs.us5.datadoghq.com` in `android-dev-denied`. Usage
    metrics (no code, prompts or paths) reach Anthropic through
    `api.anthropic.com`.
  - Bypass-permissions mode stays available (open question 4).
- **Instructions for every project.** `/etc/claude-code/CLAUDE.md`, Claude
  Code's managed-policy file, links to
  `/usr/lib/android-dev-vm/claude-code/CLAUDE.md`. Claude Code loads it
  before the user's and the project's own, and no one can exclude it, so it
  changes only with the image. Projects add their own `CLAUDE.md` on top,
  and may make the rules stricter, never looser.
  - It started from the `CLAUDE.md` of an example Compose app made in the
    VM. Its general rules moved here, and its project facts stay in the
    project. It covers the VM (no root, the proxy, the emulator next to a
    phone, Studio's shared Gradle daemon), "the check" (each project's one
    command, Gradle or Flutter), fatal quality gates, dependencies, commits,
    the review workflow, and always-on security and UX rules.
  - It stays under the 200 lines Claude Code's docs advise, since every
    session loads it. The long procedures are skills.
  - dev can still write `~/.claude/CLAUDE.md`, which loads after ours. No
    managed setting stops that.
- **Skills.** `/etc/claude-code/.claude/skills` links to
  `/usr/lib/android-dev-vm/claude-code/skills/`. Managed skills take
  precedence over personal and project ones, and only their names and
  descriptions are in every session: a body loads when the skill is used.
  - `/security-sweep`, `/quality-sweep` and `/ux-audit` look at the whole
    codebase (or every screen) with parallel subagents, and have a second
    subagent try to refute each finding before it's reported.
    `/emulator-test` drives the app over adb for what changed and checks
    the outcome from system state. All of them stick to the emulator and
    put it back the way they found it.
  - The image checks run Claude Code as dev against a fake Messages API on
    loopback and check that the request carries the managed CLAUDE.md and
    every skill's name. That catches a path or format Claude Code doesn't
    pick up, which it ignores without a word.
- **Sandbox.** Claude Code's optional Bash sandbox needs bubblewrap and
  socat. Both come with Kinoite, and the image checks assert they're there.
  bubblewrap isn't setuid. It uses user namespaces, where dev's sockets
  still belong to UID 1500 (the VM test checks the rule from inside one).
  The optional seccomp filter (an npm package) isn't installed.
- **Hosts.** Checked in a VM with no login: a print-mode call and an
  interactive start used `api.anthropic.com`, `platform.claude.com` and
  `raw.githubusercontent.com` (the changelog), and made no direct attempt.
  Not allowlisted, so these don't work:
  - `registry.npmjs.org`: plugins and MCP servers that come from npm.
  - `*.frame.claudeusercontent.com`: reading artifacts.
  - `bridge.claudeusercontent.com`: Claude in Chrome (there's no Chrome).
- **Studio plugin.** Anthropic's JetBrains plugin, "Claude Code [Beta]",
  comes with Studio (see Studio plugins). It shows Claude's edits in
  Studio's diff viewer and shares the current selection and Studio's
  diagnostics. It runs `/usr/bin/claude`, so the managed settings apply,
  and talks to it over loopback.
- **Signing in** happens in a browser on the host, for the reason in
  `docs/security-model.md` ("Logins in dev's session"). In dev's Firefox it
  doesn't work anyway: the sign-in page needs `*.hcaptcha.com` for email
  sign-in, which isn't allowlisted. Google sign-in needs
  `accounts.google.com`, which is, but it hasn't been tried.

### Studio plugins

- **Which.** Claude Code [Beta] (Anthropic, marketplace ID 27310), Flutter
  (Google, 9212) and Dart (JetBrains, 6351), which Flutter needs. The
  Flutter plugin needs a Flutter SDK, which isn't in the image. Its
  releases and its Android build artifacts come from
  `storage.googleapis.com`, which is allowlisted.
- **Install.** `build_files/studio-plugins.txt` pins each release zip by ID,
  sha256 and URL.
  `studio-plugins.sh` checks each hash and that the zip holds the plugin
  with that ID, and unpacks it into `/usr/lib/android-studio/plugins/<ID>`.
  Studio loads plugins there as its own bundled ones. A copy of the list
  goes to `/usr/lib/android-dev-vm/`, where the checks read it.
- **Updates.** Studio updates its plugins on its own, from the JetBrains
  Marketplace (allowlisted), into dev's profile, where a newer version
  takes precedence over the image's. The image's versions are the starting
  point for a new profile. Studio's default is to only offer updates, and
  nothing in its installation can change that default (it's a hard-coded
  `false`). So `/usr/bin/android-studio` (a launcher in
  `/usr/libexec/android-dev-vm`) adds `PLUGINS_AUTO_UPDATE` to the
  profile's `options/updates.xml`, once per profile, from the second start
  on. Not before the first: a profile that exists before Studio's first
  start makes it skip its first-start setup, the SDK wizard included (seen
  in a VM). If dev turns the setting off later, it stays off. Settings →
  Appearance & Behavior → System Settings → Updates → Update plugins
  automatically.

### Boxes

What GNOME Boxes gives the VM over SPICE, and what the VM does to use it.

- **Shared folders.** Boxes shares a host folder over a SPICE port
  (`org.spice-space.webdav.0`). udev starts `spice-webdavd` when the port
  appears, and it serves the folder as WebDAV on port 9843, which Dolphin
  opens at `webdav://localhost:9843/` (README).
  - spice-webdavd requires avahi, which was masked (Privilege, root-side
    services). avahi now runs only for it, with its own config in
    `/usr/lib/android-dev-vm/avahi/`, started by a drop-in. `lo` is its
    only interface, so mDNS stays inside the VM, and wide-area DNS and the
    reflector are off, so it sends nothing on the network. Seen in a VM:
    spice-webdavd starts and keeps running, and listens on 127.0.0.1 only.
  - It stays disabled. That also removes the alias that D-Bus activation
    goes through, so no other client can start it.
- **Clipboard.** spice-vdagent is an X11 client, and KWin hands the Wayland
  clipboard to X11 only while an X11 window has focus. So text came from
  the host but didn't go back (seen in Boxes).
  - `android-dev-clipboard.service`, a user unit, starts with the graphical
    session when spice-vdagent's daemon runs. It watches the Wayland
    clipboard with `wl-paste --watch` and puts each new text on the X11 one
    with `xclip` (added to the image), where spice-vdagent sends it on.
  - It skips text that X11 already holds, which is how text from the host
    arrives, so nothing echoes back.
  - Seen in a headless KWin: text copied on the Wayland side reaches X11,
    trailing newlines included, and text an X11 client sets (as
    spice-vdagent does) reaches Wayland without the bridge taking it over.
  - Text only: images copied in the VM don't reach the host.
- **First-boot screen.**
  - systemd-firstboot runs with `--chrome=no`, without its header and
    footer bars. In Boxes its screen came out scrambled, likely because
    Boxes resized the console under the bars (not reproduced). The
    drop-in repeats Fedora's command to add it, and the image checks
    compare the two.
  - Kernel messages printed over the questions (reproduced). The
    `loglevel=4` kernel argument (`kargs.d/10-console.toml`) keeps all but
    errors and worse off the consoles, as `quiet` does, but leaves
    systemd's boot messages, on the screen and on the CI test's serial log.
    An error can still land on the prompt. A sysctl.d file didn't stick:
    Plymouth puts back the level from before its splash, which starts in
    the initrd (seen in a VM).
- **Emulator.** With 3D acceleration on in Boxes, GL in the VM goes through
  virgl and Vulkan is Mesa's software lavapipe. The emulator crashed at
  start (SIGSEGV), with software graphics too, and ran with hardware
  graphics and Vulkan and GLDirectMem off (seen in Boxes).
  - A user-tmpfiles.d line copies an `advancedFeatures.ini` with those two
    off into `~/.android/` when there's none. A file of the user's own, or
    edits to ours, stay.
  - The graphics mode is per virtual device, so the README says to choose
    hardware graphics.

### Privilege

- **Accounts.** sysusers.d creates `admin` (1000, `wheel`) and `dev` (1500, no
  extra groups), both locked.
  - Homes (`/var/home/<user>`, from `/etc/skel`) are created by the first-boot
    unit with `mkhomedir_helper`.
- **First boot.** `android-dev-firstboot.service` runs on tty1 before the
  display manager and asks for both passwords.
  - Each password is typed twice, and dev's must differ from admin's, also
    when admin's was set on an earlier boot (`unix_chkpwd` compares it with
    admin's hash). It's set with `passwd --stdin`, so pwquality still
    applies, and `enforce_for_root` makes it reject weak passwords instead of
    only warning.
  - `passwd --stdin` exits 0 even when PAM rejects the password
    (shadow-utils 4.19), so the script checks shadow for a hash instead.
  - After 5 failed attempts per account it gives up. It ignores Ctrl+C,
    Ctrl+\ and Ctrl+Z, logs failures to the journal, and marks itself done
    only on success, so the next boot asks again, for the passwords still
    missing. Until then the login screen appears, but an account without a
    password can't log in.
  - `systemd-mute-console` keeps kernel and systemd status messages off the
    prompt while it runs.
  - The unit starts after `plymouth-quit.service` has taken the boot splash
    off tty1. plymouthd once hung while quitting in a VM. Fedora's unit
    then times out after 20 s, but stops only the `plymouth quit` client:
    plymouthd keeps the display, and `plymouth-quit-wait.service` (no
    timeout), which the gettys wait for, waits forever. Our first-boot unit,
    which ran its own `plymouth quit` with no timeout, hung too. A drop-in
    now kills plymouthd when `plymouth-quit.service` doesn't succeed, on
    every boot.
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
  `systemd-firstboot` asks for locale, keymap and timezone first, so the
  passwords are typed with the right layout. It sets the console's layout at
  once and converts it for the login screen. It skips its root-password
  prompt because root already has a locked shadow entry (`*`), which the image
  checks assert. Root stays locked.
  - Upstream's unit has `ConditionFirstBoot=yes`, which never holds here: the
    image ships an empty `/etc/machine-id`, which systemd reads as "not the
    first boot". A drop-in replaces the condition with "until
    `firstboot.done` exists".
  - systemd-firstboot asks only for settings that have no file, and tmpfiles
    (`etc.conf`) has by then copied systemd's fallback `locale.conf` and
    `vconsole.conf` from `/usr/share/factory`. The drop-in removes them first
    while they're those untouched copies.
  - The VM test passes a German keymap and Warsaw's time zone and checks
    both, including the login screen's layout.
- **Sudo.** `dev` isn't in `wheel`. The image checks assert that
  `sudo -l -U dev` grants nothing.
- **su.** `pam_wheel.so use_uid` is `requisite` in `/etc/pam.d/su`, so non-wheel
  users are refused before any password prompt.
- **No automatic sshd.** systemd-ssh-generator binds sshd to
  `/run/ssh-unix-local/socket` (mode 0666) on every boot, and to vsock port
  22 when the VM has a vsock device, although `sshd` is disabled. With
  password logins on, `ssh admin@.host` from dev's session would reach
  admin's login. Only an SELinux denial stopped it. `kargs.d/10-ssh.toml`
  sets `systemd.ssh_auto=no`. The VM test's `ssh.listen` credential still
  works, and the VM checks assert it's the only sshd socket.
- **polkit's password helper.** The setuid `polkit-agent-helper-1` runs PAM
  for whichever user its caller names and reports whether the password was
  right. dev could have guessed admin's password through it, limited only by
  `pam_faildelay`'s 2 s per attempt, in parallel. `16-polkit-helper.sh` makes
  it `4750 root:wheel`, so dev can't run it at all. dev never needs it, since
  polkit never asks dev for a password. Socket activation
  (`polkit-agent-helper.socket`) would run it as root for any caller, so it's
  masked. The image checks run the helper as dev and admin.
- **polkit.** `00-android-dev.rules` returns `NO` for every action dev asks for,
  except these, and only while dev's local session is active (as upstream's
  `allow_active`, but `NO` instead of an admin prompt everywhere else):
  - login1 power-off, reboot, suspend and set-wall-message. power-off and
    reboot imply set-wall-message (`policykit.imply`), and polkit grants an
    implied action even when a rule says no (seen in a VM), so it can't be
    taken away on its own. dev can leave a message that logind shows on
    every terminal at the next scheduled shutdown, admin's included. That's
    accepted: nothing in it can ask for a password that dev could read.
  - login1 inhibitors
  - RealtimeKit (audio)
  - udisks2 removable-media mount and eject

  It sorts first, ahead of Kinoite's `empower.rules`, which grants everything
  to the `empower` group. `tests/image/polkit.sh` runs polkitd in the image and
  checks dev against every registered action. Its subjects have no login
  session, so every answer must be `NO`. The VM checks open an active local
  session for dev on tty8 and require `YES` for exactly the allowlist and
  `NO` for everything else. polkit also counts dev's systemd user units
  (where Plasma runs apps) as part of the active session, so they get the
  allowlist too. Seen in a VM.
  Without the rule,
  dev would get silent `YES` for systemd's mount and namespace helpers, and
  admin prompts (`CHALLENGE`) for rpm-ostree, firewalld and more.
- **Root-side services dev could drive.** cups/cups-browsed and geoclue are
  masked. avahi runs only for Boxes' shared folders, on `lo` alone
  (Boxes). NetworkManager, the flatpak system helper and rpm-ostree are
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

- **Timer.** Kinoite ships `bootc-fetch-apply-updates.timer` (an hour after
  boot, then every 8 hours) but doesn't enable it. We enable it from `/usr`.
  The stock service runs `bootc upgrade --apply`, which reboots as soon as an
  update is staged. Our drop-in replaces it with `bootc upgrade --quiet`,
  which stages only. The new image applies at the user's next reboot.
- **`/boot` isn't an automount.** systemd-gpt-auto-generator automounts the
  EFI System Partition on `/boot`, in front of ostree's own `/boot` on the
  root filesystem, with a 2-minute idle timeout. In one VM shutdown it was
  stopped before `ostree-finalize-staged.service` ran, which failed
  ("Remounting /boot read-write: Invalid argument") and dropped the staged
  update without a word. It's a race (staging and rebooting after the idle
  timeout didn't reproduce it), and a known upstream problem on Fedora 44
  (bootc-dev/bootc#2402, ostreedev/ostree#2544), with no fix released yet.
  The image masks `boot.automount`. bootupd mounts the ESP itself, which a
  VM check confirmed, and a staged update then applied. An existing VM gets
  the mask with the update that brings it, so that one update can still hit
  the race once.
- **Reusing the Android Studio layer.** CI builds with `--timestamp 0`, so a
  layer's digest depends only on its content. The Studio layer (1.6 GB
  compressed) then stays the same when only the base changes, and a VM
  doesn't download it again. Checked with two full builds on two Kinoite
  bases two weeks apart: same layer, also after gzip. ostree resets every
  file's time to 0 when it deploys, so nothing is lost. The image's
  creation date becomes 1970, so the version label carries the date.
  Rechunking the whole image (as Fedora does for its own images) would make
  every unchanged package reusable too (see Later).
- **Rollback.** `bootc rollback` swaps to the previous deployment and discards
  any staged one. The README explains that the next timer run will stage the
  newer image again.
- **Weekly rebuild.** The CI rebuild picks up the current Kinoite 44 image and
  the current `claude-code` RPM from the stable channel.
- **Other bumps.** Android Studio and the Fedora major version change through
  PRs that edit `versions.env`, Studio's plugins through PRs that edit
  `build_files/studio-plugins.txt`.

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
- **`publish.yml`** (push to `main`, Mondays 03:17 UTC, dispatch):
  - A `version` job sets the version, `44.<yyyymmdd>.<run number>`, shaped
    like Kinoite's own (whose last part counts builds per day, ours never
    resets). `bootc status` shows it, and the manifest's
    `org.opencontainers.image.version` annotation carries it too (otherwise
    it would be Kinoite's, inherited from the base).
  - It calls `_build-test.yml` with that version and `export-image`, which
    uploads the tested image (an OCI layout) as the `image` artifact, only
    when the VM test passed.
  - A `publish` job bound to the `release` Environment (deployment branches:
    `main` only) is the only job with `packages: write`.
  - That job pushes the image once with skopeo, under its version. The
    build job passes out the ID of the image it tested, and both the
    artifact's and the pushed manifest's config digest must equal it.
    `sha-<12 hex>` and then `stable` (what VMs track) point at the same
    manifest.
  - Then it pushes the tested qcow2 to the same repository as an OCI
    artifact, under `disk-<version>` and then `disk`. People download it
    with `podman artifact pull` (README). Artifact storage gave 1–2 MB/s,
    against 8 MB/s for one connection to GHCR's CDN. 256 MiB chunks, one
    layer each, let podman fetch several at once, and it checks each
    digest. oras pushes it (pinned by sha256), since the runner's podman
    4.9 can't. Old `disk-*` versions pile up. Public package storage is
    free, so cleaning them up can wait.
  - One publish at a time. A queued run waits.
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
  - The qcow2 is uploaded as an artifact (for PR runs and run-vm.sh).
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
   `packages.sh` so every package shares one layer, and managed settings.
   bubblewrap and socat for its optional sandbox are already in Kinoite.
7. **Updates and publishing.**
   - The update timer enabled, with the stage-only drop-in.
   - `boot.automount` masked, so staged updates aren't dropped at shutdown.
   - ⚙ `--timestamp 0` in CI's build, so the Android Studio layer is reused
     across bases.
   - ⚙ `publish.yml` with the `release`-bound publish job.
   - You create the `release` Environment first (deployment branches:
     `main`), and after the first publish make the GHCR package public, so
     VMs can pull it without credentials.
8. **Docs.**
   - `README.md`:
     - creating the VM in GNOME Boxes from the qcow2
     - first boot (passwords, their own Claude login)
     - nested virtualization on the host for the emulator
     - updates and rollback
   - `docs/allowlist.md`: edit → PR → CI → staged update → reboot.
9. **Claude Code instructions for every project.** The managed
   `CLAUDE.md` and the sweep skills (see Claude Code).
10. **Later, each after discussion:** image signing, a DNS filtering resolver,
   narrower GitHub hosts, automated Android Studio bump PRs, rechunking the
   image (`rpm-ostree compose build-chunked-oci`) so updates download only
   the packages that changed, and dropping the `boot.automount` mask once
   bootc or ostree handle it.

## Testing

| Layer | Where | What |
|---|---|---|
| Static | devcontainer and CI, via pre-commit | hadolint, shellcheck, actionlint, plus whitespace, YAML/JSON and private-key checks from `pre-commit-hooks`. |
| Image | `podman run` against the built image, after `systemd-sysusers` | Accounts, UIDs and groups. No password hashes, `authorized_keys` or SSH host keys. No sudo for `dev`, `su` is wheel-only, and only wheel may run polkit's password helper. polkit: our rule sorts first, and dev gets `NO` for every registered action outside its allowlist. setuid/setgid files and capabilities match the reviewed list. `/dev/kvm` is world-accessible. The first-boot unit is enabled, root is locked (so there's no root-password prompt), and the expected units are masked. avahi is disabled, starts on our config, and that allows only `lo` and turns off wide-area DNS and the reflector. systemd-firstboot runs Fedora's command plus `--chrome=no`. The clipboard bridge's user unit is pulled in from `/usr`. Network: the nft rule and Squid config parse with the image's own `nft` and `squid` (no Squid warnings), the allowlist has no IP addresses or bare top-level domains, the rule and Squid are enabled from `/usr`, user sessions require the rule, systemd's tmpfiles entry creates `/run/nologin` at boot, pam_nologin guards the login stacks, and dev (not admin) gets the proxy environment. Android Studio: the launcher, a valid desktop entry and platform updates off. Every plugin in `studio-plugins.txt` is installed and its build range includes Studio's build. JDK 25. Claude Code: `claude --version` runs, the package is signed with the pinned key, which is the only key besides Fedora's that rpm trusts, bubblewrap and socat are present, and `/etc/claude-code` holds only links to our managed settings, CLAUDE.md and skills. The settings turn updates off and have exactly the proxy variables from `proxy.env`. Claude Code, run as dev against a fake API on loopback, sends the managed CLAUDE.md and every managed skill's name. Updates: the timer is enabled from `/usr`, its service runs exactly one command, `bootc upgrade --quiet` (no `--apply`), and `boot.automount` is masked. |
| VM | CI (required), or locally on a `gh run download`ed qcow2 | See below. |
| Manual | in GNOME Boxes, by hand | SDK download through the proxy, emulator with nested virtualization and hardware graphics, Claude login, the first-boot screens and password flow in Boxes, a shared folder in Dolphin, text copied both ways, and in dev's desktop session: power off, reboot and mount a USB stick without any password prompt. |

VM test assertions (`tests/vm/checks.sh`):

- **Accounts and privilege.**
  - Boot finishes with no failed units, SELinux is enforcing, the `kargs.d`
    console arguments are applied, only kernel errors and worse reach the
    console, and bootc tracks the GHCR image.
  - `android-dev-firstboot.service` ran and succeeded, sysusers created the
    accounts, both passwords were set from credentials, and the homes exist,
    are private and are labelled `user_home_dir_t`. Root is still locked.
  - A plymouthd that hangs while quitting (a stopped one) is killed when
    `plymouth-quit.service` times out, and the first-boot unit starts after
    that unit.
  - dev: `sudo`, `run0` and `pkexec` are denied (non-zero, no hang waiting for
    a password, and run0 and pkexec say polkit refused, not that nobody
    answered a prompt), `su` is refused before any prompt, and `pkcheck` on a
    real dev process says no to managing units.
  - The only sshd socket is the test's own (`ssh.listen`), none from
    systemd-ssh-generator's automatic ones.
  - In an active local session for dev (on tty8), polkit says `YES` to
    exactly the allowlist and `NO` to every other action.
  - `/dev/kvm` is mode 0666 and dev isn't refused when opening it. Without
    nested virtualization the node still exists (udev `static_node`) but the
    open fails with a different error, which the check accepts.
- **Network containment.**
  - Everything listening matches a reviewed list (resolved's stub, chronyd's
    command port, Squid, spice-webdavd, avahi's mDNS socket and the test's
    sshd), since dev reaches all of it over loopback.
  - The rule is loaded and survives `firewall-cmd --reload`.
  - Control: root can connect directly, which proves the negative checks
    below actually test something.
  - dev directly: TCP over IPv4 and IPv6, UDP 53 to a public resolver, and
    ICMP all fail without hanging, and the rule's counters go up. The
    counters show it was the rule and not a missing route (CI has no IPv6
    upstream, so there's no IPv6 control). TCP is tried from inside a
    bubblewrap user namespace too.
  - dev through the proxy, with a clean login environment (profile.d):
    `https://dl.google.com` and `https://api.anthropic.com` get CONNECT 200,
    `https://storage.googleapis.com` gets 200 too (the Flutter SDK), and
    `https://example.com` gets 403, which `android-dev-denied` lists.
  - dev's systemd --user environment has the proxy variables and
    `JAVA_TOOL_OPTIONS`, parsed whole from the generator.
- **Android tooling.**
  - Command-line Java as dev gets `dl.google.com` through Squid.
  - Android Studio, started as dev in a headless KWin
    (`kwin_wayland --virtual`), fetches the SDK lists through Squid, makes no
    direct connection attempt, and in that first minute gets nothing refused
    except its plain-HTTP connectivity check. The test VM has 6 GiB for it.
  - Studio's log from that run lists every plugin in `studio-plugins.txt` as
    loaded. A second start through the launcher turns on automatic plugin
    updates in that profile.
- **Boxes.** `run-vm.sh` gives the VM the two virtio ports Boxes adds
  (`org.spice-space.webdav.0` and `com.redhat.spice.0`), with nothing on the
  other end, so their services start as they would in Boxes.
  - spice-webdavd and avahi run, and avahi's only interface is `lo`.
  - The clipboard bridge, run as dev in a headless KWin: text copied on the
    Wayland side reaches X11, and text an X11 client sets reaches Wayland
    without the bridge taking it back.
  - dev has the emulator defaults in `~/.android/advancedFeatures.ini`.
- **Claude Code.** Run as dev with an empty environment and a dummy API key,
  it calls `api.anthropic.com` through Squid (so the proxy came from the
  managed settings) and makes no direct attempt. What Squid refuses isn't
  asserted: the version isn't pinned, and a new release that asks for one
  more host shouldn't block the weekly build.
- **Updates.** The timer is active and its service runs exactly one command,
  `bootc upgrade --quiet`, and `/boot` isn't an automount.

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
- The checks are copied into the guest and run with no stdin, so a check
  that reads stdin can't swallow the rest of the script. ssh keepalives and
  a timeout on waiting for boot to finish make a stuck guest fail the run
  with its logs.
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
   - `github.com`, `.githubusercontent.com`, the Anthropic API and claude.ai
     can all carry data out. So can the Gradle Plugin Portal, JetBrains'
     marketplace and addons.mozilla.org, with an account.
   - *Recommendation:* narrow `.githubusercontent.com` to `raw.`, `objects.` and
     `release-assets.` once the VM test shows that's enough. Document the rest
     as accepted risk.
3. **Other channels to document.**
   - Boxes clipboard (spice-vdagent) and folder sharing (spice-webdavd).
   - Phones attached over USB, via adb.
   - Root-side daemons generally.
   - Emulator guests only get HTTPS, through the proxy, to allowlisted
     domains, so Play Store and similar won't work.
4. **Claude Code bypass-permissions mode.**
   - *Recommendation:* leave it available, because the VM is the sandbox.
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
  <https://code.claude.com/docs/en/managed-settings>,
  <https://code.claude.com/docs/en/sandboxing>,
  <https://code.claude.com/docs/en/data-usage>
- Android Studio: <https://developer.android.com/studio>,
  <https://developer.android.com/studio/intro/studio-config>
- systemd-ssh-generator(8):
  <https://www.freedesktop.org/software/systemd/man/latest/systemd-ssh-generator.html>
