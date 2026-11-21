#import "AppDelegate.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <math.h>

#pragma mark - WaveView（实时/回放波形显示）

@interface WaveView : UIView
- (void)setData:(const float *)d length:(NSUInteger)n level:(float)rms;
@end

@implementation WaveView {
    float _data[600];
    NSUInteger _n;
    float _level;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.04];
        _n = 0;
        _level = 0;
        memset(_data, 0, sizeof(_data));
    }
    return self;
}

- (void)setData:(const float *)d length:(NSUInteger)n level:(float)rms {
    if (n > 600) n = 600;
    if (d != NULL && n > 0) memcpy(_data, d, n * sizeof(float));
    _n = n;
    _level = rms;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat midY = h / 2.0;

    [[UIColor colorWithWhite:0 alpha:0.25] set];
    UIBezierPath *base = [UIBezierPath bezierPath];
    [base moveToPoint:CGPointMake(0, midY)];
    [base addLineToPoint:CGPointMake(w, midY)];
    base.lineWidth = 1.0;
    [base stroke];

    if (_n > 1) {
        [[UIColor colorWithRed:0.18 green:0.49 blue:0.20 alpha:1] setStroke];
        UIBezierPath *p = [UIBezierPath bezierPath];
        CGFloat amp = h / 2.0 * 0.92;
        for (NSUInteger i = 0; i < _n; i++) {
            CGFloat x = w * (CGFloat)i / (CGFloat)(_n - 1);
            float v = _data[i];
            if (v > 1) v = 1; else if (v < -1) v = -1;
            CGFloat y = midY - v * amp;
            if (i == 0) [p moveToPoint:CGPointMake(x, y)];
            else [p addLineToPoint:CGPointMake(x, y)];
        }
        p.lineWidth = 2.0;
        [p stroke];
    }

    // 底部电平条
    CGFloat barW = MAX(0, MIN(1, _level * 4.0f)) * w;
    [[UIColor colorWithRed:0.08 green:0.40 blue:0.75 alpha:1] setFill];
    UIBezierPath *bar = [UIBezierPath bezierPathWithRect:CGRectMake(0, h - 8, barW, 8)];
    [bar fill];
}

@end

#pragma mark - AppDelegate

@interface AppDelegate () <AVAudioSessionDelegate, AVAudioPlayerDelegate>
{
    // 滤波状态（仅音频回调线程访问，最多2声道）
    float _filtXP[2];
    float _filtYPH[2];
    float _filtYPL[2];
    // 实时波形环（回调写，UI读，锁保护）
    float _waveRing[1200];
    NSInteger _wavePos;
    NSLock *_waveLock;
    float _level;
    AVAudioFormat *_inFmt; // 强引用输入格式
}
// 音频
@property (nonatomic, strong) AVAudioEngine *engine;
@property (nonatomic, strong) AVAudioPlayerNode *player;
@property (nonatomic, assign) BOOL running;
// 参数（跨线程原子访问）
@property (atomic, assign) float gain;        // 0.5 ~ 20.0
// 滤波模式：0=原始（真正零处理，直通） 1=宽带80~1kHz 2=心跳20~250Hz
// ★ 默认 0（原始）——用户要的是不降噪的原始声音
@property (atomic, assign) NSInteger filterMode;
// 录音
@property (atomic, assign) BOOL recording;
@property (atomic, strong) AVAudioFile *recFile;
@property (atomic, strong) NSURL *recURL;
// 回放
@property (nonatomic, strong) AVAudioPlayer *audioPlayer;
// 滤波系数（按实际采样率在启动时计算）
@property (atomic, assign) float aH80;
@property (atomic, assign) float aH20;
@property (atomic, assign) float aL1k;
@property (atomic, assign) float aL250;
// UI（window 已在 AppDelegate.h 声明）
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UISlider *gainSlider;
@property (nonatomic, strong) UILabel *gainLabel;
@property (nonatomic, strong) UISegmentedControl *filterSeg;
@property (nonatomic, strong) WaveView *liveWave;
@property (nonatomic, strong) UISlider *zoomSlider;
@property (nonatomic, strong) UILabel *zoomValueLabel;
@property (nonatomic, strong) UISwitch *recordSwitch;
@property (nonatomic, strong) UILabel *recFileLabel;
@property (nonatomic, strong) UIButton *playButton;
@property (nonatomic, strong) WaveView *playWave;
@property (nonatomic, strong) NSTimer *uiTimer;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)app
        didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.gain = 3.0f;
    self.filterMode = 0;      // ★ 默认「原始」：不滤波，直通
    _waveLock = [[NSLock alloc] init];
    _wavePos = 0;
    memset(_waveRing, 0, sizeof(_waveRing));

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

    // UI 刷新定时器：约30fps
    __weak typeof(self) wself = self;
    self.uiTimer = [NSTimer timerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer *t) {
        [wself refreshWaveUI];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.uiTimer forMode:NSRunLoopCommonModes];

    return YES;
}

// ------------------------------------------------------------------ UI

- (void)buildUI:(UIViewController *)vc {
    UIView *root = vc.view;
    CGFloat w = root.bounds.size.width;

    // 整页滚动容器（控件多，小屏也能滚到底）
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:root.bounds];
    scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    scroll.alwaysBounceVertical = YES;
    [root addSubview:scroll];
    UIView *content = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, 960)];
    scroll.contentSize = CGSizeMake(w, 960);
    [scroll addSubview:content];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 24, w, 34)];
    title.text = @"胎心耳返";
    title.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;
    [content addSubview:title];

    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 64, w - 32, 40)];
    self.statusLabel.text = @"未运行 · 先连接蓝牙耳机";
    self.statusLabel.font = [UIFont systemFontOfSize:14];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 2;
    self.statusLabel.textColor = [UIColor secondaryLabelColor];
    [content addSubview:self.statusLabel];

    self.toggleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.toggleButton.frame = CGRectMake(32, 112, w - 64, 52);
    self.toggleButton.layer.cornerRadius = 12;
    self.toggleButton.backgroundColor = [UIColor systemBlueColor];
    self.toggleButton.tintColor = [UIColor whiteColor];
    self.toggleButton.titleLabel.font = [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold];
    [self.toggleButton setTitle:@"开始监听" forState:UIControlStateNormal];
    [self.toggleButton addTarget:self action:@selector(onToggle) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.toggleButton];

    UILabel *gainTitle = [[UILabel alloc] initWithFrame:CGRectMake(32, 180, w - 64, 22)];
    gainTitle.text = @"增益（音量放大倍数）";
    gainTitle.font = [UIFont systemFontOfSize:15];
    [content addSubview:gainTitle];

    self.gainSlider = [[UISlider alloc] initWithFrame:CGRectMake(32, 206, w - 64, 36)];
    self.gainSlider.minimumValue = 0.5f;
    self.gainSlider.maximumValue = 20.0f;     // ★ 最大 20 倍（用户要求）
    self.gainSlider.value = 20.0f;            // ★ 默认拉满
    [self.gainSlider addTarget:self action:@selector(onGainChange:) forControlEvents:UIControlEventValueChanged];
    [content addSubview:self.gainSlider];

    self.gainLabel = [[UILabel alloc] initWithFrame:CGRectMake(32, 244, w - 64, 20)];
    self.gainLabel.text = @"2000%";
    self.gainLabel.font = [UIFont systemFontOfSize:14];
    self.gainLabel.textAlignment = NSTextAlignmentCenter;
    self.gainLabel.textColor = [UIColor secondaryLabelColor];
    [content addSubview:self.gainLabel];

    UILabel *filterTitle = [[UILabel alloc] initWithFrame:CGRectMake(32, 276, w - 64, 22)];
    filterTitle.text = @"滤波模式（默认原始＝完全不处理）";
    filterTitle.font = [UIFont systemFontOfSize:15];
    [content addSubview:filterTitle];

    // ★ 「原始」放第一项并默认选中：进去就是零处理直通
    self.filterSeg = [[UISegmentedControl alloc] initWithItems:@[@"原始", @"宽带 80~1kHz", @"心跳 20~250Hz"]];
    self.filterSeg.frame = CGRectMake(32, 300, w - 64, 32);
    self.filterSeg.selectedSegmentIndex = 0;
    [self.filterSeg addTarget:self action:@selector(onFilterChange:) forControlEvents:UIControlEventValueChanged];
    [content addSubview:self.filterSeg];

    UILabel *waveTitle = [[UILabel alloc] initWithFrame:CGRectMake(32, 344, w - 64, 20)];
    waveTitle.text = @"实时波形";
    waveTitle.font = [UIFont systemFontOfSize:15];
    [content addSubview:waveTitle];

    self.liveWave = [[WaveView alloc] initWithFrame:CGRectMake(16, 368, w - 32, 120)];
    [content addSubview:self.liveWave];

    UILabel *zoomTitle = [[UILabel alloc] initWithFrame:CGRectMake(32, 498, 80, 22)];
    zoomTitle.text = @"波形放大";
    zoomTitle.font = [UIFont systemFontOfSize:15];
    [content addSubview:zoomTitle];

    self.zoomSlider = [[UISlider alloc] initWithFrame:CGRectMake(116, 494, w - 200, 32)];
    self.zoomSlider.minimumValue = 0;
    self.zoomSlider.maximumValue = 7;
    self.zoomSlider.value = 0;
    [self.zoomSlider addTarget:self action:@selector(onZoomChange:) forControlEvents:UIControlEventValueChanged];
    [content addSubview:self.zoomSlider];

    self.zoomValueLabel = [[UILabel alloc] initWithFrame:CGRectMake(w - 78, 498, 64, 22)];
    self.zoomValueLabel.text = @"1x";
    self.zoomValueLabel.font = [UIFont systemFontOfSize:15];
    self.zoomValueLabel.textAlignment = NSTextAlignmentRight;
    self.zoomValueLabel.textColor = [UIColor secondaryLabelColor];
    [content addSubview:self.zoomValueLabel];

    UILabel *recTitle = [[UILabel alloc] initWithFrame:CGRectMake(32, 538, w - 120, 24)];
    recTitle.text = @"录音保存（监听时录制 WAV）";
    recTitle.font = [UIFont systemFontOfSize:15];
    [content addSubview:recTitle];

    self.recordSwitch = [[UISwitch alloc] initWithFrame:CGRectMake(w - 92, 532, 60, 32)];
    self.recordSwitch.on = NO;
    [self.recordSwitch addTarget:self action:@selector(onRecordChange:) forControlEvents:UIControlEventValueChanged];
    [content addSubview:self.recordSwitch];

    self.recFileLabel = [[UILabel alloc] initWithFrame:CGRectMake(32, 566, w - 64, 18)];
    self.recFileLabel.font = [UIFont systemFontOfSize:11];
    self.recFileLabel.textColor = [UIColor tertiaryLabelColor];
    self.recFileLabel.text = @"";
    [content addSubview:self.recFileLabel];

    self.playButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.playButton.frame = CGRectMake(32, 594, w - 64, 46);
    self.playButton.layer.cornerRadius = 10;
    self.playButton.backgroundColor = [UIColor secondarySystemFillColor];
    self.playButton.tintColor = [UIColor labelColor];
    self.playButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    [self.playButton setTitle:@"回放最近录音" forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(onPlayToggle) forControlEvents:UIControlEventTouchUpInside];
    [content addSubview:self.playButton];

    self.playWave = [[WaveView alloc] initWithFrame:CGRectMake(16, 648, w - 32, 110)];
    [content addSubview:self.playWave];

    UITextView *notes = [[UITextView alloc] initWithFrame:CGRectMake(24, 772, w - 48, 180)];
    notes.editable = NO;
    notes.scrollEnabled = NO;
    notes.backgroundColor = [UIColor clearColor];
    notes.font = [UIFont systemFontOfSize:13];
    notes.textColor = [UIColor secondaryLabelColor];
    notes.text = @"使用说明：\n1. 先连接蓝牙耳机，再点「开始监听」\n2. 默认「原始」模式：不降噪、不滤波，麦克风声音直接放大\n3. 环境噪声大时再切「心跳 20~250Hz」；想听中高频切「宽带」\n4. 增益最高 2000%（20倍），过大容易啸叫，先把耳机音量调小\n5. 麦克风孔压紧身体、手掌罩住密封，安静房间效果最好\n6. 打开「录音保存」可回放；文件在 文档/Recordings\n7. 蓝牙延迟约0.2~0.4秒属正常\n8. 仅实时监听辅助，不替代医疗诊断";
    [content addSubview:notes];
}

// 实时波形 UI 刷新（主线程定时器）
- (void)refreshWaveUI {
    if (!self.running) return;
    static float full[600];
    static float win[600];
    [_waveLock lock];
    for (int i = 0; i < 600; i++) {
        int src = (int)((i * 1200) / 600);
        full[i] = _waveRing[(_wavePos + src) % 1200];
    }
    [_waveLock unlock];
    NSInteger zoom = (NSInteger)self.zoomSlider.value + 1;
    NSInteger winN = MAX(60, 600 / zoom);
    for (NSInteger i = 0; i < winN; i++) win[i] = full[600 - winN + i];
    [self.liveWave setData:win length:(NSUInteger)winN level:_level];
}

// ------------------------------------------------------------------ 音频

- (void)onToggle {
    if (self.running) {
        [self stopMonitor];
    } else {
        [self startMonitor];
    }
}

- (NSURL *)recordingsDir {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    NSURL *dir = [NSURL fileURLWithPath:[docs stringByAppendingPathComponent:@"Recordings"]];
    [[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

- (NSURL *)latestRecording {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtURL:[self recordingsDir] includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 error:nil];
    NSURL *best = nil;
    NSDate *bestDate = nil;
    for (NSURL *f in files) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"wav"]) continue;
        NSDate *d = nil;
        [f getResourceValue:&d forKey:NSURLContentModificationDateKey error:nil];
        if (best == nil || [d compare:bestDate] == NSOrderedDescending) {
            best = f;
            bestDate = d;
        }
    }
    return best;
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
    _inFmt = inFmt;
    [self.engine connect:self.player to:self.engine.mainMixerNode format:inFmt];

    // 按实际采样率计算滤波系数
    double sr = inFmt.sampleRate;
    self.aH80 = (float)exp(-2.0 * M_PI * 80.0 / sr);
    self.aH20 = (float)exp(-2.0 * M_PI * 20.0 / sr);
    self.aL1k = (float)(1.0 - exp(-2.0 * M_PI * 1000.0 / sr));
    self.aL250 = (float)(1.0 - exp(-2.0 * M_PI * 250.0 / sr));
    NSLog(@"[FetalEar] sr=%.0f aH20=%.4f aH80=%.4f aL250=%.4f aL1k=%.4f", sr, self.aH20, self.aH80, self.aL250, self.aL1k);

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
    // 若开关已打开则开始录音
    if (self.recordSwitch.on) [self startRecording];
    UIApplication.sharedApplication.idleTimerDisabled = YES; // 屏幕常亮
    [self.toggleButton setTitle:@"停止监听" forState:UIControlStateNormal];
    [self setStatus:[NSString stringWithFormat:@"监听中 · 输出：%@ · 延迟约0.2~0.4秒", [self currentOutputName]]];
    NSLog(@"[FetalEar] 监听已启动");
}

- (void)stopMonitor {
    if (!self.running) return;
    NSLog(@"[FetalEar] 停止监听");
    self.running = NO;
    [self stopRecording];

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

// 录音：AVAudioFile 直接写 WAV（录的是滤波+增益后的信号，与听到的一致）
- (void)startRecording {
    if (self.recording) return;
    if (_inFmt == nil) return;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *ts = [df stringFromDate:[NSDate date]];
    NSURL *url = [[self recordingsDir] URLByAppendingPathComponent:[NSString stringWithFormat:@"fetal_%@.wav", ts]];
    NSError *err = nil;
    AVAudioFile *f = [[AVAudioFile alloc] initForWriting:url
                                                settings:_inFmt.settings
                                            commonFormat:AVAudioPCMFormatFloat32
                                             interleaved:NO
                                                   error:&err];
    if (f == nil) {
        NSLog(@"[FetalEar] 录音创建失败: %@", err);
        return;
    }
    self.recURL = url;
    self.recFile = f;
    self.recording = YES;
    self.recFileLabel.text = [NSString stringWithFormat:@"录音中：%@", url.lastPathComponent];
}

- (void)stopRecording {
    if (!self.recording) return;
    self.recording = NO;
    self.recFile = nil;
    self.recFileLabel.text = @"";
    NSLog(@"[FetalEar] 录音已停止");
}

// 音频回调：只做增益（原始模式）或滤波+增益，不做任何磁盘/分配重活
- (void)processBuffer:(AVAudioPCMBuffer *)buf {
    if (!self.running) return;
    float **channels = buf.floatChannelData;
    NSUInteger frames = buf.frameLength;
    float g = self.gain;
    NSInteger mode = self.filterMode;
    float aH;
    float aL;
    BOOL useLp;

    if (mode == 2) {
        aH = self.aH20;   // 心跳模式：20~250Hz
        aL = self.aL250;
        useLp = YES;
    } else if (mode == 1) {
        aH = self.aH80;   // 宽带：80~1000Hz
        aL = self.aL1k;
        useLp = YES;
    } else {
        // ★ 原始模式：零滤波。不高通、不低通、不去直流。
        //   信号链就是 x * gain，跟麦克风出来的样本只差一个倍数。
        //   直流偏置由麦克风本身保证极低（iPhone 的 ADC 带硬件 DC 阻断），
        //   所以这里不需要软件再去直流。
        aH = 0.0f;
        aL = 0.0f;
        useLp = NO;
    }

    if (!useLp && aH == 0.0f) {
        // ===== 原始模式的快速路径：只有乘法和削顶，一个滤波运算都不做 =====
        for (NSUInteger c = 0; c < buf.format.channelCount && c < 2; c++) {
            float *p = channels[c];
            for (NSUInteger i = 0; i < frames; i++) {
                float v = p[i] * g;
                // 硬削顶：超出满刻度的部分直接截断（原始模式下不做任何软压缩）
                if (v > 1.0f) v = 1.0f;
                else if (v < -1.0f) v = -1.0f;
                p[i] = v;
                if (c == 0 && (i % 24) == 0) {
                    [_waveLock lock];
                    _waveRing[_wavePos] = v;
                    _wavePos = (_wavePos + 1) % 1200;
                    [_waveLock unlock];
                }
            }
        }
    } else {
        // ===== 带滤波的路径（宽带 / 心跳模式）=====
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
                if (c == 0 && (i % 24) == 0) {
                    [_waveLock lock];
                    _waveRing[_wavePos] = v;
                    _wavePos = (_wavePos + 1) % 1200;
                    [_waveLock unlock];
                }
            }
            _filtXP[c] = xp;
            _filtYPH[c] = ypH;
            _filtYPL[c] = ypL;
        }
    }

    // RMS 电平（声道0）
    if (frames > 0) {
        float sum2 = 0;
        float *p0 = channels[0];
        for (NSUInteger i = 0; i < frames; i++) sum2 += p0[i] * p0[i];
        _level = sqrtf(sum2 / (float)frames);
    }

    // 录音（处理后的同一 buffer）
    if (self.recording && self.recFile != nil) {
        [self.recFile writeFromBuffer:buf error:nil];
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
        // startMonitor 内部会按开关恢复录音
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

- (void)onFilterChange:(UISegmentedControl *)seg {
    self.filterMode = seg.selectedSegmentIndex;
    NSLog(@"[FetalEar] 滤波模式: %ld", (long)seg.selectedSegmentIndex);
}

- (void)onZoomChange:(UISlider *)slider {
    self.zoomValueLabel.text = [NSString stringWithFormat:@"%ldx", (long)slider.value + 1];
}

- (void)onRecordChange:(UISwitch *)sw {
    if (sw.on) {
        if (self.running) [self startRecording];
    } else {
        [self stopRecording];
    }
}

- (void)onPlayToggle {
    if (self.audioPlayer != nil) {
        [self.audioPlayer stop];
        self.audioPlayer = nil;
        [self.playButton setTitle:@"回放最近录音" forState:UIControlStateNormal];
        if (self.running) {
            [self setStatus:[NSString stringWithFormat:@"监听中 · 输出：%@ · 延迟约0.2~0.4秒", [self currentOutputName]]];
        } else {
            [self setStatus:@"已停止"];
        }
        return;
    }
    NSURL *url = [self latestRecording];
    if (url == nil) {
        [self setStatus:@"还没有录音：先打开「录音保存」再监听一会儿"];
        return;
    }
    // 后台读取整段录音画峰值波形
    NSURL *waveURL = url;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSError *err = nil;
        AVAudioFile *f = [[AVAudioFile alloc] initForReading:waveURL error:&err];
        if (f == nil) return;
        AVAudioFormat *fmt = f.processingFormat;
        AVAudioFrameCount frames = (AVAudioFrameCount)f.length;
        if (frames == 0) return;
        AVAudioPCMBuffer *buf = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frames];
        if (buf == nil) return;
        [f readIntoBuffer:buf error:&err];
        float *ch = buf.floatChannelData[0];
        float *peaks = (float *)malloc(600 * sizeof(float));
        if (peaks == NULL) return;
        AVAudioFrameCount n = buf.frameLength;
        for (int i = 0; i < 600; i++) {
            AVAudioFrameCount s = (AVAudioFrameCount)(((int64_t)i) * n / 600);
            AVAudioFrameCount e = (AVAudioFrameCount)(((int64_t)i + 1) * n / 600);
            float peak = 0;
            for (AVAudioFrameCount j = s; j < e; j++) {
                float v = fabsf(ch[j]);
                if (v > peak) peak = v;
            }
            peaks[i] = peak;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.playWave setData:peaks length:600 level:0];
            free(peaks);
        });
    });
    NSError *perr = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:waveURL error:&perr];
    if (p == nil) {
        [self setStatus:@"回放失败"];
        return;
    }
    self.audioPlayer = p;
    p.delegate = self;
    [p play];
    [self.playButton setTitle:@"停止回放" forState:UIControlStateNormal];
    [self setStatus:[NSString stringWithFormat:@"回放中：%@", url.lastPathComponent]];
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.audioPlayer = nil;
        [self.playButton setTitle:@"回放最近录音" forState:UIControlStateNormal];
    });
}

@end
