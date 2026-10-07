---
title: Keenetic Tray menu-bar app
date: 2026-10-07
type: implementation
status: resolved
session_id: ses_eeb35e11affeqIx1jaHSWYFbA8
services: [keenetic-router]
branch: -
tickets: []
tags: [keenetic, menu-bar, swift, rci-api, macos]
related: []
---

# Keenetic Tray menu-bar app

## TL;DR

Built a macOS menu-bar app (`main.swift`) that lists Keenetic Hero 4G+ clients
and lets you rebind each client's connection policy (default ↔ "Only ADSL") via the router's
RCI REST API. Added a settings modal to filter visible clients, embedded a template tray
icon, and fixed a recurring "auth failed" bug caused by the persisted session cookie.

---

## Overview

**File:** `main.swift`

The app is a single-file Swift binary (`make build` → `dist/KeeneticTray`)
that runs as an `.accessory` NSApplication with an `NSStatusItem` menu.

- Auth: `GET /auth` → 401 with `X-Ndm-Realm` / `X-Ndm-Challenge` headers, then
  `POST /auth {"login": ..., "password": sha256(challenge + md5(login:realm:password))}`.
- Clients: `GET /rci/show/ip/hotspot` → `host[]` with `mac`, `name`, `hostname`, `policy`
  (`""` = default segment policy), `active`.
- Policies: `GET /rci/show/ip/policy` → e.g. `Policy0` = `"Only ADSL"`, bound via
  `ip hotspot` → `host <mac> policy Policy0` (running-config confirms this mapping).
- Set policy: `POST /rci/ip/hotspot/host {"mac": ..., "policy": "Policy0"}`;
  reset to default: `{"mac": ..., "policy": false}`.
- Password stored in macOS Keychain (service `keenetic-router`, account `admin`):
  `security add-generic-password -U -a admin -s keenetic-router -w '<password>'`.

Menu structure: each client is a submenu with "Default policy" + each policy description,
the current one checkmarked; plus Settings…, Refresh, Quit. Clients polled every 60 s.

## Settings modal

**File:** `main.swift` — `openSettings()`, `allowedClients()`, filter in `menuWillOpen`.

NSAlert with an `NSTextField` accessory; comma-separated client names (matched against
`name` and `hostname`, case-insensitive), stored in `UserDefaults` key `allowedClients`.
Empty list shows all clients. Other clients are hidden from the menu.

## Tray icon

The SVG source lives at `media/router.svg` but is **embedded** in `main.swift` as a base64
template PNG (`routerIconPNGBase64`); `trayIcon()` decodes it, sets 18×18 pt and
`isTemplate = true` so it adapts to light/dark menu bar. No resource files next to the
binary are required. Falls back to `⌁` text; becomes `⚠️` while the router is unreachable.

## Debug — "auth failed" on refresh

**Symptom:** Refresh in the menu showed an error starting with "auth failed".

**Root cause:** `URLSession.shared` persists the session cookie (`kvMoN8yMN`, 5-min lifetime)
in its shared cookie storage, so `GET /auth` returned **200** (already logged in) instead of
401 + challenge headers. The app required 401, so it threw `E.authFailed`.

**Fix:**
1. In `login()`, a 200 from `GET /auth` is now treated as "already authenticated".
2. `get()`/`post()` now reset the `authed` flag and re-run the full login + retry once on
   any non-200 response, covering session expiry mid-run.
3. Debug lines written to stderr (captured in `/tmp/keenetic_tray.log`) that made the
   failing branch identifiable.

**Test results:** after the fix, no errors in `/tmp/keenetic_tray.log`; refresh works.

## Test Results

- `swiftc -O` builds clean (only a `CC_MD5` deprecation warning, acceptable — required by router protocol).
- Router API verified directly with Python before coding (auth, hotspot list, policy list).
- Live probe: `GET /rci/ip/hotspot/host` returns 200; 15 of 30 clients carry `Policy0`.

---

## Update — 2026-10-07

**Refactor:** app files moved to repo root — `main.swift`, `media/router.svg`,
`com.keenetic.tray.plist`, `Makefile`. Build is now `make build && ./dist/KeeneticTray`
(binary in `dist/`). `make build` had been stale (referenced `main.swift` from the
old `KeeneticTray/` dir); fixed, and the earlier `cp -R media dist/` step was dropped once
the icon became embedded. Docs updated: `AGENTS.md`, `README.md`.

**Embedded icon:** the SVG is embedded in `main.swift` as base64 so the binary needs no
resource files. `trayIcon()` decodes it → `NSImage` → 18 pt → `isTemplate = true`.

**Debug — white square instead of the router icon (3 attempts):**

1. *File lookup:* icon was resolved relative to `CommandLine.arguments[0]` as
   `media/router.svg`, so `dist/KeeneticTray` found nothing → text fallback. Motivated the
   embed.
2. *SVG string → NSImage:* rendered as an opaque block. `NSImage(data:)` for SVG reports
   `Alpha=NO`, and drawing the SVG into an offscreen bitmap painted everything opaque.
   Also removed the unused `attempt` loop variable warning.
3. *Quick Look PNG:* `qlmanage -t -s 64` produced a PNG whose background was **opaque white**
   (`colorAt(0,0)` = `1 1 1 1`) → still a square.

**Root cause:** the SVG's trailing
`<rect x="0" y="0" width="36" height="36" fill-opacity="0"/>` — the macOS SVG renderer
ignores `fill-opacity="0"` and paints that full-canvas rect opaque (it inherits
`fill="#000000"` from the root), so every render was a filled square.

**Fix:** strip that rect, render the glyph on white, convert luminance → alpha
(`alpha = 255 - luminance`, RGB = 0) into a transparent template PNG, and embed that PNG's
base64 in `main.swift`. Verified corner alpha `0`, disk alpha `255`; composited over
green/black/white it draws the router disk with transparent arrow cutouts.

**Test results:** `make build` clean (only the `CC_MD5` deprecation warning); app runs from
`dist/KeeneticTray`. Icon regeneration recipe if `media/router.svg` changes: remove the
transparent `<rect>`, render, luminance→alpha, then `base64`.

---

## Follow-ups

- Optional: launchd autostart (`com.keenetic.tray.plist` written, not loaded).
- Multiple policies beyond "Only ADSL" will appear automatically once added on the router.

## References

- Related: none yet
- External: https://forum.keenetic.com/topic/14285-delete-setting-via-http-api/
