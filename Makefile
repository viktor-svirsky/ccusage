APP_NAME = CCUsage
APP_DIR = $(APP_NAME).app
CONTENTS = $(APP_DIR)/Contents
MACOS = $(CONTENTS)/MacOS
INSTALL_DIR = /Applications
VERSION ?= $(shell cat VERSION 2>/dev/null || echo 0.0.0-dev)
# Set PRODUCTION=1 to compile with `-D PRODUCTION`, which tags Sentry events as
# environment=production. The release workflow passes it; local `make build` / `make install`
# leaves it unset so dev-machine errors don't pollute production alert rules.
SWIFT_FLAGS = $(if $(PRODUCTION),-D PRODUCTION,)

.PHONY: build test install uninstall clean generate-icon widget widget-test

generate-icon:
	swiftc -O build-icon.swift -framework Cocoa -o build-icon
	./build-icon
	iconutil -c icns $(APP_NAME).iconset

build: generate-icon
	mkdir -p $(MACOS)
	mkdir -p $(CONTENTS)/Resources
	cp Info.plist $(CONTENTS)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(VERSION)" $(CONTENTS)/Info.plist
	cp $(APP_NAME).icns $(CONTENTS)/Resources/$(APP_NAME).icns
	swiftc -O $(SWIFT_FLAGS) -o $(MACOS)/$(APP_NAME) main.swift -framework Cocoa -framework UserNotifications
	# Ad-hoc sign the full bundle so _CodeSignature/CodeResources exists.
	# Without this step `codesign --verify --deep --strict` fails with
	# "code has no resources but signature indicates they must be present",
	# which breaks auto-update's pre-install signature check (shipped in v1.25.14)
	# and bricked update for every user on v1.25.14/15/16.
	codesign --force --deep --sign - $(APP_DIR)
	# Fail the build immediately if the signature we just produced isn't valid —
	# catches regressions that would re-introduce the same bug.
	codesign --verify --deep --strict $(APP_DIR)

test:
	swiftc -DTESTING -o /tmp/$(APP_NAME)Tests main.swift CCUsageTests.swift -framework Cocoa -framework UserNotifications
	/tmp/$(APP_NAME)Tests

install: build
	cp -R $(APP_DIR) $(INSTALL_DIR)/$(APP_DIR)
	open $(INSTALL_DIR)/$(APP_DIR)

uninstall:
	pkill -f $(APP_NAME) 2>/dev/null || true
	rm -rf $(INSTALL_DIR)/$(APP_DIR)

widget-test:
	swiftc -DTESTING -o /tmp/CCUsageWidgetTests \
		CCUsageWidget/CCUsageWidgetApp/SharedModels.swift \
		CCUsageWidget/CCUsageWidgetApp/WidgetProjection.swift \
		CCUsageWidget/CCUsageWidgetApp/WidgetSentry.swift \
		CCUsageWidget/CCUsageWidgetApp/DataService.swift \
		CCUsageWidget/CCUsageWidgetApp/NotificationService.swift \
		CCUsageWidget/WidgetTests.swift
	/tmp/CCUsageWidgetTests

widget:
	rm -rf /tmp/CCUsageWidget.xcarchive /tmp/CCUsageIPA
	xcodebuild -project CCUsageWidget/CCUsageWidget.xcodeproj \
		-scheme CCUsageWidgetApp \
		-configuration Release \
		-archivePath /tmp/CCUsageWidget.xcarchive \
		archive \
		CODE_SIGN_IDENTITY=- \
		CODE_SIGNING_ALLOWED=NO \
		MARKETING_VERSION=$(VERSION) \
		CURRENT_PROJECT_VERSION=$(VERSION) \
		SWIFT_ACTIVE_COMPILATION_CONDITIONS='$$(inherited) PRODUCTION'
	mkdir -p /tmp/CCUsageIPA/Payload
	cp -r /tmp/CCUsageWidget.xcarchive/Products/Applications/CCUsageWidgetApp.app /tmp/CCUsageIPA/Payload/
	cd /tmp/CCUsageIPA && zip -r /tmp/CCUsageWidgetApp.ipa Payload/
	@echo "IPA built: /tmp/CCUsageWidgetApp.ipa (v$(VERSION))"

clean:
	rm -rf $(APP_DIR) /tmp/$(APP_NAME)Tests $(APP_NAME).iconset $(APP_NAME).icns build-icon /tmp/CCUsageWidget.xcarchive /tmp/CCUsageIPA
