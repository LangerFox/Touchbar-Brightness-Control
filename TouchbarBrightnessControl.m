#import <Cocoa/Cocoa.h>
#import <ServiceManagement/ServiceManagement.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <sys/xattr.h>

static const float kMinNits = 11.9f;
static const float kMaxNits = 357.1f;
static const CFTimeInterval kSelfWriteIgnoreWindow = 0.25;
static const CFTimeInterval kMinRetryInterval = 0.50;
static const CFTimeInterval kBurstWindowDuration = 5.0;
static const NSInteger kMaxBurstCount = 3;

typedef CFURLRef (*SecTranslocateCreateOriginalPathForURLFn)(CFURLRef translocatedPath, CFErrorRef *error);

@interface NSObject (CoreBrightnessPrivate)
- (id)copyPropertyForKey:(id)key;
- (BOOL)setProperty:(id)prop forKey:(id)key;
- (void)registerNotificationBlock:(void (^)(id key, id val))block;
- (void)registerNotificationBlock:(void (^)(id key, id val))block forProperties:(NSArray *)props;
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property (strong) NSStatusItem *statusItem;
@property (strong) NSMenu *menu;
@property (strong) NSTextField *valueLabel;
@property (strong) NSSlider *slider;
@property (strong) NSMenuItem *wakeGuardItem;
@property (strong) NSMenuItem *loginItem;
@property (strong) id bscClient;
@property (assign) float targetBrightness;
@property (assign) BOOL wakeGuardEnabled;
@property (assign) BOOL screensSleeping;
@property (assign) CFAbsoluteTime lastApplyTime;
@property (assign) CFAbsoluteTime lastAutoRestoreTime;
@property (assign) CFAbsoluteTime burstWindowStart;
@property (assign) NSInteger burstCount;
@end

static void displayReconfigCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo);

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY);
    Class bscCls = objc_getClass("BrightnessSystemClient");
    if (bscCls) {
        self.bscClient = [[bscCls alloc] init];
    }

    // If Launch at Login was already enabled, keep its path synced with the real (non-translocated) bundle path
    [self syncLaunchAgentPathIfNeeded];

    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if ([defs objectForKey:@"TargetBrightness"] != nil) {
        self.targetBrightness = [defs floatForKey:@"TargetBrightness"];
    } else {
        NSDictionary *cur = [self.bscClient copyPropertyForKey:@"DisplayBrightness"];
        NSNumber *curNum = [cur isKindOfClass:[NSDictionary class]] ? cur[@"Brightness"] : nil;
        float curB = curNum ? [curNum floatValue] : 0.50f;
        if (curB <= 0.01f) curB = 0.50f;
        self.targetBrightness = curB;
    }

    if ([defs objectForKey:@"WakeGuardEnabled"] != nil) {
        self.wakeGuardEnabled = [defs boolForKey:@"WakeGuardEnabled"];
    } else {
        self.wakeGuardEnabled = YES;
    }

    [self setupStatusItem];
    [self applyBrightness:self.targetBrightness save:YES];
    [self setupEventDrivenWakeObservers];
}

- (void)setupStatusItem {
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSStatusBarButton *btn = self.statusItem.button;
    NSImage *img = [NSImage imageWithSystemSymbolName:@"slider.horizontal.below.rectangle"
                             accessibilityDescription:@"Touchbar Brightness Control"];
    if (!img) {
        img = [NSImage imageWithSystemSymbolName:@"sun.max.fill"
                        accessibilityDescription:@"Touchbar Brightness Control"];
    }
    if (img) {
        [img setTemplate:YES];
        btn.image = img;
    } else {
        btn.title = @"TB";
    }
    btn.toolTip = @"Touchbar Brightness Control";

    self.menu = [[NSMenu alloc] initWithTitle:@"Touchbar Brightness Control"];
    self.menu.delegate = self;
    self.menu.autoenablesItems = NO;

    NSView *panel = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 112)];

    NSTextField *titleLabel = [NSTextField labelWithString:@"Touchbar Brightness"];
    titleLabel.font = [NSFont boldSystemFontOfSize:12.5];
    titleLabel.frame = NSMakeRect(16, 84, 228, 18);
    [panel addSubview:titleLabel];

    self.valueLabel = [NSTextField labelWithString:@"50% (184.5 Nits)"];
    self.valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
    self.valueLabel.textColor = [NSColor secondaryLabelColor];
    self.valueLabel.alignment = NSTextAlignmentLeft;
    self.valueLabel.frame = NSMakeRect(16, 62, 228, 18);
    [panel addSubview:self.valueLabel];

    self.slider = [NSSlider sliderWithValue:self.targetBrightness
                                   minValue:0.0
                                   maxValue:1.0
                                     target:self
                                     action:@selector(sliderChanged:)];
    self.slider.continuous = YES;
    self.slider.frame = NSMakeRect(16, 36, 228, 22);
    [panel addSubview:self.slider];

    NSArray<NSNumber *> *presets = @[@0.0, @0.25, @0.50, @0.75, @1.0];
    NSArray<NSString *> *titles  = @[@"Min", @"25%", @"50%", @"75%", @"Max"];
    CGFloat btnW = 42.0;
    CGFloat gap = 4.5;
    for (NSUInteger i = 0; i < presets.count; i++) {
        NSButton *pBtn = [NSButton buttonWithTitle:titles[i] target:self action:@selector(presetClicked:)];
        pBtn.bezelStyle = NSBezelStyleRounded;
        pBtn.controlSize = NSControlSizeSmall;
        pBtn.font = [NSFont systemFontOfSize:10.5];
        pBtn.tag = (NSInteger)([presets[i] floatValue] * 100.0f);
        pBtn.frame = NSMakeRect(16 + i * (btnW + gap), 6, btnW, 22);
        [panel addSubview:pBtn];
    }

    NSMenuItem *sliderItem = [[NSMenuItem alloc] init];
    sliderItem.view = panel;
    [self.menu addItem:sliderItem];

    [self.menu addItem:[NSMenuItem separatorItem]];

    self.wakeGuardItem = [[NSMenuItem alloc] initWithTitle:@"Lock Brightness on Lid Wake (Broken ALS)"
                                                    action:@selector(toggleWakeGuard:)
                                             keyEquivalent:@""];
    self.wakeGuardItem.target = self;
    self.wakeGuardItem.state = self.wakeGuardEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [self.menu addItem:self.wakeGuardItem];

    self.loginItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                action:@selector(toggleLaunchAtLogin:)
                                         keyEquivalent:@""];
    self.loginItem.target = self;
    self.loginItem.state = [self isLaunchAgentInstalled] ? NSControlStateValueOn : NSControlStateValueOff;
    [self.menu addItem:self.loginItem];

    [self.menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit Touchbar Brightness Control"
                                                      action:@selector(terminate:)
                                               keyEquivalent:@"q"];
    quitItem.target = NSApp;
    [self.menu addItem:quitItem];

    self.statusItem.menu = self.menu;
}

- (void)updateValueLabelFromHardwareOrFallback:(float)fallbackVal {
    float actualB = fallbackVal;
    float nits = kMinNits + fallbackVal * (kMaxNits - kMinNits);

    if (self.bscClient) {
        id raw = [self.bscClient copyPropertyForKey:@"DisplayBrightness"];
        if ([raw isKindOfClass:[NSDictionary class]]) {
            NSDictionary *cur = (NSDictionary *)raw;
            NSNumber *nitsNum = cur[@"Nits"];
            NSNumber *bNum = cur[@"Brightness"];
            if ([nitsNum isKindOfClass:[NSNumber class]]) {
                nits = [nitsNum floatValue];
                actualB = (nits - kMinNits) / (kMaxNits - kMinNits);
            } else if ([bNum isKindOfClass:[NSNumber class]]) {
                actualB = [bNum floatValue];
                nits = kMinNits + actualB * (kMaxNits - kMinNits);
            }
        }
    }

    if (actualB < 0.0f) actualB = 0.0f;
    if (actualB > 1.0f) actualB = 1.0f;

    self.valueLabel.stringValue = [NSString stringWithFormat:@"%.0f%% (%.1f Nits)", actualB * 100.0f, nits];
}

- (void)menuWillOpen:(NSMenu *)menu {
    [self updateValueLabelFromHardwareOrFallback:self.targetBrightness];
    self.loginItem.state = [self isLaunchAgentInstalled] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)sliderChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.targetBrightness = val;
    self.burstCount = 0;
    [self applyBrightness:val save:YES];
}

- (void)presetClicked:(NSButton *)sender {
    float val = (float)sender.tag / 100.0f;
    self.targetBrightness = val;
    self.slider.floatValue = val;
    self.burstCount = 0;
    [self applyBrightness:val save:YES];
}

- (void)applyBrightness:(float)val save:(BOOL)save {
    if (val < 0.0f) val = 0.0f;
    if (val > 1.0f) val = 1.0f;

    // Record timestamp BEFORE and AFTER writing so async XPC echo callbacks within 0.25s are ignored
    self.lastApplyTime = CFAbsoluteTimeGetCurrent();
    if (self.bscClient) {
        [self.bscClient setProperty:@NO forKey:@"DisplayBrightnessAuto"];
        [self.bscClient setProperty:@(val) forKey:@"DisplayBrightness"];
    }
    self.lastApplyTime = CFAbsoluteTimeGetCurrent();

    [self updateValueLabelFromHardwareOrFallback:val];

    if (save) {
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        [defs setFloat:val forKey:@"TargetBrightness"];
    }
}

- (void)attemptAutoRestoreIfNeeded {
    if (!self.wakeGuardEnabled || self.screensSleeping || !self.bscClient) return;

    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    // 1. Ignore notifications caused by our own recent write
    if (now - self.lastApplyTime < kSelfWriteIgnoreWindow) return;

    // 2. Minimum interval rate limit (>= 0.5s between auto-restores)
    if (now - self.lastAutoRestoreTime < kMinRetryInterval) return;

    // 3. Check whether hardware brightness actually drifted from targetBrightness
    id raw = [self.bscClient copyPropertyForKey:@"DisplayBrightness"];
    if (![raw isKindOfClass:[NSDictionary class]]) return;
    NSNumber *bNum = ((NSDictionary *)raw)[@"Brightness"];
    if (![bNum isKindOfClass:[NSNumber class]]) return;

    float curB = [bNum floatValue];
    // Allow ~6% tolerance for the 11-step NitsToUserBrightnessTable quantization
    if (fabsf(curB - self.targetBrightness) <= 0.06f) return;

    // 4. Burst limit: at most 3 auto-restores per 5-second window
    if (now - self.burstWindowStart > kBurstWindowDuration) {
        self.burstWindowStart = now;
        self.burstCount = 0;
    }
    if (self.burstCount >= kMaxBurstCount) return;

    self.burstCount++;
    self.lastAutoRestoreTime = now;
    [self applyBrightness:self.targetBrightness save:NO];
}

- (void)restoreOnWakeSequence {
    self.screensSleeping = NO;
    self.burstCount = 0;
    self.burstWindowStart = CFAbsoluteTimeGetCurrent();
    if (!self.wakeGuardEnabled) return;

    [self applyBrightness:self.targetBrightness save:NO];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delayMs in @[@300, @900, @1800]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs.intValue * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf && strongSelf.wakeGuardEnabled && !strongSelf.screensSleeping) {
                [strongSelf applyBrightness:strongSelf.targetBrightness save:NO];
            }
        });
    }
}

- (void)setupEventDrivenWakeObservers {
    __weak typeof(self) weakSelf = self;

    // 1. Pure event-driven CoreBrightness XPC notification with time-window suppression & burst rate-limiting
    void (^cbBlock)(id, id) = ^(id key, id val) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf attemptAutoRestoreIfNeeded];
        });
    };

    if (self.bscClient) {
        if ([self.bscClient respondsToSelector:@selector(registerNotificationBlock:forProperties:)]) {
            [self.bscClient registerNotificationBlock:cbBlock
                                        forProperties:@[@"DisplayBrightness", @"DisplayBrightnessAuto"]];
        } else if ([self.bscClient respondsToSelector:@selector(registerNotificationBlock:)]) {
            [self.bscClient registerNotificationBlock:cbBlock];
        }
    }

    // 2. Track screen/system sleep & wake states so we never fight CoreBrightness while the lid is closed
    NSNotificationCenter *wsnc = [[NSWorkspace sharedWorkspace] notificationCenter];
    NSOperationQueue *mainQ = [NSOperationQueue mainQueue];
    void (^sleepBlock)(NSNotification *) = ^(NSNotification *note) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf) strongSelf.screensSleeping = YES;
    };
    void (^wakeBlock)(NSNotification *) = ^(NSNotification *note) {
        [weakSelf restoreOnWakeSequence];
    };

    [wsnc addObserverForName:NSWorkspaceWillSleepNotification object:nil queue:mainQ usingBlock:sleepBlock];
    [wsnc addObserverForName:NSWorkspaceScreensDidSleepNotification object:nil queue:mainQ usingBlock:sleepBlock];
    [wsnc addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:mainQ usingBlock:wakeBlock];
    [wsnc addObserverForName:NSWorkspaceScreensDidWakeNotification object:nil queue:mainQ usingBlock:wakeBlock];

    // 3. CoreGraphics display reconfiguration callback
    CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, (__bridge void *)self);
}

- (void)toggleWakeGuard:(NSMenuItem *)sender {
    self.wakeGuardEnabled = !self.wakeGuardEnabled;
    sender.state = self.wakeGuardEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [[NSUserDefaults standardUserDefaults] setBool:self.wakeGuardEnabled forKey:@"WakeGuardEnabled"];
    if (self.wakeGuardEnabled) {
        self.burstCount = 0;
        [self applyBrightness:self.targetBrightness save:NO];
    }
}

// Resolve real on-disk .app path even if macOS Gatekeeper launched the app inside /private/var/folders/.../AppTranslocation/
- (NSString *)resolvedRealBundlePath {
    NSURL *bundleURL = [[NSBundle mainBundle] bundleURL];
    NSString *path = [bundleURL path];
    if ([path containsString:@"/AppTranslocation/"]) {
        void *sec = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
        if (sec) {
            SecTranslocateCreateOriginalPathForURLFn fn = (SecTranslocateCreateOriginalPathForURLFn)dlsym(sec, "SecTranslocateCreateOriginalPathForURL");
            if (fn) {
                CFURLRef origRef = fn((__bridge CFURLRef)bundleURL, NULL);
                if (origRef) {
                    NSURL *origURL = CFBridgingRelease(origRef);
                    if ([origURL path]) {
                        path = [origURL path];
                    }
                }
            }
        }
    }
    if (path) {
        // Strip com.apple.quarantine from the real bundle so subsequent launches are never translocated
        removexattr([path fileSystemRepresentation], "com.apple.quarantine", 0);
    }
    return path;
}

- (NSString *)launchAgentLabel {
    return [[NSBundle mainBundle] bundleIdentifier] ?: @"app.touchbar.BrightnessControl";
}

- (NSString *)launchAgentPath {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);
    NSString *libDir = paths.firstObject ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Library"];
    NSString *agentsDir = [libDir stringByAppendingPathComponent:@"LaunchAgents"];
    NSString *fileName = [[self launchAgentLabel] stringByAppendingString:@".plist"];
    return [agentsDir stringByAppendingPathComponent:fileName];
}

- (BOOL)isLaunchAgentInstalled {
    if (@available(macOS 13.0, *)) {
        if ([SMAppService mainAppService].status == SMAppServiceStatusEnabled) {
            return YES;
        }
    }
    return [[NSFileManager defaultManager] fileExistsAtPath:[self launchAgentPath]];
}

- (BOOL)writeLaunchAgentPlist {
    NSString *plistPath = [self launchAgentPath];
    NSString *realBundlePath = [self resolvedRealBundlePath];
    if (!realBundlePath) return NO;

    NSDictionary *dict = @{
        @"Label": [self launchAgentLabel],
        @"ProgramArguments": @[@"/usr/bin/open", @"-a", realBundlePath],
        @"RunAtLoad": @YES,
        @"KeepAlive": @NO
    };
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[plistPath stringByDeletingLastPathComponent]
  withIntermediateDirectories:YES
                   attributes:nil
                        error:nil];
    return [dict writeToFile:plistPath atomically:YES];
}

- (void)syncLaunchAgentPathIfNeeded {
    // Always strip quarantine on the real bundle path on startup
    NSString *realPath = [self resolvedRealBundlePath];
    (void)realPath;
    if ([[NSFileManager defaultManager] fileExistsAtPath:[self launchAgentPath]]) {
        [self writeLaunchAgentPlist];
    }
}

- (void)toggleLaunchAtLogin:(NSMenuItem *)sender {
    NSString *plistPath = [self launchAgentPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL currentlyEnabled = [self isLaunchAgentInstalled];

    if (currentlyEnabled) {
        if (@available(macOS 13.0, *)) {
            [[SMAppService mainAppService] unregisterAndReturnError:nil];
        }
        if ([fm fileExistsAtPath:plistPath]) {
            [fm removeItemAtPath:plistPath error:nil];
        }
        sender.state = NSControlStateValueOff;
    } else {
        BOOL registered = NO;
        NSString *bundlePath = [[[NSBundle mainBundle] bundleURL] path] ?: @"";
        // Prefer native macOS 13+ SMAppService when not running from a temporary AppTranslocation mount
        if (@available(macOS 13.0, *)) {
            if (![bundlePath containsString:@"/AppTranslocation/"]) {
                registered = [[SMAppService mainAppService] registerAndReturnError:nil];
            }
        }
        // Fallback to LaunchAgents plist (with de-translocated real path) if SMAppService is unavailable or translocated
        if (!registered) {
            registered = [self writeLaunchAgentPlist];
        }
        if (registered) {
            sender.state = NSControlStateValueOn;
        }
    }
}

@end

static void displayReconfigCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
    if ((flags & kCGDisplayBeginConfigurationFlag) != 0) return;
    AppDelegate *del = (__bridge AppDelegate *)userInfo;
    if (del && del.wakeGuardEnabled && !del.screensSleeping) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [del attemptAutoRestoreIfNeeded];
        });
    }
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        AppDelegate *del = [[AppDelegate alloc] init];
        app.delegate = del;
        [app run];
    }
    return 0;
}
