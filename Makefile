APP_NAME = Touchbar Brightness Control
APP_BUNDLE = $(APP_NAME).app
APP_TARGET = Touchbar\ Brightness\ Control.app
MACOS_DIR = $(APP_BUNDLE)/Contents/MacOS
RES_DIR = $(APP_BUNDLE)/Contents/Resources
ZIP_NAME = Touchbar-Brightness-Control-macOS-Universal.zip

all: $(APP_TARGET)

$(APP_TARGET): TouchbarBrightnessControl.m Info.plist AppIcon.icns
	mkdir -p "$(MACOS_DIR)" "$(RES_DIR)"
	cp Info.plist "$(APP_BUNDLE)/Contents/Info.plist"
	cp AppIcon.icns "$(RES_DIR)/AppIcon.icns"
	clang -O2 -fobjc-arc -arch arm64 -arch x86_64 TouchbarBrightnessControl.m \
		-framework Cocoa -framework CoreGraphics -framework ServiceManagement \
		-mmacosx-version-min=12.0 \
		-o "$(MACOS_DIR)/$(APP_NAME)"
	codesign --force --deep --sign - "$(APP_BUNDLE)"

release: all
	ditto -c -k --keepParent "$(APP_BUNDLE)" "$(ZIP_NAME)"

clean:
	rm -rf "$(APP_BUNDLE)" "$(ZIP_NAME)"
