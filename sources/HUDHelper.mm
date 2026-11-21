//
//  HUDHelper.mm
//  DZ
//
//  Created by Lessica on 2024/1/24.
//

#import <spawn.h>
#import <notify.h>
#import <mach-o/dyld.h>
#import <sys/wait.h>
#import <sys/sysctl.h>
#import <unistd.h>
#import <string.h>
#import <signal.h>

#import "HUDHelper.h"
#import "NSUserDefaults+Private.h"
#import "DOEnvironmentManager.h"

extern "C" char **environ;

// S45 新增：主程序日志通道
extern "C" void KernelLogLine(const char *line);

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern "C" int posix_spawnattr_set_persona_np(const posix_spawnattr_t* __restrict, uid_t, uint32_t);
extern "C" int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t* __restrict, uid_t);
extern "C" int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t* __restrict, uid_t);

// S45 新增：HUD 执行 Spawn（三级 spawn 策略）
// 还原自 __ZL14HUD__SpawnPKcS0_iPi 0x100057090
//   策略2 = persona(root) + setpgroup + flags
//   策略1 = setpgroup + flags（不换 persona）
//   策略0 = 原样 spawn
// 返回 posix_spawn 的 rc，pid 通过出参带回
static int HUD执行Spawn(const char *程序, const char *参数, unsigned 策略, pid_t *pid出) {
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    int personaRC = 0, uidRC = 0, gidRC = 0;
    if (策略 == 2) {
        personaRC = posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
        uidRC = posix_spawnattr_set_persona_uid_np(&attr, 0);
        gidRC = posix_spawnattr_set_persona_gid_np(&attr, 0);
        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    } else if (策略 == 1) {
        posix_spawnattr_setpgroup(&attr, 0);
        posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    }

    const char *argv[] = { 程序, 参数, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, 程序, NULL, &attr, (char **)argv, environ);
    posix_spawnattr_destroy(&attr);

    char 行[320];
    snprintf(行, sizeof(行), "SetHUD: 策略%d spawn %s rc=%d(%s) pid=%d persona(%d/%d/%d)",
             策略, 参数, rc, strerror(rc), pid, personaRC, uidRC, gidRC);
    KernelLogLine(行);

    if (pid出) *pid出 = pid;
    return rc;
}

// 限时 waitpid：子进程（-check/-exit/launchctl）如果卡在 jbserver XPC 上，
// 无界 waitpid 会把调用方（多数时候是 UI 主线程）一起拖死 —— 表现就是
// 「开关悬浮之后整个 app 卡住」。这里最多等 毫秒上限，超时强杀后不再等。
static int 限时waitpid(pid_t pid, int 毫秒上限) {
    int status = 0;
    for (int 等 = 0; 等 < 毫秒上限; 等 += 20) {
        pid_t r = waitpid(pid, &status, WNOHANG);
        if (r == pid || r == -1) return status;
        usleep(20000);
    }
    kill(pid, SIGKILL);
    for (int 等 = 0; 等 < 300; 等 += 20) {
        if (waitpid(pid, &status, WNOHANG) == pid) return status;
        usleep(20000);
    }
    return status;
}

#define LAUNCH_DAEMON_PATH ROOT_PATH("/Library/LaunchDaemons/ch.xxtou.hudservices.plist")

// S45 新增：守护 pid 文件路径
#define HUD_PID_FILE "/var/mobile/Library/Caches/cnm.sb.sjz.pid"

// ==================== v77：浮层实例查杀 ====================
// 旧关停链路只有一条：-exit 读 pid 文件 → kill。pid 文件写失败（沙盒拒写
// /var/mobile/Library/Caches 时 writeToFile error:nil 直接吞掉）就全断：
// -exit 什么都没杀、-check 永远说"没在跑"（开了又拉新实例，越堆越多），
// 表现就是「总开关关不掉 + 设备越来越卡」。这里补一条不依赖 pid 文件的路：
// KERN_PROCARGS2 找 argv[1]=="-hud" 的实例直接 SIGKILL —— 主 UI（无参数）、
// HIDDevice、-check/-exit 都不会误伤。

static NSString *HUD可执行名(void) {
    static NSString *名 = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        uint32_t sz = 0;
        _NSGetExecutablePath(NULL, &sz);
        char *p = (char *)calloc(1, sz + 1);
        if (p) {
            _NSGetExecutablePath(p, &sz);
            名 = [[NSString stringWithUTF8String:p] lastPathComponent];
            free(p);
        }
    });
    return 名;
}

// 取 pid 的 argv[1]（KERN_PROCARGS2）；取不到返回 nil
static NSString *HUD进程参数1(pid_t pid) {
    int mib[3] = {CTL_KERN, KERN_PROCARGS2, (int)pid};
    size_t size = 0;
    if (sysctl(mib, 3, NULL, &size, NULL, 0) != 0 || size <= sizeof(int)) return nil;
    char *buf = (char *)calloc(1, size + 1);
    if (!buf) return nil;
    NSString *arg1 = nil;
    if (sysctl(mib, 3, buf, &size, NULL, 0) == 0 && size > sizeof(int)) {
        int argc = 0;
        memcpy(&argc, buf, sizeof(int));
        char *p = buf + sizeof(int);
        char *end = buf + size;
        // 布局：[argc][exec_path][argv0][argv1]…[env…]
        // 跳过 exec_path
        while (p < end && *p) p++;
        while (p < end && !*p) p++;
        // 再跳过 argv[0]，剩下的才是 argv[1]
        if (argc >= 2 && p < end && *p) {
            while (p < end && *p) p++;
            while (p < end && !*p) p++;
            if (p < end && *p) arg1 = [NSString stringWithUTF8String:p];
        }
    }
    free(buf);
    return arg1;
}

// 进程名匹配（p_comm 截断 16 字节，-check 同款判法）
static BOOL HUD进程名对得上(pid_t pid) {
    struct kinfo_proc kp;
    size_t len = sizeof(kp);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid};
    if (sysctl(mib, 4, &kp, &len, NULL, 0) != 0 || len == 0) return NO;
    if (kp.kp_proc.p_stat == SZOMB) return NO;
    NSString *名 = HUD可执行名();
    if (!名) return NO;
    return strncmp(kp.kp_proc.p_comm, 名.UTF8String, 16) == 0;
}

pid_t HUDFindOverlayPID(void) {
    // ① pid 文件快路径（写成功时够用）
    NSString *pid串 = [NSString stringWithContentsOfFile:ROOT_PATH_NS(@HUD_PID_FILE)
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (pid串.length) {
        pid_t pid = (pid_t)pid串.intValue;
        if (pid > 1 && [@"-hud" isEqualToString:HUD进程参数1(pid)] && HUD进程名对得上(pid)) {
            return pid;
        }
    }
    // ② 全进程扫描（pid 文件缺失/过期时的正路）
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) != 0 || len == 0) return 0;
    struct kinfo_proc *all = (struct kinfo_proc *)calloc(1, len + sizeof(struct kinfo_proc));
    if (!all) return 0;
    pid_t 命中 = 0;
    if (sysctl(mib, 3, all, &len, NULL, 0) == 0) {
        size_t 个数 = len / sizeof(struct kinfo_proc);
        for (size_t i = 0; i < 个数 && !命中; ++i) {
            pid_t pid = all[i].kp_proc.p_pid;
            if (pid <= 1 || pid == getpid()) continue;
            if (all[i].kp_proc.p_stat == SZOMB) continue;
            if (!HUD进程名对得上(pid)) continue;
            if ([@"-hud" isEqualToString:HUD进程参数1(pid)]) 命中 = pid;
        }
    }
    free(all);
    return 命中;
}

int HUDKillOverlay(const char *reason) {
    int 杀数 = 0;
    // ① pid 文件精确杀
    NSString *pid串 = [NSString stringWithContentsOfFile:ROOT_PATH_NS(@HUD_PID_FILE)
                                               encoding:NSUTF8StringEncoding
                                                  error:nil];
    if (pid串.length) {
        pid_t pid = (pid_t)pid串.intValue;
        NSString *a1 = (pid > 1) ? HUD进程参数1(pid) : nil;
        // argv 读得出就必须是 -hud（防 pid 复用到 HIDDevice/-check）；
        // 读不出（权限/竞态）时退化成进程名匹配 —— pid 文件是浮层自己写的。
        BOOL 该杀 = (pid > 1 && pid != getpid() && HUD进程名对得上(pid)
                     && (a1 == nil || [a1 isEqualToString:@"-hud"]));
        if (该杀) {
            if (kill(pid, SIGKILL) == 0) {
                杀数++;
                char 行[160];
                snprintf(行, sizeof(行), "SetHUD: [%s] pid文件杀浮层 pid=%d", reason ? reason : "-", pid);
                KernelLogLine(行);
            }
        }
        unlink([ROOT_PATH_NS(@HUD_PID_FILE) fileSystemRepresentation]);
    }
    // ② 全进程扫描：argv[1]=="-hud" 全杀（堆叠实例、pid 文件丢失都在这兜住）
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) == 0 && len > 0) {
        struct kinfo_proc *all = (struct kinfo_proc *)calloc(1, len + sizeof(struct kinfo_proc));
        if (all) {
            if (sysctl(mib, 3, all, &len, NULL, 0) == 0) {
                size_t 个数 = len / sizeof(struct kinfo_proc);
                for (size_t i = 0; i < 个数; ++i) {
                    pid_t pid = all[i].kp_proc.p_pid;
                    if (pid <= 1 || pid == getpid()) continue;
                    if (all[i].kp_proc.p_stat == SZOMB) continue;
                    if (!HUD进程名对得上(pid)) continue;
                    if (![@"-hud" isEqualToString:HUD进程参数1(pid)]) continue;
                    if (kill(pid, SIGKILL) == 0) {
                        杀数++;
                        char 行[160];
                        snprintf(行, sizeof(行), "SetHUD: [%s] 扫描杀浮层 pid=%d", reason ? reason : "-", pid);
                        KernelLogLine(行);
                    }
                }
            }
            free(all);
        }
    }
    return 杀数;
}

BOOL IsHUDEnabled(void)
{
    // v77：不再 spawn -check 子进程 + waitpid（主线程上最多卡 2 秒，
    // 表现为"开关点半天没反应"）。进程内直接判定，微秒级。
    return HUDFindOverlayPID() > 0;
}

// SetHUDEnabled 三级 spawn 策略序列（还原自 SetHUDEnabled::策略序列）
// 普通设备维持原序 1,0,2（persona 在非越狱机多半不可用，放最后兜底）；
// 越狱设备改成 2,1,0 —— persona(root) 优先：jbclient_initialize_primitives 硬性
// 要求 uid 0（root 域只放行 root 进程），策略 1/0 拉起的 -hud 是 uid=501，
// 越狱通道必然降级、kread 全废、自检永远 ❌。-hud 拿到 root 后自己会降权回 mobile。
static const unsigned 策略序列_普通[3] = { 1, 0, 2 };
static const unsigned 策略序列_越狱[3] = { 2, 1, 0 };
static const unsigned* 策略表(void) {
    static const unsigned* p = NULL;
    if (!p) {
        BOOL jb = [DOEnvironmentManager sharedManager].isJailbroken;
        p = jb ? 策略序列_越狱 : 策略序列_普通;
        char 行[120];
        snprintf(行, sizeof(行), "SetHUD: spawn 策略序=%s",
                 jb ? "2,1,0（persona root 优先）" : "1,0,2");
        KernelLogLine(行);
    }
    return p;
}

// 开关重活统一走串行队列：调用线程（基本都是 UI 主线程）只发淡出通知就
// 返回。旧实现在主线程上 sleep + spawn + waitpid（最多 6 秒+），关开关时
// 整个 app 冻住，体感就是「点了没反应 / 关不掉」。
static dispatch_queue_t HUD开关队列(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("cnm.sb.sjz.set-hud", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static void SetHUDEnabled同步(BOOL isEnabled)
{
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    // ===== S45 新增：诊断 + 守护 plist 程序校验 =====
    KernelLogLine(isEnabled ? "SetHUD: 请求开启浮层" : "SetHUD: 请求关闭浮层");
    const char *plist路径 = LAUNCH_DAEMON_PATH;
    {
        char 行[300];
        snprintf(行, sizeof(行), "SetHUD: LaunchDaemon plist %s",
                 access(plist路径, F_OK) == 0 ? "存在" : "不存在");
        KernelLogLine(行);
    }

    BOOL 守护程序在 = NO;
    if (access(plist路径, F_OK) == 0) {
        // plist 在 → 校验它指向的程序是否真的存在
        NSString *plist串 = [NSString stringWithUTF8String:plist路径];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plist串];
        NSString *程序 = [[plist objectForKey:@"ProgramArguments"] firstObject];
        if ([程序 isKindOfClass:[NSString class]] && 程序.length
            && access([程序 fileSystemRepresentation], F_OK) == 0) {
            守护程序在 = YES;
        } else {
            KernelLogLine("SetHUD: ★守护 plist 在，但它指向的程序不存在 → 改直接 spawn 自身");
        }
    }

    if (守护程序在)
    {
        if (!isEnabled) {
            [NSThread sleepForTimeInterval:FADE_OUT_DURATION];
            // v77：launchctl unload 扑空时（守护没在跑/路径不对）也要把
            // 浮层实例杀干净，不能只依赖守护。
            HUDKillOverlay("关开关·守护旁路");
        }

        pid_t task_pid;
        static const char *executablePath = ROOT_PATH("/usr/bin/launchctl");
        const char *args[] = { executablePath, isEnabled ? "load" : "unload", LAUNCH_DAEMON_PATH, NULL };
        int rc = posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
        posix_spawnattr_destroy(&attr);
        {
            char 行[400];
            snprintf(行, sizeof(行), "SetHUD: launchctl %s rc=%d(%s) pid=%d",
                     isEnabled ? "load" : "unload", rc, strerror(rc), task_pid);
            KernelLogLine(行);
        }

        int status = 限时waitpid(task_pid, 3000);
        if (WIFEXITED(status)) {
            log_debug(OS_LOG_DEFAULT, "child status %d", WEXITSTATUS(status));
        }

        return;
    }

    // ===== 直接 spawn 自身（守护 plist 不在或指向的程序不存在） =====
    posix_spawnattr_destroy(&attr);

    static char *executablePath = NULL;
    uint32_t executablePathSize = 0;
    _NSGetExecutablePath(NULL, &executablePathSize);
    executablePath = (char *)calloc(1, executablePathSize);
    _NSGetExecutablePath(executablePath, &executablePathSize);

    {
        char 行[420];
        snprintf(行, sizeof(行), "SetHUD: uid=%d euid=%d 可执行=%d exe=%s",
                 getuid(), geteuid(), access(executablePath, X_OK) == 0, executablePath);
        KernelLogLine(行);
    }

    if (isEnabled)
    {
        // v77：先清残留再拉新。旧逻辑只看 -check（依赖 pid 文件）说"没在跑"
        // 就 spawn —— pid 文件坏了就每次开关都堆一个新浮层，越开越卡。
        if (HUDFindOverlayPID() > 0) {
            int 清 = HUDKillOverlay("开开关清残留");
            char 行[120];
            snprintf(行, sizeof(行), "SetHUD: 开开关前清掉 %d 个残留浮层", 清);
            KernelLogLine(行);
            if (清 > 0) usleep(300000);   // 给回收留窗口，避免新旧并存
        }

        unlink(ROOT_PATH(HUD_PID_FILE));

        // 三级 spawn：按设备环境选序列，每级起活后等 600ms 确认进程还在
        for (int i = 0; i < 3; ++i) {
            unsigned 策略 = 策略表()[i];
            pid_t 拉起pid = 0;
            if (HUD执行Spawn(executablePath, "-hud", 策略, &拉起pid) == 0) {
                usleep(600000);   // 600ms
                if (拉起pid > 0 && kill(拉起pid, 0) == 0) {
                    char 行[260];
                    snprintf(行, sizeof(行), "SetHUD: ✓ 浮层已拉起（策略%d）pid=%d",
                             策略, 拉起pid);
                    KernelLogLine(行);
                    return;
                }
                char 行[260];
                snprintf(行, sizeof(行), "SetHUD: 策略%d 返回成功但 600ms 内进程就没了（pid=%d，多半 AMFI 杀签名）",
                         策略, 拉起pid);
                KernelLogLine(行);
            }
        }
        KernelLogLine("SetHUD: ✗ 三级 spawn 全部失败，浮层起不来");
    }
    else
    {
        [NSThread sleepForTimeInterval:FADE_OUT_DURATION];

        // v77 关停三板斧，缺一不可：
        //   ① 直杀（pid 文件 + 全进程扫描）—— 不依赖任何子进程 spawn 成功
        //   ② -exit 子进程兜底（顺带清 pid 文件）
        //   ③ 校验 + 补刀：还在就再杀一轮
        int 杀数 = HUDKillOverlay("关开关");
        char 行[120];
        snprintf(行, sizeof(行), "SetHUD: 关开关直杀 %d 个浮层实例", 杀数);
        KernelLogLine(行);

        for (int i = 0; i < 3; ++i) {
            pid_t 退出pid = 0;
            if (HUD执行Spawn(executablePath, "-exit", 策略表()[i], &退出pid) == 0) {
                限时waitpid(退出pid, 2000);
                break;
            }
        }

        usleep(300000);
        if (HUDFindOverlayPID() > 0) {
            KernelLogLine("SetHUD: ★关开关后浮层仍在 → 补刀一轮");
            HUDKillOverlay("关开关-补刀");
        } else {
            KernelLogLine("SetHUD: ✓ 浮层已确认关停");
        }
    }
}

void SetHUDEnabled(BOOL isEnabled)
{
    // 淡出通知立刻发：HUD 进程收到后自己渐隐 + terminateWithSuccess。
    // 其余重活（sleep/spawn/waitpid/查杀）全部下后台串行队列，主线程秒回。
    notify_post(NOTIFY_DISMISSAL_HUD);
    dispatch_async(HUD开关队列(), ^{
        @autoreleasepool {
            SetHUDEnabled同步(isEnabled);
        }
    });
}

#if DEBUG
void SimulateMemoryPressure(void)
{
    static NSString *nsExecutablePath = nil;
    static const char *executablePath = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSBundle *mainBundle = [NSBundle mainBundle];
        nsExecutablePath = [mainBundle pathForResource:@"memory_pressure" ofType:nil];
        if (nsExecutablePath) {
            executablePath = [nsExecutablePath UTF8String];
        }
    });

    if (!executablePath) {
        return;
    }

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    pid_t task_pid;
    const char *args[] = { executablePath, "-l", "critical", NULL };
    posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);

    log_debug(OS_LOG_DEFAULT, "spawned %{public}s -l critical pid = %{public}d", executablePath, task_pid);
}
#endif

NSUserDefaults *GetStandardUserDefaults(void)
{
    static NSUserDefaults *_userDefaults = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *containerPath = [[NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject] stringByDeletingLastPathComponent];
        NSURL *containerURL = [NSURL fileURLWithPath:containerPath];
        _userDefaults = [[NSUserDefaults alloc] _initWithSuiteName:nil container:containerURL];
        [_userDefaults registerDefaults:@{
            HUDUserDefaultsKeyUsesCustomOffset: @NO,
            HUDUserDefaultsKeyRealCustomOffsetX: @0,
            HUDUserDefaultsKeyRealCustomOffsetY: @0,
            HUDUserDefaultsKeyUsesCustomFontSize: @NO,
            HUDUserDefaultsKeyRealCustomFontSize: @9,
        }];
    });
    return _userDefaults;
}

void fasongxuni(void)
{
   
    uint32_t executablePathSize = 0;
    _NSGetExecutablePath(NULL, &executablePathSize);
    char *executablePath = (char *)calloc(1, executablePathSize);
    _NSGetExecutablePath(executablePath, &executablePathSize);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    // 设置 persona 为 root
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    int ret = 0;
    pid_t task_pid = 0;

    posix_spawnattr_setpgroup(&attr, 0);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);

    const char *args[] = { executablePath, "HIDDevice", NULL };
    ret = posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);

    if (ret == 0) {
      

        sleep(1); // 等待进程启动
        if (kill(task_pid, 0) == 0) {
          
        } else {
            
        }
    } else {
       
    }

   
}
