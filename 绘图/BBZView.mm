//
//  BBZView.mm - AB 控制面板
//

#import <notify.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>
#import <unistd.h>
#import <mach/machine.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import "HUDHelper.h"
#import "MainButton.h"
#import "MainApplication.h"
#import "HUDPresetPosition.h"
#import "BBZView.h"
#import "UIApplication+Private.h"
#import "DOJailbreaker.h"
#import "LFSenderIDViewController.h"
#include "游戏/SDK.h"
#import "pp.h"

#ifdef __cplusplus
extern "C" {
#endif
void KernelLoggerSetHandler(void (^handler)(NSString *line));
void KernelLogLine(const char *line);
bool 游戏已连接(void);          // 模块基址 + pid + 任务端口 三件齐
void 重连游戏进程(void);        // 清空端口与模块缓存，后台线程重扫（无内核动作）
#ifdef __cplusplus
}
#endif

// ========================================
// AB 配色方案 - 紫粉渐变风格
// ========================================
#define JVR_深色背景 [UIColor colorWithRed:18.0f/255.0f green:10.0f/255.0f blue:28.0f/255.0f alpha:1.0f]
#define JVR_卡片色 [UIColor colorWithRed:30.0f/255.0f green:18.0f/255.0f blue:45.0f/255.0f alpha:0.95f]
#define JVR_边框色 [UIColor colorWithRed:180.0f/255.0f green:100.0f/255.0f blue:255.0f/255.0f alpha:0.3f]
#define JVR_主色 [UIColor colorWithRed:200.0f/255.0f green:120.0f/255.0f blue:255.0f/255.0f alpha:1.0f]
#define JVR_副色 [UIColor colorWithRed:255.0f/255.0f green:150.0f/255.0f blue:200.0f/255.0f alpha:1.0f]
#define JVR_警告色 [UIColor colorWithRed:255.0f/255.0f green:80.0f/255.0f blue:120.0f/255.0f alpha:1.0f]
#define JVR_文字色 [UIColor colorWithRed:240.0f/255.0f green:230.0f/255.0f blue:255.0f/255.0f alpha:1.0f]
#define JVR_暗文字色 [UIColor colorWithRed:140.0f/255.0f green:110.0f/255.0f blue:170.0f/255.0f alpha:1.0f]
#define JVR_发光色 [UIColor colorWithRed:180.0f/255.0f green:100.0f/255.0f blue:255.0f/255.0f alpha:0.6f]

static BOOL _gShouldToggleHUDAfterLaunch = NO;
static __weak BBZView *gRootVC = nil;

// ========================================
// Plist 配置
// ========================================
static NSString* JVR_取配置路径() {
    return @"/var/mobile/Library/Preferences/com.map.settings.plist";
}

static void JVR_保存开关(NSString* key, BOOL val) {
    NSString *path = JVR_取配置路径();
    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!cfg) cfg = [NSMutableDictionary dictionary];
    [cfg setObject:@(val) forKey:key];
    [cfg writeToFile:path atomically:YES];
}

static BOOL JVR_读取开关(NSString* key) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:JVR_取配置路径()];
    return cfg ? [[cfg objectForKey:key] boolValue] : NO;
}

// S45 新增：浮点配置存取
static void JVR_保存浮点(NSString* key, float val) {
    NSString *path = JVR_取配置路径();
    NSMutableDictionary *cfg = [NSMutableDictionary dictionaryWithContentsOfFile:path];
    if (!cfg) cfg = [NSMutableDictionary dictionary];
    [cfg setObject:@(val) forKey:key];
    [cfg writeToFile:path atomically:YES];
}

static float JVR_读取浮点(NSString* key, float 缺省) {
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:JVR_取配置路径()];
    id v = cfg ? [cfg objectForKey:key] : nil;
    return v ? [v floatValue] : 缺省;
}


// ========================================
// JVR 六边形装饰视图
// ========================================
@interface JVRHexagonView : UIView
@property (nonatomic, strong) CAShapeLayer *hexLayer;
@property (nonatomic, strong) CAShapeLayer *glowLayer;
@end

@implementation JVRHexagonView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupHexagon];
    }
    return self;
}

- (void)setupHexagon {
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat cx = w / 2.0f;
    CGFloat cy = h / 2.0f;
    CGFloat r = MIN(w, h) / 2.0f - 4.0f;
    
    UIBezierPath *path = [UIBezierPath bezierPath];
    for (int i = 0; i < 6; i++) {
        CGFloat angle = (M_PI / 3.0f) * i - M_PI / 2.0f;
        CGFloat x = cx + r * cos(angle);
        CGFloat y = cy + r * sin(angle);
        if (i == 0) [path moveToPoint:CGPointMake(x, y)];
        else [path addLineToPoint:CGPointMake(x, y)];
    }
    [path closePath];
    
    self.glowLayer = [CAShapeLayer layer];
    self.glowLayer.path = path.CGPath;
    self.glowLayer.fillColor = [UIColor clearColor].CGColor;
    self.glowLayer.strokeColor = JVR_发光色.CGColor;
    self.glowLayer.lineWidth = 3.0f;
    self.glowLayer.shadowColor = JVR_主色.CGColor;
    self.glowLayer.shadowOffset = CGSizeZero;
    self.glowLayer.shadowOpacity = 0.8f;
    self.glowLayer.shadowRadius = 8.0f;
    [self.layer addSublayer:self.glowLayer];
    
    self.hexLayer = [CAShapeLayer layer];
    self.hexLayer.path = path.CGPath;
    self.hexLayer.fillColor = JVR_卡片色.CGColor;
    self.hexLayer.strokeColor = JVR_边框色.CGColor;
    self.hexLayer.lineWidth = 1.5f;
    [self.layer addSublayer:self.hexLayer];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self.hexLayer removeFromSuperlayer];
    [self.glowLayer removeFromSuperlayer];
    [self setupHexagon];
}
@end

// ========================================
// JVR 霓虹开关
// ========================================
@interface JVRNeonSwitch : UIView
@property (nonatomic, assign) BOOL isOn;
@property (nonatomic, copy) NSString *switchKey;
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *thumb;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, copy) void (^onToggle)(BOOL);
@end

@implementation JVRNeonSwitch

- (instancetype)initWithTitle:(NSString *)title key:(NSString *)key {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.switchKey = key;
        self.backgroundColor = [JVR_卡片色 colorWithAlphaComponent:0.6f];
        self.layer.cornerRadius = 8.0f;
        self.layer.borderWidth = 1.0f;
        self.layer.borderColor = JVR_边框色.CGColor;
        
        // 左侧竖线装饰
        UIView *accent = [[UIView alloc] init];
        accent.translatesAutoresizingMaskIntoConstraints = NO;
        accent.backgroundColor = JVR_主色;
        accent.layer.cornerRadius = 1.5f;
        [self addSubview:accent];
        
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.text = title;
        self.titleLabel.font = [UIFont systemFontOfSize:14.0f weight:UIFontWeightMedium];
        self.titleLabel.textColor = JVR_文字色;
        [self addSubview:self.titleLabel];
        
        self.statusLabel = [[UILabel alloc] init];
        self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.statusLabel.font = [UIFont fontWithName:@"Menlo" size:10.0f];
        self.statusLabel.textColor = JVR_暗文字色;
        [self addSubview:self.statusLabel];
        
        // 轨道
        self.track = [[UIView alloc] init];
        self.track.translatesAutoresizingMaskIntoConstraints = NO;
        self.track.backgroundColor = [UIColor colorWithWhite:0.15f alpha:1.0f];
        self.track.layer.cornerRadius = 12.0f;
        self.track.layer.borderWidth = 1.0f;
        self.track.layer.borderColor = [UIColor colorWithWhite:0.3f alpha:1.0f].CGColor;
        [self addSubview:self.track];
        
        // 滑块
        self.thumb = [[UIView alloc] initWithFrame:CGRectMake(2, 2, 20, 20)];
        self.thumb.backgroundColor = JVR_文字色;
        self.thumb.layer.cornerRadius = 10.0f;
        [self.track addSubview:self.thumb];
        
        [NSLayoutConstraint activateConstraints:@[
            [accent.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [accent.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [accent.widthAnchor constraintEqualToConstant:3],
            [accent.heightAnchor constraintEqualToConstant:24],
            [self.titleLabel.leadingAnchor constraintEqualToAnchor:accent.trailingAnchor constant:10],
            [self.titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
            [self.statusLabel.leadingAnchor constraintEqualToAnchor:self.titleLabel.leadingAnchor],
            [self.statusLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:2],
            [self.track.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [self.track.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.track.widthAnchor constraintEqualToConstant:44],
            [self.track.heightAnchor constraintEqualToConstant:24],
            [self.heightAnchor constraintEqualToConstant:50],
        ]];
        
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggle)];
        [self addGestureRecognizer:tap];
        
        self.isOn = JVR_读取开关(key);
        [self updateUI:NO];
    }
    return self;
}

- (void)toggle {
    self.isOn = !self.isOn;
    [self updateUI:YES];
    if (self.onToggle) self.onToggle(self.isOn);
}

- (void)updateUI:(BOOL)animated {
    CGFloat thumbX = self.isOn ? 22 : 2;
    UIColor *trackColor = self.isOn ? JVR_主色 : [UIColor colorWithWhite:0.15f alpha:1.0f];
    UIColor *borderColor = self.isOn ? JVR_主色 : [UIColor colorWithWhite:0.3f alpha:1.0f];
    
    NSTimeInterval dur = animated ? 0.2f : 0;
    [UIView animateWithDuration:dur delay:0 usingSpringWithDamping:0.7f initialSpringVelocity:0.5f options:0 animations:^{
        self.thumb.frame = CGRectMake(thumbX, 2, 20, 20);
        self.track.backgroundColor = trackColor;
        self.track.layer.borderColor = borderColor.CGColor;
        if (self.isOn) {
            self.track.layer.shadowColor = JVR_主色.CGColor;
            self.track.layer.shadowOpacity = 0.6f;
            self.track.layer.shadowRadius = 6.0f;
            self.track.layer.shadowOffset = CGSizeZero;
        } else {
            self.track.layer.shadowOpacity = 0;
        }
    } completion:nil];
    
    self.statusLabel.text = self.isOn ? @"已启用" : @"已关闭";
    self.statusLabel.textColor = self.isOn ? JVR_副色 : JVR_暗文字色;
}
@end

// ========================================
// S45 新增：霓虹滑条（JVRNeonSlider）
// 还原自 -[JVRNeonSlider initWithTitle:key:min:max:缺省:整数:] 0x10005F57C
// ========================================
@interface JVRNeonSlider : UIView
@property (nonatomic, copy)   NSString *cfgKey;
@property (nonatomic, strong) UISlider  *slider;
@property (nonatomic, strong) UILabel   *valueLabel;
@property (nonatomic, assign) bool      整数模式;
@property (nonatomic, copy)   void (^onChange)(float value);
- (instancetype)initWithTitle:(NSString*)标题 key:(NSString*)键
                          min:(float)最小 max:(float)最大
                        缺省:(float)缺省 整数:(bool)整数;
- (void)refreshLabel;
@end

@implementation JVRNeonSlider

- (instancetype)initWithTitle:(NSString*)标题 key:(NSString*)键
                          min:(float)最小 max:(float)最大
                        缺省:(float)缺省 整数:(bool)整数 {
    if (self = [super initWithFrame:CGRectZero]) {
        _cfgKey = [键 copy];
        self.backgroundColor = [UIColor colorWithRed:0.117647059 green:0.0705882385
                                                blue:0.176470593 alpha:0.6f];
        self.layer.cornerRadius = 8.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithRed:0.70588237 green:0.392156869
                                                  blue:1.0 alpha:0.3f].CGColor;

        // 左侧竖色条
        UIView *accent = [[UIView alloc] init];
        accent.translatesAutoresizingMaskIntoConstraints = NO;
        accent.backgroundColor = JVR_主色;
        accent.layer.cornerRadius = 1.5;
        [self addSubview:accent];

        // 标题
        UILabel *title = [[UILabel alloc] init];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.text = 标题;
        title.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        title.textColor = JVR_文字色;
        [self addSubview:title];

        // 数值
        _valueLabel = [[UILabel alloc] init];
        _valueLabel.translatesAutoresizingMaskIntoConstraints = NO;
        _valueLabel.font = [UIFont fontWithName:@"Menlo" size:12.0];
        _valueLabel.textColor = JVR_副色;
        _valueLabel.textAlignment = NSTextAlignmentRight;
        [self addSubview:_valueLabel];

        // 滑条
        _slider = [[UISlider alloc] init];
        _slider.translatesAutoresizingMaskIntoConstraints = NO;
        _slider.minimumValue = 最小;
        _slider.maximumValue = 最大;
        _slider.minimumTrackTintColor = [UIColor colorWithRed:0.784313738 green:0.470588237 blue:1.0 alpha:1.0];
        _slider.maximumTrackTintColor = [UIColor colorWithWhite:0.22 alpha:1.0];
        _slider.thumbTintColor = JVR_文字色;

        float 初值 = JVR_读取浮点(键, 缺省);
        if (初值 < 最小) 初值 = 最小;
        if (初值 > 最大) 初值 = 最大;
        _slider.value = 初值;

        [_slider addTarget:self action:@selector(dragChanged:)
          forControlEvents:UIControlEventValueChanged];            // 4096
        [_slider addTarget:self action:@selector(dragDone:)
          forControlEvents:(UIControlEventTouchUpInside | UIControlEventTouchUpOutside)];  // 192
        [self addSubview:_slider];

        [NSLayoutConstraint activateConstraints:@[
            [accent.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [accent.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
            [accent.widthAnchor constraintEqualToConstant:3],
            [accent.heightAnchor constraintEqualToConstant:16],
            [title.leadingAnchor constraintEqualToAnchor:accent.trailingAnchor constant:10],
            [title.centerYAnchor constraintEqualToAnchor:accent.centerYAnchor],
            [_valueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_valueLabel.centerYAnchor constraintEqualToAnchor:accent.centerYAnchor],
            [_valueLabel.widthAnchor constraintEqualToConstant:80],
            [_slider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [_slider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_slider.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
            [_slider.heightAnchor constraintEqualToConstant:28],
            [self.heightAnchor constraintEqualToConstant:62],
        ]];

        _整数模式 = 整数;
        [self refreshLabel];
    }
    return self;
}

// 大范围滑条自动按整数显示（跨度 > 40）
- (bool)大跨度 {
    return (self.slider.maximumValue - self.slider.minimumValue) > 40.0f;
}

- (void)refreshLabel {
    if (self.整数模式 || self.大跨度) {
        self.valueLabel.text = [NSString stringWithFormat:@"%.0f", self.slider.value];
    } else {
        self.valueLabel.text = [NSString stringWithFormat:@"%.1f", self.slider.value];
    }
}

- (void)dragChanged:(UISlider*)sender {
    [self refreshLabel];
    if (self.onChange) self.onChange(sender.value);
}

- (void)dragDone:(UISlider*)sender {
    JVR_保存浮点(self.cfgKey, sender.value);
}

@end

// ========================================
// S45 新增：分段选择行（JVRSegRow）
// 还原自 -[JVRSegRow initWithTitle:key:选项:缺省:] 0x100061E14
// ========================================
@interface JVRSegRow : UIView
@property (nonatomic, copy)   NSString            *cfgKey;
@property (nonatomic, strong) UISegmentedControl *seg;
@property (nonatomic, copy)   void (^onChange)(NSInteger index);
- (instancetype)initWithTitle:(NSString*)标题 key:(NSString*)键
                        选项:(NSArray*)选项 缺省:(int)缺省;
@end

@implementation JVRSegRow

- (instancetype)initWithTitle:(NSString*)标题 key:(NSString*)键
                        选项:(NSArray*)选项 缺省:(int)缺省 {
    if (self = [super initWithFrame:CGRectZero]) {
        _cfgKey = [键 copy];
        self.backgroundColor = [UIColor colorWithRed:0.117647059 green:0.0705882385
                                                blue:0.176470593 alpha:0.95f];
        self.layer.cornerRadius = 8.0;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithRed:0.70588237 green:0.392156869
                                                  blue:1.0 alpha:0.3f].CGColor;

        UIView *accent = [[UIView alloc] init];
        accent.translatesAutoresizingMaskIntoConstraints = NO;
        accent.backgroundColor = [UIColor colorWithRed:0.784313738 green:0.470588237 blue:1.0 alpha:1.0];
        accent.layer.cornerRadius = 1.5;
        [self addSubview:accent];

        UILabel *title = [[UILabel alloc] init];
        title.translatesAutoresizingMaskIntoConstraints = NO;
        title.text = 标题;
        title.font = [UIFont systemFontOfSize:14.0 weight:UIFontWeightMedium];
        title.textColor = JVR_文字色;
        [self addSubview:title];

        _seg = [[UISegmentedControl alloc] initWithItems:选项];
        _seg.translatesAutoresizingMaskIntoConstraints = NO;
        int 选中 = (int)JVR_读取浮点(键, (float)缺省);
        if (选中 < 0 || 选中 >= (int)选项.count) 选中 = 缺省;
        _seg.selectedSegmentIndex = 选中;
        _seg.backgroundColor = [UIColor colorWithWhite:0.16 alpha:1.0];
        _seg.selectedSegmentTintColor = [UIColor colorWithRed:0.784313738 green:0.470588237 blue:1.0 alpha:1.0];
        [_seg setTitleTextAttributes:@{
            NSForegroundColorAttributeName: JVR_文字色,
            NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightMedium],
        } forState:UIControlStateNormal];
        [_seg setTitleTextAttributes:@{
            NSForegroundColorAttributeName: [UIColor colorWithRed:0.0705882385 green:0.0392156877
                                                            blue:0.109803922 alpha:1.0],
            NSFontAttributeName: [UIFont systemFontOfSize:12.0 weight:UIFontWeightBold],
        } forState:UIControlStateSelected];
        [_seg addTarget:self action:@selector(segChanged:)
          forControlEvents:UIControlEventValueChanged];
        [self addSubview:_seg];

        [NSLayoutConstraint activateConstraints:@[
            [accent.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [accent.topAnchor constraintEqualToAnchor:self.topAnchor constant:12],
            [accent.widthAnchor constraintEqualToConstant:3],
            [accent.heightAnchor constraintEqualToConstant:16],
            [title.leadingAnchor constraintEqualToAnchor:accent.trailingAnchor constant:10],
            [title.centerYAnchor constraintEqualToAnchor:accent.centerYAnchor],
            [_seg.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
            [_seg.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor constant:8],
            [_seg.centerYAnchor constraintEqualToAnchor:accent.centerYAnchor],
            [_seg.heightAnchor constraintEqualToConstant:30],
            [self.heightAnchor constraintEqualToConstant:54],
        ]];
    }
    return self;
}

- (void)segChanged:(UISegmentedControl*)sender {
    JVR_保存浮点(self.cfgKey, (float)sender.selectedSegmentIndex);
    if (self.onChange) self.onChange(sender.selectedSegmentIndex);
}

@end


// ========================================
// JVR 主控制卡片
// ========================================
@interface JVRMainCard : UIView
@property (nonatomic, strong) UIView *indicator;
@property (nonatomic, strong) UILabel *statusText;
@property (nonatomic, strong) UIView *pulseRing;
@property (nonatomic, assign) BOOL isActive;
@property (nonatomic, copy) void (^onTap)(BOOL);
@end

@implementation JVRMainCard

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {
    self.backgroundColor = JVR_卡片色;
    self.layer.cornerRadius = 12.0f;
    self.layer.borderWidth = 1.0f;
    self.layer.borderColor = JVR_边框色.CGColor;
    
    // 顶部装饰线
    UIView *topLine = [[UIView alloc] init];
    topLine.translatesAutoresizingMaskIntoConstraints = NO;
    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.colors = @[(id)JVR_主色.CGColor, (id)[UIColor clearColor].CGColor];
    grad.startPoint = CGPointMake(0, 0.5);
    grad.endPoint = CGPointMake(1, 0.5);
    [topLine.layer addSublayer:grad];
    [self addSubview:topLine];
    
    // 状态指示器
    self.pulseRing = [[UIView alloc] init];
    self.pulseRing.translatesAutoresizingMaskIntoConstraints = NO;
    self.pulseRing.backgroundColor = [UIColor clearColor];
    self.pulseRing.layer.borderWidth = 2.0f;
    self.pulseRing.layer.borderColor = JVR_主色.CGColor;
    self.pulseRing.layer.cornerRadius = 25.0f;
    [self addSubview:self.pulseRing];
    
    self.indicator = [[UIView alloc] init];
    self.indicator.translatesAutoresizingMaskIntoConstraints = NO;
    self.indicator.backgroundColor = JVR_暗文字色;
    self.indicator.layer.cornerRadius = 20.0f;
    [self addSubview:self.indicator];
    
    // 标签
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = @"系统";
    label.font = [UIFont systemFontOfSize:10.0f weight:UIFontWeightBold];
    label.textColor = JVR_暗文字色;
    [self addSubview:label];
    
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"主开关";
    title.font = [UIFont systemFontOfSize:18.0f weight:UIFontWeightBold];
    title.textColor = JVR_文字色;
    [self addSubview:title];
    
    self.statusText = [[UILabel alloc] init];
    self.statusText.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusText.font = [UIFont fontWithName:@"Menlo" size:12.0f];
    self.statusText.textColor = JVR_暗文字色;
    [self addSubview:self.statusText];
    
    // 右侧箭头
    UILabel *arrow = [[UILabel alloc] init];
    arrow.translatesAutoresizingMaskIntoConstraints = NO;
    arrow.text = @"▶";
    arrow.font = [UIFont systemFontOfSize:14.0f];
    arrow.textColor = JVR_主色;
    [self addSubview:arrow];
    
    [NSLayoutConstraint activateConstraints:@[
        [topLine.topAnchor constraintEqualToAnchor:self.topAnchor],
        [topLine.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [topLine.widthAnchor constraintEqualToConstant:120],
        [topLine.heightAnchor constraintEqualToConstant:3],
        [self.pulseRing.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [self.pulseRing.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.pulseRing.widthAnchor constraintEqualToConstant:50],
        [self.pulseRing.heightAnchor constraintEqualToConstant:50],
        [self.indicator.centerXAnchor constraintEqualToAnchor:self.pulseRing.centerXAnchor],
        [self.indicator.centerYAnchor constraintEqualToAnchor:self.pulseRing.centerYAnchor],
        [self.indicator.widthAnchor constraintEqualToConstant:40],
        [self.indicator.heightAnchor constraintEqualToConstant:40],
        [label.leadingAnchor constraintEqualToAnchor:self.pulseRing.trailingAnchor constant:14],
        [label.topAnchor constraintEqualToAnchor:self.topAnchor constant:16],
        [title.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:2],
        [self.statusText.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [self.statusText.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [arrow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [arrow.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintEqualToConstant:80],
    ]];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
    [self addGestureRecognizer:tap];
    
    self.isActive = NO;
    [self updateState:NO];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    for (CALayer *sub in self.subviews.firstObject.layer.sublayers) {
        if ([sub isKindOfClass:[CAGradientLayer class]]) {
            sub.frame = CGRectMake(0, 0, 120, 3);
        }
    }
}

- (void)tapped {
    self.isActive = !self.isActive;
    [self updateState:YES];
    if (self.onTap) self.onTap(self.isActive);
}

- (void)updateState:(BOOL)animated {
    UIColor *indicatorColor = self.isActive ? JVR_副色 : JVR_暗文字色;
    UIColor *ringColor = self.isActive ? JVR_副色 : JVR_主色;
    
    NSTimeInterval dur = animated ? 0.25f : 0;
    [UIView animateWithDuration:dur animations:^{
        self.indicator.backgroundColor = indicatorColor;
        self.pulseRing.layer.borderColor = ringColor.CGColor;
        if (self.isActive) {
            self.indicator.layer.shadowColor = JVR_副色.CGColor;
            self.indicator.layer.shadowOpacity = 0.8f;
            self.indicator.layer.shadowRadius = 10.0f;
            self.indicator.layer.shadowOffset = CGSizeZero;
        } else {
            self.indicator.layer.shadowOpacity = 0;
        }
    }];
    
    self.statusText.text = self.isActive ? @"状态: 运行中" : @"状态: 已关闭";
    self.statusText.textColor = self.isActive ? JVR_副色 : JVR_暗文字色;
    
    if (self.isActive) {
        [self startPulse];
    } else {
        [self.pulseRing.layer removeAllAnimations];
        self.pulseRing.alpha = 1.0f;
    }
}

- (void)startPulse {
    CABasicAnimation *pulse = [CABasicAnimation animationWithKeyPath:@"transform.scale"];
    pulse.fromValue = @1.0f;
    pulse.toValue = @1.2f;
    pulse.duration = 1.0f;
    pulse.autoreverses = YES;
    pulse.repeatCount = HUGE_VALF;
    [self.pulseRing.layer addAnimation:pulse forKey:@"pulse"];
}
@end


// ========================================
// JVR 终端日志视图
// ========================================
@interface JVRTerminal : UIView
@property (nonatomic, strong) UITextView *logView;
@property (nonatomic, strong) UIView *scanLine;
@end

@implementation JVRTerminal

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {
    self.backgroundColor = [UIColor colorWithRed:5.0f/255.0f green:10.0f/255.0f blue:18.0f/255.0f alpha:1.0f];
    self.layer.cornerRadius = 10.0f;
    self.layer.borderWidth = 1.0f;
    self.layer.borderColor = JVR_边框色.CGColor;
    self.clipsToBounds = YES;
    
    // 顶部栏
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    header.backgroundColor = [UIColor colorWithWhite:0.1f alpha:1.0f];
    [self addSubview:header];
    
    // 三个小圆点
    UIView *dot1 = [[UIView alloc] init];
    dot1.translatesAutoresizingMaskIntoConstraints = NO;
    dot1.backgroundColor = JVR_警告色;
    dot1.layer.cornerRadius = 4.0f;
    [header addSubview:dot1];
    
    UIView *dot2 = [[UIView alloc] init];
    dot2.translatesAutoresizingMaskIntoConstraints = NO;
    dot2.backgroundColor = [UIColor colorWithRed:255.0f/255.0f green:204.0f/255.0f blue:0.0f/255.0f alpha:1.0f];
    dot2.layer.cornerRadius = 4.0f;
    [header addSubview:dot2];
    
    UIView *dot3 = [[UIView alloc] init];
    dot3.translatesAutoresizingMaskIntoConstraints = NO;
    dot3.backgroundColor = JVR_副色;
    dot3.layer.cornerRadius = 4.0f;
    [header addSubview:dot3];
    
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"运行日志";
    title.font = [UIFont systemFontOfSize:10.0f weight:UIFontWeightBold];
    title.textColor = JVR_暗文字色;
    [header addSubview:title];
    
    self.logView = [[UITextView alloc] init];
    self.logView.translatesAutoresizingMaskIntoConstraints = NO;
    self.logView.backgroundColor = [UIColor clearColor];
    self.logView.textColor = JVR_主色;
    self.logView.font = [UIFont fontWithName:@"Menlo" size:10.0f];
    self.logView.editable = NO;
    self.logView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.logView.showsVerticalScrollIndicator = YES;
    self.logView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    [self addSubview:self.logView];
    
    // 扫描线效果
    self.scanLine = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 400, 2)];
    self.scanLine.backgroundColor = [JVR_主色 colorWithAlphaComponent:0.3f];
    [self addSubview:self.scanLine];
    
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:28],
        [dot1.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:10],
        [dot1.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [dot1.widthAnchor constraintEqualToConstant:8],
        [dot1.heightAnchor constraintEqualToConstant:8],
        [dot2.leadingAnchor constraintEqualToAnchor:dot1.trailingAnchor constant:6],
        [dot2.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [dot2.widthAnchor constraintEqualToConstant:8],
        [dot2.heightAnchor constraintEqualToConstant:8],
        [dot3.leadingAnchor constraintEqualToAnchor:dot2.trailingAnchor constant:6],
        [dot3.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [dot3.widthAnchor constraintEqualToConstant:8],
        [dot3.heightAnchor constraintEqualToConstant:8],
        [title.centerXAnchor constraintEqualToAnchor:header.centerXAnchor],
        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [self.logView.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [self.logView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [self.logView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [self.logView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    ]];
    
    [self startScanAnimation];
}

- (void)startScanAnimation {
    [UIView animateWithDuration:3.0f delay:0 options:UIViewAnimationOptionRepeat | UIViewAnimationOptionCurveLinear animations:^{
        self.scanLine.frame = CGRectMake(0, self.bounds.size.height, self.bounds.size.width, 2);
    } completion:nil];
}

- (void)appendLog:(NSString *)line {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *timestamp = [self timestamp];
        NSString *old = self.logView.text ?: @"";
        NSString *nl = old.length ? @"\n" : @"";
        self.logView.text = [old stringByAppendingFormat:@"%@[%@] > %@", nl, timestamp, line];
        [self.logView scrollRangeToVisible:NSMakeRange(self.logView.text.length, 0)];
    });
}

- (NSString *)timestamp {
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    return [fmt stringFromDate:[NSDate date]];
}
@end


// ========================================
// JVR 内核按钮
// ========================================
@interface JVRKernelButton : UIView
@property (nonatomic, strong) UILabel *label;
@property (nonatomic, strong) CAGradientLayer *borderGrad;
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation JVRKernelButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setup];
    }
    return self;
}

- (void)setup {
    self.backgroundColor = [UIColor clearColor];
    self.layer.cornerRadius = 10.0f;
    self.clipsToBounds = YES;
    
    // 渐变边框
    UIView *borderView = [[UIView alloc] init];
    borderView.translatesAutoresizingMaskIntoConstraints = NO;
    borderView.layer.cornerRadius = 10.0f;
    borderView.clipsToBounds = YES;
    [self addSubview:borderView];
    
    self.borderGrad = [CAGradientLayer layer];
    self.borderGrad.colors = @[(id)JVR_主色.CGColor, (id)JVR_副色.CGColor];
    self.borderGrad.startPoint = CGPointMake(0, 0);
    self.borderGrad.endPoint = CGPointMake(1, 1);
    [borderView.layer addSublayer:self.borderGrad];
    
    // 内部填充
    UIView *inner = [[UIView alloc] init];
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    inner.backgroundColor = JVR_深色背景;
    inner.layer.cornerRadius = 8.0f;
    [self addSubview:inner];
    
    // 图标
    UILabel *icon = [[UILabel alloc] init];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.text = @"⚡";
    icon.font = [UIFont systemFontOfSize:16.0f];
    [self addSubview:icon];
    
    self.label = [[UILabel alloc] init];
    self.label.translatesAutoresizingMaskIntoConstraints = NO;
    self.label.text = @"连接游戏进程";
    self.label.font = [UIFont systemFontOfSize:14.0f weight:UIFontWeightBold];
    self.label.textColor = JVR_主色;
    [self addSubview:self.label];
    
    [NSLayoutConstraint activateConstraints:@[
        [borderView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [borderView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [borderView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [borderView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [inner.topAnchor constraintEqualToAnchor:self.topAnchor constant:2],
        [inner.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
        [inner.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
        [inner.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-2],
        [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.label.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [self.label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [self.heightAnchor constraintEqualToConstant:44],
    ]];
    
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
    [self addGestureRecognizer:tap];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.borderGrad.frame = self.bounds;
}

- (void)tapped {
    [UIView animateWithDuration:0.1f animations:^{
        self.transform = CGAffineTransformMakeScale(0.96f, 0.96f);
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.1f animations:^{
            self.transform = CGAffineTransformIdentity;
        }];
    }];
    if (self.onTap) self.onTap();
}
@end

// ========================================
// JVR 分区标题
// ========================================
@interface JVRSectionHeader : UIView
@end

@implementation JVRSectionHeader

- (instancetype)initWithTitle:(NSString *)title {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        UIView *line = [[UIView alloc] init];
        line.translatesAutoresizingMaskIntoConstraints = NO;
        line.backgroundColor = JVR_主色;
        line.layer.cornerRadius = 1.0f;
        line.layer.shadowColor = JVR_主色.CGColor;
        line.layer.shadowOpacity = 0.8f;
        line.layer.shadowRadius = 4.0f;
        line.layer.shadowOffset = CGSizeZero;
        [self addSubview:line];
        
        UILabel *label = [[UILabel alloc] init];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.text = title;
        label.font = [UIFont systemFontOfSize:13.0f weight:UIFontWeightBold];
        label.textColor = JVR_主色;
        [self addSubview:label];
        
        UIView *dash = [[UIView alloc] init];
        dash.translatesAutoresizingMaskIntoConstraints = NO;
        dash.backgroundColor = [JVR_边框色 colorWithAlphaComponent:0.5f];
        [self addSubview:dash];
        
        [NSLayoutConstraint activateConstraints:@[
            [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [line.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [line.widthAnchor constraintEqualToConstant:3],
            [line.heightAnchor constraintEqualToConstant:16],
            [label.leadingAnchor constraintEqualToAnchor:line.trailingAnchor constant:10],
            [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [dash.leadingAnchor constraintEqualToAnchor:label.trailingAnchor constant:10],
            [dash.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [dash.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [dash.heightAnchor constraintEqualToConstant:1],
            [self.heightAnchor constraintEqualToConstant:30],
        ]];
    }
    return self;
}
@end


// ============================================================
// 王者内核 · 胶囊分页界面（P2）
// 纯 UIKit：顶栏 + 胶囊分页 + 主开关卡 + 指标网格 + 列表 + 终端
// ============================================================
#define SLK_底色   [UIColor colorWithRed:7.0/255.0   green:8.0/255.0   blue:11.0/255.0  alpha:1.0]
#define SLK_卡面   [UIColor colorWithRed:14.0/255.0  green:16.0/255.0  blue:20.0/255.0  alpha:1.0]
#define SLK_卡面2  [UIColor colorWithRed:22.0/255.0  green:25.0/255.0  blue:31.0/255.0  alpha:1.0]
#define SLK_开卡   [UIColor colorWithRed:15.0/255.0  green:43.0/255.0  blue:34.0/255.0  alpha:1.0]
#define SLK_线     [UIColor colorWithWhite:1.0 alpha:0.065]
#define SLK_主字   [UIColor colorWithRed:242.0/255.0 green:244.0/255.0 blue:248.0/255.0 alpha:1.0]
#define SLK_次字   [UIColor colorWithRed:142.0/255.0 green:150.0/255.0 blue:170.0/255.0 alpha:1.0]
#define SLK_弱字   [UIColor colorWithRed:97.0/255.0  green:105.0/255.0 blue:124.0/255.0 alpha:1.0]
#define SLK_极弱   [UIColor colorWithRed:62.0/255.0  green:69.0/255.0  blue:82.0/255.0  alpha:1.0]
#define SLK_绿     [UIColor colorWithRed:53.0/255.0  green:224.0/255.0 blue:161.0/255.0 alpha:1.0]
#define SLK_红     [UIColor colorWithRed:255.0/255.0 green:110.0/255.0 blue:120.0/255.0 alpha:1.0]

static UILabel *SLK_标签(NSString *text, CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *l = [[UILabel alloc] init];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    l.text = text;
    l.font = [UIFont systemFontOfSize:size weight:weight];
    l.textColor = color;
    return l;
}

static UIView *SLK_细线(void) {
    UIView *v = [[UIView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.backgroundColor = SLK_线;
    return v;
}

static UIStackView *SLK_等宽行(NSArray<UIView *> *views, CGFloat spacing) {
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:views];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.alignment = UIStackViewAlignmentFill;
    row.spacing = spacing;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    return row;
}

static UILabel *SLK_分组标题(NSString *text) {
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.font = [UIFont systemFontOfSize:10.5f weight:UIFontWeightSemibold];
    l.textColor = SLK_弱字;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    return l;
}

// ============================================================
// 运行时设备信息 — 全部现场读取，不写死机型 / 系统版本 / 架构
// ============================================================

// 机型标识，如 iPhone10,3
static NSString *SLK_机型标识(void) {
    static NSString *ident = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char buf[128] = {0};
        size_t len = sizeof(buf);
        if (sysctlbyname("hw.machine", buf, &len, NULL, 0) == 0 && len > 0 && buf[0]) {
            ident = [NSString stringWithUTF8String:buf];
        } else {
            struct utsname u;
            ident = (uname(&u) == 0) ? [NSString stringWithUTF8String:u.machine] : @"unknown";
        }
    });
    return ident ?: @"unknown";
}

// 机型标识 → 市场名（未收录的原样显示标识，不做假）
static NSString *SLK_机型名称(void) {
    static NSDictionary<NSString *, NSString *> *map = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            // iPhone 8 / X
            @"iPhone10,1": @"iPhone 8",       @"iPhone10,4": @"iPhone 8",
            @"iPhone10,2": @"iPhone 8 Plus",  @"iPhone10,5": @"iPhone 8 Plus",
            @"iPhone10,3": @"iPhone X",       @"iPhone10,6": @"iPhone X",
            // XS / XR
            @"iPhone11,2": @"iPhone XS",      @"iPhone11,8": @"iPhone XR",
            @"iPhone11,4": @"iPhone XS Max",  @"iPhone11,6": @"iPhone XS Max",
            // 11 系列
            @"iPhone12,1": @"iPhone 11",      @"iPhone12,3": @"iPhone 11 Pro",
            @"iPhone12,5": @"iPhone 11 Pro Max", @"iPhone12,8": @"iPhone SE 2",
            // 12 系列
            @"iPhone13,1": @"iPhone 12 mini", @"iPhone13,2": @"iPhone 12",
            @"iPhone13,3": @"iPhone 12 Pro",  @"iPhone13,4": @"iPhone 12 Pro Max",
            // 13 系列
            @"iPhone14,2": @"iPhone 13 Pro",  @"iPhone14,3": @"iPhone 13 Pro Max",
            @"iPhone14,4": @"iPhone 13 mini", @"iPhone14,5": @"iPhone 13",
            @"iPhone14,6": @"iPhone SE 3",
            // 14 系列
            @"iPhone14,7": @"iPhone 14",      @"iPhone14,8": @"iPhone 14 Plus",
            @"iPhone15,2": @"iPhone 14 Pro",  @"iPhone15,3": @"iPhone 14 Pro Max",
            // 15 系列
            @"iPhone15,4": @"iPhone 15",      @"iPhone15,5": @"iPhone 15 Plus",
            @"iPhone16,1": @"iPhone 15 Pro",  @"iPhone16,2": @"iPhone 15 Pro Max",
            // 16 系列
            @"iPhone17,1": @"iPhone 16 Pro",  @"iPhone17,2": @"iPhone 16 Pro Max",
            @"iPhone17,3": @"iPhone 16",      @"iPhone17,4": @"iPhone 16 Plus",
            @"iPhone17,5": @"iPhone 16e",
            // 17 系列
            @"iPhone18,1": @"iPhone 17 Pro",  @"iPhone18,2": @"iPhone 17 Pro Max",
            @"iPhone18,3": @"iPhone 17",      @"iPhone18,4": @"iPhone Air",
            // iPod
            @"iPod9,1":   @"iPod touch 7",
            // iPad 常见机型
            @"iPad11,1": @"iPad mini 5",      @"iPad11,2": @"iPad mini 5",
            @"iPad12,1": @"iPad 9",           @"iPad12,2": @"iPad 9",
            @"iPad13,1": @"iPad Air 4",       @"iPad13,2": @"iPad Air 4",
            @"iPad13,4": @"iPad Pro 11 3",    @"iPad13,5": @"iPad Pro 11 3",
            @"iPad13,6": @"iPad Pro 11 3",    @"iPad13,7": @"iPad Pro 11 3",
            @"iPad13,8": @"iPad Pro 12.9 5",  @"iPad13,9": @"iPad Pro 12.9 5",
            @"iPad13,10": @"iPad Pro 12.9 5", @"iPad13,11": @"iPad Pro 12.9 5",
            @"iPad13,16": @"iPad Air 5",      @"iPad13,17": @"iPad Air 5",
            @"iPad14,1": @"iPad mini 6",      @"iPad14,2": @"iPad mini 6",
        };
    });
    NSString *ident = SLK_机型标识();
    return map[ident] ?: ident;
}

// 系统版本，如 14.4.1
static NSString *SLK_系统版本(void) {
    static NSString *ver = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ver = [[UIDevice currentDevice] systemVersion] ?: @"unknown";
    });
    return ver;
}

// 编译/运行架构：arm64e 设备跑 arm64e 切片时返回 arm64e
static NSString *SLK_CPU架构(void) {
    static NSString *arch = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cpu_subtype_t sub = 0;
        size_t len = sizeof(sub);
        if (sysctlbyname("hw.cpusubtype", &sub, &len, NULL, 0) == 0 && sub == CPU_SUBTYPE_ARM64E) {
            arch = @"arm64e";
        } else {
            arch = @"arm64";
        }
    });
    return arch;
}

// 是否已脱离沙盒（TrollStore / 越狱都会命中）
static BOOL SLK_已越权(void) {
    static BOOL v = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        // 1) 沙盒外可写
        if ([fm isWritableFileAtPath:@"/var/mobile/Library/Preferences"]) { v = YES; return; }
        // 2) 能读系统内核缓存（沙盒 App 读不到）
        if ([fm fileExistsAtPath:@"/System/Library/Caches/com.apple.kernelcaches/kernelcache"]) { v = YES; return; }
        // 3) 越狱根目录
        if ([fm fileExistsAtPath:@"/var/jb"] || [fm fileExistsAtPath:@"/var/lib/dpkg"] ||
            [fm fileExistsAtPath:@"/var/lib/apt"]) { v = YES; return; }
    });
    return v;
}

// 是否由 TrollStore 安装（标记文件 / 系统路径可读 / 非普通容器）
static BOOL SLK_TrollStore安装(void) {
    static BOOL v = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *bundle = [NSBundle mainBundle].bundlePath;
        // TrollStore 的 _Star 标记（旧版）
        NSString *marker = [[bundle stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"_Star"];
        if ([fm fileExistsAtPath:marker]) { v = YES; return; }
        // TrollStore 2.x 的容器标记
        if ([fm fileExistsAtPath:@"/var/mobile/Library/Preferences/com.opa334.trollstore.plist"] ||
            [fm fileExistsAtPath:@"/var/containers/Bundle/trollstore"]) { v = YES; return; }
        // 系统路径可读 → 已脱沙盒（TrollStore 的典型特征）
        if ([fm fileExistsAtPath:@"/System/Library/Caches/com.apple.kernelcaches/kernelcache"]) { v = YES; return; }
        NSString *appPath = [[bundle stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        if ([appPath hasPrefix:@"/private/var/containers/Bundle/Application"] &&
            [fm fileExistsAtPath:[appPath stringByAppendingPathComponent:@"_TrollStore"]] ) { v = YES; return; }
    });
    return v;
}

// 运行环境一句话：TrollStore · 已脱沙盒 / 越狱环境 · 已越权 / 沙盒内运行
static NSString *SLK_运行环境(void) {
    BOOL ts = SLK_TrollStore安装();
    BOOL jb = SLK_已越权();
    if (ts && jb) return @"TrollStore · 已脱沙盒";
    if (ts)       return @"TrollStore · 已安装";
    if (jb)       return @"越狱环境 · 已越权";
    return @"沙盒内运行";
}

// 主二进制 Mach-O 头（按可执行路径在已加载镜像里精确匹配）
static const struct mach_header_64 *SLK_主二进制头(void) {
    static const struct mach_header_64 *hdr = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *exe = [[[NSBundle mainBundle] executablePath] fileSystemRepresentation];
        uint32_t n = _dyld_image_count();
        for (uint32_t i = 0; i < n; i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && exe && strcmp(name, exe) == 0) {
                hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
                break;
            }
        }
        if (!hdr && n > 0) hdr = (const struct mach_header_64 *)_dyld_get_image_header(0);
    });
    return hdr;
}

// 主二进制实际加载基址（ASLR 后的值，不是链接期的 0x100000000）
static uintptr_t SLK_内核段基址(void) {
    const struct mach_header_64 *hdr = SLK_主二进制头();
    return hdr ? (uintptr_t)hdr : 0;
}

// 镜像占用的文件跨度（所有 segment 中 fileoff+filesize 的最大值）
static unsigned long long SLK_镜像字节(void) {
    static unsigned long long total = 0;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const struct mach_header_64 *hdr = SLK_主二进制头();
        if (!hdr) return;
        const uint8_t *p = (const uint8_t *)(hdr + 1);
        for (uint32_t i = 0; i < hdr->ncmds; i++) {
            const struct load_command *lc = (const struct load_command *)p;
            if (lc->cmdsize == 0) break;
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                unsigned long long end = seg->fileoff + seg->filesize;
                if (end > total) total = end;
            }
            p += lc->cmdsize;
        }
        if (total == 0) {
            // 兜底：直接读文件大小
            NSDictionary *attr = [[NSFileManager defaultManager]
                attributesOfItemAtPath:[[NSBundle mainBundle] executablePath] error:nil];
            total = [attr[NSFileSize] unsignedLongLongValue];
        }
    });
    return total;
}

static NSString *SLK_字节文本(unsigned long long b) {
    if (b >= 1024ULL * 1024ULL) return [NSString stringWithFormat:@"%.1f MB", b / 1048576.0];
    if (b >= 1024ULL)           return [NSString stringWithFormat:@"%.0f KB", b / 1024.0];
    return [NSString stringWithFormat:@"%llu B", b];
}

// App 版本，取 Info.plist
static NSString *SLK_版本号(void) {
    static NSString *v = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSDictionary *info = [NSBundle mainBundle].infoDictionary;
        v = info[@"CFBundleShortVersionString"] ?: (info[@"CFBundleVersion"] ?: @"1.0");
    });
    return v;
}

static NSString *SLK_偏移摘要(BOOL 已校验) {
    return [NSString stringWithFormat:@"· %d 项偏移%@", SDK::偏移项数, 已校验 ? @"已校验" : @"待校验"];
}

// ---------------- 背景微光 ----------------
@interface SLKGlowView : UIView
@end

@implementation SLKGlowView {
    CAGradientLayer *_g1;
    CAGradientLayer *_g2;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];

        _g1 = [CAGradientLayer layer];
        _g1.type = kCAGradientLayerRadial;
        _g1.colors = @[(id)[SLK_绿 colorWithAlphaComponent:0.13f].CGColor,
                       (id)[UIColor clearColor].CGColor];
        _g1.locations = @[@0.0, @1.0];
        _g1.startPoint = CGPointMake(0.5, 0.5);
        _g1.endPoint = CGPointMake(1.0, 1.0);
        [self.layer addSublayer:_g1];

        _g2 = [CAGradientLayer layer];
        _g2.type = kCAGradientLayerRadial;
        _g2.colors = @[(id)[[UIColor colorWithRed:70.0/255.0 green:120.0/255.0 blue:255.0/255.0 alpha:1.0] colorWithAlphaComponent:0.11f].CGColor,
                       (id)[UIColor clearColor].CGColor];
        _g2.locations = @[@0.0, @1.0];
        _g2.startPoint = CGPointMake(0.5, 0.5);
        _g2.endPoint = CGPointMake(1.0, 1.0);
        [self.layer addSublayer:_g2];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _g1.frame = CGRectMake(-110.0f, -150.0f, 380.0f, 380.0f);
    _g2.frame = CGRectMake(CGRectGetWidth(self.bounds) - 210.0f, -130.0f, 340.0f, 320.0f);
}

@end


// ---------------- 终端 ----------------
@interface SLKTerminal : UIView
- (void)appendLog:(NSString *)line;
- (void)clearLog;
- (NSString *)plainText;
@end

@implementation SLKTerminal {
    UIScrollView *_sv;
    UIStackView *_stack;
    NSMutableArray<NSString *> *_lines;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _lines = [NSMutableArray array];
        self.backgroundColor = [UIColor colorWithRed:8.0/255.0 green:10.0/255.0 blue:13.0/255.0 alpha:1.0];
        self.layer.cornerRadius = 17.0f;
        self.layer.borderWidth = 1.0f;
        self.layer.borderColor = SLK_线.CGColor;
        self.clipsToBounds = YES;

        _sv = [[UIScrollView alloc] init];
        _sv.translatesAutoresizingMaskIntoConstraints = NO;
        _sv.showsVerticalScrollIndicator = NO;
        _sv.alwaysBounceVertical = YES;
        [self addSubview:_sv];

        _stack = [[UIStackView alloc] init];
        _stack.axis = UILayoutConstraintAxisVertical;
        _stack.spacing = 2.0f;
        _stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_sv addSubview:_stack];

        [NSLayoutConstraint activateConstraints:@[
            [_sv.topAnchor constraintEqualToAnchor:self.topAnchor constant:13.0f],
            [_sv.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:13.0f],
            [_sv.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-13.0f],
            [_sv.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-13.0f],
            [_stack.topAnchor constraintEqualToAnchor:_sv.contentLayoutGuide.topAnchor],
            [_stack.leadingAnchor constraintEqualToAnchor:_sv.contentLayoutGuide.leadingAnchor],
            [_stack.trailingAnchor constraintEqualToAnchor:_sv.contentLayoutGuide.trailingAnchor],
            [_stack.bottomAnchor constraintEqualToAnchor:_sv.contentLayoutGuide.bottomAnchor],
            [_stack.widthAnchor constraintEqualToAnchor:_sv.frameLayoutGuide.widthAnchor],
        ]];
    }
    return self;
}

- (void)appendLog:(NSString *)line {
    if (line.length == 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        static NSDateFormatter *fmt = nil;
        if (!fmt) {
            fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"HH:mm:ss";
        }
        NSString *ts = [NSString stringWithFormat:@"[%@] ", [fmt stringFromDate:[NSDate date]]];
        [self->_lines addObject:[NSString stringWithFormat:@"%@%@", ts, line]];
        if (self->_lines.count > 200) [self->_lines removeObjectAtIndex:0];

        UIColor *body = SLK_次字;
        if ([line containsString:@"成功"] || [line containsString:@"就绪"] ||
            [line containsString:@"已启用"] || [line containsString:@"已挂载"]) {
            body = SLK_绿;
        } else if ([line containsString:@"失败"] || [line containsString:@"错误"] ||
                   [line containsString:@"未就绪"] || [line containsString:@"清除"]) {
            body = SLK_红;
        }

        NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
            initWithString:ts
                attributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:9.0f weight:UIFontWeightRegular],
                             NSForegroundColorAttributeName: SLK_极弱}];
        [s appendAttributedString:[[NSAttributedString alloc]
            initWithString:line
                attributes:@{NSFontAttributeName: [UIFont monospacedSystemFontOfSize:10.0f weight:UIFontWeightRegular],
                             NSForegroundColorAttributeName: body}]];

        UILabel *l = [[UILabel alloc] init];
        l.numberOfLines = 0;
        l.attributedText = s;
        [self->_stack addArrangedSubview:l];

        while (self->_stack.arrangedSubviews.count > 120) {
            UIView *f = self->_stack.arrangedSubviews.firstObject;
            [self->_stack removeArrangedSubview:f];
            [f removeFromSuperview];
        }

        [self->_stack layoutIfNeeded];
        CGFloat maxY = self->_sv.contentSize.height - self->_sv.bounds.size.height;
        if (maxY > 0) {
            [self->_sv setContentOffset:CGPointMake(0, maxY) animated:YES];
        }
    });
}

- (NSString *)plainText {
    return [_lines componentsJoinedByString:@"\n"];
}

- (void)clearLog {
    [_lines removeAllObjects];
    for (UIView *v in [_stack.arrangedSubviews copy]) {
        [_stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    [_sv setContentOffset:CGPointZero animated:NO];
}

@end


// ---------------- 胶囊分页 ----------------
@interface SLKPillTabs : UIView
@property (nonatomic) NSInteger selected;
@property (nonatomic, copy) void (^onChange)(NSInteger idx);
- (instancetype)initWithTitles:(NSArray<NSString *> *)titles;
@end

@implementation SLKPillTabs {
    NSMutableArray<UIButton *> *_btns;
    UIView *_indicator;
    UIStackView *_bar;
}

- (instancetype)initWithTitles:(NSArray<NSString *> *)titles {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:13.0/255.0 green:15.0/255.0 blue:19.0/255.0 alpha:1.0];
        self.layer.cornerRadius = 13.0f;
        self.layer.borderWidth = 1.0f;
        self.layer.borderColor = SLK_线.CGColor;

        _indicator = [[UIView alloc] init];
        _indicator.backgroundColor = SLK_主字;
        _indicator.layer.cornerRadius = 9.0f;
        _indicator.layer.shadowColor = [UIColor blackColor].CGColor;
        _indicator.layer.shadowOpacity = 0.4f;
        _indicator.layer.shadowRadius = 6.0f;
        _indicator.layer.shadowOffset = CGSizeMake(0, 2);
        [self addSubview:_indicator];

        _bar = [[UIStackView alloc] init];
        _bar.axis = UILayoutConstraintAxisHorizontal;
        _bar.distribution = UIStackViewDistributionFillEqually;
        _bar.spacing = 4.0f;
        _bar.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_bar];
        [NSLayoutConstraint activateConstraints:@[
            [_bar.topAnchor constraintEqualToAnchor:self.topAnchor constant:4.0f],
            [_bar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:4.0f],
            [_bar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-4.0f],
            [_bar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-4.0f],
        ]];

        _btns = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)titles.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
            [b setTitle:titles[i] forState:UIControlStateNormal];
            b.titleLabel.font = [UIFont systemFontOfSize:12.5f weight:UIFontWeightSemibold];
            b.tag = i;
            [b addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
            [_bar addArrangedSubview:b];
            [_btns addObject:b];
        }
        _selected = 0;
        [self refreshTitleColors];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self moveIndicator:NO];
}

- (void)moveIndicator:(BOOL)animated {
    if (_btns.count == 0) return;
    NSInteger idx = MAX(0, MIN(_selected, (NSInteger)_btns.count - 1));
    UIButton *b = _btns[idx];
    CGRect target = [self convertRect:b.frame fromView:_bar];
    if (animated) {
        [UIView animateWithDuration:0.26f delay:0
                            options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ self->_indicator.frame = target; }
                         completion:nil];
    } else {
        _indicator.frame = target;
    }
}

- (void)refreshTitleColors {
    for (NSInteger i = 0; i < (NSInteger)_btns.count; i++) {
        UIColor *c = (i == _selected) ? [UIColor colorWithRed:10.0/255.0 green:12.0/255.0 blue:16.0/255.0 alpha:1.0] : SLK_弱字;
        [_btns[i] setTitleColor:c forState:UIControlStateNormal];
    }
}

- (void)tabTapped:(UIButton *)sender {
    if (sender.tag == _selected) return;
    _selected = sender.tag;
    [self refreshTitleColors];
    [self moveIndicator:YES];
    UISelectionFeedbackGenerator *g = [[UISelectionFeedbackGenerator alloc] init];
    [g selectionChanged];
    if (self.onChange) self.onChange(_selected);
}

- (void)setSelected:(NSInteger)selected {
    _selected = selected;
    [self refreshTitleColors];
    [self moveIndicator:YES];
}

@end


// ---------------- 主开关卡 ----------------
@interface SLKHeroCard : UIView
@property (nonatomic) BOOL ready;
@property (nonatomic, copy) void (^onToggle)(BOOL wantOn);
@property (nonatomic, copy) void (^onDenied)(void);
- (BOOL)isOn;
- (void)setOn:(BOOL)on animated:(BOOL)animated;
- (void)setStatusText:(NSString *)status sub:(NSString *)sub live:(BOOL)live;
@end

@implementation SLKHeroCard {
    UILabel *_bigLabel;
    UILabel *_subLabel;
    UILabel *_statusLabel;
    UIView *_dot;
    UIView *_bar;
    UIView *_barFill;
    NSLayoutConstraint *_fillWidth;
    UISwitch *_sw;
    CGFloat _progress;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithRed:20.0/255.0 green:23.0/255.0 blue:29.0/255.0 alpha:1.0];
        self.layer.cornerRadius = 20.0f;
        self.layer.borderWidth = 1.0f;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08f].CGColor;
        self.clipsToBounds = YES;

        UILabel *kLabel = SLK_标签(@"主开关", 10.0f, UIFontWeightSemibold, SLK_极弱);
        kLabel.attributedText = [[NSAttributedString alloc]
            initWithString:@" 主 开 关 "
                attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10.0f weight:UIFontWeightSemibold],
                             NSForegroundColorAttributeName: SLK_弱字,
                             NSKernAttributeName: @(0.6)}];
        [self addSubview:kLabel];

        _bigLabel = SLK_标签(@"关闭", 33.0f, UIFontWeightLight, SLK_次字);
        [self addSubview:_bigLabel];

        _sw = [[UISwitch alloc] init];
        _sw.translatesAutoresizingMaskIntoConstraints = NO;
        _sw.onTintColor = SLK_绿;
        _sw.transform = CGAffineTransformMakeScale(0.94f, 0.94f);
        [_sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_sw];

        _bar = [[UIView alloc] init];
        _bar.translatesAutoresizingMaskIntoConstraints = NO;
        _bar.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.08f];
        _bar.layer.cornerRadius = 1.5f;
        _bar.clipsToBounds = YES;
        [self addSubview:_bar];

        _barFill = [[UIView alloc] init];
        _barFill.translatesAutoresizingMaskIntoConstraints = NO;
        _barFill.backgroundColor = SLK_绿;
        _barFill.layer.cornerRadius = 1.5f;
        _barFill.layer.shadowColor = SLK_绿.CGColor;
        _barFill.layer.shadowOpacity = 0.9f;
        _barFill.layer.shadowRadius = 6.0f;
        _barFill.layer.shadowOffset = CGSizeZero;
        [_bar addSubview:_barFill];

        _dot = [[UIView alloc] init];
        _dot.translatesAutoresizingMaskIntoConstraints = NO;
        _dot.backgroundColor = [UIColor colorWithRed:57.0/255.0 green:65.0/255.0 blue:79.0/255.0 alpha:1.0];
        _dot.layer.cornerRadius = 3.0f;
        [self addSubview:_dot];

        _statusLabel = SLK_标签(@"等待连接", 11.0f, UIFontWeightMedium, SLK_次字);
        [self addSubview:_statusLabel];

        _subLabel = SLK_标签(SLK_偏移摘要(NO), 11.0f, UIFontWeightRegular, SLK_弱字);
        [self addSubview:_subLabel];

        _fillWidth = [_barFill.widthAnchor constraintEqualToConstant:0];

        [NSLayoutConstraint activateConstraints:@[
            [kLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:18.0f],
            [kLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18.0f],

            [_bigLabel.topAnchor constraintEqualToAnchor:kLabel.bottomAnchor constant:8.0f],
            [_bigLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18.0f],

            [_sw.topAnchor constraintEqualToAnchor:self.topAnchor constant:16.0f],
            [_sw.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18.0f],

            [_bar.topAnchor constraintEqualToAnchor:_bigLabel.bottomAnchor constant:18.0f],
            [_bar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18.0f],
            [_bar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-18.0f],
            [_bar.heightAnchor constraintEqualToConstant:3.0f],

            [_barFill.leadingAnchor constraintEqualToAnchor:_bar.leadingAnchor],
            [_barFill.topAnchor constraintEqualToAnchor:_bar.topAnchor],
            [_barFill.bottomAnchor constraintEqualToAnchor:_bar.bottomAnchor],
            _fillWidth,

            [_dot.topAnchor constraintEqualToAnchor:_bar.bottomAnchor constant:15.0f],
            [_dot.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18.0f],
            [_dot.widthAnchor constraintEqualToConstant:6.0f],
            [_dot.heightAnchor constraintEqualToConstant:6.0f],
            [_dot.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-17.0f],

            [_statusLabel.centerYAnchor constraintEqualToAnchor:_dot.centerYAnchor],
            [_statusLabel.leadingAnchor constraintEqualToAnchor:_dot.trailingAnchor constant:7.0f],

            [_subLabel.centerYAnchor constraintEqualToAnchor:_dot.centerYAnchor],
            [_subLabel.leadingAnchor constraintEqualToAnchor:_statusLabel.trailingAnchor constant:4.0f],
            [_subLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-16.0f],
        ]];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _fillWidth.constant = _bar.bounds.size.width * _progress;
}

- (BOOL)isOn { return _sw.isOn; }

- (void)setOn:(BOOL)on animated:(BOOL)animated {
    void (^apply)(void) = ^{
        [self->_sw setOn:on animated:animated];
        self.backgroundColor = on ? SLK_开卡
                                  : [UIColor colorWithRed:20.0/255.0 green:23.0/255.0 blue:29.0/255.0 alpha:1.0];
        self.layer.borderColor = (on ? [SLK_绿 colorWithAlphaComponent:0.26f] : [UIColor colorWithWhite:1.0 alpha:0.08f]).CGColor;
        self->_bigLabel.text = on ? @"开启" : @"关闭";
        self->_bigLabel.textColor = on ? [UIColor colorWithRed:244.0/255.0 green:255.0/255.0 blue:249.0/255.0 alpha:1.0] : SLK_次字;
        self->_progress = on ? 1.0f : 0.0f;
        [self setNeedsLayout];
    };
    if (animated) {
        [UIView animateWithDuration:0.28f animations:^{
            apply();
            [self layoutIfNeeded];
        }];
    } else {
        apply();
        [self layoutIfNeeded];
    }
}

- (void)setStatusText:(NSString *)status sub:(NSString *)sub live:(BOOL)live {
    _statusLabel.text = status;
    _subLabel.text = sub;
    _dot.backgroundColor = live ? SLK_绿
                                : [UIColor colorWithRed:57.0/255.0 green:65.0/255.0 blue:79.0/255.0 alpha:1.0];
    if (live) {
        _dot.layer.shadowColor = SLK_绿.CGColor;
        _dot.layer.shadowOpacity = 0.85f;
        _dot.layer.shadowRadius = 5.0f;
        _dot.layer.shadowOffset = CGSizeZero;
    } else {
        _dot.layer.shadowOpacity = 0.0f;
    }
}

- (void)switchChanged:(UISwitch *)sender {
    BOOL want = sender.isOn;
    if (!_ready && want) {
        [sender setOn:NO animated:YES];
        if (self.onDenied) self.onDenied();
        return;
    }
    if (self.onToggle) self.onToggle(want);
}

@end


// ---------------- 指标格 ----------------
@interface SLKMetricCell : UIView
- (instancetype)initWithTitle:(NSString *)title value:(NSString *)value unit:(NSString *)unit;
- (void)setValueText:(NSString *)value;
@end

@implementation SLKMetricCell {
    UILabel *_v;
    NSString *_unit;
}

- (instancetype)initWithTitle:(NSString *)title value:(NSString *)value unit:(NSString *)unit {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _unit = [unit copy];
        self.backgroundColor = SLK_卡面;
        self.layer.cornerRadius = 15.0f;
        self.layer.borderWidth = 1.0f;
        self.layer.borderColor = SLK_线.CGColor;

        UILabel *k = SLK_标签(title, 10.5f, UIFontWeightRegular, SLK_弱字);
        [self addSubview:k];

        _v = SLK_标签(@"", 15.5f, UIFontWeightSemibold, SLK_主字);
        [self addSubview:_v];
        [self setValueText:value];

        [NSLayoutConstraint activateConstraints:@[
            [k.topAnchor constraintEqualToAnchor:self.topAnchor constant:13.0f],
            [k.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14.0f],
            [k.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-12.0f],

            [_v.topAnchor constraintEqualToAnchor:k.bottomAnchor constant:6.0f],
            [_v.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14.0f],
            [_v.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-12.0f],
            [_v.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-13.0f],
        ]];
    }
    return self;
}

- (void)setValueText:(NSString *)value {
    if (_unit.length == 0) {
        _v.text = value;
        return;
    }
    NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
        initWithString:value
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:15.5f weight:UIFontWeightSemibold],
                         NSForegroundColorAttributeName: SLK_主字}];
    [s appendAttributedString:[[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@" %@", _unit]
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10.0f weight:UIFontWeightMedium],
                         NSForegroundColorAttributeName: SLK_弱字}]];
    _v.attributedText = s;
}

@end


// ---------------- 列表行 ----------------
@interface SLKListRow : UIView
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *subLabel;
@property (nonatomic, copy) void (^onTap)(void);
- (instancetype)initWithSymbol:(NSString *)symbol
                          tint:(UIColor *)tint
                         title:(NSString *)title
                           sub:(NSString *)sub
                      trailing:(NSString *)trailing
                       chevron:(BOOL)chevron;
- (void)setTrailingText:(NSString *)text;
- (void)setTrailingColor:(UIColor *)color;
@end

@implementation SLKListRow {
    UILabel *_trailing;
    BOOL _interactive;
}

- (instancetype)initWithSymbol:(NSString *)symbol
                          tint:(UIColor *)tint
                         title:(NSString *)title
                           sub:(NSString *)sub
                      trailing:(NSString *)trailing
                       chevron:(BOOL)chevron {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _interactive = chevron;
        self.backgroundColor = [UIColor clearColor];

        if (symbol.length > 0) {
            UIView *ic = [[UIView alloc] init];
            ic.translatesAutoresizingMaskIntoConstraints = NO;
            ic.backgroundColor = [tint colorWithAlphaComponent:0.10f];
            ic.layer.cornerRadius = 9.0f;
            ic.layer.borderWidth = 1.0f;
            ic.layer.borderColor = [tint colorWithAlphaComponent:0.20f].CGColor;
            [self addSubview:ic];

            UIImageView *iv = [[UIImageView alloc] init];
            iv.translatesAutoresizingMaskIntoConstraints = NO;
            iv.image = [UIImage systemImageNamed:symbol];
            iv.tintColor = tint;
            iv.contentMode = UIViewContentModeScaleAspectFit;
            [ic addSubview:iv];

            [NSLayoutConstraint activateConstraints:@[
                [ic.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14.0f],
                [ic.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
                [ic.widthAnchor constraintEqualToConstant:32.0f],
                [ic.heightAnchor constraintEqualToConstant:32.0f],
                [iv.centerXAnchor constraintEqualToAnchor:ic.centerXAnchor],
                [iv.centerYAnchor constraintEqualToAnchor:ic.centerYAnchor],
                [iv.widthAnchor constraintEqualToConstant:16.0f],
                [iv.heightAnchor constraintEqualToConstant:16.0f],
            ]];
        }

        _titleLabel = SLK_标签(title, 13.5f, UIFontWeightMedium, SLK_主字);
        [self addSubview:_titleLabel];

        _subLabel = SLK_标签(sub, 10.5f, UIFontWeightRegular, SLK_弱字);
        _subLabel.numberOfLines = 1;
        [self addSubview:_subLabel];

        _trailing = SLK_标签(trailing, 11.0f, UIFontWeightMedium, SLK_极弱);
        _trailing.textAlignment = NSTextAlignmentRight;
        [self addSubview:_trailing];

        CGFloat lead = symbol.length > 0 ? 14.0f + 32.0f + 11.0f : 14.0f;

        NSMutableArray *cs = [NSMutableArray array];
        [cs addObjectsFromArray:@[
            [_titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:13.0f],
            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:lead],
            [_subLabel.topAnchor constraintEqualToAnchor:_titleLabel.bottomAnchor constant:3.0f],
            [_subLabel.leadingAnchor constraintEqualToAnchor:_titleLabel.leadingAnchor],
            [_subLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor constant:-14.0f],
            [_subLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-13.0f],
            [_trailing.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [self.heightAnchor constraintGreaterThanOrEqualToConstant:58.0f],
        ]];
        if (chevron) {
            UIImageView *ch = [[UIImageView alloc] init];
            ch.translatesAutoresizingMaskIntoConstraints = NO;
            ch.image = [UIImage systemImageNamed:@"chevron.right"];
            ch.tintColor = [UIColor colorWithWhite:1.0 alpha:0.22f];
            ch.contentMode = UIViewContentModeScaleAspectFit;
            [self addSubview:ch];
            [cs addObjectsFromArray:@[
                [ch.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
                [ch.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0f],
                [ch.widthAnchor constraintEqualToConstant:11.0f],
                [ch.heightAnchor constraintEqualToConstant:14.0f],
                [_trailing.trailingAnchor constraintEqualToAnchor:ch.leadingAnchor constant:-8.0f],
            ]];
        } else {
            [cs addObject:[_trailing.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14.0f]];
        }
        [cs addObject:[_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_trailing.leadingAnchor constant:-8.0f]];
        [cs addObject:[_subLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_trailing.leadingAnchor constant:-8.0f]];
        [NSLayoutConstraint activateConstraints:cs];

        if (chevron) {
            UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(rowTapped)];
            [self addGestureRecognizer:tap];
        }
    }
    return self;
}

- (void)setTrailingText:(NSString *)text {
    _trailing.text = text;
}

- (void)setTrailingColor:(UIColor *)color {
    _trailing.textColor = color;
}

- (void)rowTapped {
    self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05f];
    [UIView animateWithDuration:0.18f animations:^{
        self.backgroundColor = [UIColor clearColor];
    }];
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [g impactOccurred];
    if (self.onTap) self.onTap();
}

@end


// ---------------- 列表分组 ----------------
@interface SLKListGroup : UIView
- (instancetype)initWithRows:(NSArray<UIView *> *)rows;
@end

@implementation SLKListGroup

- (instancetype)initWithRows:(NSArray<UIView *> *)rows {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = SLK_卡面;
        self.layer.cornerRadius = 17.0f;
        self.layer.borderWidth = 1.0f;
        self.layer.borderColor = SLK_线.CGColor;
        self.clipsToBounds = YES;

        NSMutableArray *items = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)rows.count; i++) {
            if (i > 0) {
                UIView *holder = [[UIView alloc] init];
                holder.translatesAutoresizingMaskIntoConstraints = NO;
                UIView *line = SLK_细线();
                [holder addSubview:line];
                [NSLayoutConstraint activateConstraints:@[
                    [holder.heightAnchor constraintEqualToConstant:1.0f],
                    [line.leadingAnchor constraintEqualToAnchor:holder.leadingAnchor constant:14.0f],
                    [line.trailingAnchor constraintEqualToAnchor:holder.trailingAnchor constant:-14.0f],
                    [line.topAnchor constraintEqualToAnchor:holder.topAnchor],
                    [line.heightAnchor constraintEqualToConstant:1.0f],
                ]];
                [items addObject:holder];
            }
            UIView *r = rows[i];
            r.translatesAutoresizingMaskIntoConstraints = NO;
            [items addObject:r];
        }

        UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:items];
        st.axis = UILayoutConstraintAxisVertical;
        st.spacing = 0.0f;
        st.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:st];
        [NSLayoutConstraint activateConstraints:@[
            [st.topAnchor constraintEqualToAnchor:self.topAnchor],
            [st.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [st.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [st.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
    }
    return self;
}

@end


// ---------------- block 按钮 ----------------
@interface SLKBlockButton : UIButton
@property (nonatomic, copy) void (^onTap)(void);
@end

@implementation SLKBlockButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self addTarget:self action:@selector(slk_tap) forControlEvents:UIControlEventTouchUpInside];
    }
    return self;
}
- (void)slk_tap {
    if (self.onTap) self.onTap();
}
@end


// ---------------- 完成弹窗 ----------------
@interface SLKDoneAlert : UIView
+ (void)showIn:(UIView *)host;
@end

@implementation SLKDoneAlert

+ (void)showIn:(UIView *)host {
    if (!host) return;

    UIView *mask = [[UIView alloc] initWithFrame:host.bounds];
    mask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    mask.backgroundColor = [UIColor colorWithRed:3.0/255.0 green:4.0/255.0 blue:6.0/255.0 alpha:0.0f];
    mask.tag = 9911;

    UIView *box = [[UIView alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.backgroundColor = [UIColor colorWithRed:18.0/255.0 green:20.0/255.0 blue:26.0/255.0 alpha:1.0];
    box.layer.cornerRadius = 22.0f;
    box.layer.borderWidth = 1.0f;
    box.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.11f].CGColor;
    box.layer.shadowColor = [UIColor blackColor].CGColor;
    box.layer.shadowOpacity = 0.55f;
    box.layer.shadowRadius = 30.0f;
    box.layer.shadowOffset = CGSizeMake(0, 14);
    box.transform = CGAffineTransformMakeScale(0.9f, 0.9f);
    box.alpha = 0.0f;
    [mask addSubview:box];

    UIView *circle = [[UIView alloc] init];
    circle.translatesAutoresizingMaskIntoConstraints = NO;
    circle.backgroundColor = [SLK_绿 colorWithAlphaComponent:0.13f];
    circle.layer.cornerRadius = 23.0f;
    circle.layer.borderWidth = 1.0f;
    circle.layer.borderColor = [SLK_绿 colorWithAlphaComponent:0.4f].CGColor;
    [box addSubview:circle];

    UIImageView *check = [[UIImageView alloc] init];
    check.translatesAutoresizingMaskIntoConstraints = NO;
    check.image = [UIImage systemImageNamed:@"checkmark"];
    check.tintColor = SLK_绿;
    check.contentMode = UIViewContentModeScaleAspectFit;
    [circle addSubview:check];

    UILabel *title = SLK_标签(@"初始化完成", 16.0f, UIFontWeightSemibold, SLK_主字);
    title.textAlignment = NSTextAlignmentCenter;
    [box addSubview:title];

    UILabel *desc = SLK_标签(@"已连接游戏，现在可以打开主开关", 11.5f, UIFontWeightRegular, SLK_次字);
    desc.textAlignment = NSTextAlignmentCenter;
    desc.numberOfLines = 2;
    [box addSubview:desc];

    SLKBlockButton *ok = [[SLKBlockButton alloc] initWithFrame:CGRectZero];
    ok.translatesAutoresizingMaskIntoConstraints = NO;
    ok.backgroundColor = SLK_绿;
    ok.layer.cornerRadius = 12.0f;
    [ok setTitle:@"好" forState:UIControlStateNormal];
    [ok setTitleColor:[UIColor colorWithRed:4.0/255.0 green:21.0/255.0 blue:15.0/255.0 alpha:1.0] forState:UIControlStateNormal];
    ok.titleLabel.font = [UIFont systemFontOfSize:14.0f weight:UIFontWeightSemibold];
    [box addSubview:ok];

    [NSLayoutConstraint activateConstraints:@[
        [box.centerXAnchor constraintEqualToAnchor:mask.centerXAnchor],
        [box.centerYAnchor constraintEqualToAnchor:mask.centerYAnchor],
        [box.widthAnchor constraintEqualToConstant:266.0f],

        [circle.topAnchor constraintEqualToAnchor:box.topAnchor constant:24.0f],
        [circle.centerXAnchor constraintEqualToAnchor:box.centerXAnchor],
        [circle.widthAnchor constraintEqualToConstant:46.0f],
        [circle.heightAnchor constraintEqualToConstant:46.0f],
        [check.centerXAnchor constraintEqualToAnchor:circle.centerXAnchor],
        [check.centerYAnchor constraintEqualToAnchor:circle.centerYAnchor],
        [check.widthAnchor constraintEqualToConstant:20.0f],
        [check.heightAnchor constraintEqualToConstant:20.0f],

        [title.topAnchor constraintEqualToAnchor:circle.bottomAnchor constant:14.0f],
        [title.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:20.0f],
        [title.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-20.0f],

        [desc.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:7.0f],
        [desc.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:18.0f],
        [desc.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-18.0f],

        [ok.topAnchor constraintEqualToAnchor:desc.bottomAnchor constant:18.0f],
        [ok.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:22.0f],
        [ok.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-22.0f],
        [ok.heightAnchor constraintEqualToConstant:42.0f],
        [ok.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-18.0f],
    ]];

    __weak typeof(mask) weakMask = mask;
    UIView *capturedBox = box;
    ok.onTap = ^{
        [UIView animateWithDuration:0.22f animations:^{
            weakMask.alpha = 0.0f;
            capturedBox.transform = CGAffineTransformMakeScale(0.94f, 0.94f);
        } completion:^(BOOL finished) {
            [weakMask removeFromSuperview];
        }];
    };

    UITapGestureRecognizer *bgTap = [[UITapGestureRecognizer alloc] init];
    (void)bgTap;

    [host addSubview:mask];
    [UIView animateWithDuration:0.26f animations:^{
        mask.backgroundColor = [UIColor colorWithRed:3.0/255.0 green:4.0/255.0 blue:6.0/255.0 alpha:0.66f];
        box.transform = CGAffineTransformIdentity;
        box.alpha = 1.0f;
    }];
    [mask layoutIfNeeded];
}

@end


// ========================================
// BBZView 主控制器
// ========================================
@interface BBZView ()
- (void)slk_showToast:(NSString *)text;
@end

@implementation BBZView {
    NSMutableDictionary *_userDefaults;
    MainButton *_mainButton;
    BOOL _isRemoteHUDActive;
    UIImpactFeedbackGenerator *_impactFeedbackGenerator;
    SLKTerminal *_terminal;
    SLKHeroCard *_heroCard;
    SLKMetricCell *_ballCell;
    SLKBlockButton *_initBtn;
    UIView *_pageCore;
    UIView *_pageWork;
    BOOL _hasEnteredMenu;
}

+ (void)setShouldToggleHUDAfterLaunch:(BOOL)flag { _gShouldToggleHUDAfterLaunch = flag; }
+ (BOOL)shouldToggleHUDAfterLaunch { return _gShouldToggleHUDAfterLaunch; }

- (BOOL)isHUDEnabled {
#if !NO_TROLL
    return IsHUDEnabled();
#else
    return NO;
#endif
}

- (void)setHUDEnabled:(BOOL)enabled {
#if !NO_TROLL
    SetHUDEnabled(enabled);
#endif
}

- (void)registerNotifications {
    int token;
    notify_register_dispatch(NOTIFY_RELOAD_APP, &token, dispatch_get_main_queue(), ^(int token) {
        [self loadUserDefaults:YES];
    });
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(toggleHUDNotificationReceived:) name:kToggleHUDAfterLaunchNotificationName object:nil];
}

- (void)loadView {
    CGRect bounds = UIScreen.mainScreen.bounds;
    self.view = [[UIView alloc] initWithFrame:bounds];
    self.view.backgroundColor = JVR_深色背景;
    
    self.backgroundView = [[UIView alloc] initWithFrame:bounds];
    self.backgroundView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.backgroundView.backgroundColor = JVR_深色背景;
    [self.view addSubview:self.backgroundView];
    
    // 打开 App 直接进主菜单：启动页（Logo + 进度条 + 「进入系统」按钮）
    // 已经去掉，那一屏只是多一次点击，没有任何初始化动作。
    [self buildMainMenu];
}

- (void)addGridBackground:(UIView *)container {
    CAShapeLayer *grid = [CAShapeLayer layer];
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGFloat spacing = 40.0f;
    CGFloat w = UIScreen.mainScreen.bounds.size.width;
    CGFloat h = UIScreen.mainScreen.bounds.size.height;
    
    for (CGFloat x = 0; x <= w; x += spacing) {
        [path moveToPoint:CGPointMake(x, 0)];
        [path addLineToPoint:CGPointMake(x, h)];
    }
    for (CGFloat y = 0; y <= h; y += spacing) {
        [path moveToPoint:CGPointMake(0, y)];
        [path addLineToPoint:CGPointMake(w, y)];
    }
    
    grid.path = path.CGPath;
    grid.strokeColor = [UIColor colorWithWhite:1.0f alpha:0.03f].CGColor;
    grid.lineWidth = 0.5f;
    [container.layer addSublayer:grid];
}

// ========================================
// JVR 主菜单
// ========================================
- (void)buildMainMenu {
    _hasEnteredMenu = YES;
    for (UIView *sub in self.backgroundView.subviews) [sub removeFromSuperview];

    UIView *bg = self.backgroundView;
    bg.backgroundColor = SLK_底色;
    UILayoutGuide *safe = bg.safeAreaLayoutGuide;
    __weak typeof(self) weakSelf = self;

    // ---- 背景微光 ----
    SLKGlowView *glow = [[SLKGlowView alloc] initWithFrame:bg.bounds];
    glow.translatesAutoresizingMaskIntoConstraints = NO;
    [bg addSubview:glow];
    [NSLayoutConstraint activateConstraints:@[
        [glow.topAnchor constraintEqualToAnchor:bg.topAnchor],
        [glow.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor],
        [glow.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor],
        [glow.bottomAnchor constraintEqualToAnchor:bg.bottomAnchor],
    ]];

    // ---- 顶栏 ----
    UIView *header = [[UIView alloc] init];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    [bg addSubview:header];

    UIView *logo = [[UIView alloc] init];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.backgroundColor = SLK_卡面;
    logo.layer.cornerRadius = 9.0f;
    logo.layer.borderWidth = 1.0f;
    logo.layer.borderColor = SLK_线.CGColor;
    [header addSubview:logo];

    UIView *diamond = [[UIView alloc] init];
    diamond.translatesAutoresizingMaskIntoConstraints = NO;
    diamond.backgroundColor = SLK_绿;
    diamond.layer.cornerRadius = 2.0f;
    diamond.layer.shadowColor = SLK_绿.CGColor;
    diamond.layer.shadowOpacity = 0.85f;
    diamond.layer.shadowRadius = 5.0f;
    diamond.layer.shadowOffset = CGSizeZero;
    diamond.transform = CGAffineTransformMakeRotation(M_PI / 4.0);
    [logo addSubview:diamond];

    UILabel *title = SLK_标签(@"王者内核", 14.0f, UIFontWeightSemibold, SLK_主字);
    [header addSubview:title];

    UILabel *subtitle = SLK_标签(@"", 9.0f, UIFontWeightSemibold, SLK_极弱);
    subtitle.attributedText = [[NSAttributedString alloc]
        initWithString:[NSString stringWithFormat:@"%s · KERNEL CONSOLE", SDK::赛季]
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:9.0f weight:UIFontWeightSemibold],
                         NSForegroundColorAttributeName: SLK_极弱,
                         NSKernAttributeName: @(1.1)}];
    [header addSubview:subtitle];

    SLKBlockButton *refresh = [[SLKBlockButton alloc] initWithFrame:CGRectZero];
    refresh.translatesAutoresizingMaskIntoConstraints = NO;
    refresh.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04f];
    refresh.layer.cornerRadius = 15.5f;
    refresh.layer.borderWidth = 1.0f;
    refresh.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.10f].CGColor;
    [refresh setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    [refresh setPreferredSymbolConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12.0f weight:UIImageSymbolWeightSemibold]
                           forImageInState:UIControlStateNormal];
    refresh.tintColor = SLK_次字;
    [header addSubview:refresh];

    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:16.0f],
        [header.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-16.0f],
        [header.heightAnchor constraintEqualToConstant:62.0f],

        [logo.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [logo.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [logo.widthAnchor constraintEqualToConstant:32.0f],
        [logo.heightAnchor constraintEqualToConstant:32.0f],
        [diamond.centerXAnchor constraintEqualToAnchor:logo.centerXAnchor],
        [diamond.centerYAnchor constraintEqualToAnchor:logo.centerYAnchor],
        [diamond.widthAnchor constraintEqualToConstant:9.0f],
        [diamond.heightAnchor constraintEqualToConstant:9.0f],

        [title.leadingAnchor constraintEqualToAnchor:logo.trailingAnchor constant:10.0f],
        [title.topAnchor constraintEqualToAnchor:logo.topAnchor constant:1.0f],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2.0f],

        [refresh.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [refresh.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [refresh.widthAnchor constraintEqualToConstant:31.0f],
        [refresh.heightAnchor constraintEqualToConstant:31.0f],
    ]];

    // ---- 胶囊分页 ----
    SLKPillTabs *tabs = [[SLKPillTabs alloc] initWithTitles:@[@"内核", @"运行"]];
    tabs.translatesAutoresizingMaskIntoConstraints = NO;
    [bg addSubview:tabs];

    UIView *pageHost = [[UIView alloc] init];
    pageHost.translatesAutoresizingMaskIntoConstraints = NO;
    pageHost.clipsToBounds = YES;
    [bg addSubview:pageHost];

    [NSLayoutConstraint activateConstraints:@[
        [tabs.topAnchor constraintEqualToAnchor:header.bottomAnchor constant:2.0f],
        [tabs.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:16.0f],
        [tabs.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-16.0f],
        [tabs.heightAnchor constraintEqualToConstant:42.0f],

        [pageHost.topAnchor constraintEqualToAnchor:tabs.bottomAnchor constant:12.0f],
        [pageHost.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor constant:16.0f],
        [pageHost.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor constant:-16.0f],
        [pageHost.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-4.0f],
    ]];

    // ==================== 页一：内核 ====================
    UIScrollView *p1 = [[UIScrollView alloc] init];
    p1.translatesAutoresizingMaskIntoConstraints = NO;
    p1.showsVerticalScrollIndicator = NO;
    p1.alwaysBounceVertical = YES;
    [pageHost addSubview:p1];

    UIStackView *c1 = [[UIStackView alloc] init];
    c1.axis = UILayoutConstraintAxisVertical;
    c1.spacing = 0.0f;
    c1.translatesAutoresizingMaskIntoConstraints = NO;
    [p1 addSubview:c1];

    [NSLayoutConstraint activateConstraints:@[
        [p1.topAnchor constraintEqualToAnchor:pageHost.topAnchor],
        [p1.leadingAnchor constraintEqualToAnchor:pageHost.leadingAnchor],
        [p1.trailingAnchor constraintEqualToAnchor:pageHost.trailingAnchor],
        [p1.bottomAnchor constraintEqualToAnchor:pageHost.bottomAnchor],

        [c1.topAnchor constraintEqualToAnchor:p1.contentLayoutGuide.topAnchor],
        [c1.leadingAnchor constraintEqualToAnchor:p1.contentLayoutGuide.leadingAnchor],
        [c1.trailingAnchor constraintEqualToAnchor:p1.contentLayoutGuide.trailingAnchor],
        [c1.bottomAnchor constraintEqualToAnchor:p1.contentLayoutGuide.bottomAnchor constant:-18.0f],
        [c1.widthAnchor constraintEqualToAnchor:p1.frameLayoutGuide.widthAnchor],
    ]];

    SLKMetricCell *m1 = [[SLKMetricCell alloc] initWithTitle:@"偏移项"
                                                       value:[NSString stringWithFormat:@"%d", SDK::偏移项数]
                                                        unit:@"项"];
    SLKMetricCell *m2 = [[SLKMetricCell alloc] initWithTitle:@"世界地址"
                                                       value:[NSString stringWithFormat:@"%08llX", (unsigned long long)SDK::根世界]
                                                        unit:@""];
    SLKMetricCell *m3 = [[SLKMetricCell alloc] initWithTitle:@"运行环境"
                                                       value:[NSString stringWithFormat:@"iOS %@", SLK_系统版本()]
                                                        unit:@""];
    _ballCell = [[SLKMetricCell alloc] initWithTitle:@"悬浮球" value:@"未挂载" unit:@""];

    UIStackView *gridRow1 = SLK_等宽行(@[m1, m2], 9.0f);
    UIStackView *gridRow2 = SLK_等宽行(@[m3, _ballCell], 9.0f);
    UIStackView *grid = [[UIStackView alloc] initWithArrangedSubviews:@[gridRow1, gridRow2]];
    grid.axis = UILayoutConstraintAxisVertical;
    grid.spacing = 9.0f;
    [c1 addArrangedSubview:grid];
    [c1 setCustomSpacing:22.0f afterView:grid];

    UILabel *labWork = SLK_分组标题(@"维护");
    [c1 addArrangedSubview:labWork];
    [c1 setCustomSpacing:9.0f afterView:labWork];

    SLKListRow *rInit = [[SLKListRow alloc] initWithSymbol:@"bolt.fill" tint:SLK_绿
                                                      title:@"重连游戏进程" sub:@"清空端口与模块缓存后重新握手"
                                                   trailing:@"" chevron:YES];
    SLKListRow *rClear = [[SLKListRow alloc] initWithSymbol:@"trash" tint:SLK_红
                                                       title:@"重置连接缓存" sub:@"丢掉端口与模块缓存并重扫"
                                                    trailing:@"" chevron:YES];
    SLKListGroup *gWork = [[SLKListGroup alloc] initWithRows:@[rInit, rClear]];
    [c1 addArrangedSubview:gWork];
    [c1 setCustomSpacing:22.0f afterView:gWork];

    UILabel *labDev = SLK_分组标题(@"设备");
    [c1 addArrangedSubview:labDev];
    [c1 setCustomSpacing:9.0f afterView:labDev];

    NSString *设备标题 = [NSString stringWithFormat:@"%@ · %@", SLK_机型名称(), SLK_CPU架构()];
    NSString *设备副标 = SLK_运行环境();
    NSString *内核标题 = [NSString stringWithFormat:@"内核段 0x%lX", (unsigned long)SLK_内核段基址()];
    NSString *内核副标 = [NSString stringWithFormat:@"镜像 %@ · 页 %ld KB",
                          SLK_字节文本(SLK_镜像字节()), (long)(getpagesize() / 1024)];

    SLKListRow *d1 = [[SLKListRow alloc] initWithSymbol:@"" tint:SLK_绿
                                                   title:设备标题 sub:设备副标
                                                trailing:@"DEVICE" chevron:NO];
    SLKListRow *d2 = [[SLKListRow alloc] initWithSymbol:@"" tint:SLK_绿
                                                   title:内核标题 sub:内核副标
                                                trailing:@"IMAGE" chevron:NO];
    SLKListGroup *gDev = [[SLKListGroup alloc] initWithRows:@[d1, d2]];
    [c1 addArrangedSubview:gDev];

    // ==================== 页二：维护 ====================
    UIScrollView *p2 = [[UIScrollView alloc] init];
    p2.translatesAutoresizingMaskIntoConstraints = NO;
    p2.showsVerticalScrollIndicator = NO;
    p2.alwaysBounceVertical = YES;
    [pageHost addSubview:p2];

    UIStackView *c2 = [[UIStackView alloc] init];
    c2.axis = UILayoutConstraintAxisVertical;
    c2.spacing = 0.0f;
    c2.translatesAutoresizingMaskIntoConstraints = NO;
    [p2 addSubview:c2];

    [NSLayoutConstraint activateConstraints:@[
        [p2.topAnchor constraintEqualToAnchor:pageHost.topAnchor],
        [p2.leadingAnchor constraintEqualToAnchor:pageHost.leadingAnchor],
        [p2.trailingAnchor constraintEqualToAnchor:pageHost.trailingAnchor],
        [p2.bottomAnchor constraintEqualToAnchor:pageHost.bottomAnchor],

        [c2.topAnchor constraintEqualToAnchor:p2.contentLayoutGuide.topAnchor],
        [c2.leadingAnchor constraintEqualToAnchor:p2.contentLayoutGuide.leadingAnchor],
        [c2.trailingAnchor constraintEqualToAnchor:p2.contentLayoutGuide.trailingAnchor],
        [c2.bottomAnchor constraintEqualToAnchor:p2.contentLayoutGuide.bottomAnchor constant:-18.0f],
        [c2.widthAnchor constraintEqualToAnchor:p2.frameLayoutGuide.widthAnchor],
    ]];

    _heroCard = [[SLKHeroCard alloc] init];
    [c2 addArrangedSubview:_heroCard];
    [c2 setCustomSpacing:20.0f afterView:_heroCard];

    // ==================== 运行页 · 日志（紧跟主开关） ====================

    UIView *logBar = [[UIView alloc] init];
    logBar.translatesAutoresizingMaskIntoConstraints = NO;
    [c2 addArrangedSubview:logBar];
    [c2 setCustomSpacing:9.0f afterView:logBar];

    UILabel *labLog = SLK_标签(@"", 10.0f, UIFontWeightSemibold, SLK_弱字);
    labLog.attributedText = [[NSAttributedString alloc]
        initWithString:@"SYSTEM OUTPUT"
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:10.0f weight:UIFontWeightSemibold],
                         NSForegroundColorAttributeName: SLK_弱字,
                         NSKernAttributeName: @(1.0)}];
    [logBar addSubview:labLog];

    SLKBlockButton *clearLog = [[SLKBlockButton alloc] initWithFrame:CGRectZero];
    clearLog.translatesAutoresizingMaskIntoConstraints = NO;
    clearLog.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06f];
    clearLog.layer.cornerRadius = 8.0f;
    [clearLog setTitle:@"清空" forState:UIControlStateNormal];
    [clearLog setTitleColor:SLK_次字 forState:UIControlStateNormal];
    clearLog.titleLabel.font = [UIFont systemFontOfSize:10.5f weight:UIFontWeightMedium];
    [logBar addSubview:clearLog];

    SLKBlockButton *copyLog = [[SLKBlockButton alloc] initWithFrame:CGRectZero];
    copyLog.translatesAutoresizingMaskIntoConstraints = NO;
    copyLog.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06f];
    copyLog.layer.cornerRadius = 8.0f;
    [copyLog setTitle:@"复制" forState:UIControlStateNormal];
    [copyLog setTitleColor:SLK_次字 forState:UIControlStateNormal];
    copyLog.titleLabel.font = [UIFont systemFontOfSize:10.5f weight:UIFontWeightMedium];
    [logBar addSubview:copyLog];

    _terminal = [[SLKTerminal alloc] init];
    _terminal.translatesAutoresizingMaskIntoConstraints = NO;
    [c2 addArrangedSubview:_terminal];
    [_terminal.heightAnchor constraintEqualToConstant:200.0f].active = YES;
    [c2 setCustomSpacing:22.0f afterView:_terminal];

    [NSLayoutConstraint activateConstraints:@[
        [logBar.heightAnchor constraintEqualToConstant:26.0f],

        [labLog.leadingAnchor constraintEqualToAnchor:logBar.leadingAnchor constant:2.0f],
        [labLog.centerYAnchor constraintEqualToAnchor:logBar.centerYAnchor],

        [copyLog.trailingAnchor constraintEqualToAnchor:logBar.trailingAnchor],
        [copyLog.centerYAnchor constraintEqualToAnchor:logBar.centerYAnchor],
        [copyLog.widthAnchor constraintEqualToConstant:46.0f],
        [copyLog.heightAnchor constraintEqualToConstant:24.0f],

        [clearLog.trailingAnchor constraintEqualToAnchor:copyLog.leadingAnchor constant:-8.0f],
        [clearLog.centerYAnchor constraintEqualToAnchor:copyLog.centerYAnchor],
        [clearLog.widthAnchor constraintEqualToConstant:46.0f],
        [clearLog.heightAnchor constraintEqualToConstant:24.0f],

        [labLog.trailingAnchor constraintLessThanOrEqualToAnchor:clearLog.leadingAnchor constant:-8.0f],
    ]];

    clearLog.onTap = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s->_terminal clearLog];
        [s->_terminal appendLog:@"日志已清空"];
    };

    copyLog.onTap = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        NSString *txt = [s->_terminal plainText];
        if (txt.length == 0) {
            [s slk_showToast:@"日志为空"];
            return;
        }
        [UIPasteboard generalPasteboard].string = txt;
        NSUInteger lines = [txt componentsSeparatedByString:@"\n"].count;
        [s slk_showToast:[NSString stringWithFormat:@"已复制 %lu 行日志", (unsigned long)lines]];
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [g impactOccurred];
    };

    UILabel *labInfo = SLK_分组标题(@"内核维护");
    [c2 addArrangedSubview:labInfo];
    [c2 setCustomSpacing:9.0f afterView:labInfo];

    SLKListRow *v1 = [[SLKListRow alloc] initWithSymbol:@"doc.text" tint:SLK_次字
                                                  title:@"偏移表"
                                                    sub:[NSString stringWithFormat:@"根世界 0x%llX · 根相机 0x%llX",
                                                         (unsigned long long)SDK::根世界,
                                                         (unsigned long long)SDK::根相机]
                                               trailing:[NSString stringWithFormat:@"%d 项", SDK::偏移项数]
                                                chevron:NO];
    SLKListRow *v2 = [[SLKListRow alloc] initWithSymbol:@"internaldrive" tint:SLK_次字
                                                  title:@"镜像占用"
                                                    sub:[NSString stringWithFormat:@"主二进制 %@ · %@",
                                                         SLK_字节文本(SLK_镜像字节()), SLK_CPU架构()]
                                               trailing:@"" chevron:NO];
    SLKListGroup *gInfo = [[SLKListGroup alloc] initWithRows:@[v1, v2]];
    [c2 addArrangedSubview:gInfo];
    [c2 setCustomSpacing:14.0f afterView:gInfo];

    _initBtn = [[SLKBlockButton alloc] initWithFrame:CGRectZero];
    _initBtn.backgroundColor = SLK_绿;
    _initBtn.layer.cornerRadius = 14.0f;
    [_initBtn setTitle:@"重连游戏进程" forState:UIControlStateNormal];
    [_initBtn setTitleColor:[UIColor colorWithRed:4.0/255.0 green:21.0/255.0 blue:15.0/255.0 alpha:1.0]
                   forState:UIControlStateNormal];
    _initBtn.titleLabel.font = [UIFont systemFontOfSize:14.5f weight:UIFontWeightSemibold];
    [_initBtn.heightAnchor constraintEqualToConstant:46.0f].active = YES;
    [c2 addArrangedSubview:_initBtn];
    [c2 setCustomSpacing:10.0f afterView:_initBtn];

    SLKBlockButton *clearBtn = [[SLKBlockButton alloc] initWithFrame:CGRectZero];
    clearBtn.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05f];
    clearBtn.layer.cornerRadius = 14.0f;
    clearBtn.layer.borderWidth = 1.0f;
    clearBtn.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.09f].CGColor;
    [clearBtn setTitle:@"重置连接缓存" forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor colorWithRed:195.0/255.0 green:202.0/255.0 blue:216.0/255.0 alpha:1.0]
                   forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:14.5f weight:UIFontWeightMedium];
    [clearBtn.heightAnchor constraintEqualToConstant:46.0f].active = YES;
    [c2 addArrangedSubview:clearBtn];
    [c2 setCustomSpacing:22.0f afterView:clearBtn];

    UILabel *labNote = SLK_分组标题(@"说明");
    [c2 addArrangedSubview:labNote];
    [c2 setCustomSpacing:9.0f afterView:labNote];

    NSString *noteText =
        @"设备已由越狱持有内核，本 App 只做一件事：用 task_for_pid 拿游戏的任务端口读内存，不跑任何内核初始化。\n「重连游戏进程」会清空端口与模块缓存后重新握手；「重置连接缓存」等于同样的重置并卸载悬浮球。\n绘制、调节与自瞄参数请在悬浮球里调整。";
    UILabel *note = SLK_标签(noteText,
                             11.5f, UIFontWeightRegular, SLK_弱字);
    note.numberOfLines = 0;
    [c2 addArrangedSubview:note];

    _pageCore = p1;
    _pageWork = p2;
    // 主开关已移到运行页，默认停在运行
    p1.hidden = YES;
    p2.hidden = NO;
    tabs.selected = 1;

    tabs.onChange = ^(NSInteger idx) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        s->_pageCore.hidden = (idx != 0);
        s->_pageWork.hidden = (idx != 1);
    };

    refresh.onTap = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [UIView animateWithDuration:0.45f animations:^{
            refresh.imageView.transform = CGAffineTransformMakeRotation((CGFloat)M_PI);
        } completion:^(BOOL finished) {
            refresh.imageView.transform = CGAffineTransformIdentity;
        }];
        BOOL ok = 游戏已连接();
        [s->_heroCard setStatusText:(ok ? @"已连接游戏" : @"未连接")
                                sub:SLK_偏移摘要(ok)
                               live:ok];
        [s->_terminal appendLog:(ok ? @"状态刷新: 任务端口已连接" : @"状态刷新: 等待连接游戏进程")];
    };

    // ---- 主开关 ----
    BOOL 已连接 = 游戏已连接();
    _isRemoteHUDActive = 已连接 ? [self isHUDEnabled] : NO;
    _heroCard.ready = 已连接;
    [_heroCard setOn:_isRemoteHUDActive animated:NO];
    [_heroCard setStatusText:(已连接 ? (_isRemoteHUDActive ? @"绘制运行中" : @"已连接游戏") : @"等待连接")
                         sub:SLK_偏移摘要(_isRemoteHUDActive)
                        live:(已连接 && _isRemoteHUDActive)];
    [_ballCell setValueText:(_isRemoteHUDActive ? @"已挂载" : @"未挂载")];

    _heroCard.onDenied = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        [s->_heroCard setOn:NO animated:YES];
        [s 提示内核未就绪];
        [s->_terminal appendLog:@"主开关被拦截 · 还没连上游戏进程"];
    };

    _heroCard.onToggle = ^(BOOL wantOn) {
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;

        if (wantOn && !游戏已连接()) {
            [s 提示内核未就绪];
            [s->_heroCard setOn:NO animated:YES];
            s->_isRemoteHUDActive = NO;
            return;
        }

        s->_isRemoteHUDActive = wantOn;
        [s setHUDEnabled:wantOn];
        [s->_heroCard setOn:wantOn animated:YES];
        [s->_heroCard setStatusText:(wantOn ? @"绘制运行中" : @"绘制已停止")
                                sub:(wantOn ? SLK_偏移摘要(YES) : @"· 绘制进程已挂起")
                               live:wantOn];
        [s->_ballCell setValueText:(wantOn ? @"已挂载" : @"未挂载")];
        [s->_terminal appendLog:(wantOn ? @"主开关已开启 · 悬浮球已挂载" : @"主开关已关闭 · 绘制已停止")];
    };

    // ---- 重连游戏进程（内核由越狱持有，这里不做任何内核动作） ----
    _initBtn.onTap = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if (s->_initBtn.enabled == NO) return;

        s->_initBtn.enabled = NO;
        s->_initBtn.alpha = 0.65f;
        [s->_initBtn setTitle:@"重连中…" forState:UIControlStateNormal];
        [s->_terminal appendLog:@"重连 · 清空任务端口与模块缓存（不跑 exploit、不接内核原语）"];

        重连游戏进程();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strong = weakSelf;
            if (!strong) return;
            BOOL ok = 游戏已连接();
            strong->_initBtn.enabled = YES;
            strong->_initBtn.alpha = 1.0f;
            [strong->_initBtn setTitle:@"重连游戏进程" forState:UIControlStateNormal];
            strong->_heroCard.ready = ok;
            [strong->_heroCard setStatusText:(ok ? @"已连接游戏" : @"等待连接")
                                         sub:SLK_偏移摘要(ok)
                                        live:ok];
            [strong->_terminal appendLog:(ok ? @"已连接 · task_for_pid 成功，任务端口就绪"
                                             : @"还没连上 · 确认游戏已在运行，再点一次重连")];
            [strong slk_showToast:(ok ? @"已连接游戏" : @"尚未连接")];
        });
    };

    // ---- 重置连接缓存 ----
    clearBtn.onTap = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        重连游戏进程();
        s->_isRemoteHUDActive = NO;
        s->_heroCard.ready = NO;
        [s->_heroCard setOn:NO animated:YES];
        [s->_heroCard setStatusText:@"等待连接" sub:SLK_偏移摘要(NO) live:NO];
        [s->_ballCell setValueText:@"未挂载"];
        [s->_terminal appendLog:@"连接缓存已重置 · 3 秒内后台重扫"];
        [s slk_showToast:@"连接缓存已重置"];
    };

    rInit.onTap = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if (s->_initBtn.onTap) s->_initBtn.onTap();
    };
    rClear.onTap = ^{
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        if (clearBtn.onTap) clearBtn.onTap();
    };

    [self reloadMainButtonState];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self->_terminal appendLog:[NSString stringWithFormat:@"内核引导器 v%@ · %s", SLK_版本号(), SDK::赛季]];
        [self->_terminal appendLog:[NSString stringWithFormat:@"设备 %@ · iOS %@ · %@", SLK_机型名称(), SLK_系统版本(), SLK_CPU架构()]];
        [self->_terminal appendLog:[NSString stringWithFormat:@"运行环境 %@", SLK_运行环境()]];
        [self->_terminal appendLog:[NSString stringWithFormat:@"偏移表已载入 · %d 项待校验", SDK::偏移项数]];
        [self->_terminal appendLog:(游戏已连接() ? @"连接状态: 任务端口已就绪" : @"连接状态: 等待连接游戏进程…")];
    });
}

- (void)slk_showToast:(NSString *)text {
    UIView *host = self.view;
    if (!host) return;

    UILabel *t = SLK_标签(text, 12.5f, UIFontWeightMedium, SLK_主字);
    t.translatesAutoresizingMaskIntoConstraints = YES;
    t.textAlignment = NSTextAlignmentCenter;
    t.backgroundColor = [UIColor colorWithRed:20.0/255.0 green:23.0/255.0 blue:29.0/255.0 alpha:0.98f];
    t.layer.cornerRadius = 12.0f;
    t.clipsToBounds = YES;
    t.layer.borderWidth = 1.0f;
    t.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12f].CGColor;
    t.alpha = 0.0f;
    t.transform = CGAffineTransformMakeTranslation(0, 14.0f);
    [host addSubview:t];

    CGSize size = [text sizeWithAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:12.5f weight:UIFontWeightMedium]}];
    CGFloat w = size.width + 34.0f;
    t.frame = CGRectMake((CGRectGetWidth(host.bounds) - w) / 2.0f,
                         CGRectGetHeight(host.bounds) - 96.0f, w, 38.0f);

    [UIView animateWithDuration:0.26f delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        t.alpha = 1.0f;
        t.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.24f delay:1.7f options:UIViewAnimationOptionCurveEaseIn animations:^{
            t.alpha = 0.0f;
            t.transform = CGAffineTransformMakeTranslation(0, 8.0f);
        } completion:^(BOOL finished2) {
            [t removeFromSuperview];
        }];
    }];
}

- (UIView *)createHeader {
    UIView *container = [[UIView alloc] init];
    
    // Logo
    UIView *logoBox = [[UIView alloc] init];
    logoBox.translatesAutoresizingMaskIntoConstraints = NO;
    logoBox.backgroundColor = JVR_卡片色;
    logoBox.layer.cornerRadius = 10.0f;
    logoBox.layer.borderWidth = 1.0f;
    logoBox.layer.borderColor = JVR_边框色.CGColor;
    [container addSubview:logoBox];
    
    UILabel *logoText = [[UILabel alloc] init];
    logoText.translatesAutoresizingMaskIntoConstraints = NO;
    logoText.text = @"SL";
    logoText.font = [UIFont systemFontOfSize:16.0f weight:UIFontWeightBlack];
    logoText.textColor = JVR_主色;
    [logoBox addSubview:logoText];
    
    UILabel *title = [[UILabel alloc] init];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"王者内核";
    title.font = [UIFont systemFontOfSize:16.0f weight:UIFontWeightBold];
    title.textColor = JVR_文字色;
    [container addSubview:title];
    
    UILabel *subtitle = [[UILabel alloc] init];
    subtitle.translatesAutoresizingMaskIntoConstraints = NO;
    subtitle.text = [NSString stringWithFormat:@"%s · 内核控制台", SDK::赛季];
    subtitle.font = [UIFont systemFontOfSize:11.0f weight:UIFontWeightMedium];
    subtitle.textColor = JVR_暗文字色;
    [container addSubview:subtitle];
    
    [NSLayoutConstraint activateConstraints:@[
        [logoBox.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [logoBox.topAnchor constraintEqualToAnchor:container.topAnchor],
        [logoBox.widthAnchor constraintEqualToConstant:50],
        [logoBox.heightAnchor constraintEqualToConstant:40],
        [logoText.centerXAnchor constraintEqualToAnchor:logoBox.centerXAnchor],
        [logoText.centerYAnchor constraintEqualToAnchor:logoBox.centerYAnchor],
        [title.leadingAnchor constraintEqualToAnchor:logoBox.trailingAnchor constant:12],
        [title.topAnchor constraintEqualToAnchor:container.topAnchor constant:2],
        [subtitle.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [subtitle.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:2],
        [container.heightAnchor constraintEqualToConstant:44],
    ]];
    
    return container;
}

// ========================================
// 生命周期与其他方法
// ========================================
- (void)viewDidLoad {
    [super viewDidLoad];
    _impactFeedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [self registerNotifications];
    gRootVC = self;
    
    __weak typeof(self) weakSelf = self;
    KernelLoggerSetHandler(^(NSString *line) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && strongSelf->_terminal) {
            [strongSelf->_terminal appendLog:line];
        }
    });
    KernelLogLine("王者内核已启动");
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self toggleHUDAfterLaunch];
}

- (void)toggleHUDNotificationReceived:(NSNotification *)notification {
    NSString *toggleAction = notification.userInfo[kToggleHUDAfterLaunchNotificationActionKey];
    if (!toggleAction) {
        [self toggleHUDAfterLaunch];
    } else if ([toggleAction isEqualToString:kToggleHUDAfterLaunchNotificationActionToggleOn]) {
        [self toggleOnHUDAfterLaunch];
    } else if ([toggleAction isEqualToString:kToggleHUDAfterLaunchNotificationActionToggleOff]) {
        [self toggleOffHUDAfterLaunch];
    }
}

- (void)toggleHUDAfterLaunch {
    if ([BBZView shouldToggleHUDAfterLaunch]) {
        [BBZView setShouldToggleHUDAfterLaunch:NO];
        _isRemoteHUDActive = ![self isHUDEnabled];
        [self setHUDEnabled:_isRemoteHUDActive];
        [[UIApplication sharedApplication] suspend];
    }
}

- (void)toggleOnHUDAfterLaunch {
    if ([BBZView shouldToggleHUDAfterLaunch]) {
        [BBZView setShouldToggleHUDAfterLaunch:NO];
        if (!_isRemoteHUDActive) {
            _isRemoteHUDActive = YES;
            [self setHUDEnabled:YES];
        }
        [[UIApplication sharedApplication] suspend];
    }
}

- (void)toggleOffHUDAfterLaunch {
    if ([BBZView shouldToggleHUDAfterLaunch]) {
        [BBZView setShouldToggleHUDAfterLaunch:NO];
        if (_isRemoteHUDActive) {
            _isRemoteHUDActive = NO;
            [self setHUDEnabled:NO];
        }
        [[UIApplication sharedApplication] suspend];
    }
}

- (void)reloadMainButtonState {
    _isRemoteHUDActive = [self isHUDEnabled];
}

// 还没连上游戏时点主开关的提示
- (void)提示内核未就绪 {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"还没连上游戏进程"
        message:@"绘制要靠 task_for_pid 拿到的任务端口读游戏内存。现在端口还没建立，打开主开关屏幕上什么都不会画。\n请先确认游戏已在运行，再点上面的「重连游戏进程」。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];

    // 找最上层 VC 弹窗
    UIViewController *host = self;
    while (host.presentedViewController) {
        host = host.presentedViewController;
    }
    [host presentViewController:alert animated:YES completion:nil];

    UIImpactFeedbackGenerator *haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [haptic impactOccurred];
}

- (void)loadUserDefaults:(BOOL)forceReload {
    if (forceReload || !_userDefaults) {
        _userDefaults = [[NSDictionary dictionaryWithContentsOfFile:(ROOT_PATH_NS_VAR(USER_DEFAULTS_PATH))] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
}

- (void)saveUserDefaults {
    [_userDefaults writeToFile:(ROOT_PATH_NS_VAR(USER_DEFAULTS_PATH)) atomically:YES];
    notify_post(NOTIFY_RELOAD_HUD);
}

- (void)reloadModeButtonState { }
- (void)verticalSizeClassUpdated { }

- (void)showSettings:(UIButton *)sender {
    LFSenderIDViewController *vc = [LFSenderIDViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)motionEnded:(UIEventSubtype)motion withEvent:(UIEvent *)event {
    if (motion == UIEventSubtypeMotionShake) {
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Developer Area" message:@"Choose an action below." preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:@"Dismiss" style:UIAlertActionStyleCancel handler:nil]];
        [alertController addAction:[UIAlertAction actionWithTitle:@"Reset Settings" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            [self resetUserDefaults];
        }]];
        [self presentViewController:alertController animated:YES completion:nil];
    }
}

- (void)resetUserDefaults {
#if !NO_TROLL
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleIdentifier) {
        [GetStandardUserDefaults() removePersistentDomainForName:bundleIdentifier];
        [GetStandardUserDefaults() synchronize];
    }
#endif
    BOOL removed = [[NSFileManager defaultManager] removeItemAtPath:(ROOT_PATH_NS_VAR(USER_DEFAULTS_PATH)) error:nil];
    if (removed) {
        [self setHUDEnabled:NO];
        [[UIApplication sharedApplication] terminateWithSuccess];
    }
}

- (BOOL)isLandscapeOrientation { return CGRectGetWidth(self.view.bounds) > CGRectGetHeight(self.view.bounds); }
- (HUDUserDefaultsKey)selectedModeKeyForCurrentOrientation { return [self isLandscapeOrientation] ? HUDUserDefaultsKeySelectedModeLandscape : HUDUserDefaultsKeySelectedMode; }
- (HUDPresetPosition)selectedModeForCurrentOrientation {
    [self loadUserDefaults:NO];
    NSNumber *mode = [_userDefaults objectForKey:[self selectedModeKeyForCurrentOrientation]];
    return mode != nil ? (HUDPresetPosition)[mode integerValue] : HUDPresetPositionTopCenter;
}
- (void)setSelectedModeForCurrentOrientation:(HUDPresetPosition)selectedMode {
    [self loadUserDefaults:NO];
    if ([self isLandscapeOrientation]) [_userDefaults removeObjectForKey:HUDUserDefaultsKeyCurrentLandscapePositionY];
    else [_userDefaults removeObjectForKey:HUDUserDefaultsKeyCurrentPositionY];
    [_userDefaults setObject:@(selectedMode) forKey:[self selectedModeKeyForCurrentOrientation]];
    [self saveUserDefaults];
}
- (BOOL)passthroughMode { [self loadUserDefaults:NO]; NSNumber *m = [_userDefaults objectForKey:HUDUserDefaultsKeyPassthroughMode]; return m ? [m boolValue] : NO; }
- (void)setPassthroughMode:(BOOL)v { [self loadUserDefaults:NO]; [_userDefaults setObject:@(v) forKey:HUDUserDefaultsKeyPassthroughMode]; [self saveUserDefaults]; }
- (BOOL)singleLineMode { [self loadUserDefaults:NO]; NSNumber *m = [_userDefaults objectForKey:HUDUserDefaultsKeySingleLineMode]; return m ? [m boolValue] : NO; }
- (void)setSingleLineMode:(BOOL)v { [self loadUserDefaults:NO]; [_userDefaults setObject:@(v) forKey:HUDUserDefaultsKeySingleLineMode]; [self saveUserDefaults]; }
- (BOOL)usesBitrate { [self loadUserDefaults:NO]; NSNumber *m = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesBitrate]; return m ? [m boolValue] : NO; }
- (void)setUsesBitrate:(BOOL)v { [self loadUserDefaults:NO]; [_userDefaults setObject:@(v) forKey:HUDUserDefaultsKeyUsesBitrate]; [self saveUserDefaults]; }
- (BOOL)usesArrowPrefixes { [self loadUserDefaults:NO]; NSNumber *m = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesArrowPrefixes]; return m ? [m boolValue] : NO; }
- (void)setUsesArrowPrefixes:(BOOL)v { [self loadUserDefaults:NO]; [_userDefaults setObject:@(v) forKey:HUDUserDefaultsKeyUsesArrowPrefixes]; [self saveUserDefaults]; }
- (BOOL)usesLargeFont { [self loadUserDefaults:NO]; NSNumber *m = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesLargeFont]; return m ? [m boolValue] : NO; }
- (void)setUsesLargeFont:(BOOL)v { [self loadUserDefaults:NO]; [_userDefaults setObject:@(v) forKey:HUDUserDefaultsKeyUsesLargeFont]; [self saveUserDefaults]; }
- (BOOL)usesRotation { [self loadUserDefaults:NO]; NSNumber *m = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesRotation]; return m ? [m boolValue] : NO; }
- (void)setUsesRotation:(BOOL)v { [self loadUserDefaults:NO]; [_userDefaults setObject:@(v) forKey:HUDUserDefaultsKeyUsesRotation]; [self saveUserDefaults]; }
- (BOOL)usesInvertedColor { [self loadUserDefaults:NO]; NSNumber *m = [_userDefaults objectForKey:HUDUserDefaultsKeyUsesInvertedColor]; return m ? [m boolValue] : NO; }
- (void)setUsesInvertedColor:(BOOL)v { [self loadUserDefaults:NO]; [_userDefaults setObject:@(v) forKey:HUDUserDefaultsKeyUsesInvertedColor]; [self saveUserDefaults]; }
- (BOOL)keepInPlace { [self loadUserDefaults:NO]; NSNumber *m = [_userDefaults objectForKey:HUDUserDefaultsKeyKeepInPlace]; return m ? [m boolValue] : NO; }
- (void)setKeepInPlace:(BOOL)v { [self loadUserDefaults:NO]; [_userDefaults setObject:@(v) forKey:HUDUserDefaultsKeyKeepInPlace]; [self saveUserDefaults]; }
- (BOOL)hideAtSnapshot { [self loadUserDefaults:NO]; NSNumber *m = [_userDefaults objectForKey:HUDUserDefaultsKeyHideAtSnapshot]; return m ? [m boolValue] : NO; }
- (void)setHideAtSnapshot:(BOOL)v { [self loadUserDefaults:NO]; [_userDefaults setObject:@(v) forKey:HUDUserDefaultsKeyHideAtSnapshot]; [self saveUserDefaults]; }

@end
