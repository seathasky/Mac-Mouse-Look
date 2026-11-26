#define main application_main
#import "../App/App.m"
#undef main
#include <assert.h>
@interface RecorderTest : MouseLook
@property NSUInteger toggleCount;
@end
@implementation RecorderTest
- (void)send:(char)command { assert(command=='T'); self.toggleCount++; }
@end
@interface ReticleProbe : MouseLook
@property BOOL reticleVisible;
@end
@implementation ReticleProbe
- (void)showOverlay { self.reticleVisible = YES; }
- (void)hideOverlay { self.reticleVisible = NO; }
- (void)refresh {}
@end
static void checkLayeredGameWindow(void) {
    NSRect main = NSMakeRect(0,0,1440,900);
    NSDictionary *box = CFBridgingRelease(CGRectCreateDictionaryRepresentation(CGRectMake(1440,-180,1920,1080)));
    NSDictionary *other = @{(id)kCGWindowOwnerPID:@50,(id)kCGWindowLayer:@0,(id)kCGWindowBounds:box};
    NSDictionary *game = @{(id)kCGWindowOwnerPID:@72,(id)kCGWindowLayer:@1500,(id)kCGWindowBounds:box};
    ReticleTarget target = reticleTarget(@[other,game],72,main,900);
    assert(NSEqualRects(target.frame, NSMakeRect(1440,0,1920,1080)));
    assert(target.level > 1500);
    target = reticleTarget(@[other],72,main,900);
    assert(NSEqualRects(target.frame,main));
    target = reticleTarget(@[game],0,main,900);
    assert(NSEqualRects(target.frame,main));
    puts("Elevated fullscreen window, second display, and fallback placement passed.");
}
static void checkReticle(void) {
    ReticleProbe *app = [ReticleProbe new];
    [app receive:'H']; assert(!app.held && !app.reticleVisible);
    assert([app.waiting isEqual:@"Choose a game to get started"]);
    app.game = @{@"exe":@"/Games/Example/Game.exe", @"prefix":@"/Bottles/Test", @"engine":@"/Wine/bin/wine"};
    [app receive:'R']; assert(!app.reticleVisible);
    [app receive:'1']; assert(app.held && app.reticleVisible);
    [app receive:'H']; assert(app.reticleVisible);
    [app receive:'0']; assert(!app.held && !app.reticleVisible);
    [app receive:'H']; [app receive:'W']; assert(!app.reticleVisible);
    // Render the real view offscreen to check its center and transparent interior.
    unsigned char pixels[34*34*4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(pixels,34,34,8,34*4,space,kCGImageAlphaPremultipliedLast|kCGBitmapByteOrder32Big);
    assert(bitmap);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithCGContext:bitmap flipped:NO];
    ReticleView *view = [[ReticleView alloc] initWithFrame:NSMakeRect(0,0,34,34)];
    [view drawRect:view.bounds];
    [NSGraphicsContext restoreGraphicsState];
    CGContextFlush(bitmap);
    unsigned char *center = &pixels[(17*34+17)*4];
    assert(center[0]>150 && center[1]<100 && center[3]>230);
    assert(pixels[3]==0 && pixels[(21*34+21)*4+3]==0);
    CGContextRelease(bitmap); CGColorSpaceRelease(space);
    puts("Reticle render, toggle, and focus-loss checks passed.");
}
static void checkRecentGames(void) {
    NSDictionary *first = @{@"exe":@"/Games/Base/Game.exe", @"prefix":@"/Bottles/Live", @"engine":@"/Wine/bin/wine"};
    NSDictionary *second = @{@"exe":@"/Games/Base/Game.exe", @"prefix":@"/Bottles/Test", @"engine":@"/WineAlt/bin/wine"};
    NSDictionary *third = @{@"exe":@"/Games/Beta/Game.exe", @"prefix":@"/Bottles/Live"};
    NSMutableDictionary *updated = [first mutableCopy];
    updated[@"engine"] = @"/NewWine/bin/wine";
    NSArray *history = recentGames(nil,first);
    history = recentGames(history,second);
    history = recentGames(history,third);
    history = recentGames(history,updated);
    assert(history.count == 3 && [history[0] isEqual:updated] && [history[1] isEqual:third] && [history[2] isEqual:second]);
    history = recentGames(history,@{@"exe":@"/Games/Old/Game.exe"});
    assert(history.count == 3 && [history[0] isEqual:updated]);
    NSDictionary *pending = @{@"exe":@"/Games/Upcoming.exe", @"autoDetect":@YES};
    assert(validGameEntry(pending) && sameGame(pending, [pending copy]));
    assert([recentGames(@[pending],pending) isEqual:@[pending]]);
    assert(!validGameEntry(@{@"exe":@"relative.exe", @"autoDetect":@YES}));
    NSArray *migrated = recentGames(@[@"invalid",@{},second],first);
    assert(migrated.count == 2 && [migrated[0] isEqual:first]);
    for (int i=0; i<12; i++) {
        NSDictionary *entry = @{@"exe":[NSString stringWithFormat:@"/Games/%d.exe",i],@"prefix":@"/Bottles/Test"};
        history = recentGames(history,entry);
    }
    assert(history.count == 10 && [history.lastObject[@"exe"] isEqual:@"/Games/2.exe"]);
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:history format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSArray *saved = [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil];
    assert([recentGames(saved,nil) isEqual:history]);
    puts("Recent game history, bottle identity, reordering, migration and ten-entry limit passed.");
}
static void key(MouseLook *app, UInt32 identifierID, UInt32 kind) {
    EventRef event;
    assert(CreateEvent(NULL,kEventClassKeyboard,kind,0,kEventAttributeNone,&event)==noErr);
    EventHotKeyID identifier={'MmLk',identifierID};
    SetEventParameter(event,kEventParamDirectObject,typeEventHotKeyID,sizeof(identifier),&identifier);
    shortcut(NULL,event,(__bridge void *)app);
    ReleaseEvent(event);
}
static void checkEnableSwitch(void) {
    ReticleProbe *app = [ReticleProbe new];
    app.game = @{@"exe":@"/Games/Game.exe"};
    NSPipe *pipe = [NSPipe pipe];
    app.commands = pipe.fileHandleForWriting;
    [app receive:'H'];
    key(app,2,kEventHotKeyPressed);
    key(app,2,kEventHotKeyPressed);
    assert(app.disabled && !app.held && !app.reticleVisible);
    assert([NSUserDefaults.standardUserDefaults boolForKey:@"MouseLookDisabled"]);
    [app receive:'H']; // In-flight response from before disable.
    assert(!app.held && !app.reticleVisible);
    key(app,1,kEventHotKeyPressed);
    key(app,1,kEventHotKeyReleased);
    key(app,2,kEventHotKeyReleased);
    key(app,2,kEventHotKeyPressed);
    key(app,2,kEventHotKeyReleased);
    assert(!app.disabled && !app.reticleVisible);
    key(app,1,kEventHotKeyPressed);
    key(app,1,kEventHotKeyReleased);
    [app receive:'W'];
    key(app,2,kEventHotKeyPressed);
    assert(!app.disabled);
    [app toggleEnabled:nil]; // Menu is available outside the game.
    assert(app.disabled);
    [app toggleEnabled:nil];
    assert(!app.disabled && ![NSUserDefaults.standardUserDefaults boolForKey:@"MouseLookDisabled"]);
    [app.commands closeFile];
    NSData *commands = [pipe.fileHandleForReading readDataToEndOfFile];
    assert([commands isEqual:[@"UTU" dataUsingEncoding:NSASCIIStringEncoding]]);
    puts("Enable shortcut, held-key repeat, menu, disabled input, focus and reticle checks passed.");
}
int main(void) {
 @autoreleasepool {
    checkLayeredGameWindow();
    checkReticle();
    checkRecentGames();
    checkEnableSwitch();
    RecorderTest *app = [RecorderTest new];
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    [app loadBinding]; assert(app.code==kVK_ANSI_E && app.modifiers==0 && [app.bindingLabel isEqual:@"E"]);
    [defaults setVolatileDomain:@{@"Shortcut":@0} forName:NSArgumentDomain];
    [app loadBinding]; assert(app.code==kVK_ANSI_M && app.modifiers==optionKey);
    [defaults setVolatileDomain:@{@"Shortcut":@2} forName:NSArgumentDomain];
    [app loadBinding]; assert(app.code==kVK_F7 && app.modifiers==0);
    [defaults setVolatileDomain:@{@"RecordedShortcut":@{@"code":@(kVK_ANSI_K),@"modifiers":@(controlKey|optionKey),@"label":@"⌃⌥K"}} forName:NSArgumentDomain];
    [app loadBinding]; assert(app.code==kVK_ANSI_K && app.modifiers==(controlKey|optionKey) && [app.bindingLabel isEqual:@"⌃⌥K"]);
    [defaults setVolatileDomain:@{@"RecordedShortcut":@{@"code":@(kVK_ANSI_G),@"modifiers":@0,@"label":@"G"}} forName:NSArgumentDomain];
    [app loadBinding]; assert(app.code==kVK_ANSI_G && app.modifiers==0);
    assert(shortcutModifiers(NSEventModifierFlagControl | NSEventModifierFlagOption) == (controlKey|optionKey));
    app.gameFocused=YES;
    key(app,1,kEventHotKeyPressed); key(app,1,kEventHotKeyPressed); assert(app.toggleCount==1);
    key(app,1,kEventHotKeyReleased); assert(app.toggleCount==1);
    key(app,1,kEventHotKeyPressed); key(app,1,kEventHotKeyReleased); assert(app.toggleCount==2);
    puts("Shortcut loading and press/release checks passed.");
 }
}
