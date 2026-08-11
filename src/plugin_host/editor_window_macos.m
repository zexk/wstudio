#import <AppKit/AppKit.h>

void *wstudio_editor_window_open(int width, int height, const char *title) {
    [NSApplication sharedApplication];
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, width, height)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    if (!window) return NULL;
    [window setReleasedWhenClosed:NO];
    window.title = [NSString stringWithUTF8String:title];
    [window center];
    return window;
}

void *wstudio_editor_window_handle(void *raw) {
    return [(__bridge NSWindow *)raw contentView];
}

void wstudio_editor_window_resize(void *raw, int width, int height) {
    [(__bridge NSWindow *)raw setContentSize:NSMakeSize(width, height)];
}

void wstudio_editor_window_show(void *raw) {
    [(__bridge NSWindow *)raw makeKeyAndOrderFront:nil];
}

void wstudio_editor_window_hide(void *raw) {
    [(__bridge NSWindow *)raw orderOut:nil];
}

void wstudio_editor_window_service(void) {
    for (;;) {
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                            untilDate:[NSDate distantPast]
                                               inMode:NSDefaultRunLoopMode
                                              dequeue:YES];
        if (!event) break;
        [NSApp sendEvent:event];
    }
}

void wstudio_editor_window_close(void *raw) {
    NSWindow *window = (__bridge NSWindow *)raw;
    [window orderOut:nil];
    [window close];
    [window release];
}
