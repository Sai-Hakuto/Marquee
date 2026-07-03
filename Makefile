APP_NAME   = Marquee
BUILD_TYPE = debug
BUILD_DIR  = .build/$(BUILD_TYPE)
APP_BUNDLE = $(APP_NAME).app
RESOURCES_DIR = $(APP_BUNDLE)/Contents/Resources
MACOS_DIR     = $(APP_BUNDLE)/Contents/MacOS

.PHONY: all debug release app run clean

all: app

debug:
	swift build

release:
	swift build -c release
	$(eval BUILD_TYPE := release)
	$(eval BUILD_DIR  := .build/release)

app: debug
	@mkdir -p $(MACOS_DIR)
	@mkdir -p $(RESOURCES_DIR)
	@cp $(BUILD_DIR)/$(APP_NAME) $(MACOS_DIR)/
	@cp Info.plist $(APP_BUNDLE)/Contents/
	@cp assets/images/Marquee-logo-icon.png $(RESOURCES_DIR)/AppIcon.png
	@cp assets/images/Marquee-logo-icon_128.png $(RESOURCES_DIR)/
	@cp assets/images/Marquee-logo-icon_72.png $(RESOURCES_DIR)/
	@cp assets/images/Marquee-logo-icon_64.png $(RESOURCES_DIR)/
	@cp assets/images/Marqee-Title.png $(RESOURCES_DIR)/
	@cp assets/music/*.mp3 $(RESOURCES_DIR)/
	@# Copy SPM-bundled resources if present
	@-cp -rn "$(BUILD_DIR)/Marquee_Marquee.bundle/Contents/Resources/" $(RESOURCES_DIR)/ 2>/dev/null || true
	@# Strip xattr detritus + ad-hoc re-sign so the bundle launches (macOS 26 kills an
	@# invalid-signature bundle with SIGKILL "Code Signature Invalid" on launch).
	@xattr -cr $(APP_BUNDLE)
	@codesign --force --deep --sign - $(APP_BUNDLE) >/dev/null 2>&1 || true
	@echo "✓ Built $(APP_BUNDLE)"

run: app
	@open $(APP_BUNDLE)

clean:
	@rm -rf .build $(APP_BUNDLE)
	@echo "✓ Cleaned"
