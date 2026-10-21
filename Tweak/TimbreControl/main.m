#import <UIKit/UIKit.h>
#include <math.h>
static NSString *const kConfig = @"/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist";
@interface Controller : UIViewController
@property(nonatomic,strong) UISwitch *enabled;
@property(nonatomic,strong) UITextField *frequency;
@property(nonatomic,strong) UITextField *gain;
@property(nonatomic,strong) UITextField *preamp;
@property(nonatomic,strong) UITextField *quality;
@property(nonatomic,strong) UILabel *status;
@end
@implementation Controller
- (UITextField *)field:(NSString *)name value:(NSString *)value in:(UIStackView *)stack {
 UILabel *label = [[UILabel alloc] init]; label.text=name; label.textColor=UIColor.labelColor;
 UITextField *input = [[UITextField alloc] init]; input.borderStyle=UITextBorderStyleRoundedRect;
 input.keyboardType=UIKeyboardTypeNumbersAndPunctuation; input.text=value;
 [stack addArrangedSubview:label]; [stack addArrangedSubview:input]; return input;
}
- (void)viewDidLoad {
 [super viewDidLoad]; self.title=@"Timbre"; self.view.backgroundColor=UIColor.systemBackgroundColor;
 NSDictionary *d=[NSDictionary dictionaryWithContentsOfFile:kConfig] ?: @{};
 UIStackView *stack=[[UIStackView alloc] init]; stack.axis=UILayoutConstraintAxisVertical;
 stack.spacing=12; stack.translatesAutoresizingMaskIntoConstraints=NO;
 [self.view addSubview:stack];
 [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:24],
 [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-24],
 [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:24]]];
 UILabel *heading=[[UILabel alloc] init]; heading.text=@"Experimental system audio EQ";heading.font=[UIFont boldSystemFontOfSize:20]; [stack addArrangedSubview:heading];
 UIStackView *toggle=[[UIStackView alloc] init]; toggle.axis=UILayoutConstraintAxisHorizontal;
 UILabel *name=[[UILabel alloc] init]; name.text=@"Enable DSP on daemon restart";[toggle addArrangedSubview:name];
 self.enabled=[[UISwitch alloc] init];self.enabled.on=[d[@"enabled"] boolValue];[toggle addArrangedSubview:self.enabled];[stack addArrangedSubview:toggle];
 self.frequency=[self field:@"Peak frequency (Hz)" value:[NSString stringWithFormat:@"%@",d[@"frequency"] ?: @1000] in:stack];
 self.gain=[self field:@"Peak gain (dB)" value:[NSString stringWithFormat:@"%@",d[@"gain"] ?: @6] in:stack];
 self.preamp=[self field:@"Preamp (dB)" value:[NSString stringWithFormat:@"%@",d[@"preamp"] ?: @-6] in:stack];
 self.quality=[self field:@"Filter Q" value:[NSString stringWithFormat:@"%@",d[@"q"] ?: @1] in:stack];
 UIButton *save=[UIButton buttonWithType:UIButtonTypeSystem];[save setTitle:@"Save settings" forState:UIControlStateNormal];[save addTarget:self action:@selector(save) forControlEvents:UIControlEventTouchUpInside];[stack addArrangedSubview:save];
 self.status=[[UILabel alloc] init];self.status.numberOfLines=0;self.status.text=@"Changes require a userspace reboot. Current system-wide routing is unverified.";[stack addArrangedSubview:self.status];
}
- (void)save {
 double f=self.frequency.text.doubleValue, g=self.gain.text.doubleValue, p=self.preamp.text.doubleValue, q=self.quality.text.doubleValue;
 if(!isfinite(f)||f<20||f>20000||!isfinite(g)||g< -12||g>12||!isfinite(p)||p< -24||p>0||!isfinite(q)||q<0.2||q>10) {
 self.status.text=@"Invalid values. Frequency 20-20000, gain -12 to 12, preamp -24 to 0, Q 0.2-10."; return;
 }
 NSDictionary *d=@{@"enabled":@(self.enabled.on),@"frequency":@(f),@"gain":@(g),@"preamp":@(p),@"q":@(q)};
 BOOL ok=[d writeToFile:kConfig atomically:YES];
 self.status.text= ok ? @"Saved. Perform a userspace reboot for changes to take effect." : @"Could not save preferences. Check Filza permissions for /var/mobile/Library/Preferences.";
}
@end
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
 self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
 self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:[[Controller alloc] init]];
 [self.window makeKeyAndVisible];return YES;
}
@end
int main(int argc,char **argv) { @autoreleasepool {return UIApplicationMain(argc,argv,nil,NSStringFromClass([AppDelegate class]));} }
