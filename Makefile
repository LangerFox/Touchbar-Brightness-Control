APP_NAME = TouchBarBright
APP_BUNDLE = $(APP_NAME).app
MACOS_DIR = $(APP_BUNDLE)/Contents/MacOS

all: $(APP_BUNDLE)

$(APP_BUNDLE): TouchBarBright.m Info.plist
	mkdir -p $(MACOS_DIR)
	cp Info.plist $(APP_BUNDLE)/Contents/Info.plist
	clang -O2 -fobjc-arc -arch arm64 -arch x86_64 TouchBarBright.m \
		-framework Cocoa -framework CoreGraphics \
		-mmacosx-version-min=12.0 \
		-o $(MACOS_DIR)/$(APP_NAME)
	codesign --force --deep --sign - $(APP_BUNDLE)

release: all
	ditto -c -k --keepParent $(APP_BUNDLE) $(APP_NAME)-macOS-Universal.zip

clean:
	rm -rf $(APP_BUNDLE) $(APP_NAME)-macOS-Universal.zip
