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
#import <unistd.h>
#import <string.h>

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

BOOL IsHUDEnabled(void)
{
    static char *executablePath = NULL;
    uint32_t executablePathSize = 0;
    _NSGetExecutablePath(NULL, &executablePathSize);
    executablePath = (char *)calloc(1, executablePathSize);
    _NSGetExecutablePath(executablePath, &executablePathSize);

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);

    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    pid_t task_pid;
    const char *args[] = { executablePath, "-check", NULL };
    posix_spawn(&task_pid, executablePath, NULL, &attr, (char **)args, environ);
    posix_spawnattr_destroy(&attr);
    log_debug(OS_LOG_DEFAULT, "spawned %{public}s -check pid = %{public}d", executablePath, task_pid);
    
    int status = 限时waitpid(task_pid, 2000);
    if (WIFEXITED(status)) {
        log_debug(OS_LOG_DEFAULT, "child status %d", WEXITSTATUS(status));
        return WEXITSTATUS(status) != 0;
    }
    return NO;   // 超时被杀/异常退出：当作没在跑，宁可重拉也别卡死调用方
}

#define LAUNCH_DAEMON_PATH ROOT_PATH("/Library/LaunchDaemons/ch.xxtou.hudservices.plist")

// S45 新增：守护 pid 文件路径
#define HUD_PID_FILE "/var/mobile/Library/Caches/cnm.sb.sjz.pid"

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

void SetHUDEnabled(BOOL isEnabled)
{
    notify_post(NOTIFY_DISMISSAL_HUD);

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
        if (IsHUDEnabled()) {
            KernelLogLine("SetHUD: 浮层本来就在跑，不重复拉起");
            return;
        }

        unlink(HUD_PID_FILE);

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

        for (int i = 0; i < 3; ++i) {
            pid_t 退出pid = 0;
            if (HUD执行Spawn(executablePath, "-exit", 策略表()[i], &退出pid) == 0) {
                限时waitpid(退出pid, 2000);
                return;
            }
        }
    }
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
