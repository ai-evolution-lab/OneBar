// Runtime bridge to macOS 27's menu bar visibility assertion.
// API discovery follows Hidden Bar (MIT); attribution is in NOTICE.md.
#import "MenuBarNative.h"
#import <dlfcn.h>
#import <objc/message.h>

BOOL OBMenuBarVisibilityAvailable(void) {
    static void *framework;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        framework = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore",
                           RTLD_NOW | RTLD_LOCAL);
    });
    Class config = NSClassFromString(@"MBAssessmentModeConfiguration");
    Class assertion = NSClassFromString(@"MBAssessmentModeAssertion");
    return framework && config && assertion
        && [config instancesRespondToSelector:NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:")]
        && [assertion instancesRespondToSelector:NSSelectorFromString(@"activateWithConfiguration:completionHandler:")]
        && [assertion instancesRespondToSelector:NSSelectorFromString(@"invalidate")];
}

void OBMenuBarInvalidate(id assertion) {
    @try {
        SEL selector = NSSelectorFromString(@"invalidate");
        if ([assertion respondsToSelector:selector]) {
            ((void (*)(id, SEL))objc_msgSend)(assertion, selector);
        }
    } @catch (NSException *exception) {
        NSLog(@"OneBar: menu bar release failed: %@", exception.reason);
    }
}

void OBMenuBarActivate(NSArray<NSString *> *bundles,
                      void (^completion)(id, NSString *)) {
    void (^finish)(id, NSString *) = ^(id assertion, NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(assertion, error); });
    };
    if (!OBMenuBarVisibilityAvailable()) {
        finish(nil, @"当前 macOS 没有可用的菜单栏收纳接口。");
        return;
    }
    @try {
        // Preserve every system item. This feature only manages third-party apps.
        NSMutableArray<NSNumber *> *system = [NSMutableArray array];
        for (NSInteger item = 0; item < 64; item++) [system addObject:@(item)];
        SEL initializer = NSSelectorFromString(@"initWithAllowedSystemItems:allowedBundleIdentifiers:");
        id config = ((id (*)(id, SEL, NSArray *, NSArray *))objc_msgSend)(
            [NSClassFromString(@"MBAssessmentModeConfiguration") alloc], initializer, system, [bundles copy]);
        id assertion = [[NSClassFromString(@"MBAssessmentModeAssertion") alloc] init];
        if (!config || !assertion) {
            finish(nil, @"无法创建菜单栏收纳配置。");
            return;
        }
        SEL activate = NSSelectorFromString(@"activateWithConfiguration:completionHandler:");
        ((void (*)(id, SEL, id, void (^)(NSError *)))objc_msgSend)(
            assertion, activate, config, ^(NSError *error) {
                if (error) OBMenuBarInvalidate(assertion);
                finish(error ? nil : assertion, error.localizedDescription);
            });
    } @catch (NSException *exception) {
        finish(nil, [NSString stringWithFormat:@"菜单栏接口不可用：%@", exception.reason ?: exception.name]);
    }
}
