# Keenetic Tray

Menu-bar app for macOS that shows clients of your Keenetic Hero 4G+ (192.168.1.1)
and lets you bind each client to a connection policy (e.g. "Only ADSL") or back
to the default policy, via the router's RCI API.

## Usage

Click the `⌁` icon in the menu bar → pick a client → choose a policy
("Default policy" restores the segment's default binding).

- Client list is polled from the router every 60 s (and on open/Refresh).
- Current policy of each client is shown with a checkmark.
- Offline clients are marked `(offline)`.
- **Settings…**: comma-separated list of client names to show; all others are hidden
  (empty = show everyone). Stored in `UserDefaults` key `allowedClients`.

## Credentials

The router admin password is read from the macOS Keychain (service `keenetic-router`,
account `admin`). To (re)set it:

```sh
security add-generic-password -U -a admin -s keenetic-router -w 'Dis1exia'
```

## Build & run

```sh
make build
./dist/KeeneticTray
```

## Install to Applications

```sh
make install          # builds KeeneticTray.app into dist/ and copies it to /Applications
open -a KeeneticTray  # or launch it from Finder
```

## Run at login

Register the app as a login item (shows up in System Settings → General → Login Items):

```sh
osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/KeeneticTray.app", hidden:true}'
```

Remove it again with:

```sh
osascript -e 'tell application "System Events" to delete login item "KeeneticTray"'
```

Alternative (launchd): `com.keenetic.tray.plist` is bundled in
`KeeneticTray.app/Contents/Resources/`; replace its `__DIR__` with
`/Applications/KeeneticTray.app/Contents/MacOS`, write it to `~/Library/LaunchAgents/`
and `launchctl load` it.


