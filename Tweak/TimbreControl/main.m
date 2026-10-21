#import <UIKit/UIKit.h>
#include <math.h>
static NSString *const kConfig=@"/var/mobile/Library/Preferences/com.soum91.timbreaudio.plist";
static const double kFrequencies[]={31.25,62.5,125,250,500,1000,2000,4000,8000,16000};
static double clampValue(double x,double lo,double hi){return fmax(lo,fmin(x,hi));}

@interface TimbreFader : UIControl
@property(nonatomic) double gain;
@property(nonatomic) NSInteger bandIndex;
@property(nonatomic,strong) UIColor *tint;
@end
@implementation TimbreFader
- (instancetype)init { if((self=[super init])){self.backgroundColor=UIColor.clearColor;self.tint=[UIColor colorWithRed:1 green:.72 blue:.20 alpha:1];}return self;}
- (CGSize)intrinsicContentSize{return CGSizeMake(52,195);}
- (void)drawRect:(CGRect)rect {
 CGContextRef c=UIGraphicsGetCurrentContext();if(!c)return;
 CGFloat mid=CGRectGetMidX(rect),top=14,bottom=rect.size.height-35;
 CGContextSetStrokeColorWithColor(c,[UIColor colorWithWhite:.3 alpha:1].CGColor);
 CGContextSetLineWidth(c,4);CGContextMoveToPoint(c,mid,top);CGContextAddLineToPoint(c,mid,bottom);CGContextStrokePath(c);
 CGFloat y=bottom-(CGFloat)((clampValue(self.gain,-12,12)+12)/24)*(bottom-top);
 CGContextSetStrokeColorWithColor(c,self.tint.CGColor);CGContextSetLineWidth(c,4);
 CGContextMoveToPoint(c,mid,y);CGContextAddLineToPoint(c,mid,bottom);CGContextStrokePath(c);
 CGContextSetFillColorWithColor(c,self.tint.CGColor);CGContextFillEllipseInRect(c,CGRectMake(mid-11,y-11,22,22));
 NSString *v=[NSString stringWithFormat:@"%+.1f",self.gain];
 [v drawInRect:CGRectMake(0,rect.size.height-23,rect.size.width,20) withAttributes:@{NSFontAttributeName:[UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightSemibold],NSForegroundColorAttributeName:UIColor.whiteColor,NSParagraphStyleAttributeName:[self centered]}];
}
- (NSParagraphStyle *)centered {NSMutableParagraphStyle *p=[NSMutableParagraphStyle new];p.alignment=NSTextAlignmentCenter;return p;}
- (void)setGain:(double)gain{_gain=clampValue(gain,-12,12);[self setNeedsDisplay];}
- (void)moveTouch:(UITouch *)touch {
 CGPoint p=[touch locationInView:self];CGFloat top=14,bottom=self.bounds.size.height-35;
 self.gain=round((12-24*clampValue((p.y-top)/(bottom-top),0,1))*10)/10.;
 [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event{[self moveTouch:touch];return YES;}
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event{[self moveTouch:touch];return YES;}
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event{[self moveTouch:touch];[self sendActionsForControlEvents:UIControlEventEditingDidEnd];}
@end

@interface TimbreCurve : UIView
@property(nonatomic,strong) NSArray<NSDictionary *> *bands;
@end
@implementation TimbreCurve
- (void)drawRect:(CGRect)r {
 CGContextRef c=UIGraphicsGetCurrentContext();if(!c)return;
 CGFloat w=r.size.width,h=r.size.height;
 CGContextSetStrokeColorWithColor(c,[UIColor colorWithWhite:.25 alpha:1].CGColor);CGContextSetLineWidth(c,.5);
 for(int i=0;i<=4;i++){CGFloat y=8+i*(h-16)/4;CGContextMoveToPoint(c,0,y);CGContextAddLineToPoint(c,w,y);}CGContextStrokePath(c);
 CGContextSetStrokeColorWithColor(c,[UIColor colorWithRed:1 green:.7 blue:.15 alpha:1].CGColor);CGContextSetLineWidth(c,2.5);
 for(int i=0;i<220;i++){
  double f=20*pow(1000.,i/219.);double sum=0;
  for(NSDictionary *b in self.bands){
   if(![b[@"enabled"] boolValue])continue;
   double center=fmax(20,[b[@"frequency"] doubleValue]);double q=fmax(.2,[b[@"q"] doubleValue]);
   double g=[b[@"gain"] doubleValue];
   // Visualization uses a smooth approximation; daemon uses exact RBJ filters.
   double t=log2(f/center)*q;
   sum+=g*exp(-.5*t*t);
  }
  CGFloat x=(CGFloat)i*w/219.;CGFloat y=h/2-(CGFloat)clampValue(sum,-15,15)*(h-16)/30;
  if(!i)CGContextMoveToPoint(c,x,y);else CGContextAddLineToPoint(c,x,y);
 }
 CGContextStrokePath(c);
}
@end

@interface TimbreController : UIViewController
@property(nonatomic,strong) NSMutableArray<NSMutableDictionary *> *bands;
@property(nonatomic,strong) UIStackView *faderRow;
@property(nonatomic,strong) TimbreCurve *curve;
@property(nonatomic,strong) UISwitch *power;
@property(nonatomic,strong) UISlider *preampSlider;
@property(nonatomic,strong) UILabel *preampLabel;
@property(nonatomic,strong) UILabel *status;
@property(nonatomic,strong) UILabel *selectedLabel;
@property(nonatomic,strong) UISlider *frequencySlider;
@property(nonatomic,strong) UISlider *qSlider;
@property(nonatomic,strong) UISegmentedControl *typeControl;
@property(nonatomic) NSInteger selected;
@end
@implementation TimbreController
- (UILabel *)label:(NSString *)text size:(CGFloat)size {
 UILabel *l=[UILabel new];l.text=text;l.font=[UIFont systemFontOfSize:size weight:UIFontWeightMedium];l.textColor=UIColor.whiteColor;
 return l;
}
- (NSMutableDictionary *)bandAt:(NSInteger)i{return self.bands[(NSUInteger)i];}
- (void)loadConfiguration {
 NSDictionary *d=[NSDictionary dictionaryWithContentsOfFile:kConfig] ?: @{};
 self.bands=[NSMutableArray new];
 NSArray *saved=d[@"bands"];
 if([saved isKindOfClass:NSArray.class])for(NSDictionary *b in saved){
  if(self.bands.count>=12)break;
  if([b isKindOfClass:NSDictionary.class]) [self.bands addObject:[b mutableCopy]];
 }
 if(self.bands.count==0){for(int i=0;i<10;i++){
  [self.bands addObject:[@{@"enabled":@YES,@"type":@0,@"frequency":@(kFrequencies[i]),@"gain":@0,@"q":@1.0} mutableCopy]];
 }}
 self.selected=0;
}
- (UIStackView *)column:(CGFloat)spacing {UIStackView *v=[UIStackView new];v.axis=UILayoutConstraintAxisVertical;v.spacing=spacing;return v;}
- (void)viewDidLoad {
 [super viewDidLoad];[self loadConfiguration];self.title=@"Timbre";
 self.view.backgroundColor=[UIColor colorWithRed:.055 green:.065 blue:.09 alpha:1];
 UIScrollView *scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;scroll.alwaysBounceVertical=YES;
 [self.view addSubview:scroll];
 [NSLayoutConstraint activateConstraints:@[[scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],[scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],[scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
 UIStackView *root=[self column:15];root.translatesAutoresizingMaskIntoConstraints=NO;[scroll addSubview:root];
 [NSLayoutConstraint activateConstraints:@[[root.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:15],[root.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-30],[root.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:16],[root.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-16],[root.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-32]]];
 UIStackView *head=[UIStackView new];head.axis=UILayoutConstraintAxisHorizontal;
 [head addArrangedSubview:[self label:@"SYSTEM EQ" size:21]];[head addArrangedSubview:[UIView new]];
 self.power=[UISwitch new];[self.power addTarget:self action:@selector(saveChanged) forControlEvents:UIControlEventValueChanged];
 self.power.on=[[[NSDictionary dictionaryWithContentsOfFile:kConfig] ?: @{} objectForKey:@"enabled"] boolValue];[head addArrangedSubview:self.power];[root addArrangedSubview:head];
 self.curve=[TimbreCurve new];self.curve.backgroundColor=[UIColor colorWithWhite:.12 alpha:1];self.curve.layer.cornerRadius=12;self.curve.clipsToBounds=YES;self.curve.bands=self.bands;
 [self.curve.heightAnchor constraintEqualToConstant:155].active=YES;[root addArrangedSubview:self.curve];
 UILabel *caption=[self label:@"20 Hz                         1 kHz                         20 kHz" size:10];caption.adjustsFontSizeToFitWidth=YES;caption.textColor=UIColor.lightGrayColor;[root addArrangedSubview:caption];
 UIScrollView *horizontal=[UIScrollView new];horizontal.showsHorizontalScrollIndicator=YES;
 [horizontal.heightAnchor constraintEqualToConstant:248].active=YES;[root addArrangedSubview:horizontal];
 self.faderRow=[UIStackView new];self.faderRow.axis=UILayoutConstraintAxisHorizontal;self.faderRow.spacing=4;
 self.faderRow.translatesAutoresizingMaskIntoConstraints=NO;[horizontal addSubview:self.faderRow];
 [NSLayoutConstraint activateConstraints:@[[self.faderRow.leadingAnchor constraintEqualToAnchor:horizontal.contentLayoutGuide.leadingAnchor],[self.faderRow.trailingAnchor constraintEqualToAnchor:horizontal.contentLayoutGuide.trailingAnchor],[self.faderRow.topAnchor constraintEqualToAnchor:horizontal.contentLayoutGuide.topAnchor],[self.faderRow.bottomAnchor constraintEqualToAnchor:horizontal.contentLayoutGuide.bottomAnchor],[self.faderRow.heightAnchor constraintEqualToAnchor:horizontal.frameLayoutGuide.heightAnchor]]];
 [self rebuildFaders];
 UIStackView *presets=[UIStackView new];presets.axis=UILayoutConstraintAxisHorizontal;presets.spacing=7;presets.distribution=UIStackViewDistributionFillEqually;
 for(NSString *p in @[@"Flat",@"Bass",@"Vocal",@"Treble"]){UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];[b setTitle:p forState:UIControlStateNormal];b.titleLabel.font=[UIFont boldSystemFontOfSize:13];b.backgroundColor=[UIColor colorWithWhite:.17 alpha:1];b.layer.cornerRadius=7;[b addTarget:self action:@selector(presetTapped:) forControlEvents:UIControlEventTouchUpInside];[presets addArrangedSubview:b];}
 [presets.heightAnchor constraintEqualToConstant:40].active=YES;[root addArrangedSubview:presets];
 self.preampLabel=[self label:@"Preamp: 0 dB" size:14];[root addArrangedSubview:self.preampLabel];
 self.preampSlider=[UISlider new];self.preampSlider.minimumValue=-24;self.preampSlider.maximumValue=0;
 NSDictionary *d=[NSDictionary dictionaryWithContentsOfFile:kConfig] ?: @{};
 self.preampSlider.value=d[@"preamp"]?[d[@"preamp"] floatValue]:0;
 [self.preampSlider addTarget:self action:@selector(preampChanged) forControlEvents:UIControlEventValueChanged];
 [root addArrangedSubview:self.preampSlider];[self updatePreampLabel];
 self.selectedLabel=[self label:@"Band" size:15];[root addArrangedSubview:self.selectedLabel];
 self.typeControl=[[UISegmentedControl alloc] initWithItems:@[@"Peak",@"Low shelf",@"High shelf"]];
 [self.typeControl addTarget:self action:@selector(typeChanged) forControlEvents:UIControlEventValueChanged];[root addArrangedSubview:self.typeControl];
 [root addArrangedSubview:[self label:@"Selected frequency" size:12]];
 self.frequencySlider=[UISlider new];self.frequencySlider.minimumValue=0;self.frequencySlider.maximumValue=1;
 [self.frequencySlider addTarget:self action:@selector(frequencyChanged) forControlEvents:UIControlEventValueChanged];[root addArrangedSubview:self.frequencySlider];
 [root addArrangedSubview:[self label:@"Selected Q (bandwidth)" size:12]];
 self.qSlider=[UISlider new];self.qSlider.minimumValue=.2;self.qSlider.maximumValue=10;
 [self.qSlider addTarget:self action:@selector(qChanged) forControlEvents:UIControlEventValueChanged];[root addArrangedSubview:self.qSlider];
 UIStackView *actions=[UIStackView new];actions.axis=UILayoutConstraintAxisHorizontal;actions.distribution=UIStackViewDistributionFillEqually;
 for(NSString *title in @[@"+ Add band",@"Remove band"]){UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];[b setTitle:title forState:UIControlStateNormal];[b addTarget:self action:[title hasPrefix:@"+"]?@selector(addBand):@selector(removeBand) forControlEvents:UIControlEventTouchUpInside];[actions addArrangedSubview:b];}
 [root addArrangedSubview:actions];
 self.status=[self label:@"Settings reload within ~1 second. Audio routing is experimental." size:12];self.status.textColor=UIColor.lightGrayColor;self.status.numberOfLines=0;[root addArrangedSubview:self.status];
 [self updateSelected];
}
- (void)rebuildFaders {
 for(UIView *v in [self.faderRow.arrangedSubviews copy]){[self.faderRow removeArrangedSubview:v];[v removeFromSuperview];}
 NSInteger idx=0;
 for(NSDictionary *band in self.bands){
  UIStackView *col=[self column:2];col.alignment=UIStackViewAlignmentCenter;
  TimbreFader *slider=[TimbreFader new];slider.bandIndex=idx;slider.gain=[band[@"gain"] doubleValue];
  [slider.widthAnchor constraintEqualToConstant:52].active=YES;[slider.heightAnchor constraintEqualToConstant:195].active=YES;
  [slider addTarget:self action:@selector(faderMoved:) forControlEvents:UIControlEventValueChanged];
  [slider addTarget:self action:@selector(saveChanged) forControlEvents:UIControlEventEditingDidEnd];
  [col addArrangedSubview:slider];
  UIButton *select=[UIButton buttonWithType:UIButtonTypeSystem];select.tag=idx;
  double hz=[band[@"frequency"] doubleValue];[select setTitle:hz>=1000?[NSString stringWithFormat:@"%.1fk",hz/1000]:[NSString stringWithFormat:@"%.0f",hz] forState:UIControlStateNormal];
  select.titleLabel.font=[UIFont boldSystemFontOfSize:11];[select addTarget:self action:@selector(selectBand:) forControlEvents:UIControlEventTouchUpInside];
  [col addArrangedSubview:select];[self.faderRow addArrangedSubview:col];idx++;
 }
 [self.curve setNeedsDisplay];
}
- (void)faderMoved:(TimbreFader *)sender {
 [self bandAt:sender.bandIndex][@"gain"]=@(sender.gain);
 self.curve.bands=self.bands;[self.curve setNeedsDisplay];
}
- (void)selectBand:(UIButton *)sender{self.selected=sender.tag;[self updateSelected];}
- (void)updateSelected {
 if(self.selected>=self.bands.count)return;
 NSDictionary *b=[self bandAt:self.selected];double f=[b[@"frequency"] doubleValue];double q=[b[@"q"] doubleValue];
 self.selectedLabel.text=[NSString stringWithFormat:@"Band %ld    %.0f Hz    Q %.2f",(long)(self.selected+1),f,q];
 self.frequencySlider.value=log(f/20)/log(1000);self.qSlider.value=q;
 NSInteger t=[b[@"type"] integerValue];self.typeControl.selectedSegmentIndex=t==1?1:(t==2?2:0);
}
- (void)frequencyChanged {
 double f=20*pow(1000.,self.frequencySlider.value);[self bandAt:self.selected][@"frequency"]=@(round(f));
 [self updateSelected];[self rebuildFaders];[self saveChanged];
}
- (void)qChanged {[self bandAt:self.selected][@"q"]=@(self.qSlider.value);[self updateSelected];[self saveChanged];}
- (void)typeChanged {[self bandAt:self.selected][@"type"]=@(self.typeControl.selectedSegmentIndex);[self saveChanged];}
- (void)updatePreampLabel {self.preampLabel.text=[NSString stringWithFormat:@"Preamp: %.1f dB",self.preampSlider.value];}
- (void)preampChanged {[self updatePreampLabel];[self saveChanged];}
- (void)presetTapped:(UIButton *)sender {
 NSString *name=sender.currentTitle;
 for(NSInteger i=0;i<self.bands.count;i++){
  double f=[[self bandAt:i][@"frequency"] doubleValue],gain=0;
  if([name isEqual:@"Bass"] && f<=250)gain=5;
  if([name isEqual:@"Vocal"] && f>=500 && f<=4000)gain=3;
  if([name isEqual:@"Treble"] && f>=4000)gain=5;
  [self bandAt:i][@"gain"]=@(gain);
 }
 self.preampSlider.value=[name isEqual:@"Flat"]?0:-6;
 [self updatePreampLabel];[self rebuildFaders];[self saveChanged];
}
- (void)addBand {if(self.bands.count>=12)return;
 [self.bands addObject:[@{@"enabled":@YES,@"type":@0,@"frequency":@1000,@"gain":@0,@"q":@1.0} mutableCopy]];
 self.selected=self.bands.count-1;[self rebuildFaders];[self updateSelected];[self saveChanged];
}
- (void)removeBand {if(self.bands.count<=1)return;
 [self.bands removeObjectAtIndex:self.selected];self.selected=MIN(self.selected,(NSInteger)self.bands.count-1);
 [self rebuildFaders];[self updateSelected];[self saveChanged];
}
- (void)saveChanged {
 NSDictionary *d=@{@"enabled":@(self.power.on),@"preamp":@(self.preampSlider.value),@"bands":[self.bands copy]};
 BOOL ok=[d writeToFile:kConfig atomically:YES];
 self.status.text=ok?@"Saved. Changes reload automatically (experimental audio route).":@"Could not write preferences. Check file permissions.";
}
@end
@interface TimbreAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation TimbreAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
 self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
 self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:[TimbreController new]];
 [self.window makeKeyAndVisible];return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(TimbreAppDelegate.class));}}
