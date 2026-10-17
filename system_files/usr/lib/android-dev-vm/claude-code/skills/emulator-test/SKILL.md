---
name: emulator-test
description: Runs targeted agentic tests of the real app on the Android emulator over adb, exercising exactly the behavior that changed and its edge cases, and checking the outcome from system state, not only screenshots. Use after each larger batch of work, after a fix to something only visible on a device, or when asked to test on the emulator.
---

# Agentic tests on the emulator

Unit and instrumented tests check what someone thought to write down. This
checks the change the way a user meets it.

## 1. Plan

- From the diff (or the batch's commits), list the behaviors that changed
  and their edge cases: first run, empty data, permission denied and
  granted, rotation, going to the background and back, process death, no
  network, and anything the change's own logic branches on.
- For each one, decide how to observe the result from system state, not
  only the screen:
  - the top activity: `dumpsys activity activities | grep -E 'topResumed|mResumed'`
  - windows, including overlays: `dumpsys window windows`
  - settings the app writes: `settings get <namespace> <key>`
  - the app's files and preferences: `run-as <package> ls`, `run-as
    <package> cat shared_prefs/<file>.xml` (debug builds)
  - services, jobs and alarms: `dumpsys activity services <package>`,
    `dumpsys jobscheduler`, `dumpsys alarm`
  - notifications: `dumpsys notification --noredact`
  - logs: `logcat -d --pid=$(pidof <package>)`, cleared first with
    `logcat -c`

## 2. Run

- Drive the app with `input tap`, `input text`, `input keyevent` and
  `am start`. Find coordinates with `uiautomator dump` and
  `adb exec-out screencap -p`. Windows of type
  `TYPE_ACCESSIBILITY_OVERLAY` and some system dialogs don't appear in the
  dump, so find those in screenshots.
- After every action, confirm it landed (a fresh dump, screenshot or state
  check) before the next one. Close any dialog you opened.
- Flutter: run the project's `integration_test` suite with
  `flutter test integration_test -d <serial>` first, then drive the app the
  same way for what it doesn't cover.
- Watch logcat for crashes, ANRs and StrictMode violations during the run,
  even when the screen looks fine.

## 3. Report

- For each behavior: what you did, what you expected, what system state
  showed, and pass or fail, with the evidence (command output or
  screenshot).
- A failure gets a reproduction: the shortest list of commands from a fresh
  install. If the cause is clear, write a failing test for it before
  fixing.

## 4. Clean up

Put the emulator back the way you found it: settings you changed,
permissions you granted (`pm revoke`), the app's data if you cleared it, and
anything else the test touched. Leave the app installed in the state the
user had it, or reinstall it.
