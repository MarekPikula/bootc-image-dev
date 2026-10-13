# Changing the allowlist

`dev` reaches the internet only through Squid, which allows HTTPS (CONNECT to
port 443) to the domains in
[`system_files/usr/lib/android-dev-vm/squid/allowlist.txt`](../system_files/usr/lib/android-dev-vm/squid/allowlist.txt),
and nothing else. The list is part of the image, so it can't be changed
inside a VM (`/usr` is read-only there). Every change is a pull request to
this repository, and VMs get it with the next update.

## 1. Find out what was refused

In the VM, as `dev`, after the download that failed:

```
$ android-dev-denied
     12 example-cdn.net
      3 www.googletagmanager.com
```

It reads Squid's log and lists refused domains, most frequent first. Not
every refusal needs fixing. Pages pull in analytics, ads and sign-in widgets,
and programs phone home. Allow only what the work actually needs.

Some things never go through, whatever the list says: plain HTTP, ports other
than 443, and IP addresses instead of names. A tool that needs one of those
needs another way, so open an issue instead.

## 2. Add a narrow entry

One entry per line, under a comment saying what the group is for. The file's
header has the same rules as below.

- **An exact host** (`maven.google.com`) allows only that name. Prefer it.
- **A leading dot** (`.gradle.org`) allows the domain and every subdomain. Use
  it only when the hosts vary (CDN shards, for example) and all of them belong
  to the same service. Don't also list a subdomain it already covers: Squid
  warns about the overlap, and CI fails on any Squid warning.
- **Never `.google.com` or `storage.googleapis.com`.** They front far too much,
  and CI fails if any entry covers them.
- **Mind the uploads.** A host that accepts uploads from anyone with an
  account is a way for data to leave the VM. Several already are
  ([docs/security-model.md](security-model.md)). Add another only when the
  work can't do without it, and say so in the PR.

To catch both CI failures before pushing, build and run the image checks
locally (see the README's "For maintainers").

## 3. Open a pull request

Say which program needed the domain, what for, and paste the
`android-dev-denied` lines. CI builds the image, runs the image checks and
boots it in a VM to test the proxy end to end.

## 4. After the merge

The Publish workflow builds and tests `main` again and pushes the image as
`stable`. When that run is green (Actions → Publish), run
`sudo bootc upgrade --apply` as `admin` in the VM to get it now, or wait for
the VM's own check and reboot. Then retry the download.

Removing an entry goes the same way.
