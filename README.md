# Android dev VM

A KDE desktop VM for Android development with Claude Code, built on Fedora
Kinoite 44 as a bootc image. You run it in GNOME Boxes. It updates itself from
images that CI builds, tests and publishes from this repository.

How it differs from an ordinary desktop:

- **Two accounts.** `dev` is for all your work, and Claude Code runs as `dev`.
  `admin` is for administration only. `dev` can never become root.
- **A short list of websites.** `dev` reaches the internet only through a proxy
  that allows a list of domains: Claude, Google, Gradle, Maven, GitHub and a
  few more. [docs/security-model.md](docs/security-model.md)
  says what that protects and what it doesn't.
- **An image, not installed packages.** You don't install software into the
  system. Changes come as pull requests to this repository and reach the VM
  as an update.

Inside: Android Studio, JDK 25, git, Claude Code, Firefox and KDE Plasma.

## Get the disk image

The **Publish** workflow pushes the VM's disk image to GHCR next to the image it
was built from, as an OCI artifact in chunks. Download it with podman 5.5 or
newer (`podman --version`), no sign-in needed:

```
img=ghcr.io/marekpikula/bootc-image-dev:disk
podman artifact pull "$img"
podman artifact extract "$img" .
podman artifact rm "$img"
cat android-dev-vm.qcow2.* >android-dev-vm.qcow2 && rm android-dev-vm.qcow2.*
```

That gives `android-dev-vm.qcow2`, a 64 GiB disk that grows as you use it. It
needs about 11 GB free while it runs. podman checks every chunk against its
digest, and if the pull stops halfway, run it again.

Each green Publish run on `main` also keeps the disk as the
`android-dev-vm-qcow2` artifact for two weeks (Actions → Publish, signed in to
GitHub), but that download is much slower. If you use it, take a run started by
a push or the weekly schedule, never by a pull request, which can change the
workflow it runs.

## Create the VM

1. **Check nested virtualization on the host.** The Android emulator needs it.

   ```
   cat /sys/module/kvm_*/parameters/nested    # Y or 1
   ```

   Recent kernels turn it on by default. If yours shows `N` or `0`, add
   `options kvm_intel nested=1` (or `kvm_amd`) to a file in
   `/etc/modprobe.d/`, then reboot the host (or reload the module with no VMs
   running).
2. **Import the disk in GNOME Boxes.** Choose to create a virtual machine from
   an image file and select `android-dev-vm.qcow2`. Boxes copies it, so you
   can delete the download afterwards.
3. **Give it room.** At least 8 GB of memory (Android Studio and the emulator
   together need it) and 4 CPUs.
4. **Turn on 3D acceleration** in the VM's settings in Boxes. The emulator
   needs it.

## First boot

The first boot asks on the VM's console:

1. Language, keyboard layout and time zone. Pick the layout you'll type your
   passwords with.
2. A password for `admin`, then one for `dev`. Each is typed twice, must be
   strong, and the two must differ. After a few failed tries it gives up:
   reboot and it asks again.

Then log in as `dev`. In a terminal, `grep -cE 'vmx|svm' /proc/cpuinfo`
should print a number above 0. If it prints 0, the VM has no nested
virtualization and the emulator won't start: check step 1 of Create the VM,
then shut the VM down and start it again.

## Daily use

- **Android Studio** is in the application menu. Its setup wizard downloads
  the SDK through the proxy. It comes with the Claude Code, Flutter and Dart
  plugins, and from its second start it updates its plugins on its own. The
  Flutter SDK isn't included. All of Google's domains are on the list, so
  Google Play in the emulator can work. If it needs others, run
  `android-dev-denied` (below).
- **The emulator.** When you create a virtual device in Studio's Device
  Manager, set its graphics acceleration to Hardware (in Additional
  settings). With the other settings it crashed at start.
- **Claude Code.** Open a terminal and run `claude`. To sign in, it prints a
  link: open it in a browser **on your host**, sign in, and paste the code the
  page shows back into the terminal (Boxes shares the clipboard, both ways,
  text only). Android Studio comes with Claude Code's plugin: run `claude` in
  Studio's own terminal, or press Ctrl+Esc, and Claude's edits show up in
  Studio's diff viewer, with your current selection as context.
- **Claude's instructions come with the VM.** In every project, Claude Code
  follows the VM's own `CLAUDE.md`: strict quality gates, a review before
  every commit, and no installing on your phone without asking. Put a
  project's commands and architecture in that project's `CLAUDE.md`. The VM
  also brings the skills `/security-sweep`, `/quality-sweep`, `/ux-audit`
  and `/emulator-test`, and the Context7 and Superpowers plugins, which
  load from Claude Code's second start on.
- **Context7 needs a one-time sign-in**, inside the VM, since it calls back
  to Claude Code there. In `claude`, run `/mcp`, choose context7 and
  authenticate: the VM's Firefox opens Context7's sign-in. Use an account
  made for it, with email sign-in, not your GitHub or Google account, and
  sign out of the site afterwards. If the page doesn't load, run
  `android-dev-denied`.
- **Shared folders.** In Boxes, open the VM's settings, then Devices &
  Shares, and add a folder under Shared Folders. In the VM, open Dolphin,
  press Ctrl+L, type `webdav://localhost:9843/` and press Enter. To keep it
  in the sidebar, right-click it under the location bar and choose Add to
  Places. Anything that runs as `dev` can read and change what you share.
- **Don't sign in to accounts in the VM's Firefox**, GitHub above all: every
  process of `dev`, Claude Code included, could use that session (see
  [docs/security-model.md](docs/security-model.md)).
- **Something can't download.** Run `android-dev-denied` in a terminal. It
  lists the domains the proxy refused, most frequent first. To get one added,
  see [docs/allowlist.md](docs/allowlist.md). Only HTTPS goes through, and a
  program that ignores the proxy settings gets no network at all.

## Administration and updates

**Never type admin's password in dev's session.** Nothing there should ever
ask for it, so a prompt that does is not to be trusted. Log in as `admin` on
a text console instead: Ctrl+Alt+F3 (in Boxes, send the key combination from
its keyboard menu), and log out when you're done.

The VM looks for a new image a while after boot and then a few times a day.
It downloads and stages it, and never reboots on its own: the new image
applies at your next reboot. Your files in `/var/home`, and the rest of
`/var` and `/etc`, carry over. `/usr` comes from the image.

As `admin`:

- `sudo bootc status` shows the image you're running (its version), a staged
  one, and the previous one.
- `sudo bootc upgrade --apply` fetches an update now and reboots into it.
- `sudo bootc rollback --apply` reboots into the previous image. The next
  check stages the newest one again.
- To stay on one version, switch to its tag (the version `bootc status`
  shows), and switch back to `stable` to get updates again:

  ```
  sudo bootc switch --apply ghcr.io/marekpikula/bootc-image-dev:44.20261013.1
  sudo bootc switch --apply ghcr.io/marekpikula/bootc-image-dev:stable
  ```

## When something goes wrong

- **Nobody can log in after an update.** The login screen says the system is
  still booting, or refuses every login: the network rule for `dev` didn't
  load, and the VM refuses logins rather than run without it. Reboot and watch
  for the boot menu, which shows for a second at every start. Press the Down
  arrow to stop its countdown, pick the entry ending in `(ostree:1)` (the
  previous image) and press Enter. The entries show Fedora's version number,
  not the one `bootc status` shows. That lasts one boot, so log in as `admin`
  on the console and switch to the version you're running, as above, to stay
  on it. Then report the problem.
- **The first-boot questions don't appear** and the screen stays black: wait
  a minute.
- **Boxes says "Redirection of USB device … failed"** when you attach a
  phone: the host's file manager has the phone open for file transfer. Eject
  it there first, then attach it to the VM again.

## For maintainers

- [PLAN.md](PLAN.md): design decisions, the roadmap and open questions.
- [CLAUDE.md](CLAUDE.md): the rules for working on this repository.
- [docs/security-model.md](docs/security-model.md) and
  [docs/allowlist.md](docs/allowlist.md).
- Build and check locally:

  ```
  podman build --build-arg-file versions.env -t localhost/android-dev-vm .
  tests/image/checks.sh localhost/android-dev-vm
  ```

  `tests/vm/run-vm.sh android-dev-vm.qcow2` boots a qcow2 from CI and runs
  the VM checks.
