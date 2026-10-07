build:
	swiftc -O -o ./dist/KeeneticTray main.swift -framework Cocoa

bundle: build
	rm -rf ./dist/KeeneticTray.app
	mkdir -p ./dist/KeeneticTray.app/Contents/MacOS ./dist/KeeneticTray.app/Contents/Resources
	cp ./dist/KeeneticTray ./dist/KeeneticTray.app/Contents/MacOS/KeeneticTray
	cp Info.plist ./dist/KeeneticTray.app/Contents/Info.plist
	cp media/AppIcon.icns ./dist/KeeneticTray.app/Contents/Resources/AppIcon.icns
	cp media/router.svg ./dist/KeeneticTray.app/Contents/Resources/router.svg
	cp com.keenetic.tray.plist ./dist/KeeneticTray.app/Contents/Resources/com.keenetic.tray.plist

install: bundle
	rm -rf /Applications/KeeneticTray.app
	cp -R ./dist/KeeneticTray.app /Applications/KeeneticTray.app
