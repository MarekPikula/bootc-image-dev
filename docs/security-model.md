# Security model

Claude Code runs in this VM as the `dev` user, often with broad permissions.
The VM limits what `dev` can do in two ways:

- `dev` can never become root.
- `dev` reaches the network only through a proxy that allows a short list of
  domains.

This page covers what enforces those limits, what is only a convenience, and
what they don't cover. PLAN.md has the design details and the reasons behind
them.

## No root for dev

- `dev` (UID 1500) isn't in `wheel`, so sudo refuses it. `su` is limited to
  `wheel` and refuses `dev` before asking for a password.
- polkit answers `dev` with a flat no for every action except a few harmless
  ones (power off, reboot, suspend, removable media, audio priority), and allows
  those only in dev's own desktop session. `pkexec`, `run0` and the desktop's
  admin dialogs never ask `dev` for a password, so there is no admin prompt in
  dev's session to type a password into.
- `admin` (UID 1000, `wheel`) is for administration only. Never type admin's
  password in dev's session.
- setuid/setgid binaries and file capabilities are reviewed. The image checks
  fail when a package or base update adds one. Three helpers lose their
  capabilities, because they could get around the network rule below:
  GStreamer's `gst-ptp-helper` (`cap_net_admin`, enough to remove the rule),
  and `arping` and System Monitor's `ksgrd_network_helper` (`cap_net_raw` for
  packet sockets, which the rule doesn't see).

## Network

### What enforces it

- **The nftables rule.** Table `inet dev_egress` stops every packet sent by a
  socket that UID 1500 owns, unless it goes over loopback. This covers IPv4
  and IPv6, TCP, UDP, ICMP and raw IP sockets, and anything `dev` starts:
  scripts, Gradle, the emulator, containers (their user-mode networking runs
  as `dev`). A direct TCP connection fails at once with "Connection refused",
  and a UDP send with "Operation not permitted".
- **Squid** listens on `127.0.0.1:3128` and is the only way out for `dev`. It
  allows only HTTPS (CONNECT to port 443), only to the domains in
  `squid/allowlist.txt`, and refuses everything else with a 403, plain HTTP
  included.
  It matches domain names only, never reverse DNS.
- **Failing closed.** The rule loads early in boot, before the network comes
  up. User logins require it: if it doesn't load, `/run/nologin` stays and
  nobody but root can log in, on the login screen, a text console or SSH.
  The login screen then says the system is still booting. Root is locked, so
  the way back is to pick the previous entry in the boot menu.
- **firewalld** keeps working as before. It manages its own table, and our
  rule is final whatever firewalld allows.

### What is only a convenience

`dev`'s environment points programs at Squid: `http_proxy`, `https_proxy`,
`no_proxy` (and uppercase), `JAVA_TOOL_OPTIONS` for Java and Gradle, and KDE's
proxy setting. A program that ignores them gets no network at all. It can't
get around the rule.

### Changing the allowlist

- Every change goes through a PR, and CI builds and tests the new image.
- The VM stages the update. It applies at the next reboot.
- `android-dev-denied` (run as `dev`) lists the domains Squid refused
  recently, most frequent first, as a starting point for a PR.
- Keep entries narrow. `.google.com` and `storage.googleapis.com` stay out,
  and the image checks enforce it.

## What this doesn't cover

These are known and accepted for now. Some have a planned fix.

- **DNS.** `dev` can still resolve any name through systemd-resolved, which
  runs as a system service and forwards queries. That makes DNS a slow way to
  send data out. Planned: a local resolver that only answers for allowlisted
  zones.
- **Allowlisted hosts that accept uploads.** `github.com`,
  `*.githubusercontent.com` and the Anthropic API can all carry data out, for
  example as a push to any GitHub repository. So can, with an account,
  JetBrains' plugin marketplace and addons.mozilla.org. Planned: narrow the
  GitHub hosts once we know which ones builds need.
- **Domain fronting.** Squid checks only the name in the CONNECT request,
  not the TLS server name or `Host` header inside the tunnel. A shared front
  end behind an allowlisted name (Google's for `dl.google.com`, the GitHub
  CDN) might route the tunnel to a service that isn't allowlisted. Whether it
  does depends on the provider.
- **Services on loopback.** The rule allows all loopback traffic, so `dev`
  reaches any local service, not only Squid. Today the ones that matter are
  Squid and the DNS stub.
- **Root-side services.** Daemons such as NetworkManager, PackageKit, the
  flatpak system helper and fwupd connect on their own. polkit stops `dev`
  from changing their settings or installing anything, but some read-only
  requests (such as checking for updates) can still make them fetch from the
  network.
- **Channels to the host.** Boxes' shared clipboard and folder sharing
  (SPICE), USB devices passed through to the VM (phones over adb), and a
  vsock device if the VM has one, all bypass the network. They are under the
  control of whoever runs the VM on the host.
- **The emulator.** Android guests in the emulator get only proxied HTTP(S)
  to allowlisted domains, so the Play Store and similar don't work.
- **admin.** admin's traffic isn't filtered. admin must not give `dev`
  subordinate UIDs (`usermod --add-subuids`): processes under those UIDs
  aren't matched by the rule.
- **Kernel and privileged-binary bugs.** A local root exploit, or a bug in a
  reviewed setuid or capability binary, defeats all of the above.
- **Image trust.** Images aren't signed yet. VMs accept whatever reaches the
  `stable` tag on GHCR over TLS, so anyone who can push there, a workflow run
  with `packages: write` or the repository owner's credentials, controls
  every VM. Signing is planned.
