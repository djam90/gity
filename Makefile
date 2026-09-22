.PHONY: app debug run test icon clean

app:            ## Release build of build/Gity.app
	scripts/build-app.sh release

debug:          ## Debug build (enables GITY_SNAPSHOT_DIR window snapshots)
	scripts/build-app.sh debug

run: debug
	open build/Gity.app

test:
	swift test

icon:
	rm -f Resources/AppIcon.icns && scripts/make-icon.sh

clean:
	rm -rf build .build
