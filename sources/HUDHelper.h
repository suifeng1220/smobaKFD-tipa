//
//  HUDHelper.h
//  DZ
//
//  Created by Lessica on 2024/1/24.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

OBJC_EXTERN BOOL IsHUDEnabled(void);
OBJC_EXTERN void SetHUDEnabled(BOOL isEnabled);
// v77：浮层实例查杀（不依赖 pid 文件）。找/杀 argv[1]=="-hud" 的实例，
// HIDDevice、-check/-exit、主 UI 都不会误伤。-exit/-check 与 SetHUDEnabled 共用。
OBJC_EXTERN pid_t HUDFindOverlayPID(void);
OBJC_EXTERN int HUDKillOverlay(const char *reason);
OBJC_EXTERN void fasongxuni(void);
#if DEBUG
OBJC_EXTERN void SimulateMemoryPressure(void);
#endif

OBJC_EXTERN NSUserDefaults *GetStandardUserDefaults(void);

NS_ASSUME_NONNULL_END
