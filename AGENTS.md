# AGENTS.md

## What this is

`KeeneticTray` — a macOS menu-bar app (single Swift file, no Xcode project, no package
manager) that manages per-client connection-policy bindings on a Keenetic Hero 4G+ router
(192.168.1.1) via the router's RCI HTTP API.

## Commands

- Build & run: `make build && ./dist/KeeneticTray`
- Bundle / install: `make bundle` (→ `dist/KeeneticTray.app`), `make install` (→ `/Applications/KeeneticTray.app`)
- No tests, no lint, no CI. `swiftc` warnings are the only verification (a `CC_MD5`
  deprecation warning is expected — the router protocol requires MD5).

## Layout

- `main.swift` (repo root) — the entire app: `Router` (NDMS auth + HTTP), menu-bar UI,
  settings modal. Entry point is the bottom `// MARK: - main` block.
- `Info.plist` — app-bundle metadata (`LSUIElement = true`, so no Dock icon).
- `com.keenetic.tray.plist` — launchd autostart template (optional alternative to a login
  item); bundled into the app's `Resources/`.
- `media/router.svg` — source of the menu-bar icon; the app uses an embedded base64 PNG
  (`routerIconPNGBase64` in `main.swift`), so the binary needs no resource files.
  `media/AppIcon.icns` is the app-bundle icon shown in Finder.
  Gotcha: macOS's SVG renderer paints the SVG's trailing `<rect ... fill-opacity="0">`
  opaque, so a direct SVG render is a solid square. Regenerate by dropping that rect,
  rendering the glyph on white, converting `alpha = 255 - luminance` (RGB 0), then base64.
- `com.keenetic.tray.plist` — optional launchd autostart; copy to
  `~/Library/LaunchAgents/` and `launchctl load` it (not wired by default).
- `wiki/` — session knowledge base (one page per session in `wiki/pages/`, index in
  `wiki/INDEX.md`). Use `/wiki-sync` to record work; conventions in `wiki/README.md`.
- `sk.toml` / `sk.lock` — skills manifest (wiki + code-review skills); installed copies live
  in `.agents/skills/` and `.opencode/skills/`. Not part of the app build.

## Router API facts (learned the hard way)

- Auth is challenge-response: `GET /auth` → `X-Ndm-Realm` / `X-Ndm-Challenge` headers,
  then `POST /auth` with `password = sha256(challenge + md5(login:realm:password))`.
- `URLSession` persists the session cookie (5-min life) — a subsequent `GET /auth` can
  return 200 instead of 401. Treat 200 as success, and re-authenticate + retry once on
  any non-200 (`authed = false` in `Router`).
- `POST /rci/ip/hotspot/host` body `{"mac": ..., "policy": "Policy0"}` sets a client's
  policy; `{"mac": ..., "policy": false}` restores the default. Clients list:
  `GET /rci/show/ip/hotspot`; policies: `GET /rci/show/ip/policy` (`Policy0` = "Only ADSL").
- Empty-string `policy` in the hotspot listing means the segment default.

## Credentials

Never hardcode the router password. It is read from Keychain:
`security add-generic-password -U -a admin -s keenetic-router -w '<password>'`
(service `keenetic-router`, account `admin`).

## Conventions

- `allowedClients` (UserDefaults key) filters which clients appear in the menu; empty = show all.
- Tray icon is a template image (adapts to dark/light menu bar); on router error it
  falls back to `⚠️` text and logs to stderr.
