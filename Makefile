APP := build/ClaudeBar.app
LOG := $(HOME)/Library/Logs/ClaudeBar/claudebar.log

.PHONY: build app run stop logs verify clean

build:
	swift build

app:
	./scripts/make-app.sh

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
