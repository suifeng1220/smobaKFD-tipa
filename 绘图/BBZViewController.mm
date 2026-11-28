//
//  BBZViewController.mm
//  DZ
//
//  Created by Lessica on 2024/1/24.
//

#import <objc/runtime.h>
#import <objc/message.h>
#import "BBZViewController.h"
#import "HonyWindow.h"
#import "SBSAccessibilityWindowHostingController.h"
#import "UIWindow+Private.h"
#import "DOJailbreaker.h"
#include "DrawView.hpp"
#import "过直播窗口.h"
#import "SLBall.h"
//#include "ShowClient.h"

// 日志输出到主页日志框
#ifdef __cplusplus
extern "C" {
#endif
void KernelLogLine(const char *line);
#ifdef __cplusplus
}
#endif

CGFloat BBZWidth = 0; // 存储屏幕宽度
CGFloat BBZHeight = 0; // 存储屏幕高度

@implementation BBZViewController { // BBZViewController 类的实现
    SBSAccessibilityWindowHostingController *_BBZHostingController; // 无障碍窗口托管控制器
    MTKView *_MetalView; // Metal 渲染视图
    id<MTLCommandQueue> _mtlCommandQueue; // Metal 命令队列
    // CDController *_cdViewController; // 主菜单视图控制器
    SBSAccessibilityWindowHostingController *BBZMenuHostingController; // 另一个无障碍窗口托管控制器
    过直播窗口 *_过直播容器; // 过直播容器视图（直播模式：绘制不进截图）
    id _直播观察者;          // 直播模式切换通知
    NSTimer *_重注册Timer; // S45 新增：浮层重注册定时器
}

// S45 新增：上次注册的 HUD contextId（重注册浮层用）
static unsigned 上次HUDContextId = 0;

// S45 新增：重注册浮层
// 还原自 -[BBZViewController 重注册浮层] 0x10007CEFC
// 作用：游戏把 out-of-process 窗口 context 回收重发后，
//       定时比对 _contextId，变了就用 registerWindowWithContextID:atLevel: 重新挂回去。
- (void)重注册浮层 {
    if (!self.BBZwindow || !_BBZHostingController) return;

    // 窗口尺寸/位置校正：与主屏不一致时拉回屏幕
    CGRect 屏幕框 = [[UIScreen mainScreen] bounds];
    CGRect 窗口框 = self.BBZwindow.frame;
    BOOL 需要校正 = !CGSizeEqualToSize(窗口框.size, 屏幕框.size);
    if (!需要校正) 需要校正 = !CGRectEqualToRect(窗口框, 屏幕框) && !CGPointEqualToPoint(窗口框.origin, CGPointZero);
    if (需要校正) [self.BBZwindow setFrame:屏幕框];

    // 透明/隐藏校正
    if (self.BBZwindow.alpha < 0.99) [self.BBZwindow setAlpha:1.0];
    if ([self.BBZwindow isHidden]) [self.BBZwindow setHidden:NO];

    unsigned ctxHUD = [self.BBZwindow _contextId];
    unsigned ctx菜单 = [self.BBZMenu _contextId];

    if (ctxHUD && ctxHUD != 上次HUDContextId) {
        上次HUDContextId = ctxHUD;
        char 行[200];
        snprintf(行, sizeof(行), "HUD: 重注册 ctx 变了 → HUD=%u 菜单=%u（层级 %.0f）",
                 ctxHUD, ctx菜单, [self.BBZwindow windowLevel]);
        KernelLogLine(行);
    }
    if (ctxHUD) {
        ((void (*)(id, SEL, unsigned int, double))objc_msgSend)(
            _BBZHostingController,
            NSSelectorFromString(@"registerWindowWithContextID:atLevel:"),
            ctxHUD, [self.BBZwindow windowLevel]);
    }
    if (ctx菜单 && BBZMenuHostingController) {
        ((void (*)(id, SEL, unsigned int, double))objc_msgSend)(
            BBZMenuHostingController,
            NSSelectorFromString(@"registerWindowWithContextID:atLevel:"),
            ctx菜单, [self.BBZMenu windowLevel]);
    }
}

- (instancetype)init { // 构造函数
    if (self = [super init]) { // 调用父类初始化
        //log_debug(OS_LOG_DEFAULT, "- [BBZViewController init]"); // 记录日志
    }
    return self; // 返回实例
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary <UIApplicationLaunchOptionsKey, id> *)launchOptions {
    // 应用启动回调
    //log_debug(OS_LOG_DEFAULT, "- [BBZViewController application:%{public}@ didFinishLaunchingWithOptions:%{public}@]", application, launchOptions); // 记录日志
    @autoreleasepool {
        // 设备已用 Dopamine(roothide) 越狱：内核在开机时就被拿下，kfd+physrw 已在内核里生效。
        // 本进程一个内核动作都不做 —— 不跑 exploit、不接管原语表、不连 jailbreakd。
        // 读游戏内存只走 entitlements 给的 task_for_pid + vm_read_overwrite。
        KernelLogLine("HUD: 越狱已持有内核，本进程不做任何内核初始化");
        NSLog(@"DH666 纯端口模式");
        self.BBZwindow = [[HonyWindow alloc] init];
        self.BBZwindow.frame = [[UIScreen mainScreen] bounds]; // 创建 HUDMainWindow，大小为屏幕大小
        //    sss();
        [self.BBZwindow setWindowLevel:UIWindowLevelStatusBar - 1]; // 设置窗口层级，比状态栏高
        
        self.BBZwindow.backgroundColor = [UIColor clearColor];
        self.BBZwindow.opaque = NO;
        
        [self.BBZwindow setHidden:NO]; // 使窗口可见
        //[self.BBZwindow makeKeyAndVisible]; // 使窗口成为主窗口并显示
        
        UIViewController *rootVC = [[UIViewController alloc] init];
        rootVC.view.backgroundColor = [UIColor clearColor];
        rootVC.view.opaque = NO;
        self.BBZwindow.rootViewController = rootVC;
        
        _MetalView = [[MTKView alloc] initWithFrame:rootVC.view.bounds]; // 创建 MTKView，大小为窗口大小
        //_MetalView.contentScaleFactor = [UIScreen mainScreen].nativeScale; // 设置物理像素比例
        _MetalView.device = MTLCreateSystemDefaultDevice(); // 绑定默认 Metal 设备
        _MetalView.opaque = NO; // 设置透明
        _MetalView.enableSetNeedsDisplay = NO;
        _MetalView.paused = NO;
        _MetalView.preferredFramesPerSecond = 120;
        _MetalView.backgroundColor = UIColor.clearColor; // 设置背景色透明
        _MetalView.clearColor = MTLClearColorMake(0, 0, 0, 0.0); // Metal 清屏颜色为透明
        _MetalView.delegate = self; // 设定自身为 MTKView 代理
        _MetalView.autoResizeDrawable = YES;
        _MetalView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        _MetalView.depthStencilPixelFormat = MTLPixelFormatInvalid; // 不需要深度缓冲，减少GPU开销
        _MetalView.framebufferOnly = YES; // 提高 GPU 性能
        
        //_MetalView.delegate = self;
        //[self.BBZwindow addSubview:_MetalView]; // 将 MTKView 添加到主窗口
        
        // 直播模式：绘制视图始终放在过直播容器里，运行时按 livemode 切换
        // 「进不进截图/录屏」。屏幕上一直显示，只是截图录屏抓不到这层。
        _过直播容器 = [[过直播窗口 alloc] initWithFrame:rootVC.view.bounds];
        _过直播容器.backgroundColor = [UIColor clearColor];
        _过直播容器.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [rootVC.view addSubview:_过直播容器];
        [_过直播容器 addSubview:_MetalView];

        NSDictionary *直播配置 = [NSDictionary dictionaryWithContentsOfFile:
                                  @"/var/mobile/Library/Preferences/com.map.settings.plist"];
        BOOL 直播中 = [[直播配置 objectForKey:@"livemode"] boolValue];
        [_过直播容器 设置过直播:直播中];
        KernelLogLine(直播中 ? "HUD: 直播模式已开启（绘制不进截图/录屏）"
                            : "HUD: 直播模式关闭（绘制可被截取）");

        // 悬浮球里拨直播模式 → 立刻切容器，不用重启
        __weak typeof(self) weakSelf = self;
        _直播观察者 = [[NSNotificationCenter defaultCenter]
            addObserverForName:@"SLLiveModeChanged"
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            __strong typeof(weakSelf) 强 = weakSelf;
            if (!强) return;
            BOOL 开 = [note.userInfo[@"on"] boolValue];
            [强->_过直播容器 设置过直播:开];
            KernelLogLine(开 ? "HUD: 直播模式已开启（绘制不进截图/录屏）"
                            : "HUD: 直播模式关闭（绘制可被截取）");
        }];

        // 悬浮菜单 - 暂时注释掉
        // _cdViewController = [[CDController alloc] init];
        // _cdViewController.view.frame = rootVC.view.bounds;
        // _cdViewController.view.backgroundColor = [UIColor clearColor];
        // [rootVC.view addSubview:_cdViewController.view];
        
        self.BBZMenu = [[HonyMenu alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        self.BBZMenu.backgroundColor = [UIColor clearColor];
        self.BBZMenu.opaque = NO;
        [self.BBZMenu setWindowLevel:100000];
        [self.BBZMenu setHidden:NO];

        // 游戏内悬浮球：挂在菜单窗口上（层级 100000，压在绘制层之上）。
        // 开关直接写 com.map.settings.plist，绘制层每秒读一次，改完即时生效。
        self.BBZMenu.rootViewController = [SLBall share];
        [[SLBall share] syncWithOrientedView:_MetalView];
        KernelLogLine("HUD: 悬浮球已挂载到菜单窗口");
        
        IMGUI_CHECKVERSION(); // 检查 BBZGUI 版本
        BBZGUI::CreateContext(); // 创建 BBZGUI 上下文
        BBZGUI::StyleColorsDark(); // 设定 BBZGUI 主题为深色
        
        BBZGUIIO& io = BBZGUI::GetIO(); (void)io; // 获取 BBZGUI 输入输出对象
        BBZGUI::StyleColorsClassic(); // 设定 BBZGUI 主题为经典样式
        
        // 三角洲字体加载方式
        ImFontConfig config;
        config.FontDataOwnedByAtlas = false;
        ImVector<ImWchar> ranges;
        ImFontGlyphRangesBuilder builder;
        builder.AddRanges(io.Fonts->GetGlyphRangesDefault());
        builder.AddRanges(io.Fonts->GetGlyphRangesGreek());
        builder.AddRanges(io.Fonts->GetGlyphRangesKorean());
        builder.AddRanges(io.Fonts->GetGlyphRangesJapanese());
        builder.AddRanges(io.Fonts->GetGlyphRangesChineseFull());
        builder.AddRanges(io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
        builder.AddRanges(io.Fonts->GetGlyphRangesCyrillic());
        builder.AddRanges(io.Fonts->GetGlyphRangesThai());
        builder.AddRanges(io.Fonts->GetGlyphRangesVietnamese());
        builder.BuildRanges(&ranges);
        
        io.Fonts->Clear();
        NSString* 字体路径 = [[NSBundle mainBundle] pathForResource:@"阿里巴巴惠普体" ofType:@"ttf"];
        io.Fonts->AddFontFromFileTTF([字体路径 UTF8String], 30.0f, &config, ranges.Data);
        io.Fonts->Build();
        
        if (!BBZGUI_ImplMetal_Init(_MetalView.device)) { // 初始化 BBZGUI 的 Metal 绑定
            return YES; // 如果失败，返回 YES，结束启动
        }
        
        _mtlCommandQueue = [_MetalView.device newCommandQueue]; // 创建 Metal 命令队列
        if (!_mtlCommandQueue) { // 如果创建失败
            return YES; // 返回 YES，结束启动
        }
        
        _BBZHostingController = [[objc_getClass("SBSAccessibilityWindowHostingController") alloc] init]; // 初始化无障碍窗口托管控制器
        BBZMenuHostingController = [[objc_getClass("SBSAccessibilityWindowHostingController") alloc] init]; // 初始化另一个无障碍窗口托管控制器
        
        unsigned int _contextId = [self.BBZwindow _contextId]; // 获取主窗口的上下文 ID
        unsigned int _contextId1 = [self.BBZMenu _contextId]; // 获取菜单窗口的上下文 ID
        
        double windowLevel = [self.BBZwindow windowLevel]; // 获取主窗口层级
        double windowLevel1 = [self.BBZMenu windowLevel]; // 获取菜单窗口层级
        
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        
        ((void (*)(id, SEL, unsigned int, double))objc_msgSend)(_BBZHostingController,
                                                                NSSelectorFromString(@"registerWindowWithContextID:atLevel:"),
                                                                _contextId,
                                                                windowLevel); // 通过 objc_msgSend 方式调用注册窗口方法
        
        ((void (*)(id, SEL, unsigned int, double))objc_msgSend)(BBZMenuHostingController,
                                                                NSSelectorFromString(@"registerWindowWithContextID:atLevel:"),
                                                                _contextId1,
                                                                windowLevel1); // 注册菜单窗口
        
#pragma clang diagnostic pop

        // S45 新增：注册浮层日志 + 重注册定时器
        {
            char 行[200];
            snprintf(行, sizeof(行), "HUD: 注册浮层 contextId HUD=%u 菜单=%u", _contextId, _contextId1);
            KernelLogLine(行);
        }
        __weak typeof(self) weakSelf2 = self;
        _重注册Timer = [NSTimer timerWithTimeInterval:2.0
                                              target:self
                                            selector:@selector(重注册浮层)
                                            userInfo:nil
                                             repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_重注册Timer forMode:NSRunLoopCommonModes];
        (void)weakSelf2;
        
        // 设置屏幕方向变化的监听器
        [self setupOrientationObserver];
        
        return YES; // 启动成功，返回 YES
    }
}



- (void)setupOrientationObserver { // 设置屏幕方向监听
    self.orientationObserver = [[objc_getClass("FBSOrientationObserver") alloc] init]; // 创建 FBSOrientationObserver 观察者
    __weak typeof(self) weakSelf = self; // 采用弱引用，防止循环引用
    
    [self.orientationObserver setHandler:^(FBSOrientationUpdate *orientationUpdate) { // 设置方向变化的回调
        dispatch_async(dispatch_get_main_queue(), ^{ // 在主线程执行
            [weakSelf handleInterfaceOrientationChange:(UIInterfaceOrientation)orientationUpdate.orientation
                                              duration:orientationUpdate.duration]; // 处理屏幕方向变化
        });
    }];
}

- (void)handleInterfaceOrientationChange:(UIInterfaceOrientation)orientation duration:(NSTimeInterval)duration {
    BOOL isLandscape = UIInterfaceOrientationIsLandscape(orientation);
    CGSize screenSize = [UIScreen mainScreen].bounds.size; // 直接使用点尺寸
    
    // 计算横竖屏下的逻辑尺寸（点单位）
    BBZWidth = isLandscape ? MAX(screenSize.width, screenSize.height) : MIN(screenSize.width, screenSize.height);
    BBZHeight = isLandscape ? MIN(screenSize.width, screenSize.height) : MAX(screenSize.width, screenSize.height);
    
    [UIView animateWithDuration:duration animations:^{
        switch (orientation) {
            case UIInterfaceOrientationLandscapeLeft:
                self->_MetalView.transform = CGAffineTransformMakeRotation(-M_PI_2);
                self->_MetalView.bounds = CGRectMake(0, 0, BBZWidth, BBZHeight);
                break;
                
            case UIInterfaceOrientationLandscapeRight:
                self->_MetalView.transform = CGAffineTransformMakeRotation(M_PI_2);
                self->_MetalView.bounds = CGRectMake(0, 0, BBZWidth, BBZHeight);
                break;
                
            case UIInterfaceOrientationPortraitUpsideDown:
                self->_MetalView.transform = CGAffineTransformMakeRotation(M_PI);
                self->_MetalView.bounds = CGRectMake(0, 0, BBZWidth, BBZHeight);
                break;
                
            default: // Portrait
                self->_MetalView.transform = CGAffineTransformIdentity;
                self->_MetalView.bounds = CGRectMake(0, 0, BBZWidth, BBZHeight);
                break;
        }
        
        // 确保 Metal 视图更新尺寸
        [self->_MetalView setNeedsDisplay];
        [self->_MetalView draw];

        // 悬浮球跟着绘制层一起转，横竖屏都和画面同一个坐标系
        [[SLBall share] syncWithOrientedView:self->_MetalView];
    }];
}

// 全局静态变量，减少系统调用次数
static double g_Time = 0.0;
static struct timespec current_timespec;

inline void UpdateImGuiIO(MTKView *view, BBZGUIIO &io) {
    clock_gettime(CLOCK_MONOTONIC, &current_timespec);
    double current_time = (double)(current_timespec.tv_sec) + (current_timespec.tv_nsec / 1e9);
    io.DeltaTime = g_Time > 0.0 ? (float)(current_time - g_Time) : (1.0f / view.preferredFramesPerSecond);
    g_Time = current_time;

    io.DisplaySize = ImVec2(view.drawableSize.width, view.drawableSize.height);
}

- (void)drawInMTKView:(MTKView *)view {
    @autoreleasepool {
        // S45 新增：浮层心跳诊断（节流，出问题才写日志）
        static double 上次心跳 = 0;
        double 心跳时刻 = CACurrentMediaTime();
        BOOL 该心跳 = (心跳时刻 - 上次心跳) >= 5.0;
        if (该心跳) 上次心跳 = 心跳时刻;

        if (!view.device) {
            if (该心跳) KernelLogLine("浮层不会显示");
            return;
        }

        BBZGUIIO& io = BBZGUI::GetIO();

        // ⚡️ 时间更新优化
        UpdateImGuiIO(view, io);

        // 提前检查 drawable
        if (view.currentDrawable == nil) {
            if (该心跳) KernelLogLine("这一帧没法画");
            return;
        }

        // ⚡️ Metal 命令缓冲区
        id<MTLCommandBuffer> commandBuffer = [_mtlCommandQueue commandBuffer];
        MTLRenderPassDescriptor* renderPassDescriptor = view.currentRenderPassDescriptor;

        if (!renderPassDescriptor) {
            if (该心跳) KernelLogLine("浮层无法绘制");
            [commandBuffer commit];
            return;
        }

        // ⚡️ ImGui 准备帧
        BBZGUI_ImplMetal_NewFrame(renderPassDescriptor);
        BBZGUI::NewFrame();

        // ⚡️ 绘制逻辑（自定义渲染函数）
        Draw::StartBooks();

        // ⚡️ ImGui 渲染准备
        BBZGUI::Render();

        // ⚡️ 仅在有效 renderPass 下编码
        id<MTLRenderCommandEncoder> renderCommandEncoder =
            [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        BBZGUI_ImplMetal_RenderDrawData(BBZGUI::GetDrawData(), commandBuffer, renderCommandEncoder);
        [renderCommandEncoder endEncoding];

        // ⚡️ 提交 GPU 命令
        [commandBuffer presentDrawable:view.currentDrawable];
        [commandBuffer commit];
    }
}

- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size { }

@end
