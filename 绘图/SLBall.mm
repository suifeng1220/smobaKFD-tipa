//
//  SLBall.mm
//  smobaKFD — 游戏内悬浮球 + 控制面板（CC Pro 深色玻璃风格）
//
//  架构要点：
//  1) 渲染：挂在 HUD 进程 BBZMenu 窗口（level 100000）上当 rootViewController，
//     容器 transform/bounds 抄 _MetalView，绘制层怎么转它就怎么转。
//  2) 触摸：不依赖 UIKit 事件分发。HUD 进程里 BBZMenu 是 SBS 托管窗口，
//     window bounds 是竖屏、HID 点却是横屏坐标，hitTest 永远打不中——
//     所以由 BKSHIDEventRegisterEventCallback 的回调直接调 SLBall触摸()，
//     内部把原始点按三种坐标系解释一遍，哪个命中用哪个。
//  3) 控件全部自绘 + userInteractionEnabled=NO，避免和 HUD 进程的事件系统打架。
//  4) 配置直接写 /var/mobile/Library/Preferences/com.map.settings.plist，
//     绘制层每秒读一次 → 拨完 1 秒内生效。
//

#import "SLBall.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

#ifdef __cplusplus
extern "C" {
#endif
void KernelLogLine(const char *line);
#ifdef __cplusplus
}
#endif

// ==================== 配置读写 ====================

static NSString *const SL配置路径 = @"/var/mobile/Library/Preferences/com.map.settings.plist";

static NSMutableDictionary *SL配置(void) {
    NSMutableDictionary *d = [NSMutableDictionary dictionaryWithContentsOfFile:SL配置路径];
    return d ?: [NSMutableDictionary dictionary];
}

static BOOL SL读开关(NSString *键) {
    id v = SL配置()[键];
    return v ? [v boolValue] : NO;
}

static void SL写开关(NSString *键, BOOL 值) {
    NSMutableDictionary *d = SL配置();
    d[键] = @(值);
    [d writeToFile:SL配置路径 atomically:YES];
}

static float SL读浮点(NSString *键, float 缺省) {
    id v = SL配置()[键];
    return v ? [v floatValue] : 缺省;
}

static void SL写浮点(NSString *键, float 值) {
    NSMutableDictionary *d = SL配置();
    d[键] = @(值);
    [d writeToFile:SL配置路径 atomically:YES];
}

// 日志：HUD 是独立进程，App 的日志框看不到，另落一份文件。
// 写盘一律丢到后台串行队列 —— 原来是主线程同步"读 24KB → 拼串 → 整篇写回"，
// 触摸一密就一顿一顿的，拖动的手感有一部分就是被这个拖的。
static void SL日志(NSString *格式, ...) {
    va_list ap;
    va_start(ap, 格式);
    NSString *s = [[NSString alloc] initWithFormat:格式 arguments:ap];
    va_end(ap);

    KernelLogLine([s UTF8String]);

    static dispatch_queue_t 队列;
    static dispatch_once_t 一次;
    dispatch_once(&一次, ^{
        队列 = dispatch_queue_create("com.sl.ball.log", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(队列, ^{
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"HH:mm:ss.SSS";
        NSString *行 = [NSString stringWithFormat:@"[%@] %@\n", [f stringFromDate:[NSDate date]], s];
        NSString *路径 = @"/var/mobile/Library/Preferences/com.sl.ball.log";
        NSString *旧 = [NSString stringWithContentsOfFile:路径 encoding:NSUTF8StringEncoding error:nil] ?: @"";
        if (旧.length > 24576) 旧 = [旧 substringFromIndex:旧.length - 12288];
        [[旧 stringByAppendingString:行] writeToFile:路径 atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}

static void SL日志限频(NSString *格式, ...) {
    static CFAbsoluteTime 上次 = 0;
    CFAbsoluteTime 现在 = CFAbsoluteTimeGetCurrent();
    if (现在 - 上次 < 0.20) return;
    上次 = 现在;

    va_list ap;
    va_start(ap, 格式);
    NSString *s = [[NSString alloc] initWithFormat:格式 arguments:ap];
    va_end(ap);
    SL日志(@"%@", s);
}

// ==================== 配色（对齐 CC Pro 深色玻璃） ====================

static UIColor *SL色(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

#define SL主文字   SL色(0.914f, 0.933f, 0.961f, 1.0f)   // #E9EEF5
#define SL次文字   SL色(0.549f, 0.588f, 0.659f, 1.0f)   // #8C96A8
#define SL蓝       SL色(0.239f, 0.545f, 1.000f, 1.0f)   // #3D8BFF
#define SL蓝深     SL色(0.169f, 0.408f, 0.851f, 1.0f)   // #2B68D9
#define SL紫       SL色(0.573f, 0.400f, 1.000f, 1.0f)   // #9266FF（球体渐变用）
#define SL紫深     SL色(0.365f, 0.216f, 0.878f, 1.0f)
#define SL面板底   SL色(0.055f, 0.071f, 0.098f, 0.96f)  // #0E1219
#define SL卡片底   SL色(1.0f, 1.0f, 1.0f, 0.055f)
#define SL轨道底   SL色(1.0f, 1.0f, 1.0f, 0.12f)
#define SL分隔     SL色(1.0f, 1.0f, 1.0f, 0.07f)
#define SL危险     SL色(1.000f, 0.373f, 0.427f, 1.0f)

// ==================== 尺寸 ====================

static const CGFloat SL球直径  = 56.0f;
static const CGFloat SL面板宽  = 496.0f;
static const CGFloat SL面板高  = 344.0f;
static const CGFloat SL顶栏高  = 46.0f;
static const CGFloat SL侧栏宽  = 96.0f;
static const CGFloat SL行高    = 32.0f;
static const CGFloat SL卡片顶  = 10.0f;   // 距顶栏
static const CGFloat SL卡片距  = 8.0f;    // 卡片之间

// ==================== 圆环绘制小工具 ====================

static void SL画圆(CGContextRef c, CGRect rect, UIColor *色) {
    CGContextSetFillColorWithColor(c, 色.CGColor);
    CGContextFillEllipseInRect(c, rect);
}

static void SL画圆角矩形(CGContextRef c, CGRect rect, CGFloat 圆角, UIColor *色) {
    UIBezierPath *p = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:圆角];
    [色 setFill];
    [p fill];
}

// ==================== 控件基类 ====================

@class SL控件;

typedef void (^SL控件回调)(SL控件 *控件, CGPoint 局部点);

@interface SL控件 : UIView
@property (nonatomic, copy) SL控件回调 点按回调;
@property (nonatomic, copy) SL控件回调 拖动回调;
@property (nonatomic, copy) SL控件回调 松手回调;
@property (nonatomic, copy) NSString *标题;
@property (nonatomic, assign) CGFloat 标签宽;   // 右侧数值/开关预留宽度
- (void)触摸:(CGPoint)局部 阶段:(SL触摸阶段)阶段;
- (void)刷新;                                  // 子类按需重写
- (void)按下外观:(BOOL)按下;                    // 子类按需重写
@end

@implementation SL控件 {
    BOOL _按下中;
    BOOL _移动过;
    CGPoint _按下点;
}

- (void)刷新 {}


- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;   // 全部交互走 HID 直连
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)触摸:(CGPoint)局部 阶段:(SL触摸阶段)阶段 {
    switch (阶段) {
        case SL触摸按下:
            _按下中 = YES;
            _移动过 = NO;
            _按下点 = 局部;
            [self 按下外观:YES];
            break;
        case SL触摸移动: {
            if (!_按下中) break;
            if (hypot(局部.x - _按下点.x, 局部.y - _按下点.y) > 3.0) _移动过 = YES;
            if (self.拖动回调) self.拖动回调(self, 局部);
            break;
        }
        case SL触摸抬起:
        case SL触摸取消: {
            if (!_按下中) break;
            _按下中 = NO;
            [self 按下外观:NO];
            BOOL 仍在 = CGRectContainsPoint(CGRectInset(self.bounds, -6.0, -6.0), 局部);
            // 兜底：移动事件可能整段丢失，用抬起点补算一次位移，
            // 免得"拖滑条"被当成"点滑条"。
            if (hypot(局部.x - _按下点.x, 局部.y - _按下点.y) > 3.0) _移动过 = YES;
            if (阶段 == SL触摸抬起 && 仍在) {
                if (_移动过) {
                    if (self.松手回调) self.松手回调(self, 局部);
                } else if (self.点按回调) {
                    self.点按回调(self, 局部);
                }
            }
            break;
        }
        default:
            break;
    }
}

- (void)按下外观:(BOOL)按下 {}

@end

// ==================== 开关行 ====================

@interface SL开关行 : SL控件
- (instancetype)initWithTitle:(NSString *)标题 key:(NSString *)键;
- (void)刷新;
- (void)应用状态:(BOOL)动画;
- (void)摆放圆点:(BOOL)动画;
@end

@implementation SL开关行 {
    NSString *_键;
    UILabel *_标题标签;
    CALayer *_轨道;
    CALayer *_圆点;
    BOOL _开;
}

- (instancetype)initWithTitle:(NSString *)标题 key:(NSString *)键 {
    if ((self = [super initWithFrame:CGRectZero])) {
        _键 = [键 copy];

        _标题标签 = [[UILabel alloc] initWithFrame:CGRectZero];
        _标题标签.text = 标题;
        _标题标签.font = [UIFont systemFontOfSize:13.0f weight:UIFontWeightMedium];
        _标题标签.textColor = SL主文字;
        _标题标签.userInteractionEnabled = NO;
        [self addSubview:_标题标签];

        _轨道 = [CALayer layer];
        _轨道.cornerRadius = 13.0f;
        [self.layer addSublayer:_轨道];

        _圆点 = [CALayer layer];
        _圆点.cornerRadius = 10.0f;
        _圆点.backgroundColor = [UIColor whiteColor].CGColor;
        _圆点.shadowColor = [UIColor blackColor].CGColor;
        _圆点.shadowOffset = CGSizeMake(0.0f, 1.0f);
        _圆点.shadowRadius = 2.0f;
        _圆点.shadowOpacity = 0.35f;
        [self.layer addSublayer:_圆点];

        _开 = SL读开关(_键);
        [self 应用状态:NO];

        __weak typeof(self) weakSelf = self;
        self.点按回调 = ^(SL控件 *控件, CGPoint 局部点) {
            __strong typeof(weakSelf) 强 = weakSelf;
            if (!强) return;
            强->_开 = !强->_开;
            SL写开关(强->_键, 强->_开);
            [强 应用状态:YES];
            SL日志(@"悬浮球: %@ = %d", 强->_键, 强->_开);
            UIImpactFeedbackGenerator *震 =
                [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [震 impactOccurred];
        };
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat 高 = self.bounds.size.height;
    _标题标签.frame = CGRectMake(0.0f, 0.0f, self.bounds.size.width - 60.0f, 高);

    CGFloat 轨宽 = 46.0f, 轨高 = 26.0f;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _轨道.frame = CGRectMake(self.bounds.size.width - 轨宽, (高 - 轨高) * 0.5f, 轨宽, 轨高);
    [CATransaction commit];
    [self 摆放圆点:NO];
}

- (void)摆放圆点:(BOOL)动画 {
    CGFloat 轨宽 = 46.0f, 轨高 = 26.0f;
    CGFloat 直径 = 20.0f;
    CGRect 轨 = CGRectMake(self.bounds.size.width - 轨宽, (self.bounds.size.height - 轨高) * 0.5f, 轨宽, 轨高);
    CGFloat x = _开 ? CGRectGetMaxX(轨) - 直径 - 3.0f : CGRectGetMinX(轨) + 3.0f;
    CGRect 点框 = CGRectMake(x, CGRectGetMidY(轨) - 直径 * 0.5f, 直径, 直径);

    if (动画) {
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.16];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    } else {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
    }
    _圆点.frame = 点框;
    [CATransaction commit];
}

- (void)应用状态:(BOOL)动画 {
    if (动画) {
        [CATransaction begin];
        [CATransaction setAnimationDuration:0.16];
        [CATransaction setAnimationTimingFunction:[CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut]];
    } else {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
    }
    _轨道.backgroundColor = (_开 ? SL蓝 : SL轨道底).CGColor;
    [CATransaction commit];
    [self 摆放圆点:动画];
    _标题标签.textColor = _开 ? SL主文字 : SL次文字;
}

- (void)刷新 {
    BOOL 值 = SL读开关(_键);
    if (值 == _开) return;
    _开 = 值;
    [self 应用状态:YES];
}

- (void)按下外观:(BOOL)按下 {
    self.alpha = 按下 ? 0.72f : 1.0f;
}

@end

// ==================== 滑条行 ====================

@interface SL滑条行 : SL控件
- (instancetype)initWithTitle:(NSString *)标题 key:(NSString *)键
                         最小:(float)最小 最大:(float)最大 格式:(NSString *)格式;
- (void)刷新;
- (void)取点:(CGPoint)点 写盘:(BOOL)写盘;
@end

@implementation SL滑条行 {
    NSString *_键;
    NSString *_格式;
    float _最小;
    float _最大;
    float _值;
    BOOL _拖动中;
}

- (instancetype)initWithTitle:(NSString *)标题 key:(NSString *)键
                         最小:(float)最小 最大:(float)最大 格式:(NSString *)格式 {
    if ((self = [super initWithFrame:CGRectZero])) {
        _键 = [键 copy];
        _格式 = [格式 copy];
        _最小 = 最小;
        _最大 = 最大;
        _值 = SL读浮点(_键, 1.2f);
        if (_值 < _最小) _值 = _最小;
        if (_值 > _最大) _值 = _最大;
        self.标题 = 标题;
        self.标签宽 = 46.0f;

        __weak typeof(self) weakSelf = self;
        self.拖动回调 = ^(SL控件 *控件, CGPoint 局部点) {
            __strong typeof(weakSelf) 强 = weakSelf;
            if (强) [强 取点:局部点 写盘:YES];
        };
        self.点按回调 = ^(SL控件 *控件, CGPoint 局部点) {
            __strong typeof(weakSelf) 强 = weakSelf;
            if (!强) return;
            [强 取点:局部点 写盘:YES];
            强->_拖动中 = NO;
        };
        self.松手回调 = ^(SL控件 *控件, CGPoint 局部点) {
            __strong typeof(weakSelf) 强 = weakSelf;
            if (!强) return;
            [强 取点:局部点 写盘:YES];
            强->_拖动中 = NO;
        };
    }
    return self;
}

- (void)取点:(CGPoint)点 写盘:(BOOL)写盘 {
    CGFloat 左 = 74.0f;
    CGFloat 右 = self.bounds.size.width - self.标签宽 - 6.0f;
    if (右 <= 左 + 8.0f) return;
    CGFloat t = (点.x - 左) / (右 - 左);
    t = MAX(0.0f, MIN(1.0f, t));
    _值 = _最小 + (float)t * (_最大 - _最小);
    _拖动中 = YES;
    [self setNeedsDisplay];
    if (写盘) SL写浮点(_键, _值);
}

- (void)drawRect:(CGRect)rect {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGFloat 宽 = rect.size.width;
    CGFloat 高 = rect.size.height;

    NSDictionary *标题属性 = @{
        NSFontAttributeName: [UIFont systemFontOfSize:13.0f weight:UIFontWeightMedium],
        NSForegroundColorAttributeName: SL主文字,
    };
    [self.标题 drawAtPoint:CGPointMake(0.0f, (高 - 16.0f) * 0.5f) withAttributes:标题属性];

    CGFloat 左 = 74.0f;
    CGFloat 右 = 宽 - self.标签宽 - 6.0f;
    if (右 <= 左 + 8.0f) return;

    CGFloat 轨Y = 高 * 0.5f;
    CGRect 轨 = CGRectMake(左, 轨Y - 2.0f, 右 - 左, 4.0f);
    SL画圆角矩形(c, 轨, 2.0f, SL轨道底);

    CGFloat t = (_值 - _最小) / (_最大 - _最小);
    t = MAX(0.0f, MIN(1.0f, t));
    CGRect 充 = CGRectMake(左, 轨Y - 2.0f, (右 - 左) * t, 4.0f);
    SL画圆角矩形(c, 充, 2.0f, SL蓝);

    CGFloat 点X = 左 + (右 - 左) * t;
    SL画圆(c, CGRectMake(点X - 7.0f, 轨Y - 7.0f, 14.0f, 14.0f), [UIColor whiteColor]);
    SL画圆(c, CGRectMake(点X - 4.0f, 轨Y - 4.0f, 8.0f, 8.0f), SL蓝);

    NSString *值文本 = [NSString stringWithFormat:_格式, _值];
    NSDictionary *值属性 = @{
        NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:12.0f weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: SL蓝,
    };
    CGSize 尺 = [值文本 sizeWithAttributes:值属性];
    [值文本 drawAtPoint:CGPointMake(宽 - 尺.width, (高 - 尺.height) * 0.5f) withAttributes:值属性];
}

- (void)刷新 {
    if (_拖动中) return;
    float 值 = SL读浮点(_键, _值);
    if (fabsf(值 - _值) < 0.001f) return;
    _值 = 值;
    [self setNeedsDisplay];
}

@end

// ==================== 分段行 ====================

@interface SL分段行 : SL控件
- (instancetype)initWithTitle:(NSString *)标题 选项:(NSArray<NSString *> *)选项 key:(NSString *)键;
- (void)刷新;
@end

@implementation SL分段行 {
    NSString *_键;
    NSArray<NSString *> *_选项;
    NSInteger _选中;
}

- (instancetype)initWithTitle:(NSString *)标题 选项:(NSArray<NSString *> *)选项 key:(NSString *)键 {
    if ((self = [super initWithFrame:CGRectZero])) {
        _键 = [键 copy];
        _选项 = [选项 copy];
        _选中 = (NSInteger)SL读浮点(_键, 0.0f);
        if (_选中 < 0 || _选中 >= (NSInteger)_选项.count) _选中 = 0;
        self.标题 = 标题;
        self.标签宽 = 0.0f;

        __weak typeof(self) weakSelf = self;
        self.点按回调 = ^(SL控件 *控件, CGPoint 局部点) {
            __strong typeof(weakSelf) 强 = weakSelf;
            if (!强) return;
            CGFloat 左 = 74.0f;
            CGFloat 宽 = 强.bounds.size.width - 左;
            if (局部点.x < 左 || 宽 <= 0.0f) return;
            NSInteger 段 = (NSInteger)((局部点.x - 左) / (宽 / (CGFloat)强->_选项.count));
            段 = MAX(0, MIN((NSInteger)强->_选项.count - 1, 段));
            if (段 == 强->_选中) return;
            强->_选中 = 段;
            SL写浮点(强->_键, (float)段);
            [强 setNeedsDisplay];
            SL日志(@"悬浮球: %@ = %ld", 强->_键, (long)段);
            UIImpactFeedbackGenerator *震 =
                [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
            [震 impactOccurred];
        };
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGFloat 宽 = rect.size.width;
    CGFloat 高 = rect.size.height;

    NSDictionary *标题属性 = @{
        NSFontAttributeName: [UIFont systemFontOfSize:13.0f weight:UIFontWeightMedium],
        NSForegroundColorAttributeName: SL主文字,
    };
    [self.标题 drawAtPoint:CGPointMake(0.0f, (高 - 16.0f) * 0.5f) withAttributes:标题属性];

    CGFloat 左 = 74.0f;
    CGFloat 总宽 = 宽 - 左;
    CGRect 背 = CGRectMake(左, (高 - 28.0f) * 0.5f, 总宽, 28.0f);
    SL画圆角矩形(c, 背, 8.0f, SL色(1.0f, 1.0f, 1.0f, 0.07f));

    CGFloat 段宽 = 总宽 / (CGFloat)_选项.count;
    CGRect 选中框 = CGRectMake(左 + 段宽 * (CGFloat)_选中 + 3.0f, 背.origin.y + 3.0f,
                               段宽 - 6.0f, 22.0f);
    SL画圆角矩形(c, 选中框, 6.0f, SL蓝);

    for (NSInteger i = 0; i < (NSInteger)_选项.count; ++i) {
        BOOL 是选中 = (i == _选中);
        NSDictionary *属性 = @{
            NSFontAttributeName: [UIFont systemFontOfSize:11.5f weight:是选中 ? UIFontWeightSemibold : UIFontWeightMedium],
            NSForegroundColorAttributeName: 是选中 ? [UIColor whiteColor] : SL次文字,
        };
        NSString *文本 = _选项[i];
        CGSize 尺 = [文本 sizeWithAttributes:属性];
        CGRect 段框 = CGRectMake(左 + 段宽 * (CGFloat)i, 背.origin.y, 段宽, 28.0f);
        [文本 drawAtPoint:CGPointMake(CGRectGetMidX(段框) - 尺.width * 0.5f,
                                       CGRectGetMidY(段框) - 尺.height * 0.5f)
            withAttributes:属性];
    }
}

- (void)刷新 {
    NSInteger 值 = (NSInteger)SL读浮点(_键, 0.0f);
    if (值 < 0 || 值 >= (NSInteger)_选项.count) 值 = 0;
    if (值 == _选中) return;
    _选中 = 值;
    [self setNeedsDisplay];
}

@end

// ==================== 按钮行 ====================

@interface SL按钮行 : SL控件
- (instancetype)initWithTitle:(NSString *)标题 按钮:(NSString *)按钮文字;
@end

@implementation SL按钮行 {
    NSString *_按钮文字;
}

- (instancetype)initWithTitle:(NSString *)标题 按钮:(NSString *)按钮文字 {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.标题 = 标题;
        _按钮文字 = [按钮文字 copy];
    }
    return self;
}

- (void)drawRect:(CGRect)rect {
    CGContextRef c = UIGraphicsGetCurrentContext();
    CGFloat 宽 = rect.size.width;
    CGFloat 高 = rect.size.height;

    CGFloat 按宽 = 96.0f;
    CGFloat 按高 = 26.0f;
    CGRect 按钮 = CGRectMake(宽 - 按宽, (高 - 按高) * 0.5f, 按宽, 按高);
    SL画圆角矩形(c, 按钮, 7.0f, SL色(1.0f, 1.0f, 1.0f, 0.10f));

    NSDictionary *标题属性 = @{
        NSFontAttributeName: [UIFont systemFontOfSize:13.0f weight:UIFontWeightMedium],
        NSForegroundColorAttributeName: SL主文字,
    };
    [self.标题 drawAtPoint:CGPointMake(0.0f, (高 - 16.0f) * 0.5f) withAttributes:标题属性];

    NSDictionary *按属性 = @{
        NSFontAttributeName: [UIFont systemFontOfSize:12.0f weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: SL蓝,
    };
    CGSize 尺 = [_按钮文字 sizeWithAttributes:按属性];
    [_按钮文字 drawAtPoint:CGPointMake(CGRectGetMidX(按钮) - 尺.width * 0.5f,
                                        CGRectGetMidY(按钮) - 尺.height * 0.5f)
            withAttributes:按属性];
}

- (void)按下外观:(BOOL)按下 {
    self.alpha = 按下 ? 0.65f : 1.0f;
}

@end

// ==================== 图标按钮（顶栏用） ====================

@interface SL图标按钮 : SL控件
- (instancetype)initWithSymbol:(NSString *)符号;
@end

@implementation SL图标按钮 {
    UIImageView *_图;
}

- (instancetype)initWithSymbol:(NSString *)符号 {
    if ((self = [super initWithFrame:CGRectZero])) {
        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:11.0f
                                                            weight:UIImageSymbolWeightBold];
        _图 = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:符号 withConfiguration:cfg]];
        _图.tintColor = SL次文字;
        _图.contentMode = UIViewContentModeCenter;
        _图.userInteractionEnabled = NO;
        [self addSubview:_图];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _图.frame = self.bounds;
}

- (void)drawRect:(CGRect)rect {
    SL画圆角矩形(UIGraphicsGetCurrentContext(), CGRectInset(rect, 3.0f, 3.0f), 7.0f,
                SL色(1.0f, 1.0f, 1.0f, 0.06f));
}

- (void)按下外观:(BOOL)按下 {
    self.alpha = 按下 ? 0.45f : 1.0f;
}

@end

// ==================== 侧栏导航项 ====================

@interface SL导航项 : SL控件
@property (nonatomic, assign) NSInteger 页号;
@property (nonatomic, assign) BOOL 选中;
@end

@implementation SL导航项 {
    UIImage *_图标图;
    UIView *_高亮条;
}

- (instancetype)initWithTitle:(NSString *)标题 图标:(NSString *)图标名 页号:(NSInteger)页号 {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.页号 = 页号;
        self.标签宽 = 0.0f;
        self.标题 = 标题;

        _高亮条 = [[UIView alloc] initWithFrame:CGRectZero];
        _高亮条.backgroundColor = SL蓝;
        _高亮条.layer.cornerRadius = 1.5f;
        _高亮条.hidden = YES;
        [self addSubview:_高亮条];

        UIImageSymbolConfiguration *cfg =
            [UIImageSymbolConfiguration configurationWithPointSize:13.0f
                                                            weight:UIImageSymbolWeightSemibold];
        _图标图 = [UIImage systemImageNamed:图标名 withConfiguration:cfg];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat 高 = self.bounds.size.height;
    _高亮条.frame = CGRectMake(-12.0f, (高 - 18.0f) * 0.5f, 3.0f, 18.0f);
    [self setNeedsDisplay];
}

// 文字与图标全部自绘：drawAtPoint 只画单行，不会因为宽度不够被折成两行，
// 也不受选中改字重影响，位置永远是图标的右边。
- (void)drawRect:(CGRect)rect {
    CGFloat 高 = self.bounds.size.height;
    UIColor *字色 = _选中 ? SL主文字 : SL次文字;

    if (_图标图) {
        UIImage *图 = [_图标图 imageWithTintColor:字色 renderingMode:UIImageRenderingModeAlwaysOriginal];
        [图 drawInRect:CGRectMake(10.0f, (高 - 17.0f) * 0.5f, 17.0f, 17.0f)];
    }

    NSString *文字 = self.标题;
    if (文字.length == 0) return;

    UIFont *字体 = [UIFont systemFontOfSize:11.5f
                                      weight:(_选中 ? UIFontWeightSemibold : UIFontWeightMedium)];
    NSDictionary *属性 = @{NSFontAttributeName: 字体,
                           NSForegroundColorAttributeName: 字色};
    CGSize 尺寸 = [文字 sizeWithAttributes:属性];
    [文字 drawAtPoint:CGPointMake(34.0f, (高 - 尺寸.height) * 0.5f) withAttributes:属性];
}

- (void)set选中:(BOOL)选中 {
    _选中 = 选中;
    _高亮条.hidden = !选中;
    self.backgroundColor = 选中 ? SL色(1.0f, 1.0f, 1.0f, 0.06f) : [UIColor clearColor];
    self.layer.cornerRadius = 8.0f;
    [self setNeedsDisplay];
}

- (void)按下外观:(BOOL)按下 {
    self.alpha = 按下 ? 0.6f : 1.0f;
}

@end

// ==================== 控制面板 ====================

@interface SL面板 : UIView
- (void)触摸:(CGPoint)点 阶段:(SL触摸阶段)阶段;   // 点 = 容器坐标
- (void)刷新;
- (void)更新直播提示:(BOOL)开;
@property (nonatomic, copy) void (^关面板回调)(void);
// 私有：init 里会先用到，必须先声明，否则 ARC 下报 selector not found
- (void)搭建外观;
- (void)搭建侧栏;
- (UIView *)新页:(NSInteger)页;
- (void)搭建页0;
- (void)搭建页1;
- (void)搭建页2;
- (void)切到页:(NSInteger)页;
- (UIView *)加卡片:(NSString *)卡名 y:(CGFloat)y 高:(CGFloat)高 页:(NSInteger)页;
- (void)加控件:(SL控件 *)控件 卡片:(UIView *)卡片 第几行:(NSInteger)行 页:(NSInteger)页;
- (SL控件 *)命中:(CGPoint)面板点;
@end

@implementation SL面板 {
    UILabel *_标题;
    UILabel *_副标题;
    UILabel *_状态字;
    SL控件 *_关闭按钮;
    SL控件 *_折叠按钮;
    UIView *_侧栏;
    NSMutableArray<SL导航项 *> *_导航;
    NSMutableArray<UIView *> *_页容器;
    NSInteger _当前页;
    NSMutableArray<SL控件 *> *_可交互;
    SL控件 *_按住控件;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.userInteractionEnabled = NO;

        _可交互 = [NSMutableArray array];
        _导航 = [NSMutableArray array];
        _页容器 = [NSMutableArray array];
        _当前页 = 0;

        [self 搭建外观];
        [self 搭建侧栏];
        [self 搭建页0];
        [self 搭建页1];
        [self 搭建页2];
        [self 切到页:0];
        [self 刷新];
    }
    return self;
}

// ---------- 背景（玻璃卡片） ----------

- (void)drawRect:(CGRect)rect {
    CGContextRef c = UIGraphicsGetCurrentContext();

    // 主面板：深色 + 细边框 + 投影
    CGRect 框 = self.bounds;
    UIBezierPath *外框 = [UIBezierPath bezierPathWithRoundedRect:框 cornerRadius:18.0f];
    [SL面板底 setFill];
    [外框 fill];

    // 顶部渐变高光，模拟玻璃反光
    CGContextSaveGState(c);
    [外框 addClip];
    CGColorSpaceRef 空间 = CGColorSpaceCreateDeviceRGB();
    CGFloat 色[] = {1.0f, 1.0f, 1.0f, 0.075f,
                    1.0f, 1.0f, 1.0f, 0.0f};
    CGGradientRef 渐变 = CGGradientCreateWithColorComponents(空间, 色, NULL, 2);
    CGContextDrawLinearGradient(c, 渐变, CGPointMake(0.0f, 0.0f), CGPointMake(0.0f, 130.0f), 0);
    CGGradientRelease(渐变);
    CGColorSpaceRelease(空间);
    CGContextRestoreGState(c);

    // 边框
    CGContextSetStrokeColorWithColor(c, SL色(1.0f, 1.0f, 1.0f, 0.10f).CGColor);
    CGContextSetLineWidth(c, 1.0f);
    [外框 stroke];

    // 侧栏底
    CGRect 侧 = CGRectMake(0.0f, SL顶栏高, SL侧栏宽, 框.size.height - SL顶栏高);
    SL画圆角矩形(c, 侧, 0.0f, SL色(0.0f, 0.0f, 0.0f, 0.22f));
    CGContextSetStrokeColorWithColor(c, SL分隔.CGColor);
    CGContextSetLineWidth(c, 1.0f);
    CGContextMoveToPoint(c, SL侧栏宽, SL顶栏高);
    CGContextAddLineToPoint(c, SL侧栏宽, 框.size.height);
    CGContextStrokePath(c);

    // 顶栏分隔线
    CGContextMoveToPoint(c, 0.0f, SL顶栏高);
    CGContextAddLineToPoint(c, 框.size.width, SL顶栏高);
    CGContextStrokePath(c);
}

- (void)搭建外观 {
    // 左上角 logo
    UIView *logo = [[UIView alloc] initWithFrame:CGRectMake(14.0f, 9.0f, 28.0f, 28.0f)];
    logo.layer.cornerRadius = 8.0f;
    logo.layer.masksToBounds = YES;
    CAGradientLayer *渐 = [CAGradientLayer layer];
    渐.frame = logo.bounds;
    渐.colors = @[(__bridge id)SL色(0.31f, 0.62f, 1.00f, 1.0f).CGColor,
                  (__bridge id)SL蓝深.CGColor];
    渐.startPoint = CGPointMake(0.2f, 0.0f);
    渐.endPoint = CGPointMake(0.8f, 1.0f);
    [logo.layer addSublayer:渐];
    UILabel *logo字 = [[UILabel alloc] initWithFrame:logo.bounds];
    logo字.text = @"SL";
    logo字.font = [UIFont systemFontOfSize:10.5f weight:UIFontWeightHeavy];
    logo字.textColor = [UIColor whiteColor];
    logo字.textAlignment = NSTextAlignmentCenter;
    [logo addSubview:logo字];
    [self addSubview:logo];

    _标题 = [[UILabel alloc] initWithFrame:CGRectMake(50.0f, 7.0f, 200.0f, 18.0f)];
    _标题.text = @"SL Pro";
    _标题.font = [UIFont systemFontOfSize:15.0f weight:UIFontWeightBold];
    _标题.textColor = SL主文字;
    [self addSubview:_标题];

    _副标题 = [[UILabel alloc] initWithFrame:CGRectMake(50.0f, 25.0f, 240.0f, 13.0f)];
    _副标题.text = @"S45 · CONTROL PANEL";
    _副标题.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightMedium];
    _副标题.textColor = SL次文字;
    [self addSubview:_副标题];

    // 右上角按钮：收起 / 关闭
    __weak typeof(self) weakSelf = self;
    _折叠按钮 = [[SL图标按钮 alloc] initWithSymbol:@"chevron.up"];
    _折叠按钮.frame = CGRectMake(SL面板宽 - 78.0f, 8.0f, 30.0f, 30.0f);
    _折叠按钮.点按回调 = ^(SL控件 *控件, CGPoint 点) {
        __strong typeof(weakSelf) 强 = weakSelf;
        if (强.关面板回调) 强.关面板回调();
    };
    [_折叠按钮 setNeedsDisplay];
    [self addSubview:_折叠按钮];

    _关闭按钮 = [[SL图标按钮 alloc] initWithSymbol:@"xmark"];
    _关闭按钮.frame = CGRectMake(SL面板宽 - 40.0f, 8.0f, 30.0f, 30.0f);
    _关闭按钮.点按回调 = ^(SL控件 *控件, CGPoint 点) {
        __strong typeof(weakSelf) 强 = weakSelf;
        if (强.关面板回调) 强.关面板回调();
    };
    [self addSubview:_关闭按钮];

    _状态字 = [[UILabel alloc] initWithFrame:CGRectMake(SL面板宽 - 250.0f, 16.0f, 160.0f, 14.0f)];
    _状态字.text = @"内核已就绪";
    _状态字.font = [UIFont systemFontOfSize:10.0f weight:UIFontWeightMedium];
    _状态字.textColor = SL色(0.29f, 0.80f, 0.55f, 1.0f);
    _状态字.textAlignment = NSTextAlignmentRight;
    [self addSubview:_状态字];
}

// ---------- 侧栏 ----------

- (void)搭建侧栏 {
    _侧栏 = [[UIView alloc] initWithFrame:CGRectMake(0.0f, SL顶栏高, SL侧栏宽, SL面板高 - SL顶栏高)];
    _侧栏.backgroundColor = [UIColor clearColor];
    [self addSubview:_侧栏];

    NSArray *项 = @[@[@"绘制", @"square.grid.2x2.fill"],
                    @[@"调节", @"slider.horizontal.3"],
                    @[@"通用", @"ellipsis.circle.fill"]];
    for (NSInteger i = 0; i < (NSInteger)项.count; ++i) {
        SL导航项 *导航 = [[SL导航项 alloc] initWithTitle:项[i][0] 图标:项[i][1] 页号:i];
        导航.frame = CGRectMake(14.0f, 10.0f + (CGFloat)i * 44.0f, SL侧栏宽 - 28.0f, 38.0f);
        __weak typeof(self) weakSelf = self;
        __weak SL导航项 *弱导航 = 导航;
        导航.点按回调 = ^(SL控件 *控件, CGPoint 点) {
            __strong typeof(weakSelf) 强 = weakSelf;
            if (强) [强 切到页:弱导航.页号];
        };
        [_侧栏 addSubview:导航];
        [_导航 addObject:导航];
    }
}

// ---------- 卡片与行 ----------

- (UIView *)加卡片:(NSString *)卡名 y:(CGFloat)y 高:(CGFloat)高 页:(NSInteger)页 {
    UIView *页视图 = _页容器[页];
    // 坐标相对"页视图"（页视图自己是 (侧栏宽, 顶栏高) 起）
    UIView *卡片 = [[UIView alloc] initWithFrame:CGRectMake(12.0f, y, SL面板宽 - SL侧栏宽 - 24.0f, 高)];
    卡片.backgroundColor = SL卡片底;
    卡片.layer.cornerRadius = 12.0f;
    卡片.layer.borderWidth = 1.0f;
    卡片.layer.borderColor = SL色(1.0f, 1.0f, 1.0f, 0.05f).CGColor;
    卡片.userInteractionEnabled = NO;
    [页视图 addSubview:卡片];

    UILabel *标题 = [[UILabel alloc] initWithFrame:CGRectMake(14.0f, 10.0f, 200.0f, 14.0f)];
    标题.text = [卡名 uppercaseString];
    标题.font = [UIFont systemFontOfSize:9.5f weight:UIFontWeightSemibold];
    标题.textColor = SL次文字;
    [卡片 addSubview:标题];

    return 卡片;
}

- (void)加控件:(SL控件 *)控件 卡片:(UIView *)卡片 第几行:(NSInteger)行 页:(NSInteger)页 {
    [self 加控件:控件 卡片:卡片 第几行:行 页:页 行高:SL行高 首行:28.0f];
}

- (void)加控件:(SL控件 *)控件 卡片:(UIView *)卡片 第几行:(NSInteger)行 页:(NSInteger)页
          行高:(CGFloat)行高 首行:(CGFloat)首行 {
    UIView *页视图 = _页容器[页];
    CGFloat x = 卡片.frame.origin.x + 14.0f;
    CGFloat 宽 = 卡片.frame.size.width - 28.0f;
    CGFloat y = 卡片.frame.origin.y + 首行 + (CGFloat)行 * 行高;
    控件.frame = CGRectMake(x, y, 宽, 行高);
    [页视图 addSubview:控件];
    [_可交互 addObject:控件];
}

- (UIView *)新页:(NSInteger)页 {
    UIView *页视图 = [[UIView alloc] initWithFrame:CGRectMake(SL侧栏宽, SL顶栏高,
                                                             SL面板宽 - SL侧栏宽,
                                                             SL面板高 - SL顶栏高)];
    页视图.backgroundColor = [UIColor clearColor];
    页视图.userInteractionEnabled = NO;
    页视图.hidden = YES;
    [self addSubview:页视图];
    [_页容器 addObject:页视图];
    return 页视图;
}

// ---------- 三页内容 ----------

- (void)搭建页0 {
    [self 新页:0];

    // 绘制与信息合并成一张卡；8 行要一屏放下，行高收到 30
    CGFloat 首行 = 28.0f;
    CGFloat 行距 = 30.0f;
    CGFloat 卡高 = 首行 + 行距 * 8.0f + 8.0f;
    UIView *卡 = [self 加卡片:@"绘制" y:SL卡片顶 高:卡高 页:0];

    NSArray *行 = @[@[@"总开关",   @"draw"],
                    @[@"小地图",   @"map"],
                    @[@"头像显示", @"avatar"],
                    @[@"技能图标", @"skill"],
                    @[@"野怪显示", @"monster"],
                    @[@"血量显示", @"health"],
                    @[@"方框显示", @"box"],
                    @[@"射线显示", @"line"]];

    for (NSInteger i = 0; i < (NSInteger)行.count; ++i) {
        SL开关行 *开关 = [[SL开关行 alloc] initWithTitle:行[i][0] key:行[i][1]];
        [self 加控件:开关 卡片:卡 第几行:i 页:0 行高:行距 首行:首行];
    }
}

- (void)搭建页1 {
    [self 新页:1];

    UIView *卡1 = [self 加卡片:@"视距" y:SL卡片顶 高:100.0f 页:1];
    [self 加控件:[[SL开关行 alloc] initWithTitle:@"视距开关" key:@"fov_on"] 卡片:卡1 第几行:0 页:1];
    [self 加控件:[[SL滑条行 alloc] initWithTitle:@"视距" key:@"fov" 最小:0.1f 最大:10.0f 格式:@"%.1f"]
          卡片:卡1 第几行:1 页:1];

    UIView *卡2 = [self 加卡片:@"显示" y:SL卡片顶 + 100.0f + SL卡片距 高:100.0f 页:1];
    [self 加控件:[[SL分段行 alloc] initWithTitle:@"阵营" 选项:@[@"自动", @"蓝方", @"红方"] key:@"team"]
          卡片:卡2 第几行:0 页:1];
    [self 加控件:[[SL开关行 alloc] initWithTitle:@"状态浮层" key:@"status"] 卡片:卡2 第几行:1 页:1];
}

- (void)搭建页2 {
    [self 新页:2];

    UIView *卡1 = [self 加卡片:@"通用" y:SL卡片顶 高:130.0f 页:2];

    // 直播模式：截图/录屏拍不到绘制，屏幕上照常显示
    [self 加控件:[[SL开关行 alloc] initWithTitle:@"直播模式" key:@"livemode"] 卡片:卡1 第几行:0 页:2];

    // 三指三击：只藏悬浮球，绘制层（小地图 / 方框 / 射线）照常输出
    [self 加控件:[[SL开关行 alloc] initWithTitle:@"三指三击显隐" key:@"hideball"] 卡片:卡1 第几行:1 页:2];

    SL按钮行 *重置 = [[SL按钮行 alloc] initWithTitle:@"悬浮球位置" 按钮:@"重置"];
    __weak typeof(self) weakSelf = self;
    重置.点按回调 = ^(SL控件 *控件, CGPoint 点) {
        __strong typeof(weakSelf) 强 = weakSelf;
        if (!强) return;
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SLBallResetPosition" object:nil];
        SL日志(@"悬浮球: 重置位置");
    };
    [self 加控件:重置 卡片:卡1 第几行:2 页:2];

    UIView *卡2 = [self 加卡片:@"关于" y:SL卡片顶 + 130.0f + SL卡片距 高:132.0f 页:2];
    UILabel *说明 = [[UILabel alloc] initWithFrame:CGRectMake(卡2.frame.origin.x + 14.0f,
                                                             卡2.frame.origin.y + 30.0f,
                                                             卡2.frame.size.width - 28.0f, 90.0f)];
    说明.numberOfLines = 0;
    说明.font = [UIFont systemFontOfSize:11.0f weight:UIFontWeightRegular];
    说明.textColor = SL次文字;
    说明.text = @"拖动 SL 球可换位置，点一下展开/收起面板。\n"
                @"三指连击三下可收起/放回悬浮球（只藏球，绘制不受影响）。\n"
                @"直播模式开启后绘制层不进截图/录屏，屏幕上照常显示。\n"
                @"开关直接改 com.map.settings.plist，绘制层每秒同步一次。\n"
                @"换赛季需要重新对 SDK 偏移（世界 / 相机）。";
    [_页容器[2] addSubview:说明];
}

- (void)更新直播提示:(BOOL)开 {
    _状态字.text = 开 ? @"直播模式 · 截图不可见" : @"内核已就绪";
    _状态字.textColor = 开 ? SL色(1.0f, 0.72f, 0.30f, 1.0f)
                           : SL色(0.29f, 0.80f, 0.55f, 1.0f);
}

// ---------- 页切换 ----------

- (void)切到页:(NSInteger)页 {
    if (页 < 0 || 页 >= (NSInteger)_页容器.count) return;
    _当前页 = 页;
    for (NSInteger i = 0; i < (NSInteger)_页容器.count; ++i) {
        _页容器[i].hidden = (i != 页);
    }
    for (SL导航项 *导航 in _导航) {
        导航.选中 = (导航.页号 == 页);
    }
    SL日志(@"悬浮球: 切到页 %ld", (long)页);
}

// ---------- 触摸分发 ----------

- (void)触摸:(CGPoint)点 阶段:(SL触摸阶段)阶段 {
    CGPoint 面板点 = [self convertPoint:点 fromView:self.superview];

    if (阶段 == SL触摸按下) {
        _按住控件 = [self 命中:面板点];
        if (_按住控件) {
            CGPoint 局部 = [_按住控件 convertPoint:面板点 fromView:self];
            [_按住控件 触摸:局部 阶段:阶段];
        }
        return;
    }

    if (!_按住控件) return;
    CGPoint 局部 = [_按住控件 convertPoint:面板点 fromView:self];
    [_按住控件 触摸:局部 阶段:阶段];
    if (阶段 == SL触摸抬起 || 阶段 == SL触摸取消) _按住控件 = nil;
}

- (SL控件 *)命中:(CGPoint)面板点 {
    // 顶栏按钮
    for (SL控件 *控件 in @[_折叠按钮, _关闭按钮]) {
        if (CGRectContainsPoint(控件.frame, 面板点)) return 控件;
    }
    // 侧栏导航
    for (SL导航项 *导航 in _导航) {
        CGPoint 局 = [_侧栏 convertPoint:面板点 fromView:self];
        if (CGRectContainsPoint(导航.frame, 局)) return 导航;
    }
    // 当前页控件
    UIView *页视图 = _页容器[_当前页];
    CGPoint 页点 = [页视图 convertPoint:面板点 fromView:self];
    for (SL控件 *控件 in _可交互) {
        if (控件.superview != 页视图) continue;
        if (!CGRectContainsPoint(控件.frame, 页点)) continue;
        return 控件;
    }
    return nil;
}

- (void)刷新 {
    for (SL控件 *控件 in _可交互) {
        [控件 刷新];
    }
}

@end

// ==================== 悬浮球 ====================

@interface SL球视图 : UIView
- (void)设置按下:(BOOL)按下;
@end

@implementation SL球视图 {
    CAGradientLayer *_渐变;
    UILabel *_字;
    BOOL _按下;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        CGFloat 半径 = frame.size.width * 0.5f;
        self.layer.cornerRadius = 半径;
        self.layer.borderWidth = 1.2f;
        self.layer.borderColor = SL色(1.0f, 1.0f, 1.0f, 0.50f).CGColor;
        self.layer.shadowColor = SL紫.CGColor;
        self.layer.shadowOffset = CGSizeZero;
        self.layer.shadowRadius = 10.0f;
        self.layer.shadowOpacity = 0.55f;

        _渐变 = [CAGradientLayer layer];
        _渐变.frame = self.bounds;
        _渐变.cornerRadius = 半径;
        _渐变.colors = @[(__bridge id)SL色(0.71f, 0.53f, 1.00f, 0.98f).CGColor,
                          (__bridge id)SL紫深.CGColor];
        _渐变.startPoint = CGPointMake(0.18f, 0.0f);
        _渐变.endPoint = CGPointMake(0.82f, 1.0f);
        [self.layer addSublayer:_渐变];

        _字 = [[UILabel alloc] initWithFrame:self.bounds];
        _字.text = @"SL";
        _字.textAlignment = NSTextAlignmentCenter;
        _字.font = [UIFont systemFontOfSize:17.0f weight:UIFontWeightHeavy];
        _字.textColor = [UIColor whiteColor];
        _字.userInteractionEnabled = NO;
        [self addSubview:_字];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _渐变.frame = self.bounds;
    _字.frame = self.bounds;
}

- (void)设置按下:(BOOL)按下 {
    if (_按下 == 按下) return;
    _按下 = 按下;
    // 不做 transform 缩放：缩放会让 frame 变成包围盒，命中判定失真，
    // 而且缩放动画（0.12s）会和拖动抢主线程，手感发飘。
    // 按下反馈只用阴影 + 透明度，帧率敏感的操作保持零动画。
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.shadowOpacity = 按下 ? 0.78f : 0.55f;
    [CATransaction commit];
    self.alpha = 按下 ? 0.90f : 1.0f;
}

@end

// ==================== 控制器 ====================

@interface SLBall ()
- (BOOL)处理原始点:(CGPoint)原始点 路径数:(int)路径数 阶段:(SL触摸阶段)阶段;
- (void)显示面板:(BOOL)显示;
- (void)应用朝向;
- (void)重置位置通知;
- (NSUserDefaults *)存档;
- (void)恢复球位置;
- (void)存球位置;
- (void)夹住球;
- (void)摆放面板;
- (void)点球;
- (void)定时刷新;
- (bool)切换球显隐;
- (BOOL)点:(CGPoint)点 命中:(CGRect)框;
@property (nonatomic, assign) BOOL 面板展开;
@end

@implementation SLBall {
    UIView *_容器;
    SL球视图 *_球;
    SL面板 *_面板;
    NSTimer *_定时器;
    CGAffineTransform _待变换;
    CGSize _待画布;
    BOOL _有朝向;

    // 触摸状态
    NSInteger _触摸归属;      // 0 无 1 球 2 面板
    BOOL _拖动中;
    BOOL _实际拖动;
    CGFloat _总位移;
    CGPoint _按下点;          // 容器坐标
    CGPoint _球起点;
    CGPoint _上次有效点;      // 最近一个"可信"的容器点（防 HID 假坐标把球甩飞）
    BOOL _有上次有效点;
    CGPoint _跳变挂起点;      // 被丢掉的那一帧，用于判断"连续两帧都在这里"
    BOOL _有跳变挂起;
    NSInteger _坐标解释;      // 上一次成功的解释方式 0/1/2
    CFAbsoluteTime _按下时刻;

    // 三指三击临时隐藏（只藏球，绘制层照常输出）。不写存档：
    // 重启 HUD 一律把球显示回来，避免"藏起来 + 又关了开关"永久找不回来。
    BOOL _三指隐藏;
}

+ (instancetype)share {
    static SLBall *实例 = nil;
    static dispatch_once_t 一次;
    dispatch_once(&一次, ^{
        实例 = [[SLBall alloc] init];
    });
    return 实例;
}

- (void)loadView {
    UIView *根 = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    根.backgroundColor = [UIColor clearColor];
    根.opaque = NO;
    根.userInteractionEnabled = NO;   // 完全不吃 UIKit 触摸
    self.view = 根;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    _触摸归属 = 0;
    _坐标解释 = -1;
    _面板展开 = NO;

    _容器 = [[UIView alloc] initWithFrame:CGRectZero];
    _容器.backgroundColor = [UIColor clearColor];
    _容器.userInteractionEnabled = NO;
    [self.view addSubview:_容器];

    CGSize 屏 = [[UIScreen mainScreen] bounds].size;
    _容器.bounds = CGRectMake(0.0f, 0.0f, MAX(屏.width, 屏.height), MIN(屏.width, 屏.height));
    _容器.center = CGPointMake(self.view.bounds.size.width * 0.5f, self.view.bounds.size.height * 0.5f);
    if (_有朝向) [self 应用朝向];

    _球 = [[SL球视图 alloc] initWithFrame:CGRectMake(0.0f, 0.0f, SL球直径, SL球直径)];
    [_容器 addSubview:_球];

    _面板 = [[SL面板 alloc] initWithFrame:CGRectMake(0.0f, 0.0f, SL面板宽, SL面板高)];
    _面板.hidden = YES;
    _面板.alpha = 0.0f;
    __weak typeof(self) weakSelf = self;
    _面板.关面板回调 = ^{
        __strong typeof(weakSelf) 强 = weakSelf;
        if (强) [强 显示面板:NO];
    };
    [_容器 addSubview:_面板];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(重置位置通知)
                                                 name:@"SLBallResetPosition"
                                               object:nil];

    [self 恢复球位置];
    if (_有朝向) [self 应用朝向];

    _定时器 = [NSTimer timerWithTimeInterval:0.8
                                      target:self
                                    selector:@selector(定时刷新)
                                    userInfo:nil
                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:_定时器 forMode:NSRunLoopCommonModes];

    SL日志(@"悬浮球: 已装载 画布 %.0fx%.0f 球 (%.0f, %.0f) 窗 %.0fx%.0f",
         _容器.bounds.size.width, _容器.bounds.size.height,
         _球.center.x, _球.center.y,
         self.view.bounds.size.width, self.view.bounds.size.height);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _容器.center = CGPointMake(self.view.bounds.size.width * 0.5f, self.view.bounds.size.height * 0.5f);
}

- (void)dealloc {
    [_定时器 invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

// ---------- 朝向 ----------

- (void)syncWithOrientedView:(UIView *)view {
    if (!view) return;
    _待变换 = view.transform;
    _待画布 = view.bounds.size;
    _有朝向 = YES;
    if (_容器) [self 应用朝向];
}

- (void)应用朝向 {
    if (!_容器) return;
    _容器.transform = _待变换;
    _容器.bounds = CGRectMake(0.0f, 0.0f, _待画布.width, _待画布.height);
    _容器.center = CGPointMake(self.view.bounds.size.width * 0.5f, self.view.bounds.size.height * 0.5f);
    [self 夹住球];
    if (_面板展开) [self 摆放面板];
    SL日志(@"悬浮球: 同步朝向 画布 %.0fx%.0f a=%.2f b=%.2f 窗 %.0fx%.0f",
         _容器.bounds.size.width, _容器.bounds.size.height,
         _容器.transform.a, _容器.transform.b,
         self.view.bounds.size.width, self.view.bounds.size.height);
}

// ---------- 球位置 ----------

- (NSUserDefaults *)存档 {
    return [NSUserDefaults standardUserDefaults];
}

// 存档键带 V2：上一版"点球跳到左下角"的 bug 会把 (32, 398) 这种假位置写进
// 存档，沿用旧键的话下次启动球就老老实实停在左下角。换键等于一次性作废旧值。
static NSString *const SL球存档键 = @"SLBallSavedV2";
static NSString *const SL球X键 = @"SLBallXV2";
static NSString *const SL球Y键 = @"SLBallYV2";

- (void)恢复球位置 {
    NSUserDefaults *存 = [self 存档];
    CGFloat 宽 = _容器.bounds.size.width;
    CGFloat 高 = _容器.bounds.size.height;
    CGFloat 缺省X = 宽 * 0.62f;
    CGFloat 缺省Y = 高 * 0.5f;

    CGFloat x = 缺省X;
    CGFloat y = 缺省Y;
    if ([存 boolForKey:SL球存档键]) {
        x = [存 doubleForKey:SL球X键];
        y = [存 doubleForKey:SL球Y键];
    }
    // 存档也可能是坏的（NaN / 越界），一律退回缺省。
    if (!isfinite(x) || !isfinite(y) || x < 0.0f || y < 0.0f ||
        x > 宽 || y > 高) {
        x = 缺省X;
        y = 缺省Y;
    }
    _球.center = CGPointMake(x, y);
    [self 夹住球];
}

- (void)重置位置通知 {
    NSUserDefaults *存 = [self 存档];
    [存 removeObjectForKey:SL球存档键];
    [存 synchronize];
    _球.center = CGPointMake(_容器.bounds.size.width * 0.62f, _容器.bounds.size.height * 0.5f);
    [self 夹住球];
    if (_面板展开) [self 摆放面板];
}

- (void)存球位置 {
    NSUserDefaults *存 = [self 存档];
    [存 setBool:YES forKey:SL球存档键];
    [存 setDouble:_球.center.x forKey:SL球X键];
    [存 setDouble:_球.center.y forKey:SL球Y键];
    [存 synchronize];
}

- (void)夹住球 {
    CGFloat 半径 = SL球直径 * 0.5f;
    CGFloat 宽 = _容器.bounds.size.width;
    CGFloat 高 = _容器.bounds.size.height;
    CGPoint c = _球.center;
    c.x = MAX(半径 + 4.0f, MIN(宽 - 半径 - 4.0f, c.x));
    c.y = MAX(半径 + 4.0f, MIN(高 - 半径 - 4.0f, c.y));
    _球.center = c;
}

// ---------- 面板 ----------

- (void)摆放面板 {
    CGFloat 宽 = _容器.bounds.size.width;
    CGFloat 高 = _容器.bounds.size.height;
    CGFloat 面板宽 = SL面板宽;
    CGFloat 面板高 = SL面板高;

    // 面板固定在画布正中，完全不参考球的位置。
    // 之前是"贴在球左边/右边"，看起来像面板被球吸住：球一拖面板就跟着挪，
    // 而且面板开着的球往哪边拖还会左右翻边。现在两者互不相干。
    CGFloat x = (宽 - 面板宽) * 0.5f;
    CGFloat y = (高 - 面板高) * 0.5f;
    x = MAX(8.0f, MIN(宽 - 面板宽 - 8.0f, x));
    y = MAX(8.0f, MIN(高 - 面板高 - 8.0f, y));
    _面板.frame = CGRectMake(x, y, 面板宽, 面板高);
}

- (void)点球 {
    [self 显示面板:!_面板展开];
    SL日志(@"悬浮球: %@", _面板展开 ? @"展开面板" : @"收起面板");
}

- (void)显示面板:(BOOL)显示 {
    if (显示 == _面板展开) return;
    _面板展开 = 显示;
    if (显示) {
        [self 摆放面板];
        // 球永远压在面板上面：面板居中时球可能正好落在面板范围内，
        // 球被盖住就没法再点它收起了。
        [_容器 bringSubviewToFront:_球];
        [_面板 刷新];
        _面板.hidden = NO;
        _面板.alpha = 0.0f;
        _面板.transform = CGAffineTransformMakeScale(0.94f, 0.94f);
        [UIView animateWithDuration:0.16
                              delay:0.0
                            options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState)
                         animations:^{
            self->_面板.alpha = 1.0f;
            self->_面板.transform = CGAffineTransformIdentity;
        } completion:nil];
        UIImpactFeedbackGenerator *震 =
            [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [震 impactOccurred];
    } else {
        [UIView animateWithDuration:0.14
                              delay:0.0
                            options:(UIViewAnimationOptionCurveEaseIn | UIViewAnimationOptionBeginFromCurrentState)
                         animations:^{
            self->_面板.alpha = 0.0f;
        } completion:^(BOOL 完成) {
            if (!self->_面板展开) self->_面板.hidden = YES;
        }];
    }
}

// ---------- 触摸核心 ----------

// 单帧跳变上限：真手指一帧最多扫过画布的四分之一（120Hz 下极快的甩动也到不了），
// 超过这个数只能是 HID 给的假坐标 —— 典型就是抬手帧路径数为 0、rep.location
// 退回 (0,0)，再经容器旋转映射正好落在画布左下角，把球"甩"到最左下。
static const CGFloat SL单帧跳变上限 = 240.0f;

- (BOOL)处理原始点:(CGPoint)原始点 路径数:(int)路径数 阶段:(SL触摸阶段)阶段 {
    if (!_容器 || _容器.bounds.size.width < 16.0f) return NO;
    if (_球.hidden && !_面板展开) return NO;

    // 坐标本身的合法性：(0,0) / 负数 / NaN 都不是真手指。
    // 屏幕最左上那一个像素没人能精准点到，球也不可能被夹到那里。
    BOOL 点像样 = isfinite(原始点.x) && isfinite(原始点.y) &&
                  (原始点.x > 1.0f || 原始点.y > 1.0f) &&
                  原始点.x > -2.0f && 原始点.y > -2.0f;
    BOOL 有手指 = (路径数 > 0);
    BOOL 坐标可用 = 点像样 && 有手指;

    // 三种坐标解释：原始点可能是
    //   0) window 坐标（HUD 进程 windows 是竖屏 bounds）
    //   1) 画布坐标（横屏逻辑点，和绘制层同一个空间）
    //   2) 物理像素（横屏，×3）
    CGFloat 比例 = [UIScreen mainScreen].nativeScale;
    if (比例 < 1.0f) 比例 = 3.0f;

    CGPoint 候选[3];
    候选[0] = 原始点;
    候选[1] = [_容器 convertPoint:原始点 toView:nil];
    候选[2] = [_容器 convertPoint:CGPointMake(原始点.x / 比例, 原始点.y / 比例) toView:nil];

    if (阶段 == SL触摸按下) {
        if (!坐标可用) {
            SL日志限频(@"触摸↓ 丢弃假坐标 raw(%.0f,%.0f) path=%d phase=%d",
                     原始点.x, 原始点.y, 路径数, (int)阶段);
            return NO;
        }

        NSInteger 选中 = -1;
        CGPoint 选中容器点 = CGPointZero;

        // 上一次成功的解释优先，避免同一串触摸中途换坐标系
        if (_坐标解释 >= 0 && _坐标解释 < 3) {
            CGPoint 容器点 = [_容器 convertPoint:候选[_坐标解释] fromView:nil];
            if ([self 点:容器点 命中:_球.frame] || (_面板展开 && [self 点:容器点 命中:_面板.frame])) {
                选中 = _坐标解释;
                选中容器点 = 容器点;
            }
        }
        if (选中 < 0) {
            for (NSInteger i = 0; i < 3; ++i) {
                CGPoint 容器点 = [_容器 convertPoint:候选[i] fromView:nil];
                BOOL 命中球 = [self 点:容器点 命中:_球.frame];
                BOOL 命中板 = _面板展开 && [self 点:容器点 命中:_面板.frame];
                if (命中球 || 命中板) {
                    选中 = i;
                    选中容器点 = 容器点;
                    break;
                }
            }
        }

        SL日志限频(@"触摸↓ raw(%.0f,%.0f) 解释%d 球(%.0f,%.0f) 板%@",
                 原始点.x, 原始点.y, (int)选中,
                 _球.center.x, _球.center.y,
                 _面板展开 ? @"显示" : @"收起");

        if (选中 < 0) {
            // 三种解释都打不中球/面板：点的是游戏画面。
            // 面板开着就顺手收起，这一下继续交给游戏（摇杆、技能不受影响）。
            if (_面板展开) {
                SL日志(@"悬浮球: 点空白处 → 收起面板");
                [self 显示面板:NO];
            }
            return NO;
        }

        _坐标解释 = 选中;
        _按下点 = 选中容器点;
        _上次有效点 = 选中容器点;
        _有上次有效点 = YES;
        _有跳变挂起 = NO;

        if (_面板展开 && [self 点:选中容器点 命中:_面板.frame]) {
            _触摸归属 = 2;
            [_面板 触摸:选中容器点 阶段:阶段];
            return YES;
        }

        _触摸归属 = 1;
        _拖动中 = YES;
        _实际拖动 = NO;
        _总位移 = 0.0f;
        _球起点 = _球.center;
        _按下时刻 = CFAbsoluteTimeGetCurrent();
        [_球 设置按下:YES];
        return YES;
    }

    if (阶段 == SL触摸移动) {
        if (_触摸归属 == 0) {
            // HID 偶尔会漏发 Began（首帧 path 还没建立），手指已经落在球上
            // 开始滑动。补一次"按下"，让这一串移动仍然能拖动球；否则整段
            // 拖动都会因为 _触摸归属 = 0 被直接丢掉。
            if (_球.hidden || !坐标可用) return NO;
            for (NSInteger i = 0; i < 3; ++i) {
                CGPoint 容器点 = [_容器 convertPoint:候选[i] fromView:nil];
                if (![self 点:容器点 命中:_球.frame]) continue;
                _坐标解释 = i;
                _触摸归属 = 1;
                _拖动中 = YES;
                _实际拖动 = NO;
                _总位移 = 0.0f;
                _按下点 = 容器点;
                _上次有效点 = 容器点;
                _有上次有效点 = YES;
                _有跳变挂起 = NO;
                _球起点 = _球.center;
                _按下时刻 = CFAbsoluteTimeGetCurrent();
                [_球 设置按下:YES];
                SL日志(@"悬浮球: 补按下（Began 丢失）解释 %ld", (long)i);
                break;
            }
            if (_触摸归属 == 0) return NO;
        }

        // 假坐标帧：吃掉但不处理。抬手帧、悬停帧、多指切换帧都会走到这里。
        if (!坐标可用) {
            SL日志限频(@"触摸→ 丢弃假坐标帧 raw(%.0f,%.0f) path=%d",
                     原始点.x, 原始点.y, 路径数);
            return YES;
        }

        CGPoint 容器点 = [_容器 convertPoint:候选[_坐标解释] fromView:nil];

        // 单帧跳变保护：坐标突然飞到画布另一头，是坏帧，不是手指。
        // 连续两帧都落在同一个地方才认（真被丢帧时也能立刻恢复跟手）。
        if (_有上次有效点) {
            CGFloat 跳 = hypot(容器点.x - _上次有效点.x, 容器点.y - _上次有效点.y);
            if (跳 > SL单帧跳变上限) {
                BOOL 连续确认 = _有跳变挂起 &&
                                hypot(容器点.x - _跳变挂起点.x, 容器点.y - _跳变挂起点.y) < 80.0f;
                if (!连续确认) {
                    _跳变挂起点 = 容器点;
                    _有跳变挂起 = YES;
                    SL日志限频(@"触摸→ 丢弃跳变帧 容器(%.0f,%.0f) 跳 %.0f",
                             容器点.x, 容器点.y, 跳);
                    return YES;
                }
                SL日志(@"悬浮球: 跳变帧连续出现，认一次 (%.0f,%.0f)", 容器点.x, 容器点.y);
            }
            _有跳变挂起 = NO;
        }
        _上次有效点 = 容器点;
        _有上次有效点 = YES;

        if (_触摸归属 == 1) {
            CGPoint 位移 = CGPointMake(容器点.x - _按下点.x, 容器点.y - _按下点.y);
            CGFloat 距离 = hypot(位移.x, 位移.y);
            if (距离 > _总位移) _总位移 = 距离;

            // 3pt 起拖：手指在球上轻微抖动不算拖动，也不会被误判成点击
            if (!_实际拖动 && _总位移 > 3.0f) {
                _实际拖动 = YES;
                [_球 设置按下:NO];   // 起拖后立刻取消按压缩放，球不被缩着走
            }
            if (_实际拖动) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];   // 关隐式动画，纯跟手
                _球.center = CGPointMake(_球起点.x + 位移.x, _球起点.y + 位移.y);
                [self 夹住球];
                [CATransaction commit];
                // 面板不跟着球走，也不逐帧重排：它有 3 页卡片 + 十几个控件，
                // 每帧改一次 frame 会连锁 layoutSubviews，手感直接变黏。

                static CFAbsoluteTime 上次移动日志 = 0;
                CFAbsoluteTime 本帧 = CFAbsoluteTimeGetCurrent();
                if (本帧 - 上次移动日志 > 1.0) {
                    上次移动日志 = 本帧;
                    SL日志(@"悬浮球: 移动帧 raw(%.0f,%.0f) 容器(%.0f,%.0f) 位移 %.1f",
                         原始点.x, 原始点.y, 容器点.x, 容器点.y, _总位移);
                }
            }
            return YES;
        }

        if (_触摸归属 == 2) {
            [_面板 触摸:容器点 阶段:阶段];
            return YES;
        }
        return NO;
    }

    // ---------- 抬起 / 取消 ----------
    if (_触摸归属 == 0) return NO;

    CGPoint 容器点 = [_容器 convertPoint:候选[_坐标解释] fromView:nil];

    // 抬手帧最不可信：HID 常在 lift / cancel 帧把 location 退化成 (0,0)，
    // 路径数组也是空的。这种点一用，球就被甩到画布左下角（用户看到的
    // "点一下球自己跑到最左下角"）。不可信就退回最后一个有效点。
    BOOL 抬手点可信 = 坐标可用;
    if (抬手点可信 && _有上次有效点) {
        if (hypot(容器点.x - _上次有效点.x, 容器点.y - _上次有效点.y) > SL单帧跳变上限) 抬手点可信 = NO;
    }
    if (!抬手点可信) {
        CGPoint 旧点 = _有上次有效点 ? _上次有效点 : _按下点;
        SL日志限频(@"悬浮球: 抬手坐标不可信 raw(%.0f,%.0f) path=%d → 用 (%.0f,%.0f)",
                 原始点.x, 原始点.y, 路径数, 旧点.x, 旧点.y);
        容器点 = 旧点;
    }

    if (_触摸归属 == 1) {
        [_球 设置按下:NO];

        // 关键兜底：这一串触摸可能一个 move 事件都没收到（HID 丢帧、
        // AXEventRepresentation 把移动吞成别的类型）。此时 _总位移 还是 0，
        // 旧逻辑就会当成点击去切面板 —— 这正是"一拖就展开菜单"的直接原因。
        // 抬起点与按下点的直线距离够远，一律按拖动处理，绝不点球。
        CGPoint 位移 = CGPointMake(容器点.x - _按下点.x, 容器点.y - _按下点.y);
        CGFloat 距离 = hypot(位移.x, 位移.y);
        if (距离 > _总位移) _总位移 = 距离;

        BOOL 算拖动 = (_实际拖动 || _总位移 > 6.0f);
        CFTimeInterval 按住 = CFAbsoluteTimeGetCurrent() - _按下时刻;
        // 位移判据已经足够区分拖动/点击；时间只用来挡"按住不放很久"
        // 这种明显不是点按的操作，阈值放大到 1.2 秒，慢慢点也能正常展开。
        BOOL 算点击 = (!算拖动 && _总位移 < 6.0f && 按住 < 1.2);

        if (算点击) {
            [self 点球];
        } else if (算拖动) {
            if (!_实际拖动 && _总位移 > 3.0f) {
                // 中间一个移动事件都没到：把球直接挪到手指最后的落点
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                _球.center = CGPointMake(_球起点.x + 位移.x, _球起点.y + 位移.y);
                [self 夹住球];
                [CATransaction commit];
            }
            [self 存球位置];
            SL日志(@"悬浮球: 拖到 (%.0f, %.0f) 位移 %.1f 移动帧=%d 按住 %.0fms",
                 _球.center.x, _球.center.y, _总位移, _实际拖动, 按住 * 1000.0);
        }
        _拖动中 = NO;
        _实际拖动 = NO;
        _触摸归属 = 0;
        _有上次有效点 = NO;
        _有跳变挂起 = NO;
        return YES;
    }

    if (_触摸归属 == 2) {
        [_面板 触摸:容器点 阶段:阶段];
        _触摸归属 = 0;
        _有上次有效点 = NO;
        _有跳变挂起 = NO;
        return YES;
    }
    return NO;
}

- (BOOL)点:(CGPoint)点 命中:(CGRect)框 {
    return CGRectContainsPoint(CGRectInset(框, -6.0f, -6.0f), 点);
}

// ---------- 三指三击 ----------

// 只收起/放回悬浮球本体（面板一起收），绘制层一根线都不动。
// 由 HUDApp 的 HID 回调判定三指三击后调用，永远在主线程。
- (bool)切换球显隐 {
    _三指隐藏 = !_三指隐藏;
    if (_三指隐藏) {
        if (_面板展开) [self 显示面板:NO];
        _球.hidden = YES;
        // 收起瞬间把触摸状态清干净：否则手指还按在球上的那一串事件
        // 会在球隐藏后继续拖动一个看不见的球。
        _触摸归属 = 0;
        _拖动中 = NO;
        _实际拖动 = NO;
        _有上次有效点 = NO;
        _有跳变挂起 = NO;
        [_球 设置按下:NO];
    } else {
        _球.hidden = NO;
        _球.alpha = SL读开关(@"draw") ? 1.0f : 0.55f;
        [_容器 bringSubviewToFront:_球];
    }
    SL日志(@"悬浮球: 三指三击 → %@（绘制层不受影响）", _三指隐藏 ? @"隐藏" : @"显示");

    UIImpactFeedbackGenerator *震 =
        [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [震 impactOccurred];
    return _三指隐藏;
}

// ---------- 定时同步 ----------

- (void)定时刷新 {
    BOOL 主开关 = SL读开关(@"draw");
    BOOL 直播 = SL读开关(@"livemode");
    // 三指三击隐藏是"临时收起"，优先级最高：主开关开着也只藏球，绘制照旧。
    BOOL 该显示 = (主开关 || _面板展开) && !_三指隐藏;
    static BOOL 上次显示 = YES;
    if (该显示 != 上次显示) {
        上次显示 = 该显示;
        SL日志(@"悬浮球: %@（主开关=%d 三指隐藏=%d）", 该显示 ? @"显示" : @"隐藏", 主开关, _三指隐藏);
    }
    _球.hidden = !该显示;
    _球.alpha = 主开关 ? 1.0f : 0.55f;

    // 直播模式只在切的那一下通知绘制进程换容器（避免每 0.8s 刷一次）
    static BOOL 上次直播 = NO;
    if (直播 != 上次直播) {
        上次直播 = 直播;
        SL日志(@"直播模式: %@", 直播 ? @"开（绘制不进截图）" : @"关（绘制可被截取）");
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SLLiveModeChanged"
                                                             object:nil
                                                           userInfo:@{@"on": @(直播)}];
    }
    [_面板 更新直播提示:直播];
    if (_面板展开) [_面板 刷新];
}

@end

// ==================== C 接口 ====================

#ifdef __cplusplus
extern "C" {
#endif

bool SLBall触摸(float x, float y, int 阶段, int 路径数) {
    SLBall *球 = [SLBall share];
    CGPoint 点 = CGPointMake(x, y);
    if ([NSThread isMainThread]) {
        return [球 处理原始点:点 路径数:路径数 阶段:(SL触摸阶段)阶段];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [球 处理原始点:点 路径数:路径数 阶段:(SL触摸阶段)阶段];
    });
    return YES;
}

bool SLBall面板可见(void) {
    return [SLBall share].面板展开;
}

// 开关只在真正可能出现三指的时刻才读，外加 1 秒缓存 —— HID 回调一秒上千次，
// 每次都去同步读 plist 会把触摸线程拖慢。
bool SL三指三击开关开(void) {
    static BOOL 缓存 = NO;
    static CFAbsoluteTime 上次 = 0;
    CFAbsoluteTime 现在 = CFAbsoluteTimeGetCurrent();
    if (现在 - 上次 >= 1.0) {
        上次 = 现在;
        缓存 = SL读开关(@"hideball");
    }
    return 缓存;
}

bool SLBall切换球显隐(void) {
    __block bool 隐藏 = false;
    void (^块)(void) = ^{
        隐藏 = [[SLBall share] 切换球显隐];
    };
    if ([NSThread isMainThread]) {
        块();
    } else {
        dispatch_sync(dispatch_get_main_queue(), 块);
    }
    return 隐藏;
}

void SL日志行(const char *行) {
    if (!行) return;
    SL日志(@"[HUD] %s", 行);
}

#ifdef __cplusplus
}
#endif
