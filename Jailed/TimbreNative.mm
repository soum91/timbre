#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach-o/dyld.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#include <dlfcn.h>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <complex>
#include "fishhook.h"
#include "../NativeDSP/TimbreDSP.hpp"


namespace {
// Observe result codes and group names only. Retry the single confirmed denied
// login namespace in this signed app\'s own default group. Never inspect values.
using TBKCopy=OSStatus(*)(CFDictionaryRef,CFTypeRef *);
using TBKAdd=OSStatus(*)(CFDictionaryRef,CFTypeRef *);
using TBKUpdate=OSStatus(*)(CFDictionaryRef,CFDictionaryRef);
using TBKDelete=OSStatus(*)(CFDictionaryRef);
static TBKCopy tbCopy=nullptr;
static TBKAdd tbAdd=nullptr;
static TBKUpdate tbUpdate=nullptr;
static TBKDelete tbDelete=nullptr;
static os_unfair_lock tbKeyLock=OS_UNFAIR_LOCK_INIT;
static uint64_t tbKeyCalls=0,tbKeyDenied=0,tbKeyRetries=0,tbKeyRetryOK=0;
static NSString *tbKeyFailure=@"No keychain failure observed";
static NSString *tbPrivateGroup=nil;
static NSMutableArray<NSString *> *tbUnresolved=nil;
static uint64_t tbRetrySuccess=0,tbRetryMissing=0,tbRetryDuplicate=0;
static void tbKeepFailure(NSString *message) {
    if(!tbUnresolved)tbUnresolved=[NSMutableArray array];
    if(![tbUnresolved containsObject:message]) {
        if(tbUnresolved.count>=8)[tbUnresolved removeObjectAtIndex:0];
        [tbUnresolved addObject:message];
    }
}
// Discover the default group granted to this signed app. The random, empty
// probe is deleted immediately and contains no account or session information.
static void tbDiscoverPrivateGroup() {
    if(!tbAdd||!tbDelete)return;
    NSString *service=[@"Timbre.KeychainProbe." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSDictionary *identity=@{@"class":@"genp",@"svce":service,@"acct":@"probe"};
    NSMutableDictionary *q=[identity mutableCopy];
    q[@"v_Data"]=[NSData data];q[@"r_Attributes"]=@YES;
    CFTypeRef out=nullptr;
    OSStatus status=tbAdd((__bridge CFDictionaryRef)q,&out);
    if(status==0 && out && CFGetTypeID(out)==CFDictionaryGetTypeID()) {
        id group=((__bridge NSDictionary *)out)[@"agrp"];
        if([group isKindOfClass:NSString.class])tbPrivateGroup=[group copy];
    }
    if(out)CFRelease(out);
    if(status==0)tbDelete((__bridge CFDictionaryRef)identity);
}
static NSDictionary *tbRetryQuery(CFDictionaryRef query,OSStatus result) {
    if(result!=-34018||!tbPrivateGroup||!query)return nil;
    NSDictionary *q=(__bridge NSDictionary *)query;
    if(![q[@"agrp"] isEqual:@"J7P34ALZ5R.com.amazon.mp3.AmazonCloudPlayer"])return nil;
    NSMutableDictionary *mapped=[q mutableCopy];mapped[@"agrp"]=tbPrivateGroup;
    return mapped;
}
static void tbRecordRetry(OSStatus result) {
    os_unfair_lock_lock(&tbKeyLock);tbKeyRetries++;
    // Missing item and duplicate item are normal keychain lookup outcomes.
    if(result==0||result==-25300||result==-25299)tbKeyRetryOK++;
    if(result==0)tbRetrySuccess++;
    else if(result==-25300)tbRetryMissing++;
    else if(result==-25299)tbRetryDuplicate++;
    else tbKeepFailure([NSString stringWithFormat:@"Private-group retry failed: %d",(int)result]);
    tbKeyFailure=[NSString stringWithFormat:@"Private-group retry: %d",(int)result];
    os_unfair_lock_unlock(&tbKeyLock);
}

static void tbRecord(NSString *operation,CFDictionaryRef query,OSStatus result) {
    if(!query)return;
    NSDictionary *q=(__bridge NSDictionary *)query;
    id group=q[@"agrp"];
    NSString *name=[group isKindOfClass:NSString.class]?group:@"default group";
    os_unfair_lock_lock(&tbKeyLock);
    tbKeyCalls++;
    if(result==-34018)tbKeyDenied++;
    if(result!=0 && result!=-25300 && result!=-25299 &&
       !(result==-34018 && tbPrivateGroup &&
         [name isEqual:@"J7P34ALZ5R.com.amazon.mp3.AmazonCloudPlayer"]))
        tbKeepFailure([NSString stringWithFormat:@"%@: %d · %@",operation,(int)result,name]);
    if(result!=0 && result!=-25300 && result!=-25299)
        tbKeyFailure=[NSString stringWithFormat:@"%@: %d · %@",operation,(int)result,name];
    os_unfair_lock_unlock(&tbKeyLock);
}
static OSStatus tbCopyCall(CFDictionaryRef q,CFTypeRef *out) {
    OSStatus r=tbCopy?tbCopy(q,out):-4;tbRecord(@"Read",q,r);
    NSDictionary *mapped=tbRetryQuery(q,r);
    if(mapped){r=tbCopy((__bridge CFDictionaryRef)mapped,out);tbRecordRetry(r);}
    return r;
}
static OSStatus tbAddCall(CFDictionaryRef q,CFTypeRef *out) {
    OSStatus r=tbAdd?tbAdd(q,out):-4;tbRecord(@"Add",q,r);
    NSDictionary *mapped=tbRetryQuery(q,r);
    if(mapped){r=tbAdd((__bridge CFDictionaryRef)mapped,out);tbRecordRetry(r);}
    return r;
}
static OSStatus tbUpdateCall(CFDictionaryRef q,CFDictionaryRef attrs) {
    OSStatus r=tbUpdate?tbUpdate(q,attrs):-4;tbRecord(@"Update",q,r);
    NSDictionary *mapped=tbRetryQuery(q,r);
    if(mapped){r=tbUpdate((__bridge CFDictionaryRef)mapped,attrs);tbRecordRetry(r);}
    return r;
}
static OSStatus tbDeleteCall(CFDictionaryRef q) {
    OSStatus r=tbDelete?tbDelete(q):-4;tbRecord(@"Delete",q,r);
    NSDictionary *mapped=tbRetryQuery(q,r);
    if(mapped){r=tbDelete((__bridge CFDictionaryRef)mapped);tbRecordRetry(r);}
    return r;
}
static NSString *tbKeyStatus() {
    os_unfair_lock_lock(&tbKeyLock);
    NSString *s=[NSString stringWithFormat:@"Calls: %llu · denied: %llu\nPrivate group: %@\nRetry success: %llu · absent: %llu · duplicate: %llu\nUnresolved errors:\n%@\nLatest: %@",
        (unsigned long long)tbKeyCalls,(unsigned long long)tbKeyDenied,
        tbPrivateGroup?@"available":@"unavailable",
        (unsigned long long)tbRetrySuccess,(unsigned long long)tbRetryMissing,
        (unsigned long long)tbRetryDuplicate,
        tbUnresolved.count?[tbUnresolved componentsJoinedByString:@"\n"]:@"None observed",
        tbKeyFailure];
    os_unfair_lock_unlock(&tbKeyLock);return s;
}
static void tbObserveKeychain(const mach_header *header,intptr_t slide) {
    if(!tbCopy||!tbAdd||!tbUpdate||!tbDelete)return;
    Dl_info info{};if(!dladdr(header,&info)||!info.dli_fname)return;
    if(!strstr(info.dli_fname,"/AmazonCloudPlayer.app/")||
       strstr(info.dli_fname,"TimbreNative-FlareStore.dylib"))return;
    rebinding hooks[]={
        {"SecItemCopyMatching",(void *)tbCopyCall,nullptr},
        {"SecItemAdd",(void *)tbAddCall,nullptr},
        {"SecItemUpdate",(void *)tbUpdateCall,nullptr},
        {"SecItemDelete",(void *)tbDeleteCall,nullptr}
    };
    rebind_symbols_image((void *)header,slide,hooks,4);
}
}

// App-local DSP. No daemon injection, inline code patching, audio export or DRM hooks.
namespace {
constexpr int MaxBands=64, MaxStreams=12, Chunk=512;
struct BandSettings {
    std::atomic<float> hz{1000}, gain{0}, q{1};
    std::atomic<int> type{0};
    std::atomic<bool> on{true};
};
struct Settings {
    BandSettings bands[MaxBands];
    std::atomic<int> count{10};
    std::atomic<bool> on{false}, comp{false}, crossfeed{false}, spatial{false}, reverb{false}, stereo{false};
    std::atomic<float> preamp{-6}, width{1};
    std::atomic<uint64_t> generation{1};
} settings;
std::atomic<uint64_t> callbacks{0}, processed{0}, rejected{0}, busy{0}, registrations{0};
std::atomic<uint64_t> lastProcessed{0};
std::atomic<int> hookedImages{0}, lastReject{0};
std::atomic<double> observedRate{0};
struct Stream {
    AUGraph graph=nullptr; AUNode node=0; UInt32 bus=0;
    AURenderCallbackStruct source{};
    AudioStreamBasicDescription format{};
    std::atomic<bool> ready{false};
    std::atomic_flag rendering=ATOMIC_FLAG_INIT;
    timbre::Coeffs coeff[MaxBands]{};
    double z1[MaxBands][2]{}, z2[MaxBands][2]{};
    size_t bandCount=0; uint64_t generation=0;
    double gain=1; bool enabled=false;
    std::unique_ptr<timbre::Effects> effects;
    bool effectsReady=false;
};
Stream streams[MaxStreams];
std::atomic<int> used{0};
static os_unfair_lock registryLock=OS_UNFAIR_LOCK_INIT;
static NSString *const SettingsKey=@"TimbreNative.v1";
static const float Defaults[]={31,62,125,250,500,1000,2000,4000,8000,16000};

static void saveSettings() {
    NSMutableArray *bands=[NSMutableArray array];
    for(int i=0;i<settings.count.load();i++) {
        auto &b=settings.bands[i];
        [bands addObject:@{@"hz":@(b.hz.load()),@"gain":@(b.gain.load()),@"q":@(b.q.load()),@"type":@(b.type.load()),@"on":@(b.on.load())}];
    }
    [[NSUserDefaults standardUserDefaults] setObject:@{@"bands":bands,@"enabled":@(settings.on.load()),@"preamp":@(settings.preamp.load()),@"comp":@(settings.comp.load()),@"crossfeed":@(settings.crossfeed.load()),@"spatial":@(settings.spatial.load()),@"reverb":@(settings.reverb.load()),@"stereo":@(settings.stereo.load()),@"width":@(settings.width.load())} forKey:SettingsKey];
}
static void changed() { settings.generation.fetch_add(1,std::memory_order_release); saveSettings(); }
static float bounded(id x,float fallback,float lo,float hi) {
    if(![x isKindOfClass:NSNumber.class]) return fallback;
    float v=[x floatValue]; return std::isfinite(v)?std::clamp(v,lo,hi):fallback;
}
static void loadSettings() {
    for(int i=0;i<10;i++) settings.bands[i].hz=Defaults[i];
    NSDictionary *d=[[NSUserDefaults standardUserDefaults] dictionaryForKey:SettingsKey];
    if(!d)return;
    NSArray *bands=[d[@"bands"] isKindOfClass:NSArray.class]?d[@"bands"]:nil;
    if(bands.count && bands.count<=MaxBands) {
        settings.count=(int)bands.count;
        for(int i=0;i<(int)bands.count;i++) {
            if(![bands[i] isKindOfClass:NSDictionary.class])continue;
            NSDictionary *v=bands[i]; auto &b=settings.bands[i];
            b.hz=bounded(v[@"hz"],1000,20,20000); b.gain=bounded(v[@"gain"],0,-24,12);
            b.q=bounded(v[@"q"],1,0.05,40);b.type=(int)bounded(v[@"type"],0,0,7);b.on=v[@"on"]?[v[@"on"] boolValue]:true;
        }
    }
    settings.on=[d[@"enabled"] boolValue];settings.preamp=bounded(d[@"preamp"],-6,-30,0);
    settings.comp=[d[@"comp"] boolValue];settings.crossfeed=[d[@"crossfeed"] boolValue];
    settings.spatial=[d[@"spatial"] boolValue];settings.reverb=[d[@"reverb"] boolValue];
    settings.stereo=[d[@"stereo"] boolValue];settings.width=bounded(d[@"width"],1,0,2);
}
static void configure(Stream &s) noexcept {
    auto generation=settings.generation.load(std::memory_order_acquire);
    if(generation==s.generation)return;
    s.enabled=settings.on.load();s.gain=std::pow(10.,settings.preamp.load()/20.);
    // Reset filter memory after edits; all buffers were allocated during registration.
    s.bandCount=0;std::memset(s.z1,0,sizeof(s.z1));std::memset(s.z2,0,sizeof(s.z2));
    int count=std::clamp(settings.count.load(),0,MaxBands);
    for(int i=0;i<count;i++) {
        auto &b=settings.bands[i];if(!b.on.load())continue;
        try { s.coeff[s.bandCount++]=timbre::coefficients({true,(timbre::FilterType)b.type.load(),b.hz.load(),b.gain.load(),b.q.load()},s.format.mSampleRate); }
        catch(...) { s.bandCount=0;break; }
    }
    if(s.effectsReady) {
        timbre::EffectsParams p;
        p.comp.on=settings.comp.load();p.crossfeed.on=settings.crossfeed.load();
        p.spatial.on=settings.spatial.load();p.spatial.mode=1;
        p.reverb.on=settings.reverb.load();p.reverb.mix=0.18;
        p.width.on=settings.stereo.load();p.width.width=settings.width.load();
        p.limiter.on=true;p.limiter.ceiling=-1;
        s.effects->configure(p);
    }
    s.generation=generation;
}
static void processChunk(Stream &s,float *data,UInt32 n) noexcept {
    for(UInt32 i=0;i<n;i++)for(int ch=0;ch<2;ch++) {
        double x=data[i*2+ch]*s.gain;
        for(size_t j=0;j<s.bandCount;j++) {
            const auto &k=s.coeff[j];double y=k.b0*x+s.z1[j][ch];
            s.z1[j][ch]=k.b1*x-k.a1*y+s.z2[j][ch];s.z2[j][ch]=k.b2*x-k.a2*y;x=y;
        }
        data[i*2+ch]=std::isfinite(x)?(float)x:0;
    }
    if(s.effectsReady)s.effects->process(data,n);
    else for(UInt32 i=0;i<n*2;i++)data[i]=std::clamp(data[i],-0.89125f,0.89125f);
}
static OSStatus render(void *ctx,AudioUnitRenderActionFlags *flags,const AudioTimeStamp *time,UInt32 bus,UInt32 frames,AudioBufferList *buffers) {
    auto &s=*static_cast<Stream *>(ctx);
    // The original callback owns decoding and playback; only its successful PCM output is processed.
    OSStatus result=s.source.inputProc(s.source.inputProcRefCon,flags,time,bus,frames,buffers);
    callbacks.fetch_add(1,std::memory_order_relaxed);
    if(result!=noErr || !s.ready.load(std::memory_order_acquire) || !buffers || !frames)return result;
    if(s.rendering.test_and_set(std::memory_order_acquire)){busy.fetch_add(1);return result;}
    const auto &f=s.format;
    const bool fl=(f.mFormatFlags&kAudioFormatFlagIsFloat)&&f.mBitsPerChannel==32;
    const bool i16=!(f.mFormatFlags&kAudioFormatFlagIsFloat)&&(f.mFormatFlags&kAudioFormatFlagIsSignedInteger)&&f.mBitsPerChannel==16;
    const bool planar=buffers->mNumberBuffers==2&&buffers->mBuffers[0].mNumberChannels==1&&buffers->mBuffers[1].mNumberChannels==1;
    const bool inter=buffers->mNumberBuffers==1&&buffers->mBuffers[0].mNumberChannels==2;
    int reject=0;
    if(f.mFormatID!=kAudioFormatLinearPCM)reject=1;
    else if((!fl&&!i16)||(f.mFormatFlags&kAudioFormatFlagIsBigEndian))reject=2;
    else if(f.mChannelsPerFrame!=2||(!planar&&!inter))reject=3;
    else if(frames>(1u<<20))reject=4;
    else for(UInt32 i=0;i<buffers->mNumberBuffers;i++) {
        auto &b=buffers->mBuffers[i];
        if(!b.mData||b.mDataByteSize<(uint64_t)frames*b.mNumberChannels*(fl?4:2)){reject=4;break;}
    }
    if(reject){lastReject=reject;rejected.fetch_add(1);s.rendering.clear(std::memory_order_release);return result;}
    observedRate=f.mSampleRate;configure(s);
    if(s.enabled && !(flags && (*flags&kAudioUnitRenderAction_OutputIsSilence))) {
        float scratch[Chunk*2];
        for(UInt32 at=0;at<frames;at+=Chunk) {
            UInt32 n=std::min((UInt32)Chunk,frames-at);
            for(UInt32 i=0;i<n;i++)for(UInt32 ch=0;ch<2;ch++) {
                const auto &b=buffers->mBuffers[planar?ch:0];size_t idx=planar?(at+i):(2*(at+i)+ch);
                scratch[2*i+ch]=fl?static_cast<float *>(b.mData)[idx]:static_cast<int16_t *>(b.mData)[idx]/32768.f;
            }
            processChunk(s,scratch,n);
            for(UInt32 i=0;i<n;i++)for(UInt32 ch=0;ch<2;ch++) {
                auto &b=buffers->mBuffers[planar?ch:0];size_t idx=planar?(at+i):(2*(at+i)+ch);
                if(fl)static_cast<float *>(b.mData)[idx]=scratch[2*i+ch];
                else static_cast<int16_t *>(b.mData)[idx]=(int16_t)std::lrintf(std::clamp(scratch[2*i+ch],-1.f,32767.f/32768.f)*32768.f);
            }
        }
        processed.fetch_add(frames,std::memory_order_relaxed);lastProcessed=mach_absolute_time();lastReject=0;
    }
    s.rendering.clear(std::memory_order_release);return result;
}
using SetCallbackFn=OSStatus(*)(AUGraph,AUNode,UInt32,const AURenderCallbackStruct *);
using StartFn=OSStatus(*)(AUGraph);
using DisposeFn=OSStatus(*)(AUGraph);
static SetCallbackFn realSet=nullptr;static StartFn realStart=nullptr;static DisposeFn realDispose=nullptr;
static void refreshFormat(Stream &s) {
    AudioUnit unit=nullptr;AudioStreamBasicDescription f{};UInt32 size=sizeof(f);
    bool ok=AUGraphNodeInfo(s.graph,s.node,nullptr,&unit)==noErr&&unit&&AudioUnitGetProperty(unit,kAudioUnitProperty_StreamFormat,kAudioUnitScope_Input,s.bus,&f,&size)==noErr;
    if(!ok||!std::isfinite(f.mSampleRate)||f.mSampleRate<8000||f.mSampleRate>192000)return;
    s.format=f;s.generation=0;s.effectsReady=s.effects&&s.effects->prepare(f.mSampleRate);
    s.ready.store(true,std::memory_order_release);
}
static OSStatus setCallback(AUGraph graph,AUNode node,UInt32 bus,const AURenderCallbackStruct *cb) {
    if(!realSet)return kAudio_ParamError;
    if(!cb||!cb->inputProc||cb->inputProc==render)return realSet(graph,node,bus,cb);
    os_unfair_lock_lock(&registryLock);
    // Reuse stopped or disposed graphs, so changing tracks does not exhaust the pool.
    // An active graph's producer is never rewritten under its render thread.
    Stream *slot=nullptr;
    for(int i=0;i<used.load();i++)if(streams[i].graph==graph&&streams[i].node==node&&streams[i].bus==bus){
        Boolean running=true;
        if(AUGraphIsRunning(graph,&running)!=noErr||running){os_unfair_lock_unlock(&registryLock);return realSet(graph,node,bus,cb);}
        slot=&streams[i];break;
    }
    if(!slot)for(int i=0;i<used.load();i++)if(!streams[i].graph){slot=&streams[i];break;}
    if(!slot&&used.load()<MaxStreams)slot=&streams[used.fetch_add(1)];
    if(!slot){os_unfair_lock_unlock(&registryLock);return realSet(graph,node,bus,cb);}
    slot->ready=false;slot->effectsReady=false;slot->generation=0;
    slot->graph=graph;slot->node=node;slot->bus=bus;slot->source=*cb;
    try {if(!slot->effects)slot->effects=std::make_unique<timbre::Effects>();}catch(...){}
    refreshFormat(*slot);
    AURenderCallbackStruct replacement{render,slot};
    OSStatus result=realSet(graph,node,bus,&replacement);
    if(result==noErr)registrations.fetch_add(1);
    else {slot->ready=false;slot->graph=nullptr;}
    os_unfair_lock_unlock(&registryLock);return result;
}
static OSStatus startGraph(AUGraph graph) {
    Boolean running=false;
    if(AUGraphIsRunning(graph,&running)==noErr&&running)return realStart?realStart(graph):kAudio_ParamError;
    os_unfair_lock_lock(&registryLock);
    for(int i=0;i<used.load();i++)if(streams[i].graph==graph)refreshFormat(streams[i]);
    os_unfair_lock_unlock(&registryLock);
    return realStart?realStart(graph):kAudio_ParamError;
}
static OSStatus disposeGraph(AUGraph graph) {
    OSStatus result=realDispose?realDispose(graph):kAudio_ParamError;
    if(result==noErr){os_unfair_lock_lock(&registryLock);for(int i=0;i<used.load();i++)if(streams[i].graph==graph){streams[i].ready=false;streams[i].graph=nullptr;}os_unfair_lock_unlock(&registryLock);}
    return result;
}
static void addedImage(const mach_header *header,intptr_t slide) {
    Dl_info info{};if(!dladdr(header,&info)||!info.dli_fname)return;
    if(!strstr(info.dli_fname,"/dmengine.framework/dmengine"))return;
    rebinding bindings[]={{"AUGraphSetNodeInputCallback",(void *)setCallback,nullptr},{"AUGraphStart",(void *)startGraph,nullptr},{"DisposeAUGraph",(void *)disposeGraph,nullptr}};
    if(rebind_symbols_image((void *)header,slide,bindings,3)==0)hookedImages.fetch_add(1);
}
} // namespace


@interface TBResponseView : UIView
@end
@implementation TBResponseView
- (void)drawRect:(CGRect)rect {
    CGRect a=CGRectInset(self.bounds,26,24);CGContextRef ctx=UIGraphicsGetCurrentContext();
    NSDictionary *attrs=@{NSFontAttributeName:[UIFont systemFontOfSize:10],NSForegroundColorAttributeName:UIColor.secondaryLabelColor};
    for(int db=-24;db<=24;db+=12){CGFloat y=CGRectGetMidY(a)-db*a.size.height/48;CGContextSetStrokeColorWithColor(ctx,UIColor.separatorColor.CGColor);CGContextMoveToPoint(ctx,a.origin.x,y);CGContextAddLineToPoint(ctx,CGRectGetMaxX(a),y);CGContextStrokePath(ctx);[[NSString stringWithFormat:@"%+d",db] drawAtPoint:CGPointMake(0,y-6) withAttributes:attrs];}
    for(double f:{20.,100.,1000.,10000.,20000.}){CGFloat px=a.origin.x+std::log(f/20.)/std::log(1000.)*a.size.width;NSString *label=f>=1000?[NSString stringWithFormat:@"%.0fk",f/1000]:[NSString stringWithFormat:@"%.0f",f];[label drawAtPoint:CGPointMake(px-8,CGRectGetMaxY(a)+5) withAttributes:attrs];}
    double rate=observedRate.load();if(rate<8000)rate=48000;
    timbre::Coeffs coeff[MaxBands];int n=0;
    for(int j=0;j<settings.count.load();j++){auto &b=settings.bands[j];if(!b.on.load())continue;try{coeff[n++]=timbre::coefficients({true,(timbre::FilterType)b.type.load(),b.hz.load(),b.gain.load(),b.q.load()},rate);}catch(...){}}
    UIBezierPath *path=[UIBezierPath bezierPath];
    for(int i=0;i<=200;i++){double f=20*std::pow(1000.,i/200.);auto z=std::polar(1.,-6.283185307179586*std::min(f,rate*0.499)/rate);double db=settings.preamp.load();
        for(int j=0;j<n;j++){auto &k=coeff[j];db+=20*std::log10(std::max(std::abs((k.b0+k.b1*z+k.b2*z*z)/(1.+k.a1*z+k.a2*z*z)),1e-9));}
        CGPoint p=CGPointMake(a.origin.x+i*a.size.width/200.,CGRectGetMidY(a)-std::clamp(db,-24.,24.)*a.size.height/48);if(i==0)[path moveToPoint:p];else[path addLineToPoint:p];}
    [UIColor.systemIndigoColor setStroke];path.lineWidth=2.5;[path stroke];
}
@end
@interface TBBandEditor : UITableViewController
@property(nonatomic) NSInteger bandIndex;
@end
@implementation TBBandEditor
- (void)viewDidLoad{[super viewDidLoad];self.title=[NSString stringWithFormat:@"Band %ld",(long)self.bandIndex+1];self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=100;}
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)section{return 5;}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)idx{
    auto &b=settings.bands[self.bandIndex];NSInteger r=idx.row;UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if(r==3){cell.textLabel.text=@"Filter";cell.detailTextLabel.text=@[@"Peak",@"Low shelf",@"High shelf",@"Low pass",@"High pass",@"Band pass",@"Notch",@"All pass"][std::clamp(b.type.load(),0,7)];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;return cell;}
    if(r==4){cell.textLabel.text=@"Enable band";UISwitch *sw=[UISwitch new];sw.on=b.on.load();[sw addTarget:self action:@selector(enabled:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=sw;return cell;}
    UILabel *label=[UILabel new];label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];label.tag=10;label.text=r==0?[NSString stringWithFormat:@"Frequency · %.0f Hz",b.hz.load()]:r==1?[NSString stringWithFormat:@"Gain · %+.1f dB",b.gain.load()]:[NSString stringWithFormat:@"Q · %.2f",b.q.load()];
    UISlider *slider=[UISlider new];slider.tag=r;slider.tintColor=UIColor.systemIndigoColor;slider.minimumValue=r==0?std::log10(20.f):r==1?-24:std::log10(0.05f);slider.maximumValue=r==0?std::log10(20000.f):r==1?12:std::log10(40.f);slider.value=r==0?std::log10(b.hz.load()):r==1?b.gain.load():std::log10(b.q.load());
    [slider addTarget:self action:@selector(adjust:) forControlEvents:UIControlEventValueChanged];[slider addTarget:self action:@selector(save:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[label,slider]];stack.axis=UILayoutConstraintAxisVertical;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=NO;[cell.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.leadingAnchor],[stack.trailingAnchor constraintEqualToAnchor:cell.contentView.layoutMarginsGuide.trailingAnchor],[stack.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:18],[stack.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-18]]];return cell;
}
- (void)adjust:(UISlider *)slider{auto &b=settings.bands[self.bandIndex];float v=slider.value;if(slider.tag==0)b.hz=std::pow(10.f,v);else if(slider.tag==1)b.gain=v;else b.q=std::pow(10.f,v);settings.generation.fetch_add(1,std::memory_order_release);UILabel *label=[slider.superview viewWithTag:10];label.text=slider.tag==0?[NSString stringWithFormat:@"Frequency · %.0f Hz",b.hz.load()]:slider.tag==1?[NSString stringWithFormat:@"Gain · %+.1f dB",b.gain.load()]:[NSString stringWithFormat:@"Q · %.2f",b.q.load()];}
- (void)save:(UISlider *)slider{saveSettings();}
- (void)enabled:(UISwitch *)sw{settings.bands[self.bandIndex].on=sw.on;changed();}
- (void)viewWillDisappear:(BOOL)animated{[super viewWillDisappear:animated];saveSettings();}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)idx{
    if(idx.row!=3)return;UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Filter type" message:nil preferredStyle:UIAlertControllerStyleActionSheet];NSArray *names=@[@"Peak",@"Low shelf",@"High shelf",@"Low pass",@"High pass",@"Band pass",@"Notch",@"All pass"];
    for(int i=0;i<8;i++){int type=i;[a addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){settings.bands[self.bandIndex].type=type;changed();[tv reloadData];}]];}
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.sourceView=[tv cellForRowAtIndexPath:idx];a.popoverPresentationController.sourceRect=[tv cellForRowAtIndexPath:idx].bounds;[self presentViewController:a animated:YES completion:nil];
}
@end

@interface TBNativeController : UITableViewController
@property(nonatomic,strong) NSTimer *statusTimer;
@property(nonatomic,strong) UISegmentedControl *pages;
@property(nonatomic,strong) TBResponseView *response;
@end
@implementation TBNativeController
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"Timbre";
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(close)];
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Presets" style:UIBarButtonItemStylePlain target:self action:@selector(presets)];
    self.view.tintColor=UIColor.systemIndigoColor;
    self.pages=[[UISegmentedControl alloc] initWithItems:@[@"Equalizer",@"Effects",@"Diagnostics"]];self.pages.selectedSegmentIndex=0;[self.pages addTarget:self action:@selector(pageChanged) forControlEvents:UIControlEventValueChanged];
    self.response=[TBResponseView new];self.response.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;self.response.layer.cornerRadius=18;[self pageChanged];
    self.statusTimer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];
}
- (void)close {[self.statusTimer invalidate];self.statusTimer=nil;[self dismissViewControllerAnimated:YES completion:nil];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];[self.statusTimer invalidate];self.statusTimer=nil;}
- (NSInteger)sourceSection:(NSInteger)section{return self.pages.selectedSegmentIndex==0?section+1:self.pages.selectedSegmentIndex==1?3:0;}
- (void)pageChanged{UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,self.tableView.bounds.size.width,self.pages.selectedSegmentIndex==0?238:62)];self.pages.frame=CGRectMake(20,12,header.bounds.size.width-40,34);self.pages.autoresizingMask=UIViewAutoresizingFlexibleWidth;[header addSubview:self.pages];if(self.pages.selectedSegmentIndex==0){self.response.frame=CGRectMake(20,62,header.bounds.size.width-40,164);self.response.autoresizingMask=UIViewAutoresizingFlexibleWidth;[header addSubview:self.response];}self.tableView.tableHeaderView=header;[self.tableView reloadData];}
- (void)viewWillAppear:(BOOL)animated{[super viewWillAppear:animated];[self.tableView reloadData];[self.response setNeedsDisplay];if(!self.statusTimer)self.statusTimer=[NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refreshStatus) userInfo:nil repeats:YES];}
- (void)viewDidLayoutSubviews{[super viewDidLayoutSubviews];UIView *h=self.tableView.tableHeaderView;if(h&&h.bounds.size.width!=self.tableView.bounds.size.width){CGRect f=h.frame;f.size.width=self.tableView.bounds.size.width;h.frame=f;self.tableView.tableHeaderView=h;}}
- (void)refreshStatus{if(self.pages.selectedSegmentIndex==2&&!self.tableView.tracking&&!self.tableView.dragging)[self.tableView reloadData];[self.response setNeedsDisplay];}
- (void)presets{
    UIAlertController *a=[UIAlertController alertControllerWithTitle:@"EQ presets" message:@"Replaces the current bands. Effects stay as configured." preferredStyle:UIAlertControllerStyleActionSheet];NSArray *names=@[@"Flat",@"Bass lift",@"Vocal focus",@"Treble lift"];
    for(int i=0;i<4;i++){int preset=i;[a addAction:[UIAlertAction actionWithTitle:names[i] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        const float gains[4][10]={{0,0,0,0,0,0,0,0,0,0},{4,4,3,1,0,0,0,0,0,0},{-2,-2,-1,0,1,3,3,1,0,-1},{0,0,0,0,0,0,1,2,3,3}};
        settings.count=10;for(int j=0;j<10;j++){auto &b=settings.bands[j];b.hz=Defaults[j];b.gain=gains[preset][j];b.q=1;b.type=0;b.on=true;}settings.preamp=preset==0?0:-6;changed();[self.tableView reloadData];[self.response setNeedsDisplay];
    }]];}[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];a.popoverPresentationController.barButtonItem=self.navigationItem.leftBarButtonItem;[self presentViewController:a animated:YES completion:nil];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {return self.pages.selectedSegmentIndex==0?2:1;}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {section=[self sourceSection:section];return section==0?4:section==1?2:section==2?settings.count.load()+1:6;}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {section=[self sourceSection:section];return @[@"Playback diagnostics",@"Master",@"Parametric EQ · tap to edit",@"Effects"][section];}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    section=[self sourceSection:section];
    if(section==0)return @"Play a track, enable Timbre, then use the -12 dB test. A rising processed-frame count and an audible volume change establish that this playback route reaches Timbre. Unsupported routes remain unchanged.";
    if(section==1)return @"A -1 dB limiter protects the output while Timbre is enabled. Settings are saved in this app.";
    if(section==2)return @"Tap a band for frequency, gain, Q and filter controls. Swipe to delete. Up to 64 bands.";
    return @"Spatial uses Timbre's existing stereo-to-binaural renderer. These effects require stereo at 96 kHz or below; EQ still supports higher rates.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)index {
    UITableViewCell *cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];NSInteger s=[self sourceSection:index.section],r=index.row;
    if(s==0){
        if(r==3){cell.textLabel.text=@"Login storage diagnostics";cell.detailTextLabel.text=tbKeyStatus();cell.detailTextLabel.numberOfLines=0;}
        if(r==0){cell.textLabel.text=hookedImages.load()?@"Native audio engine detected":@"Waiting for native audio engine";cell.detailTextLabel.text=[NSString stringWithFormat:@"Registrations: %llu · callbacks: %llu",(unsigned long long)registrations.load(),(unsigned long long)callbacks.load()];}
        if(r==1){cell.textLabel.text=[NSString stringWithFormat:@"Processed frames: %llu",(unsigned long long)processed.load()];cell.detailTextLabel.text=[NSString stringWithFormat:@"%.0f Hz · skipped: %llu · format reason: %d",observedRate.load(),(unsigned long long)rejected.load(),lastReject.load()];}
        if(r==2){cell.textLabel.text=@"Run -12 dB attenuation test";cell.textLabel.textColor=UIColor.systemBlueColor;cell.detailTextLabel.text=@"Enables Timbre with a clearly audible preamp cut";}
    } else if(s==1&&r==0){cell.textLabel.text=@"Enable Timbre";UISwitch *sw=[UISwitch new];sw.on=settings.on.load();sw.tag=100;[sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=sw;}
    else if(s==1){cell.textLabel.text=[NSString stringWithFormat:@"Preamp: %.1f dB",settings.preamp.load()];UISlider *slider=[[UISlider alloc] initWithFrame:CGRectMake(0,0,150,32)];slider.minimumValue=-30;slider.maximumValue=0;slider.value=settings.preamp.load();slider.tag=200;[slider addTarget:self action:@selector(slide:) forControlEvents:UIControlEventValueChanged];[slider addTarget:self action:@selector(slideEnd:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];cell.accessoryView=slider;}
    else if(s==2&&r==settings.count.load()){cell.textLabel.text=@"＋ Add band";cell.textLabel.textColor=UIColor.systemIndigoColor;}
    else if(s==2){auto &b=settings.bands[r];cell.textLabel.text=[NSString stringWithFormat:@"%ld · %.0f Hz    %+.1f dB",(long)r+1,b.hz.load(),b.gain.load()];cell.detailTextLabel.text=[NSString stringWithFormat:@"Q %.2f · %@ · %@",b.q.load(),@[@"Peak",@"Low shelf",@"High shelf",@"Low pass",@"High pass",@"Band pass",@"Notch",@"All pass"][std::clamp(b.type.load(),0,7)],b.on.load()?@"On":@"Bypassed"];cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;}
    else if(s==3&&r<5){cell.textLabel.text=@[@"Compressor",@"Crossfeed",@"Immersive spatial",@"Reverb",@"Stereo width"][r];UISwitch *sw=[UISwitch new];sw.tag=101+r;std::atomic<bool> *v[]={&settings.comp,&settings.crossfeed,&settings.spatial,&settings.reverb,&settings.stereo};sw.on=v[r]->load();[sw addTarget:self action:@selector(toggle:) forControlEvents:UIControlEventValueChanged];cell.accessoryView=sw;}
    else {cell.textLabel.text=[NSString stringWithFormat:@"Width: %.0f%%",settings.width.load()*100];UISlider *slider=[[UISlider alloc] initWithFrame:CGRectMake(0,0,150,32)];slider.minimumValue=0;slider.maximumValue=2;slider.value=settings.width.load();slider.tag=201;[slider addTarget:self action:@selector(slide:) forControlEvents:UIControlEventValueChanged];[slider addTarget:self action:@selector(slideEnd:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];cell.accessoryView=slider;}
    return cell;
}
- (void)toggle:(UISwitch *)sw {std::atomic<bool> *v[]={&settings.on,&settings.comp,&settings.crossfeed,&settings.spatial,&settings.reverb,&settings.stereo};int i=(int)sw.tag-100;if(i>=0&&i<6)*v[i]=sw.on;changed();}
- (void)slide:(UISlider *)slider {if(slider.tag==200)settings.preamp=slider.value;else settings.width=slider.value;settings.generation.fetch_add(1,std::memory_order_release);}
- (void)slideEnd:(UISlider *)slider {saveSettings();[self.tableView reloadData];}
- (void)addBand {int n=settings.count.load();if(n>=MaxBands)return;auto &b=settings.bands[n];b.hz=1000;b.gain=0;b.q=1;b.type=0;b.on=true;settings.count=n+1;changed();[self.tableView reloadData];}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)index {
    [tableView deselectRowAtIndexPath:index animated:YES];
    NSInteger section=[self sourceSection:index.section];
    if(section==0&&index.row==2){settings.preamp=-12;settings.on=true;changed();[tableView reloadData];return;}
    if(section!=2)return;if(index.row==settings.count.load()){[self addBand];return;}
    TBBandEditor *editor=[[TBBandEditor alloc] initWithStyle:UITableViewStyleInsetGrouped];editor.bandIndex=index.row;[self.navigationController pushViewController:editor animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)index {return [self sourceSection:index.section]==2&&index.row<settings.count.load();}
- (void)tableView:(UITableView *)tableView commitEditingStyle:(UITableViewCellEditingStyle)style forRowAtIndexPath:(NSIndexPath *)index {
    if(style!=UITableViewCellEditingStyleDelete)return;int n=settings.count.load();
    for(int i=(int)index.row;i<n-1;i++){auto &a=settings.bands[i],&b=settings.bands[i+1];a.hz=b.hz.load();a.gain=b.gain.load();a.q=b.q.load();a.type=b.type.load();a.on=b.on.load();}settings.count=n-1;changed();[tableView reloadData];
}
@end

@interface TBLauncher : NSObject
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,weak) UINavigationController *editorNavigation;
@end

static UIWindow *TBNativeWindow(void) {
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

@implementation TBLauncher
- (void)attach {
    UIWindow *window=TBNativeWindow();
    if(!window||!window.rootViewController)return;
    if(!self.button){self.button=[UIButton buttonWithType:UIButtonTypeSystem];[self.button setTitle:@"Timbre" forState:UIControlStateNormal];self.button.backgroundColor=UIColor.systemIndigoColor;[self.button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];self.button.layer.cornerRadius=18;self.button.accessibilityLabel=@"Open Timbre equalizer";[self.button addTarget:self action:@selector(open) forControlEvents:UIControlEventTouchUpInside];}
    if(self.button.superview!=window)[window addSubview:self.button];
    self.button.hidden=self.editorNavigation.presentingViewController!=nil;
    self.button.frame=CGRectMake(window.bounds.size.width-92,window.safeAreaInsets.top+8,82,36);[window bringSubviewToFront:self.button];
}
- (void)open {UIViewController *vc=self.button.window.rootViewController;while(vc.presentedViewController)vc=vc.presentedViewController;if([vc isKindOfClass:UINavigationController.class]&&[((UINavigationController *)vc).topViewController isKindOfClass:TBNativeController.class])return;TBNativeController *controller=[[TBNativeController alloc] initWithStyle:UITableViewStyleInsetGrouped];UINavigationController *nav=[[UINavigationController alloc] initWithRootViewController:controller];nav.modalInPresentation=YES;self.editorNavigation=nav;self.button.hidden=YES;[vc presentViewController:nav animated:YES completion:nil];}
@end

__attribute__((constructor)) static void launchTimbreNative() {
    @autoreleasepool {
        loadSettings();
        tbCopy=(TBKCopy)dlsym(RTLD_DEFAULT,"SecItemCopyMatching");
        tbAdd=(TBKAdd)dlsym(RTLD_DEFAULT,"SecItemAdd");
        tbUpdate=(TBKUpdate)dlsym(RTLD_DEFAULT,"SecItemUpdate");
        tbDelete=(TBKDelete)dlsym(RTLD_DEFAULT,"SecItemDelete");
        tbDiscoverPrivateGroup();
        _dyld_register_func_for_add_image(tbObserveKeychain);
        realSet=&AUGraphSetNodeInputCallback;realStart=&AUGraphStart;realDispose=&DisposeAUGraph;
        _dyld_register_func_for_add_image(addedImage);
        dispatch_async(dispatch_get_main_queue(),^{static TBLauncher *launcher=[TBLauncher new];[launcher attach];[NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){[launcher attach];}];});
    }
}
