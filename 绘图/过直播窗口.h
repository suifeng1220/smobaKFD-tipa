//
//  过直播窗口.h - 直播/录屏隐藏功能
//
//  实现方式：把绘制视图塞进 secureTextEntry 的 UITextField 内部画布视图。
//  系统会把 secure 子树的合成结果从截图 / 录屏 / 投屏流里剔除，
//  但屏幕上照常显示（本机看到的是正常画面，截图录屏里没有绘制层）。
//

#import <UIKit/UIKit.h>

@interface 过直播窗口 : UIView

/// 开 = 绘制内容不进截图/录屏；关 = 普通视图，可被截取。可随时切换。
- (void)设置过直播:(BOOL)开;

/// 当前是否处于过直播状态
@property (nonatomic, readonly) BOOL 过直播;

@end
