#import <UIKit/UIKit.h>

// Load diagnostic only. No DSP, audio interception, fishhook or executable writes.
@interface TBLoadCheck : NSObject
@property(nonatomic, strong) UIButton *button;
@end

static UIWindow *TBLoadCheckWindow(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *fallback = nil;
    for (UIWindow *candidate in app.windows) {
        if (!candidate.hidden && candidate.alpha > 0.01 && candidate.rootViewController) {
            if (!fallback) fallback = candidate;
            if (candidate.isKeyWindow) return candidate;
        }
    }
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        if (scene.activationState == UISceneActivationStateUnattached || scene.activationState == UISceneActivationStateBackground) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.hidden || candidate.alpha <= 0.01 || !candidate.rootViewController) continue;
            if (!fallback) fallback = candidate;
            if (candidate.isKeyWindow) return candidate;
        }
    }
    return fallback;
}

@implementation TBLoadCheck
- (void)attach {
    UIWindow *window = TBLoadCheckWindow();
    if (!window || !window.rootViewController) return;
    if (!self.button) {
        self.button = [UIButton buttonWithType:UIButtonTypeSystem];
        [self.button setTitle:@"Load Check" forState:UIControlStateNormal];
        self.button.backgroundColor = UIColor.systemGreenColor;
        [self.button setTitleColor:UIColor.blackColor forState:UIControlStateNormal];
        self.button.layer.cornerRadius = 18;
        [self.button addTarget:self action:@selector(showStatus) forControlEvents:UIControlEventTouchUpInside];
    }
    if (self.button.superview != window) [window addSubview:self.button];
    self.button.frame = CGRectMake(window.bounds.size.width - 118, window.safeAreaInsets.top + 8, 108, 36);
    [window bringSubviewToFront:self.button];
}
- (void)showStatus {
    UIViewController *controller = self.button.window.rootViewController;
    while (controller.presentedViewController) controller = controller.presentedViewController;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Timbre Load Check 1" message:@"The diagnostic library loaded. No audio hooks or DSP are running." preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}
@end

__attribute__((constructor)) static void startLoadCheck(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        static TBLoadCheck *check;
        check = [TBLoadCheck new];
        [check attach];
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
            [check attach];
        }];
    });
}
