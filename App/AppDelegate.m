#import "AppDelegate.h"
#import <AVFoundation/AVFoundation.h>
#import <math.h>

@interface AppDelegate () <AVAudioSessionDelegate>
{
    // 滤波状态（仅音频回调线程访问，最多2声道）
    float _filtXP[2];
    float _filtYPH[2];
    float _filtYPL[2];
}
// 音频
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioPlayerNode *player;
@property (nonatomic, assign) BOOL running;
// 参数（跨线程原子访问）
@property (atomic, assign) float gain;        // 0.5 ~ 6.0
@property (atomic, assign) BOOL bandPass;     // YES: 80~1000Hz带通, NO: 仅40Hz高通
// 滤波系数（按实际采样率在启动时计算）
@property (atomic, assign) float aH40;
@property (atomic, assign) float aH80;
@property (atomic, assign) float aL1k;
// 滤波状态（仅音频回调线程访问，最多2声道）
// （已改为实例变量，见类扩展块）
// UI（window 已在 AppDelegate.h 声明）
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UISlider *gainSlider;
@property (nonatomic, strong) UILabel *gainLabel;
@property (nonatomic, strong) UISwitch *bandPassSwitch;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)app
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.gain = 2.0f;
    self.bandPass = YES;

    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *vc = [UIViewController new];
    vc.view.backgroundColor = [UIColor systemBackgroundColor];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    [self buildUI:vc];

    // 权限申请放在 UI 出来之后
    [AVAudioSession.sharedInstance requestRecordPermission:^(BOOL granted) {
        NSLog(@"[FetalEar] 麦克风权限: %@", granted ? @"已授权" : @"被拒绝");
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!granted) self.statusLabel.text = @"麦克风权限被拒绝，请在 设置→隐私→麦克风 中开启";
        });
    }];

    // 监听蓝牙连接/断开等路由变化
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onRouteChange:)
                                                 name:AVAudioSessionRouteChangeNotification
                                               object:nil];
    // 引擎配置变化（插拔耳机导致重配置时引擎会自动停，需要重启）
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onEngineConfigChange:)
                                                 name:AVAudioEngineConfigurationChangeNotification
                                               object:self.engine];

    return YES;
}

// ------------------------------------------------------------------ UI

- (void)buildUI:(UIViewController *)vc {
    UIView *root = vc.view;
    CGFloat w = root.bounds.size.width;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 70, w, 34)];
    title.text = @"胎心耳返";
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    [root addSubview:title];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 116, w - 32, 44)];
    self.statusLabel.text = @"未运行 · 先连接蓝牙耳机";
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    [root addSubview:self.statusLabel];

    self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleButton.frame = CGRectMake(32, 172, w - 64, 56);
    self.toggleButton.layer.cornerRadius = 12;
    self.toggleButton.backgroundColor = [UIColor systemBlueColor];
    self.toggleButton.tintColor = [UIColor whiteColor];
    self.toggleButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [self.toggleButton setTitle:@"开始监听" forState:UIControlStateNormal];
    [self.toggleButton addTarget:self action:@selector(onToggle) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:self.toggleButton];

    UILabel *gainTitle = [[UILabel alloc] initWithFrame:CGRectMake(32, 250, w - 64, 22)];
    gainTitle.text = @"增益（音量放大倍数）";
    gainTitle.font = [UIFont systemFontOfSize:15];
    [root addSubview:gainTitle];

    self.gainSlider = [[UISlider alloc] initWithFrame:CGRectMake(32, 280, w - 64, 36)];
    self.gainSlider.minimumValue = 0.5f;
    self.gainSlider.maximumValue = 6.0f;
    self.gainSlider.value = 2.0f;
    [self.gainSlider addTarget:self action:@selector(onGainChange:) forControlEvents:UIControlEventValueChanged];
    [root addSubview:self.gainSlider];

    self.gainLabel = [[UILabel alloc] initWithFrame:CGRectMake(32, 318, w - 64, 22)];
    self.gainLabel.text = @"200%";
    self.gainLabel.font = [UIFont systemFontOfSize:14];
    self.gainLabel.textAlignment = NSTextAlignmentCenter;
    self.gainLabel.textColor = [UIColor secondaryLabelColor];
    [root addSubview:self.gainLabel];

    UILabel *bpTitle = [[UILabel alloc] initWithFrame:CGRectMake(32, 366, w - 64 - 60, 30)];
    bpTitle.text = @"带通滤波（80~1000Hz）";
    bpTitle.font = [UIFont systemFontOfSize:16];
    [root addSubview:bpTitle];

    self.bandPassSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 92, 366, 60, 30)];
    self.bandPassSwitch.on = YES;
    [self.bandPassSwitch addTarget:self action:@selector(onBandPassChange:) forControlEvents:UIControlEventValueChanged];
    [root addSubview:self.bandPassSwitch];

    UITextView *notes = [[UITextView alloc] initWithFrame:CGRectMake(24, 420, w - 48, 240)];
    notes.editable = NO;
    notes.scrollEnabled = NO;
    notes.backgroundColor = [UIColor clearColor];
    notes.font = [UIFont systemFontOfSize:13];
    notes.textColor = [UIColor secondaryLabelColor];
    notes.text = @"使用说明：\n1. 先连接蓝牙耳机，再点「开始监听」\n2. iPhone 麦克风贴近声源（胎心仪探头或腹部）\n3. 蓝牙链路有约0.2~0.4秒延迟，属正常现象\n4. 增益过大可能啸叫，注意扬声器音量\n5. 仅实时监听辅助，不录音不上传，不替代医疗诊断";
    [root addSubview:notes];
}

// ------------------------------------------------------------------ 音频

- (void)onToggle {
    if (self.running) {
        [self stopMonitor];
    } else {
        [self startMonitor];
    }
}

- (void)startMonitor {
    if (self.running) return;
    NSLog(@"[FetalEar] 开始监听");

    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *err = nil;
    // Measurement 模式：关闭系统自动增益，保留原始音色（对应安卓的 UNPROCESSED）
    // AllowBluetoothA2DP：允许输出走蓝牙耳机，同时内置麦克风继续可用（iOS13+）
    BOOL ok = [session setCategory:AVAudioSessionCategoryPlayAndRecord
                              mode:AVAudioSessionModeMeasurement
                           options:AVAudioSessionCategoryOptionAllowBluetoothA2DP
                             error:&err];
    if (!ok) {
        NSLog(@"[FetalEar] setCategory失败: %@", err);
        [self setStatus:[NSString stringWithFormat:@"音频会话设置失败: %@", err.localizedDescription]];
        return;
    }
    // 目标缓冲约20ms
    [session setPreferredIOBufferDuration:0.02 error:nil];
    ok = [session setActive:YES error:&err];
    if (!ok) {
        NSLog(@"[FetalEar] setActive失败: %@", err);
        [self setStatus:[NSString stringWithFormat:@"音频会话激活失败: %@", err.localizedDescription]];
        return;
    }

    self.engine = [[AVAudioEngine alloc] init];
    self.player = [[AVAudioPlayerNode alloc] init];
    [self.engine attachNode:self.player];

    AVAudioFormat *inFmt = [self.engine.inputNode outputFormatForBus:0];
    if (inFmt == nil || inFmt.sampleRate < 8000) {
        [self setStatus:@"无法获取麦克风格式"];
        return;
    }
    [self.engine connect:self.player to:self.engine.mainMixerNode format:inFmt];

    // 按实际采样率计算滤波系数
    double sr = inFmt.sampleRate;
    self.aH40 = (float)exp(-2.0 * M_PI * 40.0 / sr);
    self.aH80 = (float)exp(-2.0 * M_PI * 80.0 / sr);
    self.aL1k = (float)(1.0 - exp(-2.0 * M_PI * 1000.0 / sr));
    NSLog(@"[FetalEar] sr=%.0f aH40=%.4f aH80=%.4f aL1k=%.4f", sr, self.aH40, self.aH80, self.aL1k);

    // 滤波状态清零
    memset(_filtXP, 0, sizeof(_filtXP));
    memset(_filtYPH, 0, sizeof(_filtYPH));
    memset(_filtYPL, 0, sizeof(_filtYPL));

    __weak typeof(self) wself = self;
    [self.engine.inputNode installTapOnBus:0 bufferSize:1024 format:inFmt
                                     block:^(AVAudioPCMBuffer *buf, AVAudioTime *when) {
        [wself processBuffer:buf];
    }];

    err = nil;
    [self.engine prepare];
    ok = [self.engine startAndReturnError:&err];
    if (!ok) {
        NSLog(@"[FetalEar] 引擎启动失败: %@", err);
        [self setStatus:[NSString stringWithFormat:@"引擎启动失败: %@", err.localizedDescription]];
        [self.engine.inputNode removeTapOnBus:0];
        return;
    }
    [self.player play];

    self.running = YES;
    UIApplication.sharedApplication.idleTimerDisabled = YES; // 屏幕常亮
    [self.toggleButton setTitle:@"停止监听" forState:UIControlStateNormal];
    [self setStatus:[NSString stringWithFormat:@"监听中 · 输出：%@ · 延迟约0.2~0.4秒", [self currentOutputName]]];
    NSLog(@"[FetalEar] 监听已启动");
}

- (void)stopMonitor {
    if (!self.running) return;
    NSLog(@"[FetalEar] 停止监听");
    self.running = NO;

    [self.engine.inputNode removeTapOnBus:0];
    [self.player stop];
    [self.engine stop];
    self.engine = nil;
    self.player = nil;

    NSError *err = nil;
    [[AVAudioSession sharedInstance] setActive:NO
                                   withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                         error:&err];
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    [self.toggleButton setTitle:@"开始监听" forState:UIControlStateNormal];
    [self setStatus:@"已停止"];
}

// 音频回调：只做轻量 DSP（滤波+增益），不做任何磁盘/分配重活
- (void)processBuffer:(AVAudioPCMBuffer *)buf {
    if (!self.running) return;
    float **channels = buf.floatChannelData;
    NSUInteger frames = buf.frameLength;
    float g = self.gain;
    BOOL bp = self.bandPass;
    float aH = bp ? self.aH80 : self.aH40;
    BOOL useLp = bp;
    float aL = self.aL1k;

    for (NSUInteger c = 0; c < buf.format.channelCount && c < 2; c++) {
        float *p = channels[c];
        float xp = _filtXP[c];
        float ypH = _filtYPH[c];
        float ypL = _filtYPL[c];
        for (NSUInteger i = 0; i < frames; i++) {
            float x = p[i];
            float y = x - xp + aH * ypH;
            xp = x;
            ypH = y;
            if (useLp) {
                ypL += aL * (y - ypL);
                y = ypL;
            }
            float v = y * g;
            if (v > 1.0f) v = 1.0f;
            else if (v < -1.0f) v = -1.0f;
            p[i] = v;
        }
        _filtXP[c] = xp;
        _filtYPH[c] = ypH;
        _filtYPL[c] = ypL;
    }

    // 就地回放（处理后的同一个buffer调度到播放节点）
    [self.player scheduleBuffer:buf completionHandler:nil];
}

// ------------------------------------------------------------------ 路由/事件

- (void)onRouteChange:(NSNotification *)note {
    if (!self.running) return;
    AVAudioSessionRouteChangeReason reason =
        [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
    NSLog(@"[FetalEar] 路由变化 reason=%lu 输出=%@", (unsigned long)reason, [self currentOutputName]);
    [self setStatus:[NSString stringWithFormat:@"监听中 · 输出：%@ · 延迟约0.2~0.4秒", [self currentOutputName]]];
}

- (void)onEngineConfigChange:(NSNotification *)note {
    if (!self.running) return;
    NSLog(@"[FetalEar] 引擎配置变化，尝试重启");
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.running) return;
        [self stopMonitor];
        [self startMonitor];
    });
}

- (NSString *)currentOutputName {
    AVAudioSessionRouteDescription *route = AVAudioSession.sharedInstance.currentRoute;
    for (AVAudioSessionPortDescription *port in route.outputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortBluetoothA2DP])
            return [NSString stringWithFormat:@"蓝牙耳机 %@", port.portName];
        if ([port.portType isEqualToString:AVAudioSessionPortBluetoothLE])
            return [NSString stringWithFormat:@"蓝牙耳机 %@", port.portName];
        if ([port.portType isEqualToString:AVAudioSessionPortHeadphones])
            return [NSString stringWithFormat:@"有线耳机 %@", port.portName];
        if ([port.portType isEqualToString:AVAudioSessionPortBluetoothHFP])
            return [NSString stringWithFormat:@"蓝牙耳机 %@", port.portName];
    }
    return @"手机扬声器";
}

- (void)setStatus:(NSString *)s {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusLabel.text = s;
    });
    NSLog(@"[FetalEar] %@", s);
}

// ------------------------------------------------------------------ 控件回调

- (void)onGainChange:(UISlider *)slider {
    int pct = (int)roundf(slider.value * 100.0f);
    self.gain = slider.value;
    self.gainLabel.text = [NSString stringWithFormat:@"%d%%", pct];
}

- (void)onBandPassChange:(UISwitch *)sw {
    self.bandPass = sw.on;
    NSLog(@"[FetalEar] 带通滤波: %@", sw.on ? @"开" : @"关");
}

@end
