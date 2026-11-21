//
//  HUDApp.mm
//  DZ
//
//  Created by Lessica on 2024/1/24.
//

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <notify.h>
#import <objc/runtime.h>
#import <sys/utsname.h>
#import <sys/sysctl.h>
#import <unistd.h>

#if !NO_TROLL
#import "AXEventRepresentation.h"
#import "BackboardServices.h"
#import "HUDHelper.h"
#import "IOKit+SPI.h"
#import "TSEventFetcher.h"
#import "UIApplication+Private.h"
#import "SLBall.h"

#import "DOEnvironmentManager.h"
#import <libjailbreak/info.h>
#import <libjailbreak/jbclient_xpc.h>
#import "LFVirtualDigitizer.h"
#define PID_PATH "/var/mobile/Library/Caches/cnm.sb.sjz.pid"

static __used NSString *mDeviceModel(void) {
  struct utsname systemInfo;
  uname(&systemInfo);
  return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
}

static __used void _HUDEventCallback(void *target, void *refcon, IOHIDServiceRef service, IOHIDEventRef event) {
  static UIApplication *app = [UIApplication sharedApplication];
  log_debug(OS_LOG_DEFAULT, "_HUDEventCallback => %{public}@", event);

  // 只处理手指（digitizer）事件。键盘、加速度计、侧键、旋钮走的是同一个
  // 回调，它们的 rep 没有有效触摸坐标，被当成"移动"会把悬浮球拖到奇怪位置。
  // 用 dlsym 取符号，取不到就不过滤（HUD 进程不一定静态链了 IOKit）。
  {
    static uint32_t (*取类型)(IOHIDEventRef) = NULL;
    static dispatch_once_t 一次符号;
    dispatch_once(&一次符号, ^{
      取类型 = (uint32_t (*)(IOHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetType");
    });
    if (取类型 && 取类型(event) != 11 /* kIOHIDEventTypeDigitizer */) return;
  }

  // 诊断：确认 HID 事件确实进了 HUD 进程。悬浮球点不动时先看这行在不在。
  {
    static int 计数 = 0;
    ++计数;
    if (计数 == 1 || 计数 % 300 == 0) {
      char 行[128];
      snprintf(行, sizeof(行), "HID 回调 第 %d 次 event=%p", 计数, (void *)event);
      SL日志行(行);
    }
  }
  
  // iOS 15.1+ has a new API for handling HID events.
  if (@available(iOS 15.1, *)) {
  } else {
    [app _enqueueHIDEvent:event];
  }
  
  BOOL shouldUseAXEvent = YES; // Always use AX events now...
  
  BOOL isExactly15 = NO;
  static NSOperatingSystemVersion version = [[NSProcessInfo processInfo] operatingSystemVersion];
  if (version.majorVersion == 15 && version.minorVersion == 0 && version.patchVersion == 0) {
    NSString *deviceModel = mDeviceModel();
    if (![deviceModel hasPrefix:@"iPhone13,"] && ![deviceModel hasPrefix:@"iPhone14,"]) { // iPhone 12 & 13 Series
      isExactly15 = YES;
    }
  }
  
  if (@available(iOS 15.0, *)) {
    shouldUseAXEvent = !isExactly15;
  } else {
    shouldUseAXEvent = NO;
  }
  
  if (shouldUseAXEvent) {
    static Class AXEventRepresentationCls = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
      [[NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/AccessibilityUtilities.framework"] load];
      AXEventRepresentationCls = objc_getClass("AXEventRepresentation");
    });
    
    AXEventRepresentation *rep = [AXEventRepresentationCls representationWithHIDEvent:event
                                                                  hidStreamIdentifier:@"UIApplicationEvents"];
    if (!rep) {
      static BOOL 已报nil = NO;
      if (!已报nil) {
        已报nil = YES;
        SL日志行("HID: rep 为 nil，AXEventRepresentation 解析失败（触摸拿不到坐标）");
      }
      return;
    }
    log_debug(OS_LOG_DEFAULT, "_HUDEventCallback => %{public}@", rep.handInfo);

    // 原始 HID 帧里到底带了几根手指。AX 层在不同系统上可能只给"变动的那根"，
    // 这里再取一份原始子事件数当兜底 —— 必须在回调线程里算完再进主队列，
    // 事件对象出了回调就不保证还活着。
    static CFArrayRef (*取子事件)(IOHIDEventRef) = NULL;
    static dispatch_once_t 一次子事件;
    dispatch_once(&一次子事件, ^{
      取子事件 = (CFArrayRef (*)(IOHIDEventRef))dlsym(RTLD_DEFAULT, "IOHIDEventGetChildren");
    });
    CFIndex 帧手指数 = 0;
    if (取子事件) {
      CFArrayRef 子 = 取子事件(event);
      if (子) 帧手指数 = CFArrayGetCount(子);
    }
    
    /* I don't like this. It's too hacky, but it works. */
    {
      dispatch_async(dispatch_get_main_queue(), ^(void) {
        CGPoint 触点 = [rep location];

        // 默认值必须是"移动"，不能是"抬起"。
        // AXEventRepresentation 对移动事件的标志位并不只有 isMove 一种
        // （iOS 16 上还可能是 isDragging / 纯 path 事件，isMove 返回 NO）。
        // 默认写 Ended 的后果：手指刚滑 1px 就被判成抬起 —— 拖动被当成
        // 点击，菜单反复弹出，同时 _触摸归属 被清零，后续移动全部丢弃，
        // 手感表现为"拖着拖着球没了"。
        UITouchPhase phase = UITouchPhaseMoved;
        if ([rep isTouchDown])
          phase = UITouchPhaseBegan;
        else if ([rep isCancel])
          phase = UITouchPhaseCancelled;
        else if ([rep isLift] || [rep isInRange] || [rep isInRangeLift])
          phase = UITouchPhaseEnded;

        // 第一个事件把坐标系记下来：原始点 / window bounds / 画布尺寸。
        // 万一悬浮球还是偏，看这一行就知道 rep.location 用的是哪套坐标。
        {
          static BOOL 已报坐标 = NO;
          if (!已报坐标) {
            已报坐标 = YES;
            CGSize 窗 = [UIScreen mainScreen].bounds.size;
            char 行[224];
            snprintf(行, sizeof(行),
                     "HID 首个坐标 (%.0f,%.0f) phase=%d | window %.0fx%.0f | 画布 %.0fx%.0f",
                     (double)触点.x, (double)触点.y, (int)phase,
                     (double)窗.width, (double)窗.height,
                     (double)MAX(窗.width, 窗.height), (double)MIN(窗.width, 窗.height));
            SL日志行(行);
          }
        }

        // 悬浮球 / 控制面板走 HID 直连：BBZMenu 是 SBS 托管窗口，横屏下
        // window bounds 与 HID 坐标空间对不上，UIKit 的 hitTest 永远打不中。
        // SLBall 内部自己按三种坐标系解释原始点，命中就吃掉这次触摸。
        // 路径数一起传进去：抬起帧/取消帧/铅笔悬停帧的 rep.location 常常是
        // (0,0)，把这种帧当坐标用，球会被"拖"到画布左下角（实测现象）。
        NSArray *触摸路径 = [[rep handInfo] paths];

        // 三指三击 → 显隐悬浮球。只藏球和面板，绘制层一根线都不动。
        // 这里是 HID 旁听通道，不消费事件；游戏照常收到这三根手指。
        //
        // 判据同时兼容 handInfo 的两种给法（不同系统/机型实测不一样）：
        //   ① 一帧里带全部手指  → paths.count >= 3；
        //   ② 一帧只带变动的那根 → 0.35s 内连来 3 个按下事件。
        // 一次三指按下只认一次：必须见过抬帧（isLift / paths=0）才能认下一次，
        // 所以三指长按、三指拖动最多算"一下"，凑不满三下，不会误触。
        // 1.0s 内凑满三下才真正切换。
        {
          static CFAbsoluteTime 按下时刻[3] = {0, 0, 0};
          static int 按下写位 = 0;
          static BOOL 已见释放 = YES;
          static BOOL 有新按下 = NO;
          static CFAbsoluteTime 上次认定 = 0;
          static int 连击 = 0;
          static CFAbsoluteTime 上次点击 = 0;
          static NSUInteger 最大路径 = 0;
          static BOOL 报过多指 = NO;
          static BOOL 报过三指 = NO;

          NSUInteger 路径数 = [触摸路径 count];
          // 两路取大的：AX 层路径数 或 原始 HID 子事件数（哪个给得多用哪个）
          if ((NSUInteger)帧手指数 > 路径数) 路径数 = (NSUInteger)帧手指数;
          CFAbsoluteTime 现在 = CFAbsoluteTimeGetCurrent();
          BOOL 抬帧 = ([rep isLift] || [rep isCancel]);

          // 诊断：多指帧到底带了几根手指。第一次见到就写一行，之后只涨不写。
          if (路径数 > 最大路径) {
            最大路径 = 路径数;
            if (路径数 >= 2 && !报过多指) {
              报过多指 = YES;
              char 行[96];
              snprintf(行, sizeof(行), "HID 多指帧：单帧最多 %lu 根",
                       (unsigned long)路径数);
              SL日志行(行);
            }
          }

          if (路径数 == 0 || 抬帧) 已见释放 = YES;

          if ([rep isTouchDown]) {
            按下时刻[按下写位] = 现在;
            按下写位 = (按下写位 + 1) % 3;
            有新按下 = YES;
          }

          int 窗口内按下 = 0;
          for (int i = 0; i < 3; ++i) {
            if (按下时刻[i] > 0.0 && 现在 - 按下时刻[i] <= 0.35) 窗口内按下 += 1;
          }

          BOOL 三指 = (路径数 >= 3) || (窗口内按下 >= 3);
          if (三指 && !报过三指) {
            报过三指 = YES;
            char 行[112];
            snprintf(行, sizeof(行), "HID 三指帧（开关 %d，单帧 %lu 根，0.35s 内按下 %d 次）",
                     SL三指三击开关开() ? 1 : 0, (unsigned long)路径数, 窗口内按下);
            SL日志行(行);
          }

          if (三指 && 有新按下 && !抬帧 && 已见释放 &&
              (现在 - 上次认定) > 0.10 && SL三指三击开关开()) {
            已见释放 = NO;
            有新按下 = NO;
            上次认定 = 现在;
            按下时刻[0] = 按下时刻[1] = 按下时刻[2] = 0.0;

            if (现在 - 上次点击 > 1.2) {
              连击 = 1;
            } else {
              连击 += 1;
            }
            上次点击 = 现在;

            char 行[96];
            snprintf(行, sizeof(行), "三指点击 %d/3", 连击);
            SL日志行(行);

            // 每认一下震一下：装完新包一敲就知道"识别到了没有"。
            // 只响一下（连击 1、2）用轻震，第三下真切换时由 SLBall 里给中震。
            if (连击 < 3) {
              UIImpactFeedbackGenerator *震 =
                  [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
              [震 impactOccurred];
            }

            if (连击 >= 3) {
              连击 = 0;
              if (SLBall面板可见()) SL日志行("三指三击：收起面板并隐藏悬浮球");
              SLBall切换球显隐();
            }
          }
        }

        if (SLBall触摸(触点.x, 触点.y, (int)phase, (int)触摸路径.count)) {
          return;
        }

        // 以下 UITouch 合成留给将来可能新增的 UIKit 控件
        // 每次都重新找窗口：缓存 firstObject 会导致点到的永远是老窗口。
        // 规则：跳过纯绘制窗口（HonyWindow 整层不吃触摸），取第一个真正命中控件的窗口。
        static __weak UIWindow *上次窗口 = nil;
        static Class 绘制窗口类 = nil;
        if (!绘制窗口类) 绘制窗口类 = objc_getClass("HonyWindow");
        UIWindow *keyWindow = nil;
        UIView *keyView = nil;
        for (UIWindow *w in [app windows]) {
          if (w.isHidden || w.alpha < 0.01f) continue;
          if (绘制窗口类 && [w isKindOfClass:绘制窗口类]) continue;
          UIView *v = [w hitTest:触点 withEvent:nil];
          if (v && v != w) { keyWindow = w; keyView = v; break; }
        }
        if (!keyWindow) {
          // 手指滑出控件范围时沿用上一次的窗口，保证这一串 UITouch 能收到 Ended
          keyWindow = 上次窗口 ?: [[app windows] firstObject];
          keyView = [keyWindow hitTest:触点 withEvent:nil];
        } else {
          上次窗口 = keyWindow;
        }
        if (!keyWindow) return;

        NSInteger pointerId = [[触摸路径 firstObject] pathIdentity];
        if (pointerId > 0)
          [TSEventFetcher receiveAXEventID:MIN(MAX(pointerId, 1), 98)
                        atGlobalCoordinate:触点
                            withTouchPhase:phase
                                  inWindow:keyWindow
                                    onView:keyView];
      });
    }
  }
}
#endif

int main(int argc, char *argv[]) {
  @autoreleasepool {
    log_debug(OS_LOG_DEFAULT, "launched argc %{public}d, argv[1] %{public}s", argc, argc > 1 ? argv[1] : "NULL");
    
    /// jai
    {
      // If systemhook isn't loaded and we are already jailbroken, we need to do the checkin ourselves
      // This can happen when the jailbreak is hidden or when tweak injection into the Dopamine app is disabled via Choicy
      // ★ 只在「真正要做事」的进程里 checkin（主 UI / -hud）。-check/-exit 只查一下
      //   pid 文件就退出，不需要 jbserver 会签；XPC 对面挂死时会把调用方一起拖死
      //   （SetHUDEnabled 在主线程 waitpid 这些子进程 → UI 整个卡住）。
      if (argc <= 1 || (argv[1] && strcmp(argv[1], "-hud") == 0)) {
        jbclient_process_checkin(NULL, NULL, NULL, NULL);
      }

      if ([DOEnvironmentManager sharedManager].isJailbroken) {
        setenv("PATH", "/sbin:/bin:/usr/sbin:/usr/bin:/var/jb/sbin:/var/jb/bin:/var/jb/usr/sbin:/var/jb/usr/bin", 1);
        setenv("TERM", "xterm-256color", 1);
      }
    }

    // persona(root) 拉起的进程（越狱下 -hud 走策略2）：趁 root 先把越狱通道建好
    // —— jbclient_initialize_primitives 硬性要求 uid 0（root 域只放行 root 进程）。
    // 建完立刻降权到 mobile(501)：窗口 / NSUserDefaults / 日志都在降权之后创建，
    // 文件属主不会漂成 root，设置持久化不会断。同步执行（内部自带 8s XPC 超时），
    // 必须赶在任何 Foundation 偏好读写之前，且不能拖进 didFinishLaunching。
    // 只对 -hud / 主进程做：-check/-exit 也是 root 拉起的，但它们秒进秒出，
    // 在这跑一遍通道初始化纯属拖慢开关（-check 被限时 waitpid 2s 强杀）。
    if (getuid() == 0 && (argc <= 1 || (argv[1] && strcmp(argv[1], "-hud") == 0))) {
      extern "C" int exploit_init_jailbreak(void);
      extern "C" void KernelLogLine(const char *line);
      int 通道 = exploit_init_jailbreak();
      setgid(501);
      setuid(501);
      KernelLogLine(通道 == 0
        ? "HUD: 越狱通道就绪（零内核利用），已降权至 mobile(501)"
        : "HUD: 越狱通道未建成，已降权至 mobile(501)（kread 不可用，绘制走任务端口）");
    }

#if !NO_TROLL
    if (argc <= 1) {
      return UIApplicationMain(argc, argv, @"MainApplication", @"MainApplicationDelegate");
    }
    
    if (strcmp(argv[1], "-hud") == 0) {
        
        
      pid_t pid = getpid();
      pid_t pgid = getgid();
      (void)pgid;
      log_debug(OS_LOG_DEFAULT, "HUD pid %d, pgid %d", pid, pgid);
      
      NSString *pidString = [NSString stringWithFormat:@"%d", pid];
      [pidString writeToFile:ROOT_PATH_NS(PID_PATH) atomically:YES encoding:NSUTF8StringEncoding error:nil];
      
      [UIScreen initialize];
      CFRunLoopGetCurrent();
            
      GSInitialize();
      BKSDisplayServicesStart();
      UIApplicationInitialize();
      
      UIApplicationInstantiateSingleton(objc_getClass("HUDMainApplication"));
      static id<UIApplicationDelegate> appDelegate = [[objc_getClass("BBZViewController") alloc] init];
      [UIApplication.sharedApplication setDelegate:appDelegate];
      [UIApplication.sharedApplication _accessibilityInit];
      
      [NSRunLoop currentRunLoop];
      BKSHIDEventRegisterEventCallback(_HUDEventCallback);
      
      if (@available(iOS 15.0, *)) {
        GSEventInitialize(0);
        GSEventPushRunLoopMode(kCFRunLoopDefaultMode);
      }
      
      [UIApplication.sharedApplication __completeAndRunAsPlugin];
      
      static int _springboardBootToken;
      notify_register_dispatch("SBSpringBoardDidLaunchNotification", &_springboardBootToken, dispatch_get_main_queue(), ^(int token) {
        notify_cancel(token);
        notify_post(NOTIFY_DISMISSAL_HUD);
        // Re-enable HUD after SpringBoard is launched.
        SetHUDEnabled(YES);
        // Exit the current instance of HUD.
        kill(pid, SIGKILL);
      });
      
      CFRunLoopRun();
      return EXIT_SUCCESS;
    } else if (strcmp(argv[1], "-exit") == 0) {
      NSString *pidString = [NSString stringWithContentsOfFile:ROOT_PATH_NS(PID_PATH)
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];
      
      if (pidString) {
        pid_t pid = (pid_t)[pidString intValue];
        kill(pid, SIGKILL);
        unlink([ROOT_PATH_NS(PID_PATH) UTF8String]);
      }
      
      return EXIT_SUCCESS;
    } else if (strcmp(argv[1], "-check") == 0) {
      NSString *pidString = [NSString stringWithContentsOfFile:ROOT_PATH_NS(PID_PATH)
                                                      encoding:NSUTF8StringEncoding
                                                         error:nil];

      if (pidString) {
        pid_t pid = (pid_t)[pidString intValue];
        int killed = kill(pid, 0);
        BOOL 活 = (killed == 0);
        if (活) {
          // kill(pid,0) 对僵尸进程也返回 0：被 -exit 杀掉的浮层若还没被回收，
          // 这里会误判「还在跑」→ 关了重开永远不拉新浮层（黑屏卡死）。
          // 再用 sysctl 核对：僵尸不算活、pid 被别的程序复用也不算活。
          struct kinfo_proc kp;
          size_t len = sizeof(kp);
          int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
          if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) {
            活 = NO;
          } else if (kp.kp_proc.p_stat == SZOMB) {
            活 = NO;
          } else {
            // 进程名必须是本可执行文件（p_comm 截断到 16 字节，比 basename 前缀）
            char 自名[64] = {0};
            uint32_t sz = sizeof(自名) - 1;
            _NSGetExecutablePath(自名, &sz);
            const char *base = strrchr(自名, '/');
            base = base ? base + 1 : 自名;
            if (strncmp(kp.kp_proc.p_comm, base, 16) != 0) 活 = NO;
          }
        }
        return (活 ? EXIT_FAILURE : EXIT_SUCCESS);
      } else
        return EXIT_SUCCESS; // No PID file, so HUD is not running
    }
#else
    return UIApplicationMain(argc, argv, @"MainApplication", @"MainApplicationDelegate");
#endif
  }
}
