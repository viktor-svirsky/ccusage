APP_NAME = CCUsage
APP_DIR = $(APP_NAME).app
CONTENTS = $(APP_DIR)/Contents
MACOS = $(CONTENTS)/MacOS
INSTALL_DIR = /Applications
VERSION ?= 0.0.0-dev

.PHONY: build test install uninstall clean

build:
	mkdir -p $(MACOS)
	sed 's/<string>1.0<\/string>/<string>$(VERSION)<\/string>/' Info.plist > $(CONTENTS)/Info.plist
	swiftc -O -o $(MACOS)/$(APP_NAME) main.swift -framework Cocoa

test:
	swiftc -DTESTING -o /tmp/$(APP_NAME)Tests main.swift CCUsageTests.swift -framework Cocoa
	/tmp/$(APP_NAME)Tests

install: build
	cp -R $(APP_DIR) $(INSTALL_DIR)/$(APP_DIR)
	open $(INSTALL_DIR)/$(APP_DIR)

uninstall:
	pkill -f $(APP_NAME) 2>/dev/null || true
	rm -rf $(INSTALL_DIR)/$(APP_DIR)

clean:
	rm -rf $(APP_DIR) /tmp/$(APP_NAME)Tests
