APP := build/ClaudeBar.app
LOG := $(HOME)/Library/Logs/ClaudeBar/claudebar.log

.PHONY: build app dmg dist appcast run stop logs verify clean

build:
	swift build

app:
	./scripts/make-app.sh

# Drag-to-Applications disk image. Unsigned/dev-signed: recipients must
# approve the app once via System Settings > Privacy & Security > "Open
# Anyway". For a notarized image distributable to anyone, use `make dist`.
dmg: app
	./scripts/make-dmg.sh

# Signed + notarized + stapled DMG ready for public distribution. Requires a
# Developer ID identity and a notarytool keychain profile — see scripts/dist.sh.
#   CODESIGN_IDENTITY="Developer ID Application: Your Co (TEAMID)" make dist
dist:
	./scripts/dist.sh

# Regenerate the Sparkle update feed (appcast.xml) from the DMGs in
# appcast-archives/, signing each with the EdDSA key in your Keychain. Run after
# `make dist` + staging the new DMG. See scripts/appcast.sh for the full flow.
appcast:
	./scripts/appcast.sh

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
