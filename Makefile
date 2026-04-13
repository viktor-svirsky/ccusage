APP_NAME = CCUsage
APP_DIR = $(APP_NAME).app
CONTENTS = $(APP_DIR)/Contents
MACOS = $(CONTENTS)/MacOS
INSTALL_DIR = /Applications
VERSION ?= $(shell cat VERSION 2>/dev/null || echo 0.0.0-dev)

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
	swiftc -O -o $(MACOS)/$(APP_NAME) main.swift -framework Cocoa -framework UserNotifications

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
		CCUsageWidget/CCUsageWidgetApp/DataService.swift \
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
		CURRENT_PROJECT_VERSION=$(VERSION)
	mkdir -p /tmp/CCUsageIPA/Payload
	cp -r /tmp/CCUsageWidget.xcarchive/Products/Applications/CCUsageWidgetApp.app /tmp/CCUsageIPA/Payload/
	cd /tmp/CCUsageIPA && zip -r /tmp/CCUsageWidgetApp.ipa Payload/
	@echo "IPA built: /tmp/CCUsageWidgetApp.ipa (v$(VERSION))"

clean:
	rm -rf $(APP_DIR) /tmp/$(APP_NAME)Tests $(APP_NAME).iconset $(APP_NAME).icns build-icon /tmp/CCUsageWidget.xcarchive /tmp/CCUsageIPA
