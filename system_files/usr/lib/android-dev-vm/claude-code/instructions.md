# Android development in this VM

These instructions come with the VM image and apply in every project. Each
project's own `CLAUDE.md` adds its commands, architecture and quirks on top.
A project may make these rules stricter, never looser. Where a project's
`CLAUDE.md` is missing, or doesn't name its check command, add that first.

## The VM

- You run as `dev`, which has no root and never gets it: no sudo, run0, pkexec
  or su. Don't try. If something needs root, say what and why, and the user
  does it as `admin`.
- The network is HTTPS only, through a proxy that allows a list of domains,
  plus git over SSH to GitHub (`git@github.com:`). When a download fails with a proxy refusal or a 403 on CONNECT, run
  `android-dev-denied`, then report the domain and why the project needs it.
  The list changes through a pull request to the image. Never work around
  it: no other proxies, mirrors, tunnels, vendored copies from elsewhere or
  downloads by other means.
- System software comes with the image, so don't install packages. Project
  tools come through the project (Gradle, pub, the SDK manager).
- The Android SDK is in `~/Android/Sdk`. adb is in its `platform-tools`.
- Android Studio runs next to you and shares the emulator and Gradle's
  daemon. Never run `./gradlew --stop`, and never kill Studio's processes.
  Studio's instrumented-test runs uninstall the app afterwards, so if the app
  suddenly disappears, reinstall it before chasing a crash.
- A physical phone is often attached next to the emulator. Point every adb
  command at the emulator (`adb -s emulator-5554`, or `ANDROID_SERIAL`), and
  never install on or drive a phone without asking. `./gradlew installDebug`
  and `flutter run` pick every device or ask, so build first and install
  with `adb -s <serial> install -r <apk>`.

## Plugins

- **Context7** looks up current documentation for libraries and SDKs. Use
  it before relying on memory for an API, a Gradle DSL or a version. It
  needs a one-time sign-in from `/mcp`. If it isn't signed in, say so once
  and carry on without it.
- **Superpowers** brings skills for planning, test-driven development,
  debugging and review. Use them, but where they disagree with these rules
  or the project's (pushing, merging, branch handling, which reviews to
  run), these rules and the project's win. Its own review steps
  (requesting-code-review, the reviewers subagent-driven-development sends)
  don't come on top of the reviews here: run these instead.

## The check

"The check" is the project's one command that runs every quality gate, and
the project's `CLAUDE.md` names it. Run it before you call any change done.
Typical ones:

- Gradle: `./gradlew check` (compiler, Android Lint, detekt, unit tests).
- Flutter: `flutter analyze --fatal-infos --fatal-warnings`, then
  `dart format --output=none --set-exit-if-changed .`, then `flutter test`.

## Quality gates

Every gate is fatal. A new project gets them before its first feature, and an
existing project that lacks them gets a plan to add them.

- **Kotlin:** `allWarningsAsErrors`, `extraWarnings` and `progressiveMode`.
- **Android Lint:** `checkAllWarnings` and `warningsAsErrors`, on test
  sources and dependencies too. `lint.xml` may demote only checks that
  depend on the network or the date (`GradleDependency`,
  `NewerVersionAvailable`, `AndroidGradlePluginVersion`).
- **detekt:** `allRules = true`, with its ktlint wrapper and, for Compose,
  the Compose rules.
- **Dart and Flutter:** `analysis_options.yaml` sets `strict-casts`,
  `strict-inference` and `strict-raw-types`, and enables a strict lint set
  (`flutter_lints` plus the stricter rules from the Dart linter's full list).
  Other stacks get their strictest analyzer and formatter, all fatal.
- Fix the cause instead of suppressing. No baselines. If a suppression can't
  be avoided, scope it to the one declaration or element, with a comment
  saying why. Relax a rule in its config only for a real conflict with the
  platform's idioms, and say so in the commit message.
- Use the narrowest visibility. No dead code, commented-out code, or TODO
  without an issue.
- Changed behavior gets tests. Pure logic gets unit tests. A bug fix comes
  with a test that fails without it.

## Dependencies

- All versions live in one place (`gradle/libs.versions.toml`, or
  `pubspec.yaml` with `pubspec.lock` committed). No dynamic versions (`+`,
  `latest.release`, open ranges in apps).
- Every new dependency needs a reason in its commit message: what it does
  that the platform or an existing dependency doesn't, and who maintains it.
  Prefer the platform and first-party libraries.

## Commits

- Split work into feature commits. Each one passes the check on its own.
  Before calling a series done, check each commit in a separate
  `git worktree` (copy `local.properties` into it).
- Never commit secrets: keystores, `keystore.properties`, API keys, tokens,
  `local.properties`. Keep them out of logs and test fixtures too.
- Never push, force-push or rewrite pushed history without asking.

## Review

- **Before every commit:** `/simplify`, then `/code-review low` on the
  pending changes. Apply what holds up, then run the check again.
- **After each larger batch** (a feature over several commits, or a
  session's worth of work): `/simplify` and `/code-review high` over the
  whole batch, `/emulator-test` on what changed, and `/quality-sweep`.
- **`/security-sweep` and `/ux-audit`** whenever their descriptions say, and
  all three sweeps before a release or when the user asks.
- Report every finding you didn't fix, with the reason.

## Security while writing code

- Components are not exported unless they must be, and every component
  states `android:exported`. Exported ones check their callers.
- Intents, deep links and anything from outside the app are untrusted input.
  Validate them before use.
- PendingIntents are `FLAG_IMMUTABLE` unless they must be mutable, and then
  explicit.
- No cleartext traffic. The network security config permits none, and
  certificates are never trusted blindly.
- WebViews keep JavaScript off unless needed, and never expose a JavaScript
  interface to content the app doesn't control.
- Sensitive data stays in app-private storage, out of logs, and out of
  backups (backup and data extraction rules).
- Crypto comes from the platform (Keystore, `javax.crypto`, Tink), never
  homemade.
- Request the fewest permissions, at the moment they are needed.

## UX while writing code

- Accessibility is part of done: labels for everything a screen reader
  meets, touch targets of at least 48 dp, sufficient contrast, layouts that
  survive 200 % font scale.
- Every string is a resource, ready for translation and right-to-left.
- Every screen handles loading, empty, error and offline states.
- State survives rotation and process death.
- Edge-to-edge content respects insets, including the keyboard.
- Follow the platform's design system (Material 3 on Android) unless the
  project says otherwise.
