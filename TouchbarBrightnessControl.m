#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <dlfcn.h>

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
@property (assign) BOOL isApplying;
@end

static void displayReconfigCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo);

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY);
    Class bscCls = objc_getClass("BrightnessSystemClient");
    if (bscCls) {
        self.bscClient = [[bscCls alloc] init];
    }

    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if ([defs objectForKey:@"TargetBrightness"] != nil) {
        self.targetBrightness = [defs floatForKey:@"TargetBrightness"];
    } else {
        NSDictionary *cur = [self.bscClient copyPropertyForKey:@"DisplayBrightness"];
        float curB = cur ? [[cur objectForKey:@"Brightness"] floatValue] : 0.50f;
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

    NSView *panel = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 260, 92)];

    NSTextField *titleLabel = [NSTextField labelWithString:@"Touchbar Brightness"];
    titleLabel.font = [NSFont boldSystemFontOfSize:12.5];
    titleLabel.frame = NSMakeRect(16, 64, 145, 18);
    [panel addSubview:titleLabel];

    self.valueLabel = [NSTextField labelWithString:@"50% (184.5 Nits)"];
    self.valueLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
    self.valueLabel.textColor = [NSColor secondaryLabelColor];
    self.valueLabel.alignment = NSTextAlignmentRight;
    self.valueLabel.frame = NSMakeRect(145, 64, 100, 18);
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

    self.wakeGuardItem = [[NSMenuItem alloc] initWithTitle:@"Lock Brightness on Lid Wake (Fix ALS)"
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

- (void)menuWillOpen:(NSMenu *)menu {
    // Only query hardware state when the user actually clicks the menu bar icon
    if (self.bscClient) {
        NSDictionary *cur = [self.bscClient copyPropertyForKey:@"DisplayBrightness"];
        if (cur) {
            float actualB = [[cur objectForKey:@"Brightness"] floatValue];
            float nits = [[cur objectForKey:@"Nits"] floatValue];
            self.valueLabel.stringValue = [NSString stringWithFormat:@"%.0f%% (%.1f Nits)", actualB * 100.0f, nits];
        }
    }
    self.loginItem.state = [self isLaunchAgentInstalled] ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)sliderChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.targetBrightness = val;
    [self applyBrightness:val save:YES];
}

- (void)presetClicked:(NSButton *)sender {
    float val = (float)sender.tag / 100.0f;
    self.targetBrightness = val;
    self.slider.floatValue = val;
    [self applyBrightness:val save:YES];
}

- (void)applyBrightness:(float)val save:(BOOL)save {
    if (val < 0.0f) val = 0.0f;
    if (val > 1.0f) val = 1.0f;

    self.isApplying = YES;
    if (self.bscClient) {
        [self.bscClient setProperty:@NO forKey:@"DisplayBrightnessAuto"];
        [self.bscClient setProperty:@(val) forKey:@"DisplayBrightness"];
        NSDictionary *cur = [self.bscClient copyPropertyForKey:@"DisplayBrightness"];
        float actualB = cur ? [[cur objectForKey:@"Brightness"] floatValue] : val;
        float nits = cur ? [[cur objectForKey:@"Nits"] floatValue] : (11.9f + val * (357.1f - 11.9f));
        self.valueLabel.stringValue = [NSString stringWithFormat:@"%.0f%% (%.1f Nits)", actualB * 100.0f, nits];
    } else {
        float nits = 11.9f + val * (357.1f - 11.9f);
        self.valueLabel.stringValue = [NSString stringWithFormat:@"%.0f%% (%.1f Nits)", val * 100.0f, nits];
    }
    self.isApplying = NO;

    if (save) {
        NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
        [defs setFloat:val forKey:@"TargetBrightness"];
    }
}

- (void)restoreOnWakeSequence {
    if (!self.wakeGuardEnabled) return;
    [self applyBrightness:self.targetBrightness save:NO];
    __weak typeof(self) weakSelf = self;
    for (NSNumber *delayMs in @[@250, @800, @1800]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayMs.intValue * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf && strongSelf.wakeGuardEnabled) {
                [strongSelf applyBrightness:strongSelf.targetBrightness save:NO];
            }
        });
    }
}

- (void)setupEventDrivenWakeObservers {
    __weak typeof(self) weakSelf = self;

    // 1. Pure event-driven CoreBrightness XPC notification (0 polling when idle)
    void (^cbBlock)(id, id) = ^(id key, id val) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf.wakeGuardEnabled || strongSelf.isApplying) return;
            NSDictionary *d = [strongSelf.bscClient copyPropertyForKey:@"DisplayBrightness"];
            if (d) {
                float curB = [[d objectForKey:@"Brightness"] floatValue];
                if (curB <= 0.01f && strongSelf.targetBrightness > 0.02f) {
                    [strongSelf applyBrightness:strongSelf.targetBrightness save:NO];
                }
            }
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

    // 2. Pure event-driven macOS Workspace sleep/screen-wake notifications
    NSNotificationCenter *wsnc = [[NSWorkspace sharedWorkspace] notificationCenter];
    NSOperationQueue *mainQ = [NSOperationQueue mainQueue];
    void (^wakeBlock)(NSNotification *) = ^(NSNotification *note) {
        [weakSelf restoreOnWakeSequence];
    };
    [wsnc addObserverForName:NSWorkspaceDidWakeNotification object:nil queue:mainQ usingBlock:wakeBlock];
    [wsnc addObserverForName:NSWorkspaceScreensDidWakeNotification object:nil queue:mainQ usingBlock:wakeBlock];

    // 3. Pure event-driven CoreGraphics display power/reconfiguration callback
    CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, (__bridge void *)self);
}

- (void)toggleWakeGuard:(NSMenuItem *)sender {
    self.wakeGuardEnabled = !self.wakeGuardEnabled;
    sender.state = self.wakeGuardEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [[NSUserDefaults standardUserDefaults] setBool:self.wakeGuardEnabled forKey:@"WakeGuardEnabled"];
    if (self.wakeGuardEnabled) {
        [self applyBrightness:self.targetBrightness save:NO];
    }
}

- (NSString *)launchAgentPath {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/LaunchAgents/com.lfx.TouchbarBrightnessControl.plist"];
}

- (BOOL)isLaunchAgentInstalled {
    return [[NSFileManager defaultManager] fileExistsAtPath:[self launchAgentPath]];
}

- (void)toggleLaunchAtLogin:(NSMenuItem *)sender {
    NSString *plistPath = [self launchAgentPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:plistPath]) {
        [fm removeItemAtPath:plistPath error:nil];
        sender.state = NSControlStateValueOff;
    } else {
        NSString *execPath = [[NSBundle mainBundle] executablePath];
        NSDictionary *dict = @{
            @"Label": @"com.lfx.TouchbarBrightnessControl",
            @"ProgramArguments": @[execPath],
            @"RunAtLoad": @YES,
            @"KeepAlive": @NO
        };
        [fm createDirectoryAtPath:[plistPath stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
        [dict writeToFile:plistPath atomically:YES];
        sender.state = NSControlStateValueOn;
    }
}

@end

static void displayReconfigCallback(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *userInfo) {
    AppDelegate *del = (__bridge AppDelegate *)userInfo;
    if (del && del.wakeGuardEnabled) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [del restoreOnWakeSequence];
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
