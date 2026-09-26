#import <AppKit/AppKit.h>

@interface RosettaRequestDelegate : NSObject <NSApplicationDelegate>
@end

@implementation RosettaRequestDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    [NSApp terminate:nil];
}
@end

int main(void) {
    @autoreleasepool {
        NSApplication *application = [NSApplication sharedApplication];
        RosettaRequestDelegate *delegate = [RosettaRequestDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
