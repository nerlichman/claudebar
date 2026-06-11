APP := build/ClaudeBar.app
LOG := $(HOME)/Library/Logs/ClaudeBar/claudebar.log

.PHONY: build app dmg run stop logs verify clean

build:
	swift build

app:
	./scripts/make-app.sh

# Drag-to-Applications disk image. Note: without Developer ID signing +
# notarization, recipients must approve the app once via System Settings >
# Privacy & Security > "Open Anyway".
dmg: app
	rm -rf build/dmg
	mkdir -p build/dmg
	ditto $(APP) build/dmg/ClaudeBar.app
	ln -s /Applications build/dmg/Applications
	hdiutil create -volname ClaudeBar -srcfolder build/dmg -ov -format UDZO build/ClaudeBar.dmg
	rm -rf build/dmg

install-hook:
	mkdir -p "$(HOME)/Library/Application Support/ClaudeBar"
	cp scripts/statusline-hook.sh "$(HOME)/Library/Application Support/ClaudeBar/statusline-hook.sh"
	cp scripts/claudebar-hook.sh "$(HOME)/Library/Application Support/ClaudeBar/claudebar-hook.sh"
	chmod +x "$(HOME)/Library/Application Support/ClaudeBar/statusline-hook.sh" "$(HOME)/Library/Application Support/ClaudeBar/claudebar-hook.sh"

run: app stop
	sleep 1
	open $(APP)

install: app stop
	sleep 1
	ditto $(APP) "$(HOME)/Applications/ClaudeBar.app"
	open "$(HOME)/Applications/ClaudeBar.app"

stop:
	-pkill -x ClaudeBar 2>/dev/null || true

logs:
	tail -f $(LOG)

verify:
	./scripts/verify.sh

clean:
	rm -rf .build build
