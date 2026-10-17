---
name: ux-audit
description: Audits the app's UX and accessibility on the emulator, screen by screen and under each display, language and state condition, then reports findings with screenshots and fixes the clear ones. Use after changes to screens, navigation or strings, before a release, or when asked for a UX or accessibility review.
---

# UX audit

Drive the real app on the emulator.

## 1. Prepare

- Install a debug build. For pseudo-locales, the debug build type needs
  `isPseudoLocalesEnabled = true` (Gradle) first.
- List the screens and the ways to reach each one, from the navigation code.
- Record the emulator's settings this audit changes, so step 5 can put them
  back: `settings get system font_scale`, `wm size`, `wm density`,
  `cmd uimode night`, `settings get system accelerometer_rotation`,
  `settings get system user_rotation`, `settings get global debug.force_rtl`.
- Save screenshots (`adb exec-out screencap -p > <file>.png`) in a
  directory outside the repository, named by screen and condition.

## 2. Conditions

Go through each screen under each condition. Split screens or conditions
among parallel subagents when there are many, but only one may drive the
emulator at a time: give the others screenshots and UI dumps to review.

1. **Accessibility.** `uiautomator dump` each screen. Every clickable node
   has a label (text or content-desc) that says what it does, bounds are at
   least 48 dp in both directions (px / (density / 160)), and the reading
   order makes sense. Check contrast from the screenshots: 4.5:1 for text,
   3:1 for large text and icons.
2. **Font scale and display size.** `settings put system font_scale 2.0`,
   then `wm density` at the largest display size. Nothing clips, overlaps
   or truncates what matters, and scrolling reaches everything.
3. **Dark and light.** `cmd uimode night yes` and `no`. Every color comes
   from the theme, and nothing disappears in either.
4. **Languages and right-to-left.** `cmd locale set-app-locales <package>
   --locales en-XA` (long text) and `ar-XB` (right-to-left), or
   `settings put global debug.force_rtl 1` and restart the app. No
   hard-coded strings, nothing mirrored that shouldn't be, nothing cut off.
5. **Rotation and window size.** `settings put system accelerometer_rotation
   0` and `user_rotation 1`, then a tablet size (`wm size 2560x1600`,
   `wm density 320`). Layouts adapt, and state survives.
6. **Process death.** Fill in a screen, press Home, `am kill <package>`,
   then return through recents. What the user entered and where they were
   come back.
7. **Insets and keyboard.** Content stays clear of the status and
   navigation bars and the display cutout, and focused fields stay visible
   above the keyboard.
8. **States.** Loading, empty, error and offline (`cmd connectivity
   airplane-mode enable`) for every screen that loads data. Each says what
   happened and what the user can do.
9. **Navigation.** Back and predictive back go where users expect, nothing
   loops, and deep links land on the right screen with a sensible back
   stack.

After every tap or command, confirm it landed (a fresh dump or screenshot)
before moving on, and close any dialog you opened.

## 3. Verify

Look at each finding again in a clean state (relaunch, default settings
plus only the one condition). Drop the ones you can't reproduce.

## 4. Report and fix

- Report findings by screen, most severe first: what's wrong, under which
  condition, the screenshot, and the fix. Severity: blocks a task, hurts a
  group of users (accessibility, a language), or polish.
- Fix the clear ones (missing labels, hard-coded strings or colors, small
  targets, missing insets), each in its own commit, following the review
  rules. Leave design decisions to the user, with screenshots.

## 5. Restore

Put back every setting recorded in step 1, plus `wm size reset`,
`wm density reset`, `cmd connectivity airplane-mode disable` and the app's
locales (`cmd locale set-app-locales <package> --locales ""`). Check that
the emulator looks as it did before.
