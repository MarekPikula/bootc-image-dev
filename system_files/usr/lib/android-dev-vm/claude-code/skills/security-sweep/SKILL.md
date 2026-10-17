---
name: security-sweep
description: Sweeps the whole Android or Flutter codebase for security problems with parallel subagents, verifies each finding, and reports or fixes them. Use after changes to the manifest, permissions, network code, storage, WebViews, crypto, intents or dependencies, before a release, or when asked for a security review.
---

# Security sweep

Look at the whole codebase, not only the diff. Libraries count too: they add
components, permissions and network code to the app.

## 1. Gather

- Build the debug variant so the merged manifest exists (Gradle:
  `app/build/intermediates/merged_manifest*/`, Flutter: build the APK first).
  Read the merged one, not only the source manifest.
- List the dependencies with their versions (`./gradlew :app:dependencies
  --configuration releaseRuntimeClasspath`, or `pubspec.lock`).
- Note the app's minSdk and targetSdk: several risks depend on them.

## 2. Sweep in parallel

Start one subagent per area, all at once. Give each the paths above and ask
for findings as: file and line, what's wrong, a concrete attack (who, from
where, with what), severity (high, medium, low), and the fix.

1. **Components and intents.** Every activity, service, receiver and
   provider in the merged manifest: exported or not, permissions on it,
   intent filters, deep links and app links (`autoVerify`), and what each
   exported one does with input from its caller. PendingIntent flags.
   Content provider paths and `grantUriPermissions`. Task hijacking
   (`taskAffinity`, `launchMode`).
2. **Network.** Cleartext (`usesCleartextTraffic`, the network security
   config), trust managers and hostname verifiers, certificate pinning
   where the project wants it, what goes into URLs and headers, and
   responses parsed without validation.
3. **WebViews and embedded content.** JavaScript, `addJavascriptInterface`,
   file and content access, `loadUrl` with outside input, and links that
   leave the app.
4. **Storage, logs and backups.** What sensitive data is written where
   (shared preferences, files, databases, external storage, the clipboard,
   notifications), what's logged at any level, and `allowBackup` with the
   backup and data extraction rules.
5. **Secrets and crypto.** Keys, tokens and passwords in code, resources,
   build files, `BuildConfig`, test fixtures and git history
   (`git log -p -S`). Homemade crypto, weak algorithms or modes, fixed IVs,
   keys outside the Keystore, insecure randomness.
6. **Dependencies and build.** Each dependency's purpose and maintainer,
   unpinned or dynamic versions, repositories beyond the expected ones,
   release builds without R8, debuggable release builds, signing config in
   the repository.
7. **Flutter only: platform channels and plugins.** What each method channel
   accepts from Dart and from native, plugins with native code, and
   `--obfuscate` for release builds.

## 3. Verify

Every finding gets a second subagent that tries to refute it: is the code
reachable, is the input really attacker-controlled, does a platform default
or another check already stop it? Keep only findings that survive, and mark
those it couldn't settle as unconfirmed.

## 4. Report and fix

- Report the confirmed findings first, most severe first, each with its file
  and line, the attack, and the fix. Then the unconfirmed ones.
- Fix the confirmed high and medium ones when the fix is clear and local,
  each in its own commit, with a test that fails without the fix where one
  can be written, following the review rules.
- Leave design changes, new dependencies and anything that changes behavior
  users see to the user: describe them instead.
- Say what wasn't covered (for example native libraries without source).
