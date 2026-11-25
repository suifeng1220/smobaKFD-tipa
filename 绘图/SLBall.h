//
//  SLBall.h
//  smobaKFD — 游戏内悬浮球 + 控制面板
//
//  挂在 HUD 进程的 BBZMenu 窗口上（level 100000），
//  点一下展开控制面板，直接改 com.map.settings.plist，
//  绘制层每秒读一次配置，所以改完立刻生效。
//
//  ⚠️ 交互不走 UIKit 事件分发：
//  BBZMenu 是 SBS 托管窗口，HUD 进程的 window bounds 是竖屏、HID 点却是
//  横屏坐标，UIKit 的 hitTest/sendEvent 这条路坐标空间对不上（实测球显示
//  正常但点不到、拖不动）。所以改成由 BKSHIDEventRegisterEventCallback 的
//  回调直接调 SLBall触摸()，自己做坐标解释与命中判断，完全不依赖 UIWindow。
//

#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// 触摸阶段，数值与 UITouchPhase 对齐
typedef NS_ENUM(int, SL触摸阶段) {
    SL触摸按下 = 0,
    SL触摸移动 = 1,
    SL触摸抬起 = 3,
    SL触摸取消 = 4,
};

#ifdef __cplusplus
extern "C" {
#endif

/// HID 回调转过来的原始屏幕点（rep.location，坐标系未知，内部自己解释）。
/// 路径数 = rep.handInfo.paths.count：0 表示这一帧没有真实手指（抬起帧、
/// 取消帧、Apple Pencil 悬停帧都可能给出 (0,0) 这种假坐标），一律不信。
/// 返回 YES 表示落在悬浮球或面板上。
bool SLBall触摸(float x, float y, int 阶段, int 路径数);

/// 面板当前是否展开（日志用）
bool SLBall面板可见(void);

/// 「三指三击显隐」开关是否打开（面板 通用 → 三指三击显隐，键 hideball）。
/// HID 回调每帧都会问一次，内部按 1 秒缓存，不会反复读盘。
bool SL三指三击开关开(void);

/// 切换悬浮球显隐，返回切换后的「已隐藏」状态。
/// 只动球和面板，绘制层（小地图 / 方框 / 射线）完全不受影响。
bool SLBall切换球显隐(void);

/// HUD 进程内部诊断日志，统一落到 /var/mobile/Library/Preferences/com.map.ball.log
void SL日志行(const char *行);

#ifdef __cplusplus
}
#endif

@interface SLBall : UIViewController

+ (instancetype)share;

/// 跟绘制层用同一套朝向：把 _MetalView 的 transform/bounds 原样抄给悬浮球容器。
/// 绘制层怎么转，悬浮球就怎么转，永远不会跟画面错开 90 度。
- (void)syncWithOrientedView:(UIView *)view;

@end

NS_ASSUME_NONNULL_END
