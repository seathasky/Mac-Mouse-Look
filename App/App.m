#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <sys/stat.h>
#import <sys/mount.h>
#import <sys/fsgetpath.h>
#import <libproc.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>

static NSArray<NSString *> *keyNames(void) { return @[@"⌥M", @"F6", @"F7", @"F8", @"E"]; }
static const UInt32 keyCodes[] = {kVK_ANSI_M, kVK_F6, kVK_F7, kVK_F8, kVK_ANSI_E};
// Preset numbers are stored in preferences. Keep the original four IDs stable.
static const NSInteger defaultPreset = 4;
static UInt32 shortcutModifiers(NSEventModifierFlags flags) {
    UInt32 modifiers = 0;
    if (flags & NSEventModifierFlagCommand) modifiers |= cmdKey;
    if (flags & NSEventModifierFlagOption) modifiers |= optionKey;
    if (flags & NSEventModifierFlagControl) modifiers |= controlKey;
    if (flags & NSEventModifierFlagShift) modifiers |= shiftKey;
    return modifiers;
}
static NSString *shortcutLabel(NSEvent *event, UInt32 modifiers) {
    NSMutableString *label = [NSMutableString string];
    if (modifiers & controlKey) [label appendString:@"⌃"];
    if (modifiers & optionKey) [label appendString:@"⌥"];
    if (modifiers & shiftKey) [label appendString:@"⇧"];
    if (modifiers & cmdKey) [label appendString:@"⌘"];
    NSString *name = @{@(kVK_Space):@"Space", @(kVK_Tab):@"Tab", @(kVK_Return):@"Return",
                       @(kVK_Delete):@"Delete", @(kVK_ForwardDelete):@"Forward Delete",
                       @(kVK_LeftArrow):@"←", @(kVK_RightArrow):@"→", @(kVK_UpArrow):@"↑",
                       @(kVK_DownArrow):@"↓", @(kVK_Escape):@"Escape", @(kVK_Home):@"Home",
                       @(kVK_End):@"End", @(kVK_PageUp):@"Page Up", @(kVK_PageDown):@"Page Down",
                       @(kVK_ANSI_KeypadEnter):@"Keypad Enter"}[@(event.keyCode)];
    NSString *plain = [event charactersByApplyingModifiers:0];
    if (!name && plain.length) {
        unichar c = [plain characterAtIndex:0];
        if (c >= NSF1FunctionKey && c <= NSF35FunctionKey)
            name = [NSString stringWithFormat:@"F%d", c - NSF1FunctionKey + 1];
        else if (![NSCharacterSet.controlCharacterSet characterIsMember:c] && !(c >= 0xf700 && c <= 0xf8ff))
            name = plain.uppercaseString;
    }
    [label appendString:name ?: [NSString stringWithFormat:@"Key %u", event.keyCode]];
    return label;
}
static NSString *supportPath(NSString *relative) {
    NSString *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject.path;
    return [support stringByAppendingPathComponent:relative];
}
static BOOL validGameEntry(id entry) {
    if (![entry isKindOfClass:NSDictionary.class] ||
        ![entry[@"exe"] isKindOfClass:NSString.class] || ![entry[@"exe"] isAbsolutePath]) return NO;
    if (!entry[@"prefix"]) return [entry[@"autoDetect"] isEqual:@YES];
    return [entry[@"prefix"] isKindOfClass:NSString.class] && [entry[@"prefix"] isAbsolutePath] &&
        (!entry[@"engine"] || ([entry[@"engine"] isKindOfClass:NSString.class] && [entry[@"engine"] isAbsolutePath])) &&
        (!entry[@"crossOver"] || [entry[@"crossOver"] isKindOfClass:NSNumber.class]);
}
static BOOL sameGame(NSDictionary *a, NSDictionary *b) {
    return [a[@"exe"] isEqual:b[@"exe"]] && (a[@"prefix"] == b[@"prefix"] || [a[@"prefix"] isEqual:b[@"prefix"]]);
}
static NSArray *recentGames(NSArray *saved, NSDictionary *selection) {
    NSMutableArray *entries = [NSMutableArray array];
    if (validGameEntry(selection)) [entries addObject:selection];
    for (id entry in saved) {
        if (!validGameEntry(entry)) continue;
        BOOL duplicate = NO;
        for (NSDictionary *existing in entries) {
            if (sameGame(existing,entry)) { duplicate = YES; break; }
        }
        if (!duplicate) [entries addObject:entry];
        if (entries.count == 10) break;
    }
    return entries;
}
static BOOL isPrefix(NSString *path) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL dir = NO;
    return [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"drive_c"] isDirectory:&dir] && dir &&
        [fm fileExistsAtPath:[path stringByAppendingPathComponent:@"system.reg"]];
}
static NSString *findPrefix(NSString *path) {
    for (NSString *dir = path; dir.length > 1; dir = dir.stringByDeletingLastPathComponent)
        if (isPrefix(dir)) return dir;
    return nil;
}
static NSString *windowsPath(NSString *path, NSString *prefix) {
    NSString *devices = [prefix stringByAppendingPathComponent:@"dosdevices"];
    path = path.stringByResolvingSymlinksInPath;
    NSString *result = nil;
    NSUInteger best = 0;
    for (NSString *drive in [NSFileManager.defaultManager contentsOfDirectoryAtPath:devices error:nil]) {
        if (drive.length != 2 || ![drive hasSuffix:@":"]) continue;
        NSString *base = [[devices stringByAppendingPathComponent:drive] stringByResolvingSymlinksInPath];
        NSString *boundary = [base hasSuffix:@"/"] ? base : [base stringByAppendingString:@"/"];
        if (![path hasPrefix:boundary] || boundary.length <= best) continue;
        best = boundary.length;
        NSString *relative = [path substringFromIndex:best];
        result = [NSString stringWithFormat:@"%@\\%@",drive.uppercaseString,
                  [relative stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
    }
    return result;
}
static NSArray<NSString *> *serverDirectories(void) {
    NSString *perUser = [NSString stringWithFormat:@".wine-%u",getuid()];
    NSMutableArray *dirs = [NSMutableArray arrayWithObjects:[@"/tmp" stringByAppendingPathComponent:perUser],
        [NSTemporaryDirectory() stringByAppendingPathComponent:perUser], nil];
    NSString *xdg = NSProcessInfo.processInfo.environment[@"XDG_RUNTIME_DIR"];
    if (xdg.length) [dirs addObject:[xdg stringByAppendingPathComponent:@"wine"]];
    return dirs;
}

// Wine keys each live server directory by the bottle's device and inode. Its lock
// identifies the server process even for bottles and runtimes in custom locations.
static NSString *serverBinary(NSString *directory) {
    int fd = open([directory stringByAppendingPathComponent:@"lock"].fileSystemRepresentation,O_RDONLY | O_CLOEXEC);
    if (fd < 0) return nil;
    struct flock lock = {.l_type = F_WRLCK, .l_whence = SEEK_SET};
    BOOL locked = fcntl(fd,F_GETLK,&lock) == 0 && lock.l_type != F_UNLCK && lock.l_pid > 0;
    close(fd);
    char binary[PROC_PIDPATHINFO_MAXSIZE];
    if (!locked || proc_pidpath(lock.l_pid,binary,sizeof(binary)) <= 0) return nil;
    return [NSFileManager.defaultManager stringWithFileSystemRepresentation:binary length:strlen(binary)];
}
static NSString *runtimeForServer(NSString *server, BOOL *crossOver) {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (*crossOver) {
        NSString *app = server;
        while (app.length > 1 && ![app.pathExtension.lowercaseString isEqual:@"app"]) app = app.stringByDeletingLastPathComponent;
        NSString *launcher = [app stringByAppendingPathComponent:@"Contents/SharedSupport/CrossOver/bin/wine"];
        if (app.length > 1 && [fm isExecutableFileAtPath:launcher]) return launcher;
        if (!server.length) {
            NSURL *cx = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.codeweavers.CrossOver"];
            launcher = [(cx.path ?: @"/Applications/CrossOver.app") stringByAppendingPathComponent:@"Contents/SharedSupport/CrossOver/bin/wine"];
            return [fm isExecutableFileAtPath:launcher] ? launcher : nil;
        }
        // Some wrappers use a CrossOver-style bottle with their own Wine binary.
        *crossOver = NO;
    }
    if (!server.length) return nil;
    NSString *dir = server.stringByDeletingLastPathComponent;
    for (NSString *rel in @[@"wine", @"wine64", @"../bin/wine", @"../bin/wine64"]) {
        NSString *loader = [[dir stringByAppendingPathComponent:rel] stringByStandardizingPath];
        if ([fm isExecutableFileAtPath:loader]) return loader;
    }
    return nil;
}
static NSArray<NSDictionary *> *liveSessions(NSDictionary *game) {
    NSString *exe = game[@"exe"];
    NSString *inside = findPrefix(exe.stringByDeletingLastPathComponent);
    struct statfs *volumes = NULL;
    int count = getmntinfo(&volumes,MNT_NOWAIT);
    // getmntinfo's buffer is shared; retain the small identifiers before calling AppKit.
    NSMutableDictionary *volumeIDs = [NSMutableDictionary dictionary];
    for (int i=0; i<count; i++) {
        fsid_t fsid = volumes[i].f_fsid;
        volumeIDs[@((unsigned)fsid.val[0])] = [NSData dataWithBytes:&fsid length:sizeof(fsid)];
    }
    NSMutableDictionary *found = [NSMutableDictionary dictionary];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *base in serverDirectories()) {
        for (NSString *name in [fm contentsOfDirectoryAtPath:base error:nil]) {
            unsigned device; unsigned long long inode; char extra;
            if (sscanf(name.UTF8String,"server-%x-%llx%c",&device,&inode,&extra) != 2) continue;
            NSString *directory = [base stringByAppendingPathComponent:name];
            struct stat sock, prefixStat;
            if (stat([directory stringByAppendingPathComponent:@"socket"].fileSystemRepresentation,&sock) ||
                !S_ISSOCK(sock.st_mode) || sock.st_uid != getuid()) continue;
            NSString *prefix = nil;
            // Direct paths also work on file systems that cannot reverse-map inodes.
            for (NSString *hint in @[inside ?: @"", game[@"prefix"] ?: @""]) {
                if (hint.length && !stat(hint.fileSystemRepresentation,&prefixStat) &&
                    (unsigned)prefixStat.st_dev == device && prefixStat.st_ino == inode) { prefix = hint; break; }
            }
            if (!prefix) {
                NSData *value = volumeIDs[@(device)];
                if (!value) continue;
                fsid_t fsid; [value getBytes:&fsid length:sizeof(fsid)];
                char path[PATH_MAX];
                if (fsgetpath(path,sizeof(path),&fsid,inode) <= 0) continue;
                prefix = [fm stringWithFileSystemRepresentation:path length:strlen(path)];
            }
            if (found[prefix] || !isPrefix(prefix) || !windowsPath(exe,prefix)) continue;
            BOOL cx = [fm fileExistsAtPath:[prefix stringByAppendingPathComponent:@"cxbottle.conf"]];
            NSString *engine = runtimeForServer(serverBinary(directory),&cx);
            if (!engine && [prefix isEqual:game[@"prefix"]] && [game[@"engine"] length] &&
                [fm isExecutableFileAtPath:game[@"engine"]]) {
                engine = game[@"engine"];
                cx = [game[@"crossOver"] boolValue];
            }
            if (engine) found[prefix] = @{@"exe":exe,@"prefix":prefix,@"engine":engine,@"crossOver":@(cx)};
        }
    }
    NSMutableArray *matches = [NSMutableArray array];
    for (NSString *path in [found.allKeys sortedArrayUsingSelector:@selector(compare:)]) [matches addObject:found[path]];
    NSDictionary *preferred = found[game[@"prefix"] ?: inside ?: @""];
    if (preferred) { [matches removeObject:preferred]; [matches insertObject:preferred atIndex:0]; }
    return matches;
}

static void explain(NSString *title, NSString *message) {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title; alert.informativeText = message;
    [alert runModal];
}

// Fixed-point geometry keeps the outline legible at normal size and on Retina displays.
@interface ReticleView : NSView
@end
@implementation ReticleView
- (void)drawRect:(NSRect)dirtyRect {
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *origin = [NSAffineTransform transform];
    [origin translateXBy:NSMidX(self.bounds) yBy:NSMidY(self.bounds)];
    [origin concat];
    NSColor *edge = [NSColor colorWithRed:0.12 green:0.08 blue:0.035 alpha:0.97];
    NSColor *gold = [NSColor colorWithRed:0.87 green:0.62 blue:0.14 alpha:1];
    NSColor *glint = [NSColor colorWithRed:1 green:0.85 blue:0.37 alpha:1];
    NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(-12,-12,24,24)];
    [edge setStroke]; ring.lineWidth = 4.5; [ring stroke];
    [gold setStroke]; ring.lineWidth = 2; [ring stroke];
    for (NSInteger tick = 0; tick < 4; tick++) {
        NSBezierPath *tooth = [NSBezierPath bezierPath];
        [tooth moveToPoint:NSMakePoint(-1.6,15)];
        [tooth lineToPoint:NSMakePoint(1.6,15)];
        [tooth lineToPoint:NSMakePoint(1.4,11)];
        [tooth lineToPoint:NSMakePoint(0,7.4)];
        [tooth lineToPoint:NSMakePoint(-1.4,11)];
        [tooth closePath];
        [edge setStroke]; tooth.lineWidth = 2; [tooth stroke];
        [gold setFill]; [tooth fill];
        [glint setStroke]; [NSBezierPath strokeLineFromPoint:NSMakePoint(-0.6,13.6) toPoint:NSMakePoint(-0.3,11.2)];
        NSAffineTransform *turn = [NSAffineTransform transform];
        [turn rotateByDegrees:90]; [turn concat];
    }
    [edge setFill]; NSRectFill(NSMakeRect(-2.3,-2.3,4.6,4.6));
    [[NSColor colorWithRed:0.90 green:0.16 blue:0.12 alpha:1] setFill]; NSRectFill(NSMakeRect(-1.3,-1.3,2.6,2.6));
    [NSGraphicsContext restoreGraphicsState];
}
@end

typedef struct {
    NSRect frame;
    NSInteger level;
} ReticleTarget;

// WindowServer lists windows front to back. Wine can put full-screen games above layer zero.
static ReticleTarget reticleTarget(NSArray *windows, pid_t owner, NSRect fallback, CGFloat primaryTop) {
    ReticleTarget result = { fallback, CGWindowLevelForKey(kCGOverlayWindowLevelKey) };
    if (owner <= 0) return result;
    for (NSDictionary *window in windows) {
        if ([window[(id)kCGWindowOwnerPID] intValue] != owner) continue;
        NSInteger layer = [window[(id)kCGWindowLayer] integerValue];
        NSDictionary *bounds = window[(id)kCGWindowBounds];
        if (layer < 0 || !bounds || (window[(id)kCGWindowAlpha] && [window[(id)kCGWindowAlpha] doubleValue] <= 0)) continue;
        CGRect box;
        if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds,&box)
            || box.size.width < 100 || box.size.height < 100) continue;
        result.frame = NSMakeRect(box.origin.x, primaryTop-CGRectGetMaxY(box),box.size.width,box.size.height);
        result.level = MAX(result.level, MIN(layer+1, CGWindowLevelForKey(kCGMaximumWindowLevelKey)));
        break;
    }
    return result;
}

@interface MouseLook : NSObject <NSApplicationDelegate, NSMenuDelegate>
@property NSStatusItem *item;
@property NSMenuItem *status;
@property NSMenu *bindings;
@property NSMenuItem *bindingMenu;
@property NSDictionary *game;
@property NSArray<NSDictionary *> *history;
@property NSMenuItem *recentItem;
@property UInt32 code, modifiers;
@property NSString *bindingLabel;
@property BOOL recording;
@property NSPanel *overlay;
@property NSTimer *overlayTimer;
@property NSTask *worker;
@property NSFileHandle *commands;
@property NSFileHandle *replies;
@property NSString *stateText;
@property NSDate *retryAfter;
@property NSInteger binding;
@property NSUInteger sessionAttempt;
@property NSDictionary *probing;
@property EventHotKeyRef hotKey;
@property BOOL gameFocused, held, receivedState, shortcutDown;
@end

@implementation MouseLook
- (void)hideOverlay {
    [self.overlayTimer invalidate];
    self.overlayTimer = nil;
    [self.overlay orderOut:nil];
}
- (void)positionOverlay {
    NSScreen *primary = NSScreen.screens.firstObject;
    if (!primary) return;
    NSPoint cursor = NSEvent.mouseLocation;
    NSScreen *screen = NSScreen.mainScreen ?: primary;
    for (NSScreen *candidate in NSScreen.screens) {
        if (NSPointInRect(cursor,candidate.frame)) { screen = candidate; break; }
    }
    pid_t owner = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly |
        kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    ReticleTarget target = reticleTarget(windows, owner, screen.frame, NSMaxY(primary.frame));
    if (self.overlay.level != target.level) self.overlay.level = target.level;
    NSSize size = self.overlay.frame.size;
    [self.overlay setFrameOrigin:NSMakePoint(round(NSMidX(target.frame)-size.width/2),round(NSMidY(target.frame)-size.height/2))];
    [self.overlay orderFrontRegardless];
}
- (void)showOverlay {
    if (self.overlayTimer) { [self positionOverlay]; return; }
    if (!self.overlay) {
        NSRect bounds = NSMakeRect(0,0,34,34);
        NSPanel *panel = [[NSPanel alloc] initWithContentRect:bounds
            styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        panel.opaque = NO;
        panel.backgroundColor = NSColor.clearColor;
        panel.ignoresMouseEvents = YES;
        panel.hidesOnDeactivate = NO;
        panel.hasShadow = NO;
        panel.animationBehavior = NSWindowAnimationBehaviorNone;
        panel.floatingPanel = YES;
        panel.level = NSStatusWindowLevel;
        panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
            NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorCanJoinAllApplications |
            NSWindowCollectionBehaviorIgnoresCycle;
        panel.contentView = [[ReticleView alloc] initWithFrame:bounds];
        self.overlay = panel;
    }
    [self positionOverlay];
    [self.overlay displayIfNeeded];
    self.overlayTimer = [NSTimer scheduledTimerWithTimeInterval:0.4 target:self selector:@selector(repositionReticle:) userInfo:nil repeats:YES];
    self.overlayTimer.tolerance = 0.1;
}
- (void)repositionReticle:(NSTimer *)timer { [self positionOverlay]; }
- (void)send:(char)command {
    if (command == 'U' || command == 'Q') {
        [self hideOverlay];
    }
    if (!self.commands) return;
    NSError *error;
    [self.commands writeData:[NSData dataWithBytes:&command length:1] error:&error];
}
static OSStatus shortcut(EventHandlerCallRef next, EventRef event, void *context) {
    MouseLook *app = (__bridge MouseLook *)context;
    EventHotKeyID identifier = {0};
    GetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,NULL,sizeof(identifier),NULL,&identifier);
    if (identifier.signature != 'MmLk') return eventNotHandledErr;
    BOOL down = GetEventKind(event) == kEventHotKeyPressed;
    if (app.gameFocused && down && !app.shortcutDown) [app send:'T'];
    app.shortcutDown = down;
    return noErr;
}
- (void)refresh {
    if ((!self.gameFocused || self.recording) && self.hotKey) {
        UnregisterEventHotKey(self.hotKey);
        self.hotKey = NULL; self.shortcutDown = NO;
    }
    NSString *state = self.stateText;
    if (self.gameFocused && !self.recording) {
        if (!self.hotKey) {
            EventHotKeyRef key = NULL;
            EventHotKeyID hotID = {'MmLk', 1};
            if (RegisterEventHotKey(self.code, self.modifiers, hotID,
                                    GetApplicationEventTarget(), 0, &key) == noErr) self.hotKey = key;
        }
        state = self.hotKey ? (self.held ? @"Mouse look on" : [@"Ready in " stringByAppendingString:self.gameName]) : @"Shortcut in use · choose another";
    }
    self.status.title = state ?: self.waiting;
    self.item.button.toolTip = [NSString stringWithFormat:@"Mac Mouse Look · %@ · %@", self.status.title,self.bindingLabel];
    self.item.button.image = [NSImage imageWithSystemSymbolName:self.held ? @"computermouse.fill" : @"computermouse"
                                       accessibilityDescription:@"Mac Mouse Look"];
    self.bindingMenu.title = [NSString stringWithFormat:@"Shortcut  %@", self.bindingLabel];
    for (NSMenuItem *item in self.bindings.itemArray)
        item.state = item.action == @selector(choose:) && item.tag == self.binding ? NSControlStateValueOn : NSControlStateValueOff;
}
- (NSString *)gameName { return [self.game[@"exe"] lastPathComponent]; }
- (NSString *)waiting { return self.game ? [@"Waiting for " stringByAppendingString:self.gameName] : @"Choose a game to get started"; }
- (void)loadGames {
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    NSDictionary *current = [prefs dictionaryForKey:@"SelectedGame"];
    self.game = validGameEntry(current) ? current : nil;
    if (current && !self.game) [prefs removeObjectForKey:@"SelectedGame"];
    NSArray *saved = [prefs arrayForKey:@"RecentGames"];
    self.history = recentGames(saved,self.game);
    if (![self.history isEqual:(saved ?: @[])]) [prefs setObject:self.history forKey:@"RecentGames"];
}
- (void)updateRecentMenu {
    NSMenu *menu = self.recentItem.submenu;
    [menu removeAllItems];
    for (NSDictionary *entry in self.history) {
        NSString *exe = entry[@"exe"], *prefix = entry[@"prefix"];
        NSString *bottle = prefix.lastPathComponent;
        NSString *title = bottle ? [NSString stringWithFormat:@"%@  ·  %@",exe.lastPathComponent,bottle] : exe.lastPathComponent;
        for (NSDictionary *other in self.history) {
            if (other == entry || ![exe.lastPathComponent isEqual:[other[@"exe"] lastPathComponent]]) continue;
            if (bottle && ![bottle isEqual:[other[@"prefix"] lastPathComponent]]) continue;
            title = [NSString stringWithFormat:@"%@  ·  %@",exe.stringByAbbreviatingWithTildeInPath,
                     prefix.stringByAbbreviatingWithTildeInPath ?: @"Auto"];
            break;
        }
        NSMenuItem *item = [menu addItemWithTitle:title action:@selector(useRecent:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = entry;
        item.toolTip = exe;
        item.state = sameGame(self.game,entry) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    self.recentItem.hidden = !self.history.count;
}
- (void)useRecent:(NSMenuItem *)item {
    NSDictionary *entry = item.representedObject;
    if (!validGameEntry(entry)) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:entry[@"exe"]]) {
        explain(@"Game moved", @"Use Choose Game… to select the game executable in its new location.");
        return;
    }
    [self selectGame:entry];
}
- (void)selectGame:(NSDictionary *)selection {
    [self send:'Q'];
    [self disconnect:nil];
    self.game = selection;
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    self.history = recentGames(self.history, selection);
    [prefs setObject:self.history forKey:@"RecentGames"];
    [self updateRecentMenu];
    [prefs setObject:selection forKey:@"SelectedGame"];
    self.sessionAttempt = 0;
    self.stateText = self.waiting;
    self.retryAfter = nil;
    [self refresh];
}
- (void)chooseGame:(id)sender {
    [NSApp activate];
    NSOpenPanel *exePanel = [NSOpenPanel openPanel];
    exePanel.title = @"Choose Game";
    exePanel.message = @"Select the game executable that runs while you play.";
    exePanel.prompt = @"Choose Game";
    exePanel.treatsFilePackagesAsDirectories = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    exePanel.allowedFileTypes = @[@"exe"];
#pragma clang diagnostic pop
    NSString *bottles = supportPath(@"CrossOver/Bottles");
    if (self.game) exePanel.directoryURL = [NSURL fileURLWithPath:[self.game[@"exe"] stringByDeletingLastPathComponent]];
    else if ([NSFileManager.defaultManager fileExistsAtPath:bottles]) exePanel.directoryURL = [NSURL fileURLWithPath:bottles];
    if ([exePanel runModal] != NSModalResponseOK) return;
    NSString *path = exePanel.URL.path.stringByStandardizingPath;
    for (NSDictionary *recent in self.history) {
        if ([recent[@"exe"] isEqual:path]) { [self selectGame:recent]; return; }
    }
    [self selectGame:@{@"exe":path,@"autoDetect":@YES}];
}
- (void)loadBinding {
    NSUserDefaults *prefs = NSUserDefaults.standardUserDefaults;
    NSDictionary *custom = [prefs dictionaryForKey:@"RecordedShortcut"];
    if ([custom[@"code"] isKindOfClass:NSNumber.class] && [custom[@"code"] unsignedIntegerValue] < 128 &&
        [custom[@"modifiers"] isKindOfClass:NSNumber.class] &&
        !([custom[@"modifiers"] unsignedIntegerValue] & ~(NSUInteger)(cmdKey|shiftKey|optionKey|controlKey)) &&
        [custom[@"label"] isKindOfClass:NSString.class] && [custom[@"label"] length]) {
        self.binding = -1;
        self.code = [custom[@"code"] unsignedIntValue];
        self.modifiers = [custom[@"modifiers"] unsignedIntValue];
        self.bindingLabel = custom[@"label"];
    } else {
        NSNumber *preset = [prefs objectForKey:@"Shortcut"];
        NSInteger index = [preset isKindOfClass:NSNumber.class] ? preset.integerValue : defaultPreset;
        self.binding = index >= 0 && index < (NSInteger)keyNames().count ? index : defaultPreset;
        self.code = keyCodes[self.binding];
        self.modifiers = self.binding == 0 ? optionKey : 0;
        self.bindingLabel = keyNames()[self.binding];
    }
}
- (void)recordShortcut:(id)sender {
    if (self.recording) return;
    self.recording = YES;
    [self send:'U'];
    [self refresh];
    NSAlert *dialog = [NSAlert new];
    dialog.messageText = @"Record Shortcut";
    dialog.informativeText = @"Press a key on its own or with modifiers to toggle mouse look.";
    [dialog addButtonWithTitle:@"Cancel"];
    dialog.buttons.firstObject.keyEquivalent = @"";
    __block NSDictionary *candidate = nil;
    id monitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.window != dialog.window) return event;
        if (event.isARepeat) return nil;
        UInt32 mods = shortcutModifiers(event.modifierFlags);
        NSString *label = shortcutLabel(event, mods);
        EventHotKeyRef probe = NULL;
        EventHotKeyID testID = {'MmTs', 1};
        OSStatus result = RegisterEventHotKey(event.keyCode, mods, testID, GetApplicationEventTarget(), 0, &probe);
        if (result != noErr) {
            dialog.informativeText = [NSString stringWithFormat:@"%@ is unavailable. Press another shortcut.", label];
            return nil;
        }
        UnregisterEventHotKey(probe);
        candidate = @{@"code":@(event.keyCode), @"modifiers":@(mods), @"label":label};
        [NSApp stopModalWithCode:NSModalResponseOK];
        return nil;
    }];
    [NSApp activate];
    [dialog runModal];
    [NSEvent removeMonitor:monitor];
    if (candidate) {
        [NSUserDefaults.standardUserDefaults setObject:candidate forKey:@"RecordedShortcut"];
        [self loadBinding];
    }
    self.recording = NO;
    [self refresh];
}
- (void)choose:(NSMenuItem *)item {
    [self send:'U'];
    if (self.hotKey) { UnregisterEventHotKey(self.hotKey); self.hotKey = NULL; }
    self.shortcutDown = NO;
    self.binding = item.tag;
    [NSUserDefaults.standardUserDefaults setInteger:self.binding forKey:@"Shortcut"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"RecordedShortcut"];
    [self loadBinding];
    [self refresh];
}
- (void)focusChanged:(NSNotification *)note { [self send:'U']; }
- (void)showStartupNotice {
    NSWindow *menuWindow = self.item.button.window;
    NSScreen *screen = menuWindow.screen ?: NSScreen.mainScreen;
    if (!screen) return;

    NSRect bounds = NSMakeRect(0, 0, 406, 80);
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:bounds
        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
        backing:NSBackingStoreBuffered defer:NO];
    panel.releasedWhenClosed = NO;
    panel.opaque = NO;
    panel.backgroundColor = NSColor.clearColor;
    panel.hasShadow = YES;
    panel.hidesOnDeactivate = NO;
    panel.ignoresMouseEvents = YES;
    panel.animationBehavior = NSWindowAnimationBehaviorNone;
    panel.level = NSStatusWindowLevel;
    panel.collectionBehavior = NSWindowCollectionBehaviorMoveToActiveSpace |
        NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorCanJoinAllApplications |
        NSWindowCollectionBehaviorIgnoresCycle;
    panel.title = @"Mac Mouse Look";

    NSVisualEffectView *card = [[NSVisualEffectView alloc] initWithFrame:bounds];
    card.material = NSVisualEffectMaterialPopover;
    card.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    card.state = NSVisualEffectStateActive;
    card.wantsLayer = YES;
    card.layer.cornerRadius = 16;
    card.layer.masksToBounds = YES;
    panel.contentView = card;

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(14, 14, 52, 52)];
    NSURL *iconURL = [NSBundle.mainBundle URLForResource:@"ML" withExtension:@"icns"];
    icon.image = [[NSImage alloc] initWithContentsOfURL:iconURL] ?: NSApp.applicationIconImage;
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [card addSubview:icon];

    NSTextField *title = [NSTextField labelWithString:panel.title];
    title.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
    title.frame = NSMakeRect(78, 41, 300, 21);
    [card addSubview:title];
    NSTextField *hint = [NSTextField labelWithString:@"Click the mouse icon in the menu bar for options."];
    hint.font = [NSFont systemFontOfSize:13];
    hint.textColor = NSColor.secondaryLabelColor;
    hint.frame = NSMakeRect(78, 20, 314, 18);
    [card addSubview:hint];

    NSRect visible = screen.visibleFrame;
    CGFloat anchor = menuWindow.screen ? NSMidX(menuWindow.frame) : NSMaxX(visible);
    CGFloat left = MAX(NSMinX(visible)+8, MIN(anchor-NSWidth(bounds)/2, NSMaxX(visible)-NSWidth(bounds)-8));
    [panel setFrameTopLeftPoint:NSMakePoint(round(left), NSMaxY(visible)-8)];
    [panel orderFrontRegardless];
    [panel displayIfNeeded];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4*NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.35;
            [[panel animator] setAlphaValue:0.0];
        } completionHandler:^{
            [panel close];
        }];
    });
}
- (void)applicationDidFinishLaunching:(NSNotification *)note {
    signal(SIGPIPE, SIG_IGN);
    self.item = [NSStatusBar.systemStatusBar statusItemWithLength:NSSquareStatusItemLength];
    NSMenu *menu = [NSMenu new];
    [self loadGames];
    self.status = [menu addItemWithTitle:self.waiting action:nil keyEquivalent:@""];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *chooseGame = [menu addItemWithTitle:@"Choose Game…" action:@selector(chooseGame:) keyEquivalent:@""];
    chooseGame.target = self;
    self.recentItem = [menu addItemWithTitle:@"Recent Games" action:nil keyEquivalent:@""];
    self.recentItem.submenu = [NSMenu new];
    [self updateRecentMenu];
    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *binding = [menu addItemWithTitle:@"Shortcut" action:nil keyEquivalent:@""];
    self.bindings = [NSMenu new];
    for (NSNumber *preset in @[@(defaultPreset), @0, @1, @2, @3]) {
        NSInteger index = preset.integerValue;
        NSString *name = keyNames()[index];
        NSMenuItem *item = [self.bindings addItemWithTitle:name action:@selector(choose:) keyEquivalent:@""];
        item.tag = index; item.target = self;
    }
    [self.bindings addItem:NSMenuItem.separatorItem];
    NSMenuItem *record = [self.bindings addItemWithTitle:@"Record Shortcut…" action:@selector(recordShortcut:) keyEquivalent:@""];
    record.target = self;
    binding.submenu = self.bindings;
    self.bindingMenu = binding;
    [menu addItem:NSMenuItem.separatorItem];
    [menu addItemWithTitle:@"Quit Mac Mouse Look" action:@selector(terminate:) keyEquivalent:@"q"];
    menu.delegate = self;
    self.item.menu = menu;
    [self loadBinding];
    EventTypeSpec kinds[] = {{kEventClassKeyboard,kEventHotKeyPressed},{kEventClassKeyboard,kEventHotKeyReleased}};
    InstallApplicationEventHandler(shortcut,2,kinds,(__bridge void *)self,NULL);
    NSNotificationCenter *nc = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSString *name in @[NSWorkspaceDidActivateApplicationNotification, NSWorkspaceWillSleepNotification, NSWorkspaceSessionDidResignActiveNotification])
        [nc addObserver:self selector:@selector(focusChanged:) name:name object:nil];
    [self refresh];
    [self showStartupNotice];
    [self connectIfNeeded];
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t){ [self connectIfNeeded]; }];
}
- (void)menuWillOpen:(NSMenu *)menu { [self send:'U']; }
- (void)receive:(char)state {
    if (!self.game) return;
    if (state == '1') state = 'H';
    if (state == '0') state = 'R';
    if (state == 'H') {
        [self showOverlay];
    } else {
        [self hideOverlay];
    }
    // Only cache the session after the helper finds this exact file in that bottle.
    if (self.probing && (state == 'W' || state == 'H' || state == 'R')) {
        NSDictionary *confirmed = self.probing;
        self.probing = nil;
        self.sessionAttempt = 0;
        if (![self.game isEqual:confirmed]) {
            NSMutableArray *saved = [self.history mutableCopy];
            if (!self.game[@"prefix"]) [saved removeObject:self.game];
            self.game = confirmed;
            self.history = recentGames(saved,confirmed);
            [NSUserDefaults.standardUserDefaults setObject:confirmed forKey:@"SelectedGame"];
            [NSUserDefaults.standardUserDefaults setObject:self.history forKey:@"RecentGames"];
            [self updateRecentMenu];
        }
    }
    self.receivedState = YES;
    self.gameFocused = state == 'H' || state == 'R';
    self.held = state == 'H';
    self.stateText = state == 'N' ? self.waiting : state == 'E' ? @"Wine could not send mouse input" : [@"Focus " stringByAppendingString:self.gameName];
    [self refresh];
}
- (void)connectIfNeeded {
    if (self.worker || (self.retryAfter && self.retryAfter.timeIntervalSinceNow > 0)) return;
    if (!self.game) return;
    NSString *exe = self.game[@"exe"];
    if (![NSFileManager.defaultManager fileExistsAtPath:exe]) {
        self.stateText = @"Game moved · choose the executable again"; [self refresh]; return;
    }
    NSArray *sessions = liveSessions(self.game);
    if (!sessions.count) {
        self.retryAfter = [NSDate dateWithTimeIntervalSinceNow:1.5];
        self.stateText = self.waiting; [self refresh]; return;
    }
    NSUInteger attempt = self.sessionAttempt++;
    NSDictionary *session = sessions[attempt % sessions.count];
    NSUInteger syncMode = (attempt / sessions.count) % 3;
    NSString *prefix = session[@"prefix"];
    NSString *engine = session[@"engine"];
    self.probing = session;
    NSURL *wine = [NSURL fileURLWithPath:engine];
    NSURL *helper = [NSBundle.mainBundle URLForResource:@"MouseLook" withExtension:@"exe"];
    if (!helper) { self.stateText = @"Mouse look helper missing"; [self refresh]; return; }
    NSMutableDictionary *env = [NSProcessInfo.processInfo.environment mutableCopy];
    env[@"WINEPREFIX"] = prefix;
    NSArray *args = @[helper.path];
    NSString *target = windowsPath(exe,prefix);
    if (!target || ![NSFileManager.defaultManager fileExistsAtPath:exe]) {
        self.stateText = @"Game moved · choose the executable again"; [self refresh]; return;
    }
    env[@"MML_GAME"] = target;
    env[@"WINEDEBUG"] = @"-all";
    if ([session[@"crossOver"] boolValue]) {
        args = @[@"--bottle",prefix,@"--no-update",@"--no-gui",@"--",helper.path];
    } else {
        env[@"WINEMSYNC"] = syncMode == 0 ? @"1" : @"0";
        env[@"WINEESYNC"] = syncMode == 2 ? @"1" : @"0";
        NSString *server = [[wine URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"wineserver"].path;
        if ([NSFileManager.defaultManager isExecutableFileAtPath:server]) env[@"WINESERVER"] = server;
        NSString *installation = engine.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
        NSString *frameworks = [installation.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Frameworks"];
        if ([NSFileManager.defaultManager fileExistsAtPath:frameworks]) {
            env[@"DYLD_FALLBACK_LIBRARY_PATH"] = [NSString stringWithFormat:@"%@:%@/lib:/usr/local/lib:/usr/lib",frameworks,installation];
            env[@"DYLD_FALLBACK_FRAMEWORK_PATH"] = frameworks;
        }
    }
    NSTask *task = [NSTask new];
    task.executableURL = wine; task.arguments = args; task.environment = env;
    NSPipe *input = [NSPipe pipe], *output = [NSPipe pipe];
    task.standardInput = input; task.standardOutput = output; task.standardError = [NSFileHandle fileHandleWithNullDevice];
    self.worker = task; self.receivedState = NO;
    self.commands = input.fileHandleForWriting; self.replies = output.fileHandleForReading;
    __weak MouseLook *weakSelf = self;
    self.replies.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) { handle.readabilityHandler = nil; return; }
        dispatch_async(dispatch_get_main_queue(), ^{
            MouseLook *self = weakSelf;
            if (self.worker != task) return;
            const char *bytes = data.bytes;
            for (NSUInteger i=0; i<data.length; i++) [self receive:bytes[i]];
        });
    };
    task.terminationHandler = ^(NSTask *done) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.worker != done) return;
            BOOL failed = !self.receivedState && done.terminationStatus != 0;
            [self disconnect:failed ? @"Could not connect to Wine · retrying" : self.waiting];
        });
    };
    if (![task launchAndReturnError:nil]) { [self disconnect:@"Could not start Wine"]; return; }
    // Give every active bottle a turn even if one Wine launcher stalls at startup.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        MouseLook *app = weakSelf;
        if (app.worker != task || app.receivedState) return;
        if (task.running) [task terminate];
        [app disconnect:app.waiting];
    });
}
- (void)disconnect:(NSString *)reason {
    [self hideOverlay];
    self.replies.readabilityHandler = nil;
    [self.commands closeFile];
    self.probing = nil;
    self.worker = nil; self.commands = nil; self.replies = nil;
    self.held = NO; self.gameFocused = NO; self.stateText = reason;
    self.retryAfter = [NSDate dateWithTimeIntervalSinceNow:1];
    [self refresh];
}
- (void)applicationWillTerminate:(NSNotification *)note {
    [self send:'Q']; [self.commands closeFile];
    if (self.hotKey) UnregisterEventHotKey(self.hotKey);
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        __attribute__((objc_precise_lifetime)) MouseLook *delegate = [MouseLook new]; app.delegate = delegate; [app run];
    }
}
