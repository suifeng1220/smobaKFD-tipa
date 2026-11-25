//
//  过直播窗口.mm - 直播/录屏隐藏功能
//
//  原理：UITextField 打开 secureTextEntry 后，它内部的画布视图会被系统标记为
//  secure 层，窗口服务器在往截图 / 录屏 / AirPlay 复制画面时会把这棵子树剔掉。
//  把绘制视图挂到这棵子树里，本机屏幕上照常显示，抓屏却抓不到。
//  关掉时把绘制视图挪回普通层级，立刻恢复可截取。
//

#import "过直播窗口.h"

@implementation 过直播窗口 {
    UITextField *_安全框;     // secureTextEntry 文本框（过直播时才挂上来）
    UIView *_画布容器;        // 真正装绘制视图的容器，在两种宿主之间搬家
    BOOL _过直播;
}

- (instancetype)init {
    return [self initWithFrame:CGRectZero];
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;

        _画布容器 = [[UIView alloc] initWithFrame:self.bounds];
        _画布容器.backgroundColor = [UIColor clearColor];
        _画布容器.opaque = NO;
        _画布容器.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [super addSubview:_画布容器];   // 默认走普通层级：可被截取
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super initWithCoder:coder])) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        _画布容器 = [[UIView alloc] initWithFrame:self.bounds];
        _画布容器.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [super addSubview:_画布容器];
    }
    return self;
}

// 外部 addSubview 一律落到画布容器里，这样绘制视图始终只有一层父视图可搬
- (void)addSubview:(UIView *)view {
    if (view == nil) return;
    if (view == _画布容器) {
        [super addSubview:view];
        return;
    }
    [_画布容器 addSubview:view];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _安全框.frame = self.bounds;
    UIView *宿主 = _画布容器.superview ?: self;
    _画布容器.frame = 宿主.bounds;
}

- (BOOL)过直播 {
    return _过直播;
}

- (void)设置过直播:(BOOL)开 {
    if (_过直播 == 开) return;
    _过直播 = 开;

    UIView *新宿主 = nil;

    if (开) {
        if (!_安全框) {
            _安全框 = [[UITextField alloc] init];
            _安全框.secureTextEntry = YES;
            _安全框.userInteractionEnabled = NO;
            _安全框.backgroundColor = [UIColor clearColor];
            _安全框.borderStyle = UITextBorderStyleNone;
            _安全框.tintColor = [UIColor clearColor];
        }
        if (_安全框.superview != self) [super addSubview:_安全框];
        _安全框.frame = self.bounds;
        _安全框.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        // 文本框内部画布：secure 层就是它，绘制视图必须挂在这上面
        [_安全框 layoutIfNeeded];
        UIView *画布 = _安全框.subviews.firstObject;
        if (画布) {
            画布.userInteractionEnabled = YES;
            画布.clipsToBounds = NO;
            画布.frame = self.bounds;      // 画布尺寸不到位时 MetalView 会被压成 0
            新宿主 = 画布;
        } else {
            新宿主 = _安全框;   // 兜底（正常不会走到）
        }
    } else {
        新宿主 = self;
    }

    [_画布容器 removeFromSuperview];
    [新宿主 addSubview:_画布容器];
    _画布容器.frame = 新宿主.bounds;
    if (!开) [_安全框 removeFromSuperview];   // 关掉后不放空的安全框，免得整窗被判成 secure

    [self setNeedsLayout];
    [self layoutIfNeeded];
}

@end
