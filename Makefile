APP_NAME = Touchbar Brightness Control
APP_BUNDLE = $(APP_NAME).app
MACOS_DIR = $(APP_BUNDLE)/Contents/MacOS
ZIP_NAME = Touchbar-Brightness-Control-macOS-Universal.zip

all: $(APP_BUNDLE)

$(APP_BUNDLE): TouchbarBrightnessControl.m Info.plist
	mkdir -p "$(MACOS_DIR)"
	cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	clang -O2 -fobjc-arc -arch arm64 -arch x86_64 TouchbarBrightnessControl.m \
		-framework Cocoa -framework CoreGraphics \
		-mmacosx-version-min=12.0 \
		-o "$(MACOS_DIR)/$(APP_NAME)"
	codesign --force --deep --sign - "$(APP_BUNDLE)"

release: all
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(ZIP_NAME)"

clean:
	rm -rf "$(APP_BUNDLE)" "$(ZIP_NAME)"
