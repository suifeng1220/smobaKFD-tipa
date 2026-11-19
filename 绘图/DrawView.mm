//
//  DrawView.mm - S45 王者荣耀(smoba) 渲染核心  [S45 重建版]
//
//  由 AB_WZRY_S45重建版.tipa 内 Books 二进制反编译还原
//  （对应 __ZN4Draw10StartBooksEv 0x100082DB0 及周边辅助函数）
//

#include "DrawView.hpp"
#include <mutex>
#include <cstdint>
#include <cmath>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <cstring>
#include <cstdio>
#include "BBZGui.h"
#include "游戏/SDK.h"

#import "DOJailbreaker.h"
#include <libjailbreak/info.h>
#include <libjailbreak/primitives_external.h>
#import "SLIconCache.h"

extern "C" uint32_t kread32(uint64_t where);
extern "C" uint64_t kread64(uint64_t where);

// 主程序日志通道
extern "C" void KernelLogLine(const char *line);

#ifndef MIN
#define MIN(A,B) ((A) < (B) ? (A) : (B))
#endif

#ifdef __cplusplus
extern "C" {
#endif
bool exploit_mach_readbuf(pid_t pid, uint64_t base, void* output, size_t size);
bool exploit_mach_kwritebuf(pid_t pid, uint64_t base, const void* input, size_t size);
int exploit_kreadbuf(uint64_t kaddr, void* output, size_t size);
void exploit_v2p_cache_clear(void);
uint64_t kfd_get_current_proc(void);   // kfd 抓到的本进程 proc（内核态），作 allproc 兜底起点
#ifdef __cplusplus
}
#endif

@implementation DrawWindow

// ==================== 全局状态 ====================

static pid_t 游戏pid = -1;                 // _ZL9__pid
static uint64_t 模块基址 = 0;              // _ZL6___0
static mach_port_t 任务端口 = 0;           // _ZL12_____2
static pid_t 任务端口_pid = -1;            // 任务端口对应的 pid（pid 变了必须重新取）
static int 当前链 = -1;                    // _ZL15_____  坐标链索引
static bool 用备相机 = false;              // _ZL15______3
static const char* 状态文字 = "等待内核";  // _ZL12____
static std::atomic<int> 找进程调用{0};     // _ZL15______4
static std::atomic<int> 找进程完成{0};     // _ZL15______5
static int 读限流计数 = 0;                 // _ZL12_____1
static long 读总数 = 0;                    // _ZL15______2
static char 状态行[220] = {0};             // _ZL9____4   浮层第二行详情

// 视距
static uint64_t 视距地址 = 0;              // qword_100223588 (fov_addr)
static bool 视距是度 = false;              // _ZL15______6
static bool 视距自校准状态 = 0;            // _ZL9____7   0初始 1测试中 2锁定 3失败
static int 校准候选数 = 0;                 // _ZL15______10
static int 校准候选索引 = 0;               // _ZL12_____11
static double 校准等待时间 = 0;            // _ZL12_____12
static uint64_t 校准候选址[24];            // _ZL15______11
static float 校准候选值[24];               // _ZL15______12
static bool 校准候选是度[24];              // _ZL18______
static uint64_t 相机节点 = 0;              // _ZL15______8
static uint64_t 相机内层 = 0;              // _ZL15______7
static uint64_t 锁定视距址 = 0;            // _ZL15______9

// 对局状态
static bool 在对局 = false;                // _ZL12_____3
static double 掉出对局时刻 = 0;            // _ZL9____8

// 配置（com.map.settings.plist）
static bool cfg_draw = false;              // 0x100223558
static bool cfg_line = false;              // 0x100223559
static bool cfg_box = false;               // 0x10022355A
static bool cfg_avatar = false;            // 0x10022355B
static bool cfg_map = false;               // 0x10022355C
static bool cfg_skill = false;             // 0x10022355D
static bool cfg_monster = false;           // 0x10022355E
static bool cfg_health = false;            // 0x10022355F
static bool cfg_livemode = false;          // 0x100223560
static bool cfg_fov_on = false;            // 0x100223561
static float cfg_fov = 1.2f;               // 0x100223564
static float cfg_mapX = 32.0f;             // 0x100223568
static float cfg_mapY = 2.0f;              // 0x10022356C
static float cfg_mapSize = 123.0f;         // 0x100223570
static float cfg_skillX = 11.0f;           // 0x100223574
static float cfg_skillY = 27.0f;           // 0x100223578
static int cfg_team = 0;                   // 0x10022357C
static bool 地图已手调 = false;            // 0x100223580（plist 里有 mapX/mapY/mapSize 就不自动回写）
static bool cfg_fov_probe = false;         // 0x100223590
static bool cfg_status = false;            // 左下角状态浮层开关（默认关，不自动弹出）

// 面板「微调」页的开关
static bool cfg_mapsize_on = false;        // 地图大小可调：开 → 用 mapSize；关 → 按屏幕自动适配
static bool cfg_mappos_on = false;         // 地图位置可调(XY)：开 → 用 mapX/mapY；关 → 按屏幕自动适配
static bool cfg_skillpos_on = false;       // CD 位置可调(XY)：开 → 用 skillX/skillY；关 → 内置默认 11/27
static bool cfg_mapalign = false;          // 小地图对齐辅助：画四角括号 + 中心十字
static bool cfg_recall = false;            // 敌方回城提示：屏幕顶部横幅
static bool cfg_camprobe = false;          // 相机探测（只在日志里输出，找小地图相机用）
static bool cfg_monsteroff_on = false;     // 野怪点位对齐微调
static float cfg_monsterOffX = 0.0f;       // 野怪点左/右偏移（逻辑点）
static float cfg_monsterOffY = 0.0f;       // 野怪点上/下偏移（逻辑点）
static float cfg_monsterScale = 1.0f;      // 野怪点位缩放校正（1.0 = 原始比例，以图心为基准）
static bool 有手调尺寸 = false;            // plist 里有 mapSize
static bool 位置已手调 = false;            // plist 里 mapX / mapY 都在

static const char* 设置路径 = "/var/mobile/Library/Preferences/com.map.settings.plist";

// ==================== 面板 ↔ 绘制层直连 ====================
// 以前面板写 plist、绘制层每秒读 plist。可这条路在真机上会断：plist 路径被沙盒或
// 越狱重定向吃掉时，读配置() 拿到 nil 直接 return，开关和滑条看着动了，
// 一个字节都没进绘制层 —— 这就是"点了没反应"的根。
// 面板和绘制层本来就在同一个进程里，没必要绕文件：直接改内存变量，
// 再往 NSUserDefaults 存一份（cfprefsd 走 XPC，不过文件系统，沙盒拦不住），重启后自动恢复。
struct SL键项 {
    const char* 键;
    void*       址;
    bool        浮点;
};

static SL键项 键表[] = {
    { "draw",            &cfg_draw,            false },
    { "line",            &cfg_line,            false },
    { "box",             &cfg_box,             false },
    { "avatar",          &cfg_avatar,          false },
    { "map",             &cfg_map,             false },
    { "skill",           &cfg_skill,           false },
    { "monster",         &cfg_monster,         false },
    { "health",          &cfg_health,          false },
    { "livemode",        &cfg_livemode,        false },
    { "fov_on",          &cfg_fov_on,          false },
    { "status",          &cfg_status,          false },
    { "recall",          &cfg_recall,          false },
    { "mapalign",        &cfg_mapalign,        false },
    { "camprobe",        &cfg_camprobe,        false },
    { "mapsize_on",      &cfg_mapsize_on,      false },
    { "mappos_on",       &cfg_mappos_on,       false },
    { "skillpos_on",     &cfg_skillpos_on,     false },
    { "monsteroff_on",   &cfg_monsteroff_on,   false },
    { "fov_probe",       &cfg_fov_probe,       false },
    { "fov",             &cfg_fov,             true  },
    { "mapX",            &cfg_mapX,            true  },
    { "mapY",            &cfg_mapY,            true  },
    { "mapSize",         &cfg_mapSize,         true  },
    { "skillX",          &cfg_skillX,          true  },
    { "skillY",          &cfg_skillY,          true  },
    { "monsterOffX",     &cfg_monsterOffX,     true  },
    { "monsterOffY",     &cfg_monsterOffY,     true  },
    { "monsterScalePct", &cfg_monsterScale,    true  },   // 面板存百分比，内存里是倍数
};

static SL键项* 找键(const char* 键) {
    const size_t 数 = sizeof(键表) / sizeof(键表[0]);
    for (size_t i = 0; i < 数; ++i)
        if (strcmp(键表[i].键, 键) == 0) return &键表[i];
    return nullptr;
}

// 百分比键：面板/日志用 100 表示原始大小，内存里用 1.0
static bool 是百分比键(const char* 键) { return strcmp(键, "monsterScalePct") == 0; }

static NSMutableSet<NSString*>* 桥键集(void) {
    static NSMutableSet* s = nil;
    if (!s) s = [NSMutableSet new];     // new 而不是 set：静态持有，不能是 autorelease
    return s;
}

// 键表里没有的（面板专属 UI 状态，比如悬浮球隐藏）走这张杂项表
static NSMutableDictionary<NSString*, id>* 桥杂项(void) {
    static NSMutableDictionary* d = nil;
    if (!d) d = [NSMutableDictionary new];
    return d;
}

static NSString* 桥存储键(const char* 键) {
    return [@"cfg2." stringByAppendingString:@(键)];
}

extern "C" {

void SLCfg写开关(const char* 键, bool 值) {
    SL键项* it = 找键(键);
    if (it) {
        if (it->浮点) *(float*)it->址 = 值 ? 1.0f : 0.0f;
        else *(bool*)it->址 = 值;
    } else {
        桥杂项()[@(键)] = @(值);
    }
    [[NSUserDefaults standardUserDefaults] setBool:值 forKey:桥存储键(键)];
    [桥键集() addObject:@(键)];
}

void SLCfg写数值(const char* 键, float 值) {
    SL键项* it = 找键(键);
    if (it && it->浮点) {
        *(float*)it->址 = 是百分比键(键) ? 值 / 100.0f : 值;
    } else if (it) {
        *(bool*)it->址 = 值 != 0.0f;
    } else {
        桥杂项()[@(键)] = @(值);
    }
    [[NSUserDefaults standardUserDefaults] setFloat:值 forKey:桥存储键(键)];
    [桥键集() addObject:@(键)];
}

bool SLCfg读开关(const char* 键) {
    SL键项* it = 找键(键);
    if (!it) {
        id v = 桥杂项()[@(键)];
        return v ? [v boolValue] : false;
    }
    return it->浮点 ? (*(float*)it->址 != 0.0f) : *(bool*)it->址;
}

float SLCfg读数值(const char* 键, float 缺省) {
    SL键项* it = 找键(键);
    if (!it || !it->浮点) {
        id v = 桥杂项()[@(键)];
        return v ? [v floatValue] : 缺省;
    }
    float v = *(float*)it->址;
    return 是百分比键(键) ? v * 100.0f : v;
}

bool SLCfg有键(const char* 键) {
    return [桥键集() containsObject:@(键)];
}

// 启动/读配置时调用：把 NSUserDefaults 里存的值灌回内存变量。
// 这一层是"开关能记住"的唯一保障 —— plist 读不到也不影响。
void SLCfg同步缓存(void) {
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    const size_t 数 = sizeof(键表) / sizeof(键表[0]);
    for (size_t i = 0; i < 数; ++i) {
        NSString* k = 桥存储键(键表[i].键);
        id v = [ud objectForKey:k];
        if (!v) continue;
        if (键表[i].浮点) {
            float f = [v floatValue];
            *(float*)键表[i].址 = 是百分比键(键表[i].键) ? f / 100.0f : f;
        } else {
            *(bool*)键表[i].址 = [v boolValue];
        }
        [桥键集() addObject:@(键表[i].键)];
    }
    NSArray* 杂项键 = [[ud dictionaryRepresentation] allKeys];
    for (NSString* k in 杂项键) {
        if (![k hasPrefix:@"cfg2."]) continue;
        NSString* 短 = [k substringFromIndex:5];
        if (找键([短 UTF8String])) continue;
        桥杂项()[短] = [ud objectForKey:k];
        [桥键集() addObject:短];
    }
}

}   // extern "C"

// 备用位置：App 沙盒自己的 Documents。
// 只认 /var/mobile/Library/Preferences 太脆：那条路径一旦读不到（无根越狱重定向 / 沙盒），
// 整份配置就等于不存在，读配置() 直接 return，所有开关都表现为"点了没反应"。
static NSString* 沙盒配置路径(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/com.map.settings.plist"];
}

// 两条路径都试，谁先读到用谁；返回 nil 表示哪都没有
static NSDictionary* 读配置文件(NSString** 用了哪条) {
    NSFileManager* fm = [NSFileManager defaultManager];
    NSString* 候选[2] = { @(设置路径), 沙盒配置路径() };
    for (int i = 0; i < 2; ++i) {
        NSString* p = 候选[i];
        if (![fm fileExistsAtPath:p]) continue;
        NSDictionary* d = [NSDictionary dictionaryWithContentsOfFile:p];
        if (d) {
            if (用了哪条) *用了哪条 = p;
            return d;
        }
    }
    if (用了哪条) *用了哪条 = nil;
    return nil;
}

// StartBooks 局部静态
static float 缩放系数 = 1.0f;              // 缩放 = 短边/物理短边
static double 上次读配置 = 0;              // 读配置节流
static double 上次找进程推进 = 0;          // 看门狗
static unsigned 找进程调用快照 = 0;
static double 上次对局统计 = 0;            // 5s 统计日志
static int 技能列系数[6] = {1, 2, 3, 4, 5, 6};  // StartBooks::系数表
// 技能/头像列的水平步长（逻辑点）。实测游戏原生记分板：头像直径 21.7pt、
// 中心间距 25pt、间隙约 3.3pt。原来 13pt < 图标 17pt，导致相邻列互相压叠。
// 取 20pt = 图标 17pt + 间隙 3pt，与原生间隙一致。
static const float 技能列步长 = 20.0f;
static const float 技能列基准 = 140.0f;          // 原 167-20=147，配合步长 13 起点为 160；改步长后回退 7pt 保持起点不变

// ==================== 基础工具 ====================

static inline bool IsValidAddr(uint64_t address) {
    return address > 0x100000000ULL && address < 0x3000000000ULL;
}

// 内核地址（KASLR 后仍然落在 0xfffffff0xxxxxxxx 一带）
static inline bool IsKernelAddr(uint64_t address) {
    return address >= 0xffff000000000000ULL;
}

static double 上次限流窗口 = 0;
static long 窗口读数 = 0;

// ==================== 目标进程读取（任务端口优先） ====================
// 关键：App 的 entitlements 里有 task_for_pid-allow（platform-application 生效），
// 因此 task_for_pid() 直接能拿到游戏的任务端口，vm_read_overwrite 就能跨进程读，
// 完全不需要走内核 proc 链表（那条路依赖 allproc 符号，已经是坏的了）。
static void 释放任务端口(void) {
    if (任务端口) {
        mach_port_deallocate(mach_task_self(), 任务端口);
        任务端口 = 0;
    }
    任务端口_pid = -1;
}

static mach_port_t 取任务端口(pid_t pid) {
    if (pid <= 1) return 0;
    if (任务端口 && 任务端口_pid == pid) return 任务端口;
    释放任务端口();
    mach_port_t 端口 = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &端口);
    if (kr != KERN_SUCCESS || !端口 || 端口 == (mach_port_t)-1) return 0;
    任务端口 = 端口;
    任务端口_pid = pid;
    return 任务端口;
}

// 跨进程读：有任务端口就走 vm_read_overwrite，失败再退回内核页表路线
static bool 目标读(pid_t pid, uint64_t 地址, void* 输出, size_t 大小) {
    mach_port_t 端口 = 取任务端口(pid);
    if (端口) {
        vm_size_t 读出 = 0;
        if (vm_read_overwrite(端口, (vm_address_t)地址, (vm_size_t)大小,
                              (vm_address_t)输出, &读出) == KERN_SUCCESS && 读出 == (vm_size_t)大小)
            return true;
    }
    return exploit_mach_readbuf(pid, 地址, 输出, 大小);
}

bool readMemory(uint64_t address, void* buffer, size_t size) {
    if (!IsValidAddr(address) || size == 0 || 游戏pid <= 0) return false;
    double now = CACurrentMediaTime();
    if (now - 上次限流窗口 > 0.1) {
        上次限流窗口 = now;
        窗口读数 = 0;
    }
    if (++窗口读数 > 8000) {   // 0.1 秒内最多 8000 次读取
        读限流计数++;
        return false;
    }
    读总数++;
    char* dst = (char*)buffer;
    uint64_t src = address;
    size_t remain = size;
    while (remain > 0) {
        uint64_t 页内 = 4096 - (src & 0xFFF);
        uint64_t chunk = remain < 页内 ? remain : 页内;
        uint64_t step = chunk > 0x100 ? 0x100 : chunk;   // 单次最多 256 字节
        if (!step) return false;
        if (!目标读(游戏pid, src, dst, step)) return false;
        dst += step;
        src += step;
        remain -= step;
    }
    return true;
}

// 前向声明
static float 阵营符号(unsigned 阵营);
static void 画CD底(float cx, float cy, float 半径);
static float clamp01(float v);

template<typename T> T vm_read(uint64_t address) {
    T data{};
    readMemory(address, &data, sizeof(T));
    return data;
}

bool writeMemory(uint64_t address, const void* data, size_t size) {
    if (!IsValidAddr(address) || !size) return false;
    if (!任务端口 || vm_write(任务端口, address, (vm_offset_t)data, (vm_size_t)size) != KERN_SUCCESS) {
        if (游戏pid <= 1) return false;
        return exploit_mach_kwritebuf(游戏pid, address, data, size);
    }
    return true;
}

// 内核指针（PAC 解签）
#define BIT(b) (1ULL << (b))
uint64_t kread_ptr(uint64_t va) {
    uint64_t v = kread64(va);
    if (v & BIT(55)) return v | kconstant(pointer_mask);
    return v & ~kconstant(pointer_mask);
}

// ==================== 日志 ====================

static char 日志环[12][240];
static int 日志环写 = 0;
static int 日志环量 = 0;
static std::atomic_flag 日志锁 = ATOMIC_FLAG_INIT;
static FILE* 日志文件 = nullptr;
static FILE* 日志文件2 = nullptr;
static bool 日志可用 = false;
static char 日志路径串[256] = {0};

// 开日志：把所有能打开的候选路径都打开（不止第一个），沙盒里哪条通就落哪条。
// 以前只试 /var/mobile/Documents（沙盒外，TrollStore 常被拒），失败了才退 HOME，
// 结果诊断日志根本没落盘 —— 让用户找半天找不到文件，问题也就无从定位。
static void 初始化日志(void) {
  @autoreleasepool {
    NSMutableArray<NSString*>* 候选 = [NSMutableArray array];
    NSArray* 文档 = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (文档.count > 0) [候选 addObject:[文档[0] stringByAppendingPathComponent:@"ab_draw.log"]];
    const char* home = getenv("HOME");
    if (home) [候选 addObject:[NSString stringWithFormat:@"%s/Documents/ab_draw.log", home]];
    [候选 addObject:@"/var/mobile/Documents/ab_draw.log"];
    [候选 addObject:@"/tmp/ab_draw.log"];

    NSMutableSet<NSString*>* 已开 = [NSMutableSet set];
    for (NSString* p in 候选) {
        NSString* 键 = [p stringByStandardizingPath];
        if ([已开 containsObject:键]) continue;
        [已开 addObject:键];
        FILE* f = fopen(p.UTF8String, "a");
        if (!f) continue;
        if (!日志文件) {
            日志文件 = f;
            日志可用 = true;
            snprintf(日志路径串, sizeof(日志路径串), "%s", p.UTF8String);
        } else if (!日志文件2) {
            日志文件2 = f;
        } else {
            fclose(f);
        }
    }
  }
}

static void 日志入环(const char* line) {
    while (std::atomic_flag_test_and_set_explicit(&日志锁, std::memory_order_acquire)) {}
    int slot = 日志环写;
    strncpy(日志环[slot], line, 239);
    日志环[slot][239] = 0;
    日志环写 = (日志环写 + 1) % 12;
    if (日志环量 < 12) 日志环量++;
    std::atomic_flag_clear_explicit(&日志锁, std::memory_order_release);
}

void 日志(const char* fmt, ...) {
    static bool 日志初始化 = false;
    va_list va;
    va_start(va, fmt);
    if (!日志初始化) {
        日志初始化 = true;
        初始化日志();
    }
    char line[600];
    vsnprintf(line, sizeof(line), fmt, va);
    va_end(va);
    日志入环(line);
    KernelLogLine(line);
    if (日志文件 || 日志文件2) {
        time_t now = time(nullptr);
        struct tm tmv;
        localtime_r(&now, &tmv);
        if (日志文件) {
            fprintf(日志文件, "%02d:%02d:%02d %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, line);
            fflush(日志文件);
        }
        if (日志文件2) {
            fprintf(日志文件2, "%02d:%02d:%02d %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, line);
            fflush(日志文件2);
        }
    }
}

// ==================== 绘制原语 ====================

static ImDrawList* 画布() { return BBZGUI::GetBackgroundDrawList(); }

static void 画框(ImU32 color, float x, float y, float w, float h, float thick) {
    ImVec2 a(x, y), b(x + w, y + h);
    画布()->AddRect(a, b, color, 0.0f, 0, thick);
}

// 内核自检：kernel base 的 Mach-O magic 必须是 0xFEEDFACF，否则 kread 根本没通
static void 内核自检() {
    uint64_t 基 = gSystemInfo.kernelConstant.base;
    uint64_t 静态基 = gSystemInfo.kernelConstant.staticBase;
    uint64_t 偏移 = gSystemInfo.kernelConstant.slide;
    if (!IsKernelAddr(基)) 基 = 静态基 + 偏移;
    uint64_t allproc = gSystemInfo.kernelSymbol.allproc;
    uint32_t magic = IsKernelAddr(基) ? kread32(基) : 0;
    日志("内核自检: base=0x%llx staticBase=0x%llx slide=0x%llx allproc=0x%llx magic=0x%08x %s",
         基, 静态基, 偏移, allproc, magic,
         (magic == 0xFEEDFACF) ? "✅ kread 正常" : "❌ kread 异常/符号缺失");
    日志("内核偏移: proc.next=0x%x proc.prev=0x%x proc.pid=0x%x proc.task=0x%x proc.textvp=0x%x proc.size=0x%x",
         gSystemInfo.kernelStruct.proc.list_next,
         gSystemInfo.kernelStruct.proc.list_prev,
         gSystemInfo.kernelStruct.proc.pid,
         gSystemInfo.kernelStruct.proc.task,
         gSystemInfo.kernelStruct.proc.textvp,
         gSystemInfo.kernelStruct.proc.struct_size);
    uint64_t allproc符号 = gSystemInfo.kernelSymbol.allproc;
    uint64_t allproc头 = IsKernelAddr(allproc符号) ? kread64(allproc符号) : 0;
    uint64_t 自身proc = kfd_get_current_proc();
    日志("内核链表: allproc=0x%llx lh_first=0x%llx current_proc=0x%llx",
         allproc符号, allproc头, 自身proc);
}

static void 画实心矩形(ImU32 color, float x, float y, float w, float h) {
    画布()->AddRectFilled(ImVec2(x, y), ImVec2(x + w, y + h), color, 0.0f, 0);
}

static void 画线(ImU32 color, float x1, float y1, float x2, float y2, float thick) {
    画布()->AddLine(ImVec2(x1, y1), ImVec2(x2, y2), color, thick);
}

static void 画实心圆(ImU32 color, float cx, float cy, float r) {
    画布()->AddCircleFilled(ImVec2(cx, cy), r, color, 0);
}

// 多段圆环（PrimReserve 三角带）：半径±线宽/2，从起始角扫弧角
static void 画圆环(ImU32 color, float cx, float cy, float 半径, float 线宽, float 起始角, float 弧角) {
    if (弧角 <= 0.0005f || 线宽 <= 0.0f || 半径 <= 0.0f) return;
    if (弧角 > 6.2832f) 弧角 = 6.2832f;
    float r外 = 半径 + 线宽 * 0.5f;
    float r内 = 半径 - 线宽 * 0.5f;
    if (r内 < 0.0f) r内 = 0.0f;
    int seg = (int)(弧角 / 6.2832f * 120.0f);
    if (seg < 10) seg = 10;
    if (seg > 168) seg = 168;
    ImDrawList* dl = 画布();
    dl->PrimReserve(6 * seg, 2 * (seg + 1));
    ImVec2 uv = BBZGUI::GetFontTexUvWhitePixel();
    unsigned 索引基 = dl->_VtxCurrentIdx;
    for (int i = 0; i <= seg; ++i) {
        float ang = 起始角 + 弧角 * (float)i / (float)seg;
        float c = cosf(ang), s = sinf(ang);
        dl->PrimWriteVtx(ImVec2(cx + c * r外, cy + s * r外), uv, color);
        dl->PrimWriteVtx(ImVec2(cx + c * r内, cy + s * r内), uv, color);
    }
    for (int j = 0; j < seg; ++j) {
        unsigned short i0 = (unsigned short)(索引基 + 2 * j);
        dl->PrimWriteIdx(i0);
        dl->PrimWriteIdx(i0 + 2);
        dl->PrimWriteIdx(i0 + 3);
        dl->PrimWriteIdx(i0);
        dl->PrimWriteIdx(i0 + 3);
        dl->PrimWriteIdx(i0 + 1);
    }
}

static void 画圆(ImU32 color, float cx, float cy, float r, float thick) {
    if (thick > 2.5f) { 画圆环(color, cx, cy, r, thick, 0.0f, 6.2832f); return; }
    画布()->AddCircle(ImVec2(cx, cy), r, color, 0, thick);
}

// 血环/进度环：比例 0..1，从正上方顺时针
static void 画血环(ImU32 color, float cx, float cy, float 半径, float 比例, float 线宽) {
    if (比例 < 0.0f) 比例 = 0.0f;
    if (比例 > 1.0f) 比例 = 1.0f;
    if (比例 > 0.002f)
        画圆环(color, cx, cy, 半径, 线宽, -1.5707963f, 比例 * 6.2832f);
}

// 四角框：8 段短角线（横 1/6 竖 1/9）
static void 画角框(ImU32 color, float x, float y, float w, float h, float thick) {
    float dx = w / 6.0f, dy = h / 9.0f;
    画线(color, x, y, x + dx, y, thick);
    画线(color, x, y, x, y + dy, thick);
    画线(color, x + w - dx, y, x + w, y, thick);
    画线(color, x + w, y, x + w, y + dy, thick);
    画线(color, x, y + h, x + dx, y + h, thick);
    画线(color, x, y + h, x, y + h - dy, thick);
    画线(color, x + w - dx, y + h, x + w, y + h, thick);
    画线(color, x + w, y + h, x + w, y + h - dy, thick);
}

static void 画文字(float x, float y, const char* text, ImU32 color, bool 居中 = true, bool 瞄边 = false, float 尺寸 = 0.0f) {
    if (!text || !*text) return;
    ImFont* font = BBZGUI::GetFont();
    // 尺寸 传 0 时 AddTextX 内部会退回当前字号绘制，但 CalcTextSizeA(0) 返回 (0,0)：
    // 于是「居中」把量出来的 0 减掉，文字实际是从中心点往右下角画出去的。
    // CD 读秒、血量、野怪倒计时全部踩这个坑，统一先取实际字号再量尺寸。
    float 实际尺寸 = 尺寸 > 0.0f ? 尺寸 : BBZGUI::GetFontSize();
    if (实际尺寸 <= 0.0f) 实际尺寸 = font->FontSize;
    ImVec2 ts = font->CalcTextSizeA(实际尺寸, 3.4028e38f, 0.0f, text);
    if (居中) x -= ts.x * 0.5f;
    y -= ts.y * 0.5f;
    ImDrawList* dl = 画布();
    if (瞄边) {
        dl->AddTextX(ImVec2(x + 1, y + 1), 0xFF000000, 实际尺寸, text);
        dl->AddTextX(ImVec2(x - 1, y - 1), 0xFF000000, 实际尺寸, text);
    }
    dl->AddTextX(ImVec2(x, y), color, 实际尺寸, text);
}

// 图标：有 MTLTexture 用 AddImageRounded，否则占位圆 + 文字
static void 画图标(id 纹理, ImU32 color, const char* 编号, float x, float y, float 大小) {
    float half = 大小 * 0.5f;
    if (纹理) {
        画布()->AddImageRounded((ImTextureID)(__bridge void*)纹理,
                                ImVec2(x, y), ImVec2(x + 大小, y + 大小),
                                ImVec2(0, 0), ImVec2(1, 1),
                                0xFFFFFFFF, half, 0);
    } else {
        if (color) 画实心圆(color, x + half, y + half, half);
        画布()->AddCircle(ImVec2(x + half, y + half), half, 0x40FFFFFF, 0, 1.0f);
        if (编号 && *编号) 画文字(x + half, y + half, 编号, 0xC0FFFFFF, true, false);
    }
}

// ==================== 配置 ====================

static bool 读布尔(NSDictionary* cfg, NSString* key) {
    id v = [cfg objectForKey:key];
    return v ? [v boolValue] : false;
}
static float 读浮点(NSDictionary* cfg, NSString* key, float 缺省) {
    id v = [cfg objectForKey:key];
    return v ? [v floatValue] : 缺省;
}


static void 读配置() {
    NSString* 用了 = nil;
    NSMutableDictionary* 可变 = [读配置文件(&用了) mutableCopy];
    if (!可变) {
        // 一条都读不到：把两条路径的实际情况记下来（有几次就够定位了）
        static double 上次没读到 = 0;
        double 现在 = CACurrentMediaTime();
        if (现在 - 上次没读到 > 5.0) {
            上次没读到 = 现在;
            NSFileManager* fm = [NSFileManager defaultManager];
            const char* 主 = 设置路径;
            char 细节[256] = {0};
            struct stat st;
            bool 主有 = stat(主, &st) == 0;
            snprintf(细节, sizeof(细节), "主路径存在=%d 大小=%lld 沙盒存在=%d",
                     主有 ? 1 : 0, 主有 ? (long long)st.st_size : -1LL,
                     [fm fileExistsAtPath:沙盒配置路径()] ? 1 : 0);
            日志("配置读不到 %s", 细节);
        }
        // plist 读不到不等于没配置：面板直连写进 NSUserDefaults 的那份还在
        SLCfg同步缓存();
        // 读不到 plist 的分支同样要做一次几何复位（这台设备走的就是这条分支）
        {
            NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
            if ([[ud objectForKey:@"cfg2.geomVer"] intValue] < 3) {
                [ud setInteger:3 forKey:@"cfg2.geomVer"];
                SLCfg写开关("mapsize_on", false);
                SLCfg写开关("mappos_on", false);
                SLCfg写数值("monsterScalePct", 100.0f);
                SLCfg写开关("monsteroff_on", false);
                SLCfg写数值("monsterOffX", 0.0f);
                SLCfg写数值("monsterOffY", 0.0f);
                地图已手调 = false;
                有手调尺寸 = false;
                位置已手调 = false;
                日志("几何复位 v24（无 plist 分支）：位置/尺寸回自动、小图比例回100%%、野怪平移归零");
            }
        }
        return;
    }

    // v18 一次性迁移：以前自动适配写回的 mapX/mapY/mapSize 会被下一帧当成"用户手调"，
    // 于是自动适配第一次写就被永久锁死 —— 这就是"自动对齐改了没反应"的真正原因。
    // 这里把两个开关复位成自动，并打上版本号，之后永远按开关走。
    {
        id 版本 = [可变 objectForKey:@"mapAutoVer"];
        if (!版本 || [版本 intValue] < 2) {
            可变[@"mapsize_on"] = @NO;
            可变[@"mappos_on"] = @NO;
            可变[@"mapAutoVer"] = @2;
            [可变 writeToFile:用了 atomically:YES];
        }
    }
    NSDictionary* cfg = 可变;
    {
        id raw = [cfg objectForKey:@"draw"];
        cfg_draw = raw ? [raw boolValue] : true;   // 没有 draw 键默认开
    }
    cfg_line      = 读布尔(cfg, @"line");
    cfg_box       = 读布尔(cfg, @"box");
    cfg_avatar    = 读布尔(cfg, @"avatar");
    cfg_map       = 读布尔(cfg, @"map");
    cfg_skill     = 读布尔(cfg, @"skill");
    cfg_monster   = 读布尔(cfg, @"monster");
    cfg_health    = 读布尔(cfg, @"health");
    cfg_livemode  = 读布尔(cfg, @"livemode");
    cfg_fov_on    = 读布尔(cfg, @"fov_on");
    cfg_status    = 读布尔(cfg, @"status");
    cfg_fov       = 读浮点(cfg, @"fov", 1.2f);
    cfg_mapX      = 读浮点(cfg, @"mapX", 32.0f);
    cfg_mapY      = 读浮点(cfg, @"mapY", 2.0f);
    cfg_mapSize   = 读浮点(cfg, @"mapSize", 123.0f);
    cfg_skillX    = 读浮点(cfg, @"skillX", 11.0f);
    cfg_skillY    = 读浮点(cfg, @"skillY", 27.0f);
    cfg_team      = (int)读浮点(cfg, @"team", 0.0f);

    // 用户手动调过地图位置 / 尺寸 → 停止对应项的自适配回写
    // mapAuto=1 表示这些值是自动适配自己写进去的，不能算手调（否则自动适配把自己锁死）
    bool 自动写的 = 读布尔(cfg, @"mapAuto");
    有手调尺寸 = [cfg objectForKey:@"mapSize"] != nil && !自动写的;
    bool 有手调位置 = [cfg objectForKey:@"mapX"] != nil && [cfg objectForKey:@"mapY"] != nil && !自动写的;

    // 面板「微调」页的开关。缺键时按老行为推断（有手调值就当开关是开的），
    // 老配置升级上来不会突然跳位置。
    {
        id v = [cfg objectForKey:@"mapsize_on"];
        cfg_mapsize_on = v ? [v boolValue] : 有手调尺寸;
    }
    {
        id v = [cfg objectForKey:@"mappos_on"];
        cfg_mappos_on = v ? [v boolValue] : 有手调位置;
    }
    {
        id v = [cfg objectForKey:@"skillpos_on"];
        cfg_skillpos_on = v ? [v boolValue] : ([cfg objectForKey:@"skillX"] != nil || [cfg objectForKey:@"skillY"] != nil);
    }
    // 开关关掉时，即使 plist 里还留着旧位置也不认——回到自动/默认，避免"开关关着却还在生效"。
    位置已手调 = 有手调位置 && cfg_mappos_on;
    地图已手调 = 有手调尺寸 || 位置已手调;
    cfg_monsteroff_on = 读布尔(cfg, @"monsteroff_on");
    cfg_mapalign = 读布尔(cfg, @"mapalign");
    cfg_recall = 读布尔(cfg, @"recall");
    cfg_camprobe = 读布尔(cfg, @"camprobe");
    cfg_monsterOffX   = 读浮点(cfg, @"monsterOffX", 0.0f);
    cfg_monsterOffY   = 读浮点(cfg, @"monsterOffY", 0.0f);
    if (cfg_monsterOffX < -80.0f) cfg_monsterOffX = -80.0f;
    if (cfg_monsterOffX > 80.0f) cfg_monsterOffX = 80.0f;
    if (cfg_monsterOffY < -80.0f) cfg_monsterOffY = -80.0f;
    if (cfg_monsterOffY > 80.0f) cfg_monsterOffY = 80.0f;
    cfg_monsterScale = 读浮点(cfg, @"monsterScalePct", 100.0f) / 100.0f;
    if (cfg_monsterScale < 0.60f) cfg_monsterScale = 0.60f;
    if (cfg_monsterScale > 1.60f) cfg_monsterScale = 1.60f;
    // fov_addr 支持 "0x..." 字符串或数字
    id fa = [cfg objectForKey:@"fov_addr"];
    if (fa) {
        if ([fa isKindOfClass:[NSString class]])
            视距地址 = strtoull([fa UTF8String], nullptr, 16);
        else if ([fa isKindOfClass:[NSNumber class]])
            视距地址 = [fa unsignedLongLongValue];
        else
            视距地址 = 0;
    }
    cfg_fov_probe = 读布尔(cfg, @"fov_probe");
    视距是度 = 读布尔(cfg, @"fov_deg");

    if (cfg_mapSize < 20.0f) cfg_mapSize = 20.0f;
    if (cfg_mapSize > 999.0f) cfg_mapSize = 999.0f;
    if (cfg_fov < 0.1f) cfg_fov = 0.1f;
    if (cfg_fov > 10.0f) cfg_fov = 10.0f;

    // plist 只是"旧配置兼容"，面板直连（NSUserDefaults）那份优先级更高，最后灌进来覆盖。
    SLCfg同步缓存();

    // v24 一次性复位（geomVer 1 → 3）：把三处「旧版残留 + 手动调歪」的脏数据一次清干净。
    //  ① 地图位置/尺寸锁死：配置里 mapX=58.26、mappos_on=true，折算成设备像素是 175，
    //     而原生小地图左边界是 166 —— 整块右移 9px，左边缩进、右边溢出，就是「左右两边差了一点」。
    //     复位成自动 → 58.3 变 55.3（166px），右边 574px，与原生完全重合（高度/尺寸本来就对）。
    //  ② 小图比例 107.6%：这一条把英雄/野怪点位整体放大 7.6%，光看点位会以为「世界半程」错了。
    //     复位成 100%，比例交给 世界半程 一个常量负责，滑条只留作手动微调。
    //  ③ 野怪点位平移 monsteroff_on=true / OffX=1.32：同上，先归零。
    // plist 里那份也要一起改，否则下次启动又读回 YES。
    {
        NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
        if ([[ud objectForKey:@"cfg2.geomVer"] intValue] < 3) {
            [ud setInteger:3 forKey:@"cfg2.geomVer"];
            cfg_mapsize_on = false;
            cfg_mappos_on = false;
            SLCfg写开关("mapsize_on", false);
            SLCfg写开关("mappos_on", false);
            SLCfg写数值("monsterScalePct", 100.0f);
            cfg_monsterScale = 1.0f;
            SLCfg写开关("monsteroff_on", false);
            SLCfg写数值("monsterOffX", 0.0f);
            SLCfg写数值("monsterOffY", 0.0f);
            cfg_monsterOffX = 0.0f;
            cfg_monsterOffY = 0.0f;
            地图已手调 = false;
            有手调尺寸 = false;
            位置已手调 = false;
            if (用了) {
                可变[@"mapsize_on"] = @NO;
                可变[@"mappos_on"] = @NO;
                可变[@"monsteroff_on"] = @NO;
                可变[@"monsterScalePct"] = @100.0;
                可变[@"monsterOffX"] = @0.0;
                [可变 writeToFile:用了 atomically:YES];
            }
            日志("几何复位 v24：位置 58.3→55.3（左移9px）、尺寸回自动、小图比例回100%%、野怪平移归零");
        }
    }
    // 「CD 位置可调」关着的时候，就算缓存里还留着旧坐标也回到内置默认，避免"开关关着却还在偏移"
    if (!cfg_skillpos_on) {
        cfg_skillX = 11.0f;
        cfg_skillY = 27.0f;
    }

    // 配置快照：5 秒一次，把「用了哪条路径 + 关键开关 + 地图三值」写进日志。
    // 以后再出现"开关点了没反应"，先看这一行就够了，不用再猜。
    static double 上次快照 = 0;
    double 快照时 = CACurrentMediaTime();
    if (快照时 - 上次快照 > 5.0) {
        上次快照 = 快照时;
        const char* 路径 = 用了 ? [用了 UTF8String] : "(plist 未读到, 走本地缓存)";
        日志("配置 %s draw=%d map=%d monster=%d align=%d recall=%d 尺寸开关=%d 位置开关=%d 尺寸%.1f X%.1f Y%.1f",
             路径, cfg_draw ? 1 : 0, cfg_map ? 1 : 0, cfg_monster ? 1 : 0,
             cfg_mapalign ? 1 : 0, cfg_recall ? 1 : 0,
             cfg_mapsize_on ? 1 : 0, cfg_mappos_on ? 1 : 0,
             cfg_mapSize, cfg_mapX, cfg_mapY);
    }
}

// 小地图自适配回写：参数变化 ≥1.0 才写 plist
// 写尺寸/写位置分开控制：面板手动定了哪一项，自动适配就别把人家拖过的值冲掉。
static void 回写地图配置(float mapX, float mapY, float mapSize, bool 写尺寸, bool 写位置) {
    static double 上次 = 0;
    double now = CACurrentMediaTime();
    if (now - 上次 < 3.0) return;
    上次 = now;
    NSString* 读到 = nil;
    NSMutableDictionary* dict = [读配置文件(&读到) mutableCopy];
    if (!dict) { dict = [NSMutableDictionary dictionary]; 读到 = @(设置路径); }
    float 旧X = [dict objectForKey:@"mapX"] ? [[dict objectForKey:@"mapX"] floatValue] : -1e30f;
    float 旧Y = [dict objectForKey:@"mapY"] ? [[dict objectForKey:@"mapY"] floatValue] : -1e30f;
    float 旧S = [dict objectForKey:@"mapSize"] ? [[dict objectForKey:@"mapSize"] floatValue] : -1e30f;
    bool 尺寸变了 = 写尺寸 && fabsf(旧S - mapSize) >= 1.0f;
    bool 位置变了 = 写位置 && (fabsf(旧X - mapX) >= 1.0f || fabsf(旧Y - mapY) >= 1.0f);
    if (!位置变了 && !尺寸变了) return;
    if (写位置) {
        dict[@"mapX"] = @(roundf(mapX * 10.0f) / 10.0f);
        dict[@"mapY"] = @(roundf(mapY * 10.0f) / 10.0f);
    }
    if (写尺寸) dict[@"mapSize"] = @(roundf(mapSize * 10.0f) / 10.0f);
    dict[@"mapAuto"] = @YES;      // 标记：这几个值是自动适配写的，不是手调
    // 两条路径都写：读到哪条就写回哪条，另一条（沙盒内）也补一份，
    // 这样万一主路径读写被系统拦掉，沙盒那份还能被下一帧读到。
    BOOL ok = [dict writeToFile:读到 atomically:YES];
    NSString* 沙盒 = 沙盒配置路径();
    if (![读到 isEqualToString:沙盒]) [dict writeToFile:沙盒 atomically:YES];
    if (写位置) { cfg_mapX = mapX; cfg_mapY = mapY; }
    if (写尺寸) cfg_mapSize = mapSize;
    if (ok) {
        // 自动写回不算手调，两个标志保持 false，下一帧继续自动跟屏幕走
        有手调尺寸 = false;
        位置已手调 = false;
        地图已手调 = false;
    }
    日志("小地图自适配 %.1f/%.1f/%.1f 写尺寸=%d 写位置=%d 回写=%d 路径=%s",
         mapX, mapY, mapSize, 写尺寸 ? 1 : 0, 写位置 ? 1 : 0, ok ? 1 : 0, [读到 UTF8String]);
}

// ==================== 进程查找 ====================

static bool 名字像游戏(const char* 名字) {
    if (!名字 || !*名字) return false;
    for (int i = 0; i < 7; ++i) {
        if (!strcasecmp(名字, SDK::名候选[i])) return true;
        if (strcasestr(名字, SDK::名候选[i])) return true;
    }
    return false;
}

static bool 路径像游戏(const char* 路径) {
    if (!路径 || !*路径) return false;
    if (strstr(路径, "smoba")) return true;
    return strstr(路径, "王者") || strstr(路径, "wzry");
}

// sysctl KINFO_PROC 精确匹配进程名
static pid_t sysctl精确找pid(const char* 名字) {
    if (!名字 || !*名字) return -1;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, nullptr, &size, nullptr, 0) || !size) return -1;
    void* buf = malloc(size);
    if (!buf) return -1;
    if (sysctl(mib, 4, buf, &size, nullptr, 0)) { free(buf); return -1; }
    size_t count = size / 0x288;
    pid_t found = -1;
    for (size_t i = 0; i < count; ++i) {
        // kinfo_proc: kp_proc.p_pid @40, kp_proc.p_comm @243（老内核布局）
        if (!strcmp((const char*)buf + 648 * i + 243, 名字)) {
            found = *(pid_t*)((char*)buf + 648 * i + 40);
            break;
        }
    }
    free(buf);
    return found;
}

// sysctl 模糊匹配（名候选）
static pid_t sysctl模糊找pid() {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, nullptr, &size, nullptr, 0) || !size) return -1;
    char* buf = (char*)malloc(size);
    if (!buf) return -1;
    if (sysctl(mib, 4, buf, &size, nullptr, 0)) { free(buf); return -1; }
    pid_t found = -1;
    size_t count = size / 0x288;
    for (size_t i = 0; i < count; ++i) {
        if (名字像游戏(buf + 648 * i + 243)) {
            found = *(pid_t*)(buf + 648 * i + 40);
            break;
        }
    }
    free(buf);
    return found;
}

// 内核遍历找游戏 pid（按 textvp->v_name 匹配，双向走，不依赖 allproc 符号）
// 注意：一律用 struct system_info 的具名字段，禁止再用 ((u64*)&gSystemInfo)[N] 下标——
// 那套下标是按旧版 struct 布局算的，与当前 info.h 完全错位。
static pid_t 内核找pid() {
    const uint32_t 下个 = gSystemInfo.kernelStruct.proc.list_next;
    const uint32_t 上个 = gSystemInfo.kernelStruct.proc.list_prev;
    const uint32_t pid偏移 = gSystemInfo.kernelStruct.proc.pid;
    const uint32_t textvp偏移 = gSystemInfo.kernelStruct.proc.textvp;
    char 名字[64];

    auto 试一个 = [&](uint64_t p) -> pid_t {
        int pid = kread32(p + pid偏移);
        if (pid <= 1) return -1;
        uint64_t textvp = kread_ptr(p + textvp偏移);
        if (!IsKernelAddr(textvp)) return -1;
        uint64_t 名字指针 = kread_ptr(textvp + 184);
        if (!IsKernelAddr(名字指针)) return -1;
        memset(名字, 0, sizeof(名字));
        if (!exploit_kreadbuf(名字指针, 名字, 63)) return -1;
        if (!名字像游戏(名字)) return -1;
        日志("内核(%s): 名字命中 pid=%d 名字=%s", "遍历", pid, 名字);
        return pid;
    };
    auto 双向走 = [&](uint64_t 起点, const char* 来源) -> pid_t {
        if (!IsKernelAddr(起点)) {
            日志("内核(%s): 起点无效 0x%llx", 来源, 起点);
            return -1;
        }
        pid_t r = 试一个(起点);
        if (r > 0) return r;
        uint64_t p = kread_ptr(起点 + 下个);
        for (int i = 0; i < 2048 && IsKernelAddr(p); ++i) {
            r = 试一个(p);
            if (r > 0) return r;
            p = kread_ptr(p + 下个);
        }
        p = kread_ptr(起点 + 上个);
        for (int i = 0; i < 2048 && IsKernelAddr(p); ++i) {
            r = 试一个(p);
            if (r > 0) return r;
            p = kread_ptr(p + 上个);
        }
        return -1;
    };

    pid_t r = 双向走(kfd_get_current_proc(), "current_proc");
    if (r > 0) return r;
    uint64_t allproc = gSystemInfo.kernelSymbol.allproc;
    if (IsKernelAddr(allproc)) {
        pid_t r2 = 双向走(kread_ptr(allproc), "allproc");
        if (r2 > 0) return r2;
    }
    日志("内核: current_proc/allproc 双向遍历都没命中游戏");
    return -1;
}

// 列一遍系统进程名（排查日志）
static void 列进程表() {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, nullptr, &size, nullptr, 0) || !size) return;
    char* buf = (char*)malloc(size);
    if (!buf) return;
    if (sysctl(mib, 4, buf, &size, nullptr, 0)) { free(buf); return; }
    char 表[4000] = {0};
    int 写 = 0, 计 = 0;
    size_t count = size / 0x288;
    for (size_t i = 0; i < count; ++i) {
        const char* 名 = buf + 648 * i + 243;
        int pid = *(int*)(buf + 648 * i + 40);
        if (pid > 1 && *名 && pid != getpid()) {
            计++;
            int n = snprintf(表 + 写, sizeof(表) - 写, "%d=%s ", pid, 名);
            if (n > 0 && 写 + n < (int)sizeof(表) - 8) 写 += n;
        }
    }
    日志("进程表（共 %d 个）: %s", 计, 表);
    free(buf);
}

// ---- 模块基址：任务端口路线 / 内核路线 ----

// 任务/内核统一读：任务端口优先（内部有缓存），拿不到端口再退回内核页表路线
static bool 任务或内核读(pid_t pid, mach_port_t 任务, uint64_t 地址, void* 输出, size_t 大小) {
    (void)任务;
    return 目标读(pid, 地址, 输出, 大小);
}

// 解析 dyld_all_image_infos 头（version@0, count@4, infoArray@8）
static bool 读镜像头(pid_t pid, mach_port_t 任务, uint64_t 头地址,
                     uint64_t* 数组址, uint32_t* 数量, char* 主程序路径) {
    struct { uint32_t 版本; uint32_t 数量; uint64_t 数组; } 头 = {0, 0, 0};
    if (!任务或内核读(pid, 任务, 头地址, &头, 24)) return false;
    if (!头.版本 || 头.版本 > 0x20) return false;
    if (!头.数量 || 头.数量 > 0xFA0 || !IsValidAddr(头.数组)) return false;
    *数组址 = 头.数组;
    *数量 = 头.数量;
    if (主程序路径) {
        // 第 0 项是主程序
        struct { uint64_t 加载址; uint64_t 路径址; uint64_t 日期; } 项 = {0, 0, 0};
        if (任务或内核读(pid, 任务, 头.数组, &项, 24) && 项.路径址) {
            char 路径[256] = {0};
            if (任务或内核读(pid, 任务, 项.路径址, 路径, 255))
                strncpy(主程序路径, 路径, 255);
        }
    }
    return true;
}

// 枚举镜像列表，找 UnityFramework 基址
static uint64_t 枚举镜像(int pid, mach_port_t 任务, uint64_t all_image_info,
                         char* 主程序名, char* 主程序路径) {
    uint64_t 数组址 = 0;
    uint32_t 数量 = 0;
    if (!读镜像头(pid, 任务, all_image_info, &数组址, &数量, 主程序路径)) return 0;
    if (主程序名 && 主程序路径 && *主程序路径) {
        char* slash = strrchr(主程序路径, '/');
        strncpy(主程序名, slash ? slash + 1 : 主程序路径, 63);
    }
    for (uint32_t i = 0; i < 数量; ++i) {
        struct { uint64_t 加载址; uint64_t 路径址; uint64_t 日期; } 项 = {0, 0, 0};
        if (!任务或内核读(pid, 任务, 数组址 + 24ULL * i, &项, 24)) continue;
        if (!项.加载址 || !项.路径址) continue;
        char 路径[256] = {0};
        if (任务或内核读(pid, 任务, 项.路径址, 路径, 255) && strstr(路径, "UnityFramework"))
            return 项.加载址;
    }
    return 0;
}

// 走任务端口路线：task_for_pid → TASK_DYLD_INFO → 枚举镜像
static uint64_t 走任务端口(int pid, mach_port_t* 端口出, char* 主程序名, char* 主程序路径) {
    mach_port_t 任务 = 取任务端口(pid);
    if (!任务) {
        日志("task_for_pid(%d) 失败 → 改走内核路线", pid);
        return 0;
    }
    struct task_dyld_info dyld;
    memset(&dyld, 0, sizeof(dyld));
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    if (task_info(任务, TASK_DYLD_INFO, (task_info_t)&dyld, &cnt) != KERN_SUCCESS
        || !dyld.all_image_info_addr) {
        日志("TASK_DYLD_INFO 拿不到 → 改走内核路线");
        return 0;
    }
    uint64_t 基址 = 枚举镜像(pid, 任务, dyld.all_image_info_addr, 主程序名, 主程序路径);
    if (基址 && 端口出) *端口出 = 任务;
    if (基址) 日志("task_for_pid(%d) 成功（任务端口=%d），UnityFramework 基址=0x%llx", pid, 任务, 基址);
    return 基址;
}

// 沿 proc 链表从某节点双向遍历找 pid（不依赖 allproc 符号地址）
static uint64_t 链表找pid(uint64_t 起点, int pid, const char* 来源) {
    const uint32_t 下个 = gSystemInfo.kernelStruct.proc.list_next;
    const uint32_t 上个 = gSystemInfo.kernelStruct.proc.list_prev;
    const uint32_t pid偏移 = gSystemInfo.kernelStruct.proc.pid;
    if (!IsKernelAddr(起点)) {
        日志("链表(%s): 起点无效 0x%llx", 来源, 起点);
        return 0;
    }
    if ((int)kread32(起点 + pid偏移) == pid) {
        日志("链表(%s): 起点即目标 pid=%d", 来源, pid);
        return 起点;
    }
    uint64_t p = kread_ptr(起点 + 下个);
    int 后 = 0;
    for (int i = 0; i < 2048 && IsKernelAddr(p); ++i) {
        后++;
        if ((int)kread32(p + pid偏移) == pid) {
            日志("链表(%s): 向后命中 pid=%d（走了 %d 个）", 来源, pid, 后);
            return p;
        }
        p = kread_ptr(p + 下个);
    }
    p = kread_ptr(起点 + 上个);
    int 前 = 0;
    for (int i = 0; i < 2048 && IsKernelAddr(p); ++i) {
        前++;
        if ((int)kread32(p + pid偏移) == pid) {
            日志("链表(%s): 向前命中 pid=%d（走了 %d 个）", 来源, pid, 前);
            return p;
        }
        p = kread_ptr(p + 上个);
    }
    日志("链表(%s): 后 %d 个 / 前 %d 个都没命中 pid=%d", 来源, 后, 前, pid);
    return 0;
}

// allproc 里按 pid 找 proc
// 首选 kfd 自带的 current_proc：它是 kread_sem_open_find_proc() 沿 p_list.le_prev
// 一步步走到本进程得到的，链路已验证可用；allproc 符号在这些 build 上可能指向空。
static uint64_t 找proc(int pid) {
    uint64_t 自身 = kfd_get_current_proc();
    if (IsKernelAddr(自身)) {
        uint64_t 命中 = 链表找pid(自身, pid, "current_proc");
        if (命中) return 命中;
    } else {
        日志("内核: current_proc 无效 (0x%llx)", 自身);
    }
    uint64_t allproc = gSystemInfo.kernelSymbol.allproc;
    if (IsKernelAddr(allproc)) {
        uint64_t 头 = kread_ptr(allproc);
        if (IsKernelAddr(头)) {
            uint64_t 命中 = 链表找pid(头, pid, "allproc");
            if (命中) return 命中;
        } else {
            日志("内核: allproc 头为空 allproc=0x%llx [0]=0x%llx [8]=0x%llx",
                 allproc, kread64(allproc), kread64(allproc + 8));
        }
    } else {
        日志("内核: allproc 符号未解析 (0x%llx)", allproc);
    }
    return 0;
}

// 走内核路线：proc->task → all_image_info 地址逐 8 字节扫描
static uint64_t 走内核(int pid, char* 主程序名, char* 主程序路径) {
    uint64_t proc = 找proc(pid);
    if (!proc) { return 0; }
    // XPF 的 struct set 在部分 16.x 上不给 proc.task，退化为常见偏移逐个试
    uint32_t task偏移 = gSystemInfo.kernelStruct.proc.task;
    uint32_t 候选偏移[3] = { task偏移, 0x10, 0x08 };
    uint64_t task = 0;
    for (int i = 0; i < 3; ++i) {
        if (i > 0 && 候选偏移[i] == 候选偏移[0]) continue;
        uint64_t t = kread_ptr(proc + 候选偏移[i]);
        if (IsKernelAddr(t)) {
            task = t;
            if (i > 0) 日志("内核: proc.task 偏移 0x%x 无效，回退到 0x%x 命中 task=0x%llx",
                            候选偏移[0], 候选偏移[i], t);
            break;
        }
    }
    if (!IsKernelAddr(task)) { 日志("内核: proc->task 无效 (proc=0x%llx)", proc); return 0; }
    for (uint64_t i = 0; i < 0x1000; i += 8) {
        uint64_t 候选 = kread64(task + i);
        if (!IsValidAddr(候选)) continue;
        uint64_t 基址 = 枚举镜像(pid, 0, 候选, 主程序名, 主程序路径);
        if (基址) return 基址;
    }
    日志("内核路线也没找到 all_image_info（task=0x%llx）", task);
    return 0;
}

// 两条路线封装
static uint64_t 找模块基址(int pid, mach_port_t* 端口出, char* 主程序名, char* 主程序路径) {
    if (端口出) *端口出 = 0;
    if (主程序名) *主程序名 = 0;
    if (主程序路径) *主程序路径 = 0;
    uint64_t 基址 = 走任务端口(pid, 端口出, 主程序名, 主程序路径);
    if (基址) return 基址;
    return 走内核(pid, 主程序名, 主程序路径);
}

// 指纹成立：根世界 → +312 可读
static bool 指纹成立(int pid, uint64_t 基址) {
    uint64_t 世界 = 0;
    if (!目标读(pid, 基址 + SDK::根世界, &世界, 8) || !IsValidAddr(世界)) return false;
    uint64_t 容器 = 0;
    return 目标读(pid, 世界 + 312, &容器, 8) && IsValidAddr(容器);
}

// 基址是 MachO（FEEDFACF / CFFAEDFE）
static bool 基址是MachO(int pid, uint64_t 基址) {
    if (!基址) return false;
    uint32_t magic = 0;
    if (!目标读(pid, 基址, &magic, 4)) return false;
    return magic == 0xFEEDFACF || magic == 0xCFFAEDFE;
}

// ==================== 坐标链 ====================

static inline bool 坐标合理(int v) { return v != 1000000 && v > -200000 && v < 400000; }

// 一步解引用
static bool 链步(uint64_t* p, uint64_t off) {
    if (!IsValidAddr(*p)) return false;
    *p = vm_read<uint64_t>(*p + off);
    return IsValidAddr(*p);
}

// 读坐标值：int 直读，或 float×1000 兜底
// ===== v35：一次快照读，修「头像闪过来闪过去」=====
// 旧写法是 X、Z 各来一次 vm_read（两次独立的 vm_read_overwrite 系统调用）。
// 两次之间隔着几十微秒到几百微秒，游戏正好在这中间更新了实体坐标，
// 就会读到「新的 X + 旧的 Z」——一个根本不存在的点。英雄斜着走的时候，
// 这个点和真实点正好在对角线上，于是头像就在两点之间来回跳，就是「闪过来闪过去」。
// 一次读 12 字节（X@0、Z@8），保证 X 和 Z 来自同一帧快照。
static bool 读坐标值(uint64_t 坐标址, unsigned* X, unsigned* Z) {
    if (!IsValidAddr(坐标址)) return false;
    unsigned char 快照[12];
    if (!readMemory(坐标址, 快照, sizeof(快照))) return false;
    int ix = 0, iz = 0;
    memcpy(&ix, 快照, 4);
    memcpy(&iz, 快照 + 8, 4);
    if (坐标合理(ix) && 坐标合理(iz) && (ix || iz)) {
        *X = (unsigned)ix;
        *Z = (unsigned)iz;
        return true;
    }
    float fx = 0.0f, fz = 0.0f;
    memcpy(&fx, 快照, 4);
    memcpy(&fz, 快照 + 8, 4);
    if (isfinite(fx) && isfinite(fz) && fx > -400.0f && fx < 400.0f && fz > -400.0f && fz < 400.0f
        && (fabsf(fx) > 0.001f || fabsf(fz) > 0.001f)) {
        *X = (unsigned)(int)(fx * 1000.0f);
        *Z = (unsigned)(int)(fz * 1000.0f);
        return true;
    }
    return false;
}

// 读坐标某链：实体 → 链.一 → 链.二 → 链.三 → 链.四 → 坐标
static bool 读坐标某链(uint64_t 实体, const SDK::坐标链& 链, unsigned* X, unsigned* Z) {
    uint64_t p = 实体;
    if (!链步(&p, 链.一)) return false;
    if (!链步(&p, 链.二)) return false;
    if (!链步(&p, 链.三)) return false;
    if (!链步(&p, 链.四)) return false;
    return 读坐标值(p, X, Z);
}

// 按选定链扫一遍实体数组，统计有效坐标数（样点）
static int 链样点统计(uint64_t 数组, int 数量, int 链索引, unsigned* 样X, unsigned* 样Z) {
    if (!IsValidAddr(数组) || 数量 <= 0 || 链索引 < 0 || 链索引 >= 3) return 0;
    const SDK::坐标链& 链 = SDK::坐标链表[链索引];
    int 有效 = 0, 计数 = 0;
    for (int i = 0; i < 数量 && 计数 < 10; ++i) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * i);
        if (!IsValidAddr(实体)) continue;
        计数++;
        unsigned x = 0, z = 0;
        if (读坐标某链(实体, 链, &x, &z)
            && (int)x >= -120000 && (int)x <= 120000
            && (int)z >= -120000 && (int)z <= 120000
            && (x || z)) {
            if (!有效 && 样X) { *样X = x; *样Z = z; }
            有效++;
        }
    }
    return 有效;
}

// 链打分：三条链各扫一遍，样点最多的当选
static void 链打分(uint64_t 数组, int 数量) {
    if (!IsValidAddr(数组) || 数量 <= 0) return;
    char 汇总[160] = {0};
    int 最佳数 = 0, 最佳链 = -1;
    unsigned 样X = 0, 样Z = 0;
    int 写 = 0;
    for (int i = 0; i < 3; ++i) {
        unsigned x = 0, z = 0;
        int 数 = 链样点统计(数组, 数量, i, (unsigned*)&x, &z);
        写 += snprintf(汇总 + 写, sizeof(汇总) - 写, "%s=%d ", SDK::坐标链表[i].名字, 数);
        if (写 >= 144) break;
        if (数 > 最佳数) { 最佳数 = 数; 最佳链 = i; 样X = x; 样Z = z; }
    }
    if (最佳链 < 0 || 最佳数 < 2) {
        if (当前链 >= 0) {
            日志("坐标链全部失效（%s）→ 清空，等下一次", 汇总);
            当前链 = -1;
        }
    } else if (当前链 != 最佳链) {
        当前链 = 最佳链;
        日志("坐标链 → %s（%s）样X=%d 样Z=%d",
             SDK::坐标链表[最佳链].名字, 汇总, 样X, 样Z);
    }
}

static const char* 链名(int i) {
    if (i == 4) return "二";
    if (i == 5) return "二A";
    if (i == 3) return "本体";
    if (i < 0 || i >= 3) return "-";
    return SDK::坐标链表[i].名字;
}

// ==================== v38：三链投票 + 中位数滤波 ====================
// v37 的结论（日志实证）：实体 +0x2B8/0x2C0 对英雄读出来是常量垃圾
//   k0直(500,3213) k1直(500,3456) k3直(500,3200) k5直(1200,3318) k4直(0,3537)
//   X 只有 0/500/1200，Z 恒在 3200~3550 —— 这是静态字段，不是世界坐标。
//   野怪用同一偏移一直正常，说明英雄实体上这块布局不一样。所以英雄一律走链读，
//   直读只保留下来做日志对照，不参与输出。
// v36 的结论（日志实证）：单链读会周期性串到别的对象，吐出恒定僵尸值
//   (53395,56435) / (54045,54045) / (56368,53358)，与真值交替出现。
//   闸门「压 4 帧就认新」正好把这些值认成新位置 → 框跳到角落再弹回 = 前后跳。
// v38 三招：
//   ① 三条链同时读，投多数票（三条不同偏移同时串到同一对象的概率极低）
//   ② 9 帧中位数滤波：孤立离群值直接吃掉，匀速移动只引入约 4 帧延迟
//   ③ 离群必须连续 12 帧（200ms）才认作真瞬移，杜绝两点间来回
static int  槽直分[24] = {0};
static bool 槽直遥有[24] = {false};
static unsigned 槽直遥X[24] = {0}, 槽直遥Z[24] = {0};
static int  直读成功计 = 0, 链读成功计 = 0, 直链不符计 = 0, 用直计 = 0, 用链计 = 0;
static int  投票一致计 = 0, 投票分歧计 = 0;

// v57：范围从 ±110000 收紧到 ±60000。依据 _ab_v56.log 全量统计：
//   界内实测最大绝对值 56414；界外最小 84520（94876/90388/-934616376 这类全在外面）。
//   60000 落在 56414~84520 的空档里，切得干净。
static inline bool 坐标在界内(int v) { return v > -60000 && v < 60000; }

static int 直接读坐标(uint64_t 实体, unsigned* X, unsigned* Z) {
    unsigned x = 0, z = 0;
    if (!读坐标值(实体 + SDK::坐标X, &x, &z)) return 0;
    if (!坐标在界内((int)x) || !坐标在界内((int)z)) return 0;
    *X = x; *Z = z;
    return 1;
}

// 直读平滑分（只做诊断，决定要不要把它加回来）
static void 坐标打分(int k, unsigned x, unsigned z) {
    if (k < 0 || k >= 24) return;
    if (槽直遥有[k]) {
        double dx = (double)(int)x - (double)(int)槽直遥X[k];
        double dz = (double)(int)z - (double)(int)槽直遥Z[k];
        槽直分[k] += (dx * dx + dz * dz <= 1500.0 * 1500.0) ? 1 : -2;
        if (槽直分[k] > 600) 槽直分[k] = 600;
        if (槽直分[k] < -60) 槽直分[k] = -60;
    } else {
        槽直分[k] = 0; 槽直遥有[k] = true;
    }
    槽直遥X[k] = x; 槽直遥Z[k] = z;
}

// 三链投票：三条坐标链各读一次，±1500 内算同票，取票数 >= 2 的那组。
// 返回采用的链号（0..2），-1 = 三条全读不到。
static int 三链投票(uint64_t 实体, unsigned* X, unsigned* Z) {
    unsigned vx[3] = {0, 0, 0}, vz[3] = {0, 0, 0};
    bool ok[3] = {false, false, false};
    int 存活 = 0;
    for (int i = 0; i < 3; ++i) {
        ok[i] = 读坐标某链(实体, SDK::坐标链表[i], &vx[i], &vz[i]);
        if (ok[i]) 存活++;
    }
    if (存活 == 0) return -1;

    int 首 = -1;
    for (int i = 0; i < 3; ++i) if (ok[i]) { 首 = i; break; }

    // 有当前链就优先拿它当基准，保证帧间连续；否则拿第一条可读的
    int 基准 = (当前链 >= 0 && 当前链 < 3 && ok[当前链]) ? 当前链 : 首;

    int 票 = 0;
    for (int i = 0; i < 3; ++i) {
        if (!ok[i]) continue;
        long long dx = (long long)(int)vx[i] - (long long)(int)vx[基准];
        long long dz = (long long)(int)vz[i] - (long long)(int)vz[基准];
        if (dx * dx + dz * dz <= 1500LL * 1500LL) 票++;
    }

    if (票 >= 2 || 存活 == 1) {
        投票一致计++;
        *X = vx[基准]; *Z = vz[基准];
        return 基准;
    }

    // 三值互不相同：不硬信单帧，退到离基准最近的那条（大概率还是同一对象）
    投票分歧计++;
    int 近 = 基准;
    long long 最小 = -1;
    for (int i = 0; i < 3; ++i) {
        if (!ok[i] || i == 基准) continue;
        long long dx = (long long)(int)vx[i] - (long long)(int)vx[基准];
        long long dz = (long long)(int)vz[i] - (long long)(int)vz[基准];
        long long d = dx * dx + dz * dz;
        if (最小 < 0 || d < 最小) { 最小 = d; 近 = i; }
    }
    *X = vx[近]; *Z = vz[近];
    return 近;
}

// ==================== v46：英雄坐标主路径改为直读「二」====================
// 全部依据来自实测日志，不含假设：
//   v43（扫描结果）：坐标落在对象2 = *(*(实体+0xa8) + 0x10) 内部，该对象里只有 4 个
//     变化字，且两两相等：+0x2C/+0x34 与 +0x44/+0x4C。配对实测
//     投=400/400 屏滑=399/400 屏最大跳=15px 世变=45326（20 秒 45 米 ≈ 2.3 m/s）。
//   v44（对象图）：10 个槽的「三」= *(二+0x0) 去重 = 10，是各自独有的对象，
//     不是类级/共享指针；且 实体/一/三 的候选量级是 564/21613/3832，非世界坐标。
//   结论：实体 → +0xa8 = 一 → +0x10 = 二，世界坐标 = 二 + 0x44(X) / +0x4C(Z)，
//     单位毫米（与野怪 0x2B8 同型，投影时 /1000），量级 ±103500。
// 读法：从 二+0x44 起一次读 16 字节快照，X 取 +0x44、Z 取 +0x4C（隔 8 字节，
//   不是相邻的 8 字节对），避免分两次读拼出半新半旧的坐标。
static int 用二计 = 0, 二失败计 = 0, 二链不符计 = 0;

// ==================== v48：二 对象的四份读数（一次读 40 字节）====================
// 二 对象里有两组坐标副本，v43 实测在人机局两两相等：
//   组A = +0x2C(X) / +0x34(Z)     组B = +0x44(X) / +0x4C(Z)
// v47 实测联机局会出现「同一槽在两值间交替」（稳压涨、瞬移不涨），
// 所以必须能把四份值同时打出来，判别交替是「同一字段双缓冲」还是「两组字段不同步」。
// 从 二+0x28 一次读 40 字节（到 +0x50），四份值同帧同源，不会拼出半新半旧。
typedef struct { int A, B, C, D; bool 有; uint64_t 类; } 二十四;   // v56：类 = 二+0x00 的 vtable

static 二十四 读二四(uint64_t 二) {
    二十四 r; r.A = r.B = r.C = r.D = 0; r.有 = false; r.类 = 0;
    if (!IsValidAddr(二)) return r;
    // v56：从 二+0 一次读 96 字节，把 vtable 和四份坐标一起拿到 ——
    // 分开读会拼出「旧对象的坐标 + 新对象的 vtable」，校验就没意义了。
    unsigned char 快照[96];
    // 从 二+0 读到 +0x60，可能跨页；跨页就降档到刚好覆盖 +0x4C+4 的长度
    if (!readMemory(二, 快照, sizeof(快照)) &&
        !readMemory(二, 快照, 88) &&
        !readMemory(二, 快照, 80)) return r;
    memcpy(&r.类, 快照 + 0x00, 8);   // 二 + 0x00 = vtable（v54 实测就在这）
    memcpy(&r.A, 快照 + 0x2C, 4);    // 二 + 0x2C
    memcpy(&r.B, 快照 + 0x34, 4);    // 二 + 0x34
    memcpy(&r.C, 快照 + 0x44, 4);    // 二 + 0x44
    memcpy(&r.D, 快照 + 0x4C, 4);    // 二 + 0x4C
    r.有 = true;
    return r;
}

static bool 组可用(int x, int z) {
    if (!坐标在界内(x) || !坐标在界内(z)) return false;
    if (x == 0 && z == 0) return false;      // 未初始化
    return true;
}

// ==================== v49：帧级诊断（只读，不改绘制） ====================
// v48b 留下的问题：快照 5 秒一次，把「每帧在两组值之间跳」采成了「连续递减」，
// 属于采样混叠 —— 无法区分「真的在走」和「高频交替」。所以 A跳=186 / B跳=123
// 这两个数不能用来选边，必须看到逐帧序列本身。
//
// 这里每帧把 一/二 的低 32 位 + 四份读数存进环形缓冲；只在「世界跳变」发生时
// 打标记，延迟 6 帧后把整段环 dump 出来。帧号 + 毫秒都在行里，能直接回答三件事：
//   1) 一/二 低 32 位在帧间变不变     → 变 = 指针换人；不变 = 同一对象
//   2) 地址不变而 A 相邻帧突变         → 同一对象里两份状态在交替
//   3) 突变的间隔是 1 帧 / 2 帧 / N 帧 → 对应哪个 tick（渲染帧 / 同步包 / 插值）
#define 环深 40
struct 环样 {
    unsigned       帧;
    unsigned short 毫秒;
    unsigned       一低, 二低;
    int            A, B, C, D;
    unsigned char  态;          // bit0 okA  bit1 okB  bit2 r.有
};
static 环样          帧环[24][环深];
static unsigned      环位[24] = {0};      // 必须是 unsigned：uchar 到 255 就回零，环会错位
static unsigned      帧序 = 0;
static unsigned      待dump[24] = {0};
static int           环dump计 = 0;
static double        时基 = 0.0;
static unsigned      毫秒计 = 0;

// 读实体坐标 把本次的指针与四份读数留在这里，供主循环写环
static int          末次A = 0, 末次B = 0, 末次C = 0, 末次D = 0;
static unsigned     末次一低 = 0, 末次二低 = 0;
static unsigned char 末次态 = 0;
static bool         末次读到二 = false;

// 每槽独立的「二读失败」计数（每帧累加，快照行打出来并清零）
static int 槽二失[24] = {0};

// v49 环 dump 的「选谁打」策略：
//   来回跳 = 位移向量反复反向；单向移动 = 方向不变。
//   所以「本次跳变向量与上次点积 < 0」就直接 dump（不受间隔限制），
//   方向不变的跳（正常跑动累积出来的）就只按 1 秒一次抽样。
//   这样日志量自动集中到真正要查的那批帧上，而不是被正常移动淹没。
static long long 上向X[24] = {0}, 上向Z[24] = {0};
static bool      槽有向[24] = {false};
static unsigned  上次dump帧[24] = {0};
static int       槽dump数[24] = {0};

// 直接回答「指针到底换没换」：每槽记「二 / 一 的低 32 位在帧间变了多少次」。
// 二变了 = 换对象（换人/换源）；二没变而值变 = 同一对象里两份状态在交替。
static unsigned  槽上二低[24] = {0}, 槽上一低[24] = {0};
static bool      槽有上[24] = {false};
static int       槽二指针变[24] = {0}, 槽一指针变[24] = {0};

static void 写环(int k) {
    if (k < 0 || k >= 24) return;
    // 「二失」在写环处计一次（写环只在主路径调用），别在 读实体坐标 里计 ——
    // 那里回城标定每帧也会走一遍，会把失败数算成两倍。
    if (!(末次态 & 4) || (末次态 & 3) == 0) 槽二失[k]++;
    if (槽有上[k]) {
        if (槽上二低[k] != 末次二低) 槽二指针变[k]++;
        if (槽上一低[k] != 末次一低) 槽一指针变[k]++;
    }
    槽上二低[k] = 末次二低; 槽上一低[k] = 末次一低; 槽有上[k] = true;
    环样& s = 帧环[k][环位[k] % 环深];
    s.帧 = 帧序;
    s.毫秒 = (unsigned short)(毫秒计 & 0xFFFF);
    s.一低 = 末次一低; s.二低 = 末次二低;
    s.A = 末次A; s.B = 末次B; s.C = 末次C; s.D = 末次D;
    s.态 = 末次态;
    环位[k]++;
}

static void 环dump(int k, unsigned 跳帧) {
    if (环dump计 >= 60) return;
    const unsigned n = 环位[k] < 环深 ? 环位[k] : 环深;
    if (n < 4) return;
    环dump计++;
    日志("─环dump k=%d 跳帧=%u 环%u帧 第%d次（f=绘制帧号 ms=本进程毫秒）",
         k, 跳帧, n, 环dump计);
    const unsigned 头 = 环位[k] % 环深;
    for (unsigned i = 0; i < n; ++i) {
        const 环样& s = 帧环[k][(头 + 环深 - n + i) % 环深];
        日志("  环 k=%d f=%u ms=%u 一=%x 二=%x A(%d,%d) B(%d,%d) 态=%u%s",
             k, s.帧, (unsigned)s.毫秒, s.一低, s.二低, s.A, s.B, s.C, s.D,
             (unsigned)s.态, (s.帧 == 跳帧) ? " <<跳" : "");
    }
}

// 兼容旧调用（我方自检）：优先组A，不行用组B
static int 读英雄坐标(uint64_t 实体, unsigned* X, unsigned* Z) {
    if (!IsValidAddr(实体)) return 0;
    const uint64_t 一 = vm_read<uint64_t>(实体 + 0xa8);
    if (!IsValidAddr(一)) return 0;
    const uint64_t 二 = vm_read<uint64_t>(一 + 0x10);
    if (!IsValidAddr(二)) return 0;
    二十四 r = 读二四(二);
    if (!r.有) return 0;
    if (组可用(r.A, r.B)) { *X = (unsigned)r.A; *Z = (unsigned)r.B; return 1; }
    if (组可用(r.C, r.D)) { *X = (unsigned)r.C; *Z = (unsigned)r.D; return 1; }
    return 0;
}

// v48 槽级状态：单源锁定
//   槽组 0 = 还没定（首次两组合法时按组B优先），1 = 锁组A，2 = 锁组B
//   槽锁 = 该槽已经成功用二读出过坐标，从此不再退回链读（消除两源交替）
static int      槽组[24] = {0};
static bool     槽锁[24] = {false};

// v48b：两组各记一份「帧间跳变（>3000）次数」。同一实体的两组副本里，
// 谁在跳、谁连续，用这两个计数一眼判定，不再靠推断。
static int      槽A跳[24] = {0}, 槽B跳[24] = {0};
static int      槽A上X[24] = {0}, 槽A上Z[24] = {0}, 槽B上X[24] = {0}, 槽B上Z[24] = {0};
static unsigned char 槽上态[24] = {0};   // bit0 = 上帧组A合法，bit1 = 上帧组B合法

// 读实体坐标：返回 0..2 = 采用的链号，3 = 本体直读，4 = 二+0x44（v46 主路径），-1 = 读不到
static unsigned 上次直X = 0, 上次直Z = 0;
static bool     上次直有 = false;

// ==================== v56：vtable 校验 + 自愈（这一版改的是绘制主路径，不是探针）====================
// 依据同一 APK 两局对照（联机 _ab_v54.log 23:23:45~，离线 _ab_off.log 23:31:09~ 共 16 分钟）：
//   · 二 的地址两局都恒定，但 二 的 vtable 联机局换了 8 次（间隔 25~35 秒），离线局一个值不变；
//   · 本/一/三 的 vtable 两局全程一模一样、从不变。
//   ⇒ 二 所在那块内存被回收后原地重建成别的对象，我们还在用旧地址读 +0x2c/+0x34。
//     这不是「值在跳」，是读到别人对象的字段（use-after-free），所以任何滤波/投票都治不了。
// v56 的处理：
//   1) 每帧把 二 的 vtable 和四份坐标一起读出来（同一次读，不会拼出新旧混杂）；
//   2) vtable 与学习值相同 → 直接采用；
//   3) vtable 变了 → 看新值是否与上一帧有效位置连续（帧间 <3000mm）。连续 = 池里换了实例但
//      字段布局相同，接受并更新学习值（自愈）；不连续 = 读到别人字段 → 拒绝，保持上一帧位置；
//   4) 保持最多 30 帧，超时该槽不画 —— 宁可这一帧不画，也不画在错的位置上；
//   5) 首次锁定要连续 3 帧同一 vtable 才算学会，避免开局就学到乱对象。
// 判据只用「人不会瞬移 3 米」这一个物理事实，不拿被怀疑的那个字段自己当真值。
static int       槽失[24] = {0};      // 连续拒绝帧数
static int       槽保X[24] = {0}, 槽保Z[24] = {0};
static bool      槽保有[24] = {false};
static int       槽拒计 = 0, 槽保计 = 0, 槽重计 = 0;

// ==================== v57：判据换成「跳变幅度」，vtable 彻底退出判定 ====================
// v56 的 vtable 判据被 _ab_v56.log 这一局直接证伪，两条硬证据：
//   (1) 槽表 14 次采样全是「异=9/10」—— 每个槽的 二 本来就不是同一个 vtable，
//       这不是「池子被抢」，是结构如此；
//   (2) k=1 的 vtable 与「我」完全相同（槽表打「同」），坐标却在 94876 ↔ -400 之间跳了 13 次。
//       → vtable 匹配 ≠ 坐标正确。
//
// 那这局真正的机制是什么？看 ─环dump k=1（f=649~688）：
//   f=649..682（34 帧，0.55 秒）A(94876,-23896) B(47100,-22830)    ← 完全冻结
//   f=683                        A(-24385,47743) B(-30732,46982)  ← 一帧内 A、B 同时整体替换
//   而 一=cc4e8c18 二=cb21d368 全程不变。
//   ⇒ 二 这个对象里装的不是「这个敌人的位置」，是「最近被某个实体写进去的位置」。
//     每 15~34 帧换一个写入者，所以我们每 0.5 秒读到另一个单位。
//
// 所以 v57 只用一条判据：**跳变幅度**。这局 30 次世界跳变的幅度分布是：
//   3035 4296 4413 5434 5671 5676 7562 7977 9080 10132 11160 11477 11698 13249 13473
//   13763 14064 14217 15285 20040 21040 21954 23428 | 29585 57753 57996 58370 69249 102835 108705 139123
// 这些是**逐帧**位移（跳四值/世界跳变都是每帧比上一帧）。一帧 16 毫秒：
//   5 m/s 的人一帧走 8 厘米，10 米/帧 = 600 m/s，物理上不可能 —— 一定是换了实体。
// 而真实的「包驱动离散更新」实测是 4296 / 4413 / 5434 / 5671 / 7562 / 7977 / 9080
//   （0.5 秒一包，跑 5~9 米），都在 10000 以下。
// k=3 的抖动实测是 10132 11160 13249 13473 13763 14064 14217 15285 20040 21040 21954 23428，
//   全部 ≥10000；它的簇间距离算出来是 24255。k=1 的簇间是 57753 / 77000 / 139123。
// 10000 恰好落在「真实更新」（≤9080）和「换实体」（≥10132）之间的空档里。
#define 槽跳阈 10000LL
static int 槽验(int k, int x, int z, unsigned* X, unsigned* Z) {
    bool 采 = true;

    // 范围（坐标在界内 已收紧到 ±60000）
    if (!坐标在界内(x) || !坐标在界内(z) || (x == 0 && z == 0)) 采 = false;

    if (采 && 槽保有[k]) {
        const long long dx = (long long)x - 槽保X[k];
        const long long dz = (long long)z - 槽保Z[k];
        if (dx * dx + dz * dz > 槽跳阈 * 槽跳阈) 采 = false;   // 飞出去
    }

    if (采) {
        槽失[k] = 0;
        槽保X[k] = x; 槽保Z[k] = z; 槽保有[k] = true;
        *X = (unsigned)x; *Z = (unsigned)z;
        return 1;
    }

    ++槽失[k];
    if (槽拒计 < 3000) {
        ++槽拒计;
        日志("跳拒 k=%d 值=(%d,%d) 保=(%d,%d) 连=%d",
             k, x, z, 槽保X[k], 槽保Z[k], 槽失[k]);
    }
    if (槽保有[k] && 槽失[k] <= 90) {
        ++槽保计;
        *X = (unsigned)槽保X[k]; *Z = (unsigned)槽保Z[k];
        return 0;          // 保持 90 帧（约 1.5 秒）—— 实测换实体周期 6~869 帧，多数 24~272 帧
    }
    // 连续 90 帧都拒绝 → 判定为真的换了位置（传送 / 复活 / 换实体），重设基准。
    // 不这么做的话：槽失 只增不减、槽保有 一直为真，条件永远不成立 —— 头像会永久消失。
    if (槽失[k] > 90) {
        槽失[k] = 0;
        if (坐标在界内(x) && 坐标在界内(z) && !(x == 0 && z == 0)) {
            槽保X[k] = x; 槽保Z[k] = z; 槽保有[k] = true;
            *X = (unsigned)x; *Z = (unsigned)z;
            if (槽重计 < 200) { ++槽重计; 日志("跳重设 k=%d 值=(%d,%d)", k, x, z); }
            return 1;
        }
    }
    return -1;                                      // 宁可不画，也不画错的位置
}

static int 读实体坐标(int k, uint64_t 实体, unsigned* X, unsigned* Z) {
    unsigned dx = 0, dz = 0;
    bool 直有 = 直接读坐标(实体, &dx, &dz) != 0;
    上次直X = dx; 上次直Z = dz; 上次直有 = 直有;

    // ---- v48 主路径：二 对象，单源锁定 ----
    uint64_t 一 = 0, 二 = 0;
    if (IsValidAddr(实体)) {
        一 = vm_read<uint64_t>(实体 + 0xa8);
        if (IsValidAddr(一)) 二 = vm_read<uint64_t>(一 + 0x10);
    }
    // v49：把本次两级指针和四份读数留给主循环写环（成功、失败都记，失败本身是证据）
    末次一低 = (unsigned)(一 & 0xFFFFFFFF);
    末次二低 = (unsigned)(二 & 0xFFFFFFFF);
    末次A = 末次B = 末次C = 末次D = 0;
    末次态 = 0;
    末次读到二 = IsValidAddr(二);
    if (IsValidAddr(二)) {
        const 二十四 r = 读二四(二);
        const bool okA = r.有 && 组可用(r.A, r.B);
        const bool okB = r.有 && 组可用(r.C, r.D);
        末次A = r.A; 末次B = r.B; 末次C = r.C; 末次D = r.D;
        末次态 = (unsigned char)((r.有 ? 4 : 0) | (okA ? 1 : 0) | (okB ? 2 : 0));
        const bool 是槽 = (k >= 0 && k < 24);

        // v48b：两组各自统计帧间跳变（>3000）。只看「上一帧也合法」的相邻对，
        // 避免把 0→真值 的初始化误算成跳。
        if (是槽 && r.有) {
            if (okA) {
                if (槽上态[k] & 1) {
                    long long ax = (long long)r.A - 槽A上X[k];
                    long long az = (long long)r.B - 槽A上Z[k];
                    if (ax * ax + az * az > 3000LL * 3000LL) 槽A跳[k]++;
                }
                槽A上X[k] = r.A; 槽A上Z[k] = r.B; 槽上态[k] |= 1;
            }
            if (okB) {
                if (槽上态[k] & 2) {
                    long long bx = (long long)r.C - 槽B上X[k];
                    long long bz = (long long)r.D - 槽B上Z[k];
                    if (bx * bx + bz * bz > 3000LL * 3000LL) 槽B跳[k]++;
                }
                槽B上X[k] = r.C; 槽B上Z[k] = r.D; 槽上态[k] |= 2;
            }
        }

        int 用 = -1;                       // 0 = 组A(+0x2C)，1 = 组B(+0x44)
        // v48b：改成组A 优先。依据 _ab_v47c.log（19:09:04~19:09:31）：
        //   k=3 走「二」时，读数在 真位置 ↔ 原点附近小值 之间交替，且每秒 20~40 次：
        //     (-47528,28776) → (1029,644) → (-47057,27600) → (404,1170) → (3475,-34847) …
        //   交替的一侧恒在 ±6000 内（(1029,644)/(404,1170)/(676,1420)/(-1063,-1216)），
        //   另一侧是 ±5 万的真实世界坐标。这批小数出自组B(+0x44/+0x4C) 的读数（轨迹 v(...) 即组B）。
        //   组A(+0x2C/+0x34) 至今没有被单独观测过，因此改用它，并同时统计两组的帧间跳变次数，
        //   谁稳就用谁 —— 由 快照 行的 A跳=/B跳= 直接判定，不靠推断。
        if (是槽 && 槽组[k] == 1 && okA) 用 = 0;
        else if (是槽 && 槽组[k] == 2 && okB) 用 = 1;
        if (用 < 0) {                      // 还没定，或锁定组当帧越界 → 兜底
            if (okA) 用 = 0;
            else if (okB) 用 = 1;
            if (用 >= 0 && 是槽 && 槽组[k] == 0) 槽组[k] = 用 + 1;
        }
        if (用 >= 0) {
            用二计++;
            if (是槽) 槽锁[k] = true;
            const unsigned 新X = (unsigned)(用 == 0 ? r.A : r.C);
            const unsigned 新Z = (unsigned)(用 == 0 ? r.B : r.D);
            if (是槽) {
                // v56：先过 vtable 校验。返回 0 = 保持上一帧（类不符但还在容忍帧数内），
                // -1 = 这帧不画。绘制层只看 <0，所以 0 会照常用保持值画出来。
                const int 判 = 槽验(k, (int)新X, (int)新Z, X, Z);
                if (判 < 0) return -1;
                if (判 == 0) return 6;
            } else {
                *X = 新X; *Z = 新Z;
            }
            if (二链不符计 < 200000 && 是槽) {
                unsigned kx = 0, kz = 0;
                if (读坐标某链(实体, SDK::坐标链表[1], &kx, &kz)) {
                    double gx = (double)(int)*X - (double)(int)kx;
                    double gz = (double)(int)*Z - (double)(int)kz;
                    if (gx * gx + gz * gz > 5000.0 * 5000.0) 二链不符计++;
                }
            }
            return (用 == 0) ? 5 : 4;
        }
    }
    if (k >= 0 && k < 24) {
        二失败计++;
        // v49：分槽计数在 写环 里做（只统计主路径的一次调用）
        // v48 关键修复：已经锁定单源的槽，这一帧读不到就不画（返回 -1），
        // 绝不退回链读 —— 同一个槽在两套数据源之间交替，正是「前后跳」的来源。
        if (槽锁[k]) return -1;
    }

    if (k < 0 || k >= 24) {              // 非槽位调用（标定取样）：直读优先
        if (直有) { *X = dx; *Z = dz; return 3; }
        return 三链投票(实体, X, Z);
    }

    unsigned cx = 0, cz = 0;
    int 链号 = 三链投票(实体, &cx, &cz);
    if (链号 < 0) return -1;

    链读成功计++;
    if (直有) {
        直读成功计++;
        坐标打分(k, dx, dz);
        double gx = (double)(int)dx - (double)(int)cx;
        double gz = (double)(int)dz - (double)(int)cz;
        if (gx * gx + gz * gz > 5000.0 * 5000.0) 直链不符计++;
    }
    *X = cx; *Z = cz; 用链计++;
    return 链号;
}

// 校验并跟随链（模块刚拿到或样点过少时重新打分）
static void 校验链() {
    if (!IsValidAddr(模块基址)) return;
    uint64_t 世界 = vm_read<uint64_t>(模块基址 + SDK::根世界);
    uint64_t 容器 = IsValidAddr(世界) ? vm_read<uint64_t>(世界 + 312) : 0;
    uint64_t 数组 = IsValidAddr(容器) ? vm_read<uint64_t>(容器 + 120) : 0;
    int 数量 = IsValidAddr(容器) ? vm_read<int>(容器 + 148) : 0;
    if (!IsValidAddr(数组) || 数量 <= 0 || 数量 > 512) return;
    if (当前链 < 0) { 链打分(数组, 数量); return; }
    unsigned x = 0, z = 0;
    if (链样点统计(数组, 数量, 当前链, &x, &z) < 2)
        链打分(数组, 数量);
}

// ==================== 实体字段 ====================

static int 读血量当前(uint64_t 实体) {
    uint64_t 对象 = vm_read<uint64_t>(实体 + SDK::血量对象);
    if (!IsValidAddr(对象)) return -1;
    return vm_read<int>(对象 + SDK::血量当前);
}
static int 读血量上限(uint64_t 实体) {
    uint64_t 对象 = vm_read<uint64_t>(实体 + SDK::血量对象);
    if (!IsValidAddr(对象)) return 0;
    return vm_read<int>(对象 + SDK::血量上限);
}
static int 读阵营(uint64_t 实体) { return vm_read<int>(实体 + SDK::阵营); }

// ===== v33：我方阵营防抖（「敌方头像一直跳」的根因修复）=====
// 旧写法：`我方阵营 = 矩阵[0] <= 0.0f ? 2 : 1;` —— 每帧重算，零滤波。
// 失效链：读矩阵偶尔部分失败，m[0] 变成 0 → `0 <= 0` 成立 → 阵营翻成 2 →
// 这一帧「敌方」变成了真正的我方 5 人：小地图上 5 个头像整片从半场 A 跳到半场 B，
// 下一帧又翻回来。60fps 下就是肉眼看到的「一直跳」。纹理缓存全命中（命中=1500 空=0）
// 正是铁证 —— 跳的不是图，是位置。
// 修法三条：
//   ① 死区：|m[0]| < 0.05 视为「读坏 / 正好过零」，不参与判定，沿用上一次
//   ② 滞回：观测方向连续 30 帧（约 0.5 秒）一致才真正切换，单帧抖动一律忽略
//   ③ 诊断：每次真切换打一行日志，把 m00 和累计次数一起记下来
static int 阵营缓存 = 0;        // 0 = 还没定
static int 阵营候选 = 0;
static int 阵营候选帧 = 0;
static int 阵营切换计 = 0;
static int 阵营死区计 = 0;

static unsigned 判定我方阵营(const float* m) {    if (cfg_team) return (unsigned)cfg_team;
    const float m0 = m[0];
    bool 可疑 = !(m0 == m0)                      // NaN
             || (m0 < 0.05f && m0 > -0.05f);     // 死区：读坏或恰好过零
    if (可疑) {
        if (++阵营死区计 % 120 == 1)
            日志("阵营待定 m00=%.5f（死区，沿用 %d）累计=%d", m0, 阵营缓存, 阵营死区计);
        return (unsigned)(阵营缓存 ? 阵营缓存 : 1);
    }
    const int 观测 = (m0 < 0.0f) ? 2 : 1;
    if (阵营缓存 == 0) {                          // 首次定值直接采纳
        阵营缓存 = 观测;
        日志("阵营定值 %d（m00=%.4f）", 观测, m0);
        return (unsigned)观测;
    }
    if (观测 == 阵营缓存) { 阵营候选 = 观测; 阵营候选帧 = 0; return (unsigned)阵营缓存; }
    if (观测 != 阵营候选) { 阵营候选 = 观测; 阵营候选帧 = 0; }
    if (++阵营候选帧 < 30) return (unsigned)阵营缓存;   // 抖动：不认
    阵营切换计++;
    日志("阵营切换 %d → %d（m00=%.4f 连续30帧一致）累计切换=%d",
        阵营缓存, 观测, m0, 阵营切换计);
    阵营缓存 = 观测;
    阵营候选帧 = 0;
    return (unsigned)阵营缓存;
}

// ===== v33：实体阵营防抖 =====
// `实体+52` 和 `实体+40` 是同一类风险：偏移是反推出来的，读到的值「恰好落在合法区间」
// 并不代表它就是那个字段。表现就是同一个小英雄一会儿 1 一会儿 2 —— 而阵营直接决定
// 小地图翻转符号（阵营符号：1→-1，其他→+1），翻转一帧，它的头像就从地图这头跳到那头。
// 这里做两层保护：
//   ① 只接受 1/2，其他值（0、3、负数）当成脏读，沿用上次
//   ② 连续 8 帧一致才真正改判，单帧抖动一律吞掉
static uint64_t 槽阵营键[24]   = {0};
static int      槽阵营值[24]   = {0};
static int      槽阵营候选[24] = {0};
static int      槽阵营帧[24]   = {0};
static int      实体阵营切换计 = 0;

static int 稳定阵营(int k, uint64_t 实体) {
    if (k < 0 || k >= 24) return 0;
    if (槽阵营键[k] != 实体) {
        槽阵营键[k] = 实体; 槽阵营值[k] = 0; 槽阵营候选[k] = 0; 槽阵营帧[k] = 0;
    }
    const int 观 = vm_read<int>(实体 + 52);
    if (观 != 1 && 观 != 2) return 槽阵营值[k];        // 脏读：不动
    if (槽阵营值[k] == 0) { 槽阵营值[k] = 观; return 观; }
    if (观 == 槽阵营值[k]) { 槽阵营候选[k] = 观; 槽阵营帧[k] = 0; return 槽阵营值[k]; }
    if (观 != 槽阵营候选[k]) { 槽阵营候选[k] = 观; 槽阵营帧[k] = 0; }
    if (++槽阵营帧[k] >= 8) {
        const int 旧 = 槽阵营值[k];
        槽阵营值[k] = 观; 槽阵营帧[k] = 0;
        if (++实体阵营切换计 <= 20)
            日志("实体阵营切换 k=%d 实体=%llx %d→%d（连续8帧）累计=%d",
                 k, 实体, 旧, 观, 实体阵营切换计);
    }
    return 槽阵营值[k];
}


// ===== v32：稳定的英雄 ID =====
// 血案：`实体+40` 对一部分实体不是稳定字段。日志实证 k=1 的实体指针 2c9de18d0
// 连续 30 秒不变，而 `实体+40` 每 3 秒换一个值：133→168→152→531→168→133。
// 拿它当图标缓存 key，等于每 3 秒请求一张新图，纹理永远命中不了 →
// 走占位分支画「黑圆+白圈+编号」，编号又是 ID%1000 跟着跳 —— 这就是头像在闪。
// 修法：按槽位锁死。槽位换实体才重置；读到 [100,999] 的合法英雄 ID 就钉住，
// 之后不再重新读，纹理只请求一次，加载成功后永久命中。
static uint64_t 槽实体[24] = {0};
static int      槽英雄ID[24] = {0};
static int      槽上限[24] = {0};
static int      图标命中计 = 0;      // 头像纹理拿到真图的次数（诊断用）
static int      图标未命中计 = 0;    // 纹理为空、走占位圆的次数（诊断用）
// v33 诊断：小地图上每个槽位的上一帧位置，用来量化「跳」。一帧之内英雄最多走几像素，
// 超过 40pt 的位移只可能是阵营翻转 / 坐标读错，直接计数，5 秒打一次。
static float    槽小图X[24] = {0};
static float    槽小图Y[24] = {0};
static int      位置跳计 = 0;
// v34 诊断：直接量世界坐标的帧间位移。上一版只在小图坐标上设 40pt 阈值，
// 地图放大到 200pt 之后，世界坐标抖 1 万单位才折 19pt —— 正好漏检。
// 这里不设阈值地记录「本窗口最大世界位移」，抖动幅度一目了然。
static uint64_t 槽世键[24] = {0};
static unsigned 槽世X[24] = {0}, 槽世Z[24] = {0};
static double   槽世最大跳[24] = {0};
static int      世界跳计 = 0;
// v38 诊断：滤波「之后」的帧间位移。原始读数还在串对象，但画出去的是这个，
// 所以它才是「用户眼睛看到抖不抖」的直接指标。
static unsigned 槽出X[24] = {0}, 槽出Z[24] = {0};
static double   槽出最大跳[24] = {0};
static int      零血连续[24] = {0};      // v35：连续读到「血=0」的帧数，单帧脏读不算死

// ==================== v39 坐标门控（中位数在 50% 污染下失效）====================
// v38 用 9 帧中位数，实测更糟：错误值不是「零星离群」而是占了约一半帧，
// 中位数直接落在两簇中间 —— 输出一个两边都不在的点，看起来就是来回跳。
// 数据形态（v38 日志 23:15:42）：每帧在两组「各自都平滑」的坐标之间交替，
// k1 (4026,3681)→(106,13719)→(357,13712)→(-6585,13970)→(3852,3459)→(-6940,14010)。
//
// 所以改成「单向门控」：离上一输出 >3000 就压住不跟随，连续 60 帧（1 秒）
// 都在新位置才认作真瞬移。交替时只有一支能通过，输出就是那一支的连续轨迹 ——
// 每秒更新 30 次、每次前进一个真实步长，60fps 下看是平滑的，不会再跳回另一点。
#define 坐标窗宽 9
static unsigned 槽稳X[24] = {0}, 槽稳Z[24] = {0};
static bool     槽稳有[24] = {false};
static int      离群连[24] = {0};
static int      稳定压计 = 0;    // 被压住的帧数
static int      稳定接计 = 0;    // 接受跟随的帧数
static int      瞬移认计 = 0;    // 连续 60 帧离群后认新位置的次数

static void 稳定坐标(int k, unsigned* X, unsigned* Z) {
    if (k < 0 || k >= 24) return;
    const int rx = (int)*X, rz = (int)*Z;

    if (!槽稳有[k]) {
        槽稳X[k] = *X; 槽稳Z[k] = *Z; 槽稳有[k] = true; 离群连[k] = 0;
        稳定接计++;
        return;
    }

    long long dx = (long long)rx - (long long)(int)槽稳X[k];
    long long dz = (long long)rz - (long long)(int)槽稳Z[k];
    bool 离群 = (dx * dx + dz * dz > 3000LL * 3000LL);

    if (离群) {
        离群连[k]++;
        if (离群连[k] < 60) {
            稳定压计++;
            *X = 槽稳X[k]; *Z = 槽稳Z[k];
            return;
        }
        // 连续 60 帧（1 秒）都在新位置 → 真瞬移（闪现/复活/换人）
        槽稳X[k] = *X; 槽稳Z[k] = *Z; 离群连[k] = 0;
        瞬移认计++; 稳定接计++;
        if (瞬移认计 <= 20)
            日志("坐标认新 k=%d 新(%d,%d) 距%.0f（连续60帧）",
                 k, rx, rz, sqrt((double)(dx * dx + dz * dz)));
        return;
    }

    离群连[k] = 0;
    槽稳X[k] = *X; 槽稳Z[k] = *Z;   // 未离群：零延迟直接跟随
    稳定接计++;
}

// ==================== v42：坐标自标定（双解释 + 漏斗诊断）====================
// v41 实测（_ab_v41.log）：5 个敌方槽全试过（活度 8243 → 146210，都是真在动的人），
//   4 个对象 × 2048 个字，候选全是 0。这不是锁错人，是判据或解释方式的问题。
// 所以 v42 不改判据的「结论」，只做两件事：
//   ① 把筛子拆成漏斗，逐级计数（界内 / 界内+会变 / 界内+会变+平滑 / 全过），
//      打印每个对象每一级剩多少 —— 哪一级归零，一眼看到。
//   ② 同一批字节同时按 int32 和 float 两种解释统计。原代码整套假设坐标是
//      「千分位 int32」（投影里除以 1000，野怪 0x2B8 确实是 int）。如果英雄用的是
//      float，按 int 解释就是一串垃圾，第一关（界内）就全灭 —— 这正是「候选=0」的一个
//      可检验解释，而不是又一个猜测。
//      float 解释的额外门槛：0.01 < |f| < 110000。整数 53395 按 float 读是 7.5e-41
//      的次正规数，直接被这条挡掉，所以两种解释不会互相污染。
// float 的坐标单位有两种可能（米 或 千分之一米），无法先验确定，所以配对时两种倍率
//   （1.0 和 0.001）各算一遍，都去投影，谁分数高谁留下 —— 用投影结果说话。
// 扫描范围 v41 的 0x2000 扩到 0x4000：前 8KB 已经证明没有，就往后看，不是猜。
#define 扫范围   0x4000
#define 扫词数   (扫范围 / 4)
#define 扫对象数 4
#define 扫粗帧   240
#define 扫细帧   400
#define 短上限   48
#define 对上限   1200

static bool 投影(const float* m, int 世界X, int 世界Z, float* 屏X, float* 屏Y,
                float 宽, float 高);

struct 偏移统 {
    // int32 解释
    int 上值;
    int 帧数;
    int 界内;
    int 变;
    int 小变;
    int 最大差;
    int 总变程;
    // float 解释
    float 上F;
    int 界F;
    int 变F;
    int 滑F;
    int 最大F;
};

struct 对统 {
    int 对象;
    int 类;        // 0 = int32，1 = float
    float 倍率;    // 仅 float：1.0（米） 或 0.001（千分之一米）
    int 甲期;      // X 偏移
    int 乙期;      // Z 偏移
    int 帧数;
    int 投影成;
    int 屏内;
    int 屏平滑;
    int 屏最大跳;
    int 世变;
    int 上屏X;
    int 上屏Y;
    int 上世X;
    int 上世Z;
};

static 偏移统 扫统[扫对象数][扫词数];
static 对统   扫对[对上限];
static unsigned char 扫块[扫对象数][扫范围];
static int    扫对数 = 0;
static int    短单[扫对象数][短上限];   // 偏移字节
static signed char 短类[扫对象数][短上限];
static int    短数[扫对象数];
static uint64_t 扫对象址[扫对象数] = {0, 0, 0, 0};
static uint64_t 扫键 = 0;
static int 扫粗计 = 0;
static int 扫细计 = 0;
static int 扫阶段 = 0;
static int      稳连[24] = {0};
static uint64_t 稳实体[24] = {0};
static int      活度[24] = {0};
static int      上活X[24] = {0}, 上活Z[24] = {0};
static bool     活有[24] = {false};
static bool     已试[24] = {false};
static int      锁槽 = -1;
static int 扫调粗 = 0, 扫调细 = 0;
static int 扫空帧 = 0;
static float 扫屏宽 = 0.0f, 扫屏高 = 0.0f;

static bool 浮点可用(float f) {
    return isfinite(f) && fabsf(f) > 0.01f && fabsf(f) < 110000.0f;
}

static void 组长短名单() {
    扫对数 = 0;

    // ---- 漏斗：逐级计数，看是哪一级归零 ----
    for (int o = 0; o < 扫对象数; ++o) {
        短数[o] = 0;
        if (!IsValidAddr(扫对象址[o])) {
            日志("粗筛 对象%d 地址非法，跳过", o);
            continue;
        }
        int 界I = 0, 变I = 0, 滑I = 0, 全I = 0;
        int 界F = 0, 变F = 0, 滑F = 0;
        for (int i = 0; i < 扫词数; ++i) {
            偏移统& s = 扫统[o][i];
            if (s.帧数 < 扫粗计 || s.帧数 < 2) continue;

            double 界 = (double)s.界内 / s.帧数;
            double 变 = (double)s.变 / s.帧数;
            // v43 修 bug：分母原来写的是 (帧数-1)，但分子「小变」只统计「变了且变化小」的次数，
            // 最多等于「变」。v42 日志 int 变=19（变率 8%），滑上限只有 19/239=0.08，
            // 永远过不了 0.80 的门槛 —— 12 轮扫描全 0 候选就是这一行造成的。
            // float 那一路用的是 滑F/变F，分母正确，所以只有 int 被误杀。
            double 滑 = (s.变 > 0) ? (double)s.小变 / s.变 : 0.0;
            if (界 >= 0.85) {
                界I++;
                if (变 >= 0.03) {
                    变I++;
                    if (滑 >= 0.80) {
                        滑I++;
                        if (s.最大差 <= 6000 && s.总变程 >= 1000) {
                            全I++;
                            if (短数[o] < 短上限) {
                                短单[o][短数[o]] = i * 4;
                                短类[o][短数[o]] = 0;
                                短数[o]++;
                            }
                        }
                    }
                }
            }

            double 界f = (double)s.界F / s.帧数;
            double 变f = (double)s.变F / s.帧数;
            double 滑f = (s.变F > 0) ? (double)s.滑F / s.变F : 0.0;
            if (界f >= 0.85) {
                界F++;
                if (变f >= 0.03) {
                    变F++;
                    if (滑f >= 0.80) {
                        滑F++;
                        if (短数[o] < 短上限) {
                            短单[o][短数[o]] = i * 4;
                            短类[o][短数[o]] = 1;
                            短数[o]++;
                        }
                    }
                }
            }
        }
        日志("漏斗 对象%d 址=%llx 字=%d | int 界=%d 变=%d 滑=%d 全=%d | float 界=%d 变=%d 滑=%d | 短单=%d",
             o, (unsigned long long)扫对象址[o], 扫词数,
             界I, 变I, 滑I, 全I, 界F, 变F, 滑F, 短数[o]);

        // v43：变化字明细。不管「平滑」过不过，把「界内率≥85% 且 变率≥3%」的字全列出来，
        // 每条带 偏移 / 变率% / 滑率% / 最大帧间差 / 总变程 / 当前值。
        // 这是为了万一修好分母后仍是 0 候选，能直接看到「变化字都在哪个偏移、值多大」，
        // 而不是只知道筛空了。真坐标必然是其中某两条相差 4 或 8、值在 ±103500 附近的一对。
        {
            char 串[900] = {0};
            int 位 = 0, 已列 = 0, 行 = 0;
            for (int i = 0; i < 扫词数 && 已列 < 60; ++i) {
                偏移统& s = 扫统[o][i];
                if (s.帧数 < 2) continue;
                if ((double)s.界内 / s.帧数 < 0.85) continue;
                if ((double)s.变 / s.帧数 < 0.03) continue;
                位 += snprintf(串 + 位, sizeof(串) - 位, "+0x%X 变%d%% 滑%d%% 差%d 程%d =%d | ",
                               i * 4,
                               (int)(100.0 * s.变 / s.帧数),
                               (s.变 > 0 ? (int)(100.0 * s.小变 / s.变) : 0),
                               s.最大差, s.总变程, s.上值);
                已列++;
                if (已列 % 8 == 0 || 位 > 700) {
                    日志("变化字 对象%d (%d) %s", o, ++行, 串);
                    位 = 0; 串[0] = 0;
                }
            }
            if (位 > 0) 日志("变化字 对象%d (%d) %s", o, ++行, 串);
            if (已列 == 0) 日志("变化字 对象%d 无（界内≥85% 且 变率≥3%% 的字一个都没有）", o);
        }
    }

    // ---- 组对：同一对象、同一解释、偏移差 +4 / +8 ----
    bool 满 = false;
    for (int o = 0; o < 扫对象数 && !满; ++o) {
        for (int i = 0; i < 短数[o] && !满; ++i) {
            for (int j = 0; j < 短数[o]; ++j) {
                if (短类[o][i] != 短类[o][j]) continue;
                int d = 短单[o][j] - 短单[o][i];
                if (d != 4 && d != 8) continue;
                int 倍 = (短类[o][i] == 1) ? 2 : 1;
                for (int m = 0; m < 倍; ++m) {
                    if (扫对数 >= 对上限) { 满 = true; break; }
                    对统& p = 扫对[扫对数++];
                    memset(&p, 0, sizeof(p));
                    p.对象 = o;
                    p.类 = 短类[o][i];
                    p.倍率 = (短类[o][i] == 1 && m == 1) ? 0.001f : 1.0f;
                    p.甲期 = 短单[o][i];
                    p.乙期 = 短单[o][j];
                }
            }
        }
    }
    日志("配对 候选对数=%d", 扫对数);

    if (扫对数 == 0) {
        static int 空轮 = 0;
        空轮++;
        日志("粗筛无候选 第%d轮（见上面漏斗，看是哪一级归零）→ 换人重试", 空轮);
        if (空轮 < 5) {
            扫阶段 = 0; 扫键 = 0; 锁槽 = -1;
            return;
        }
        空轮 = 0;
        memset(已试, 0, sizeof(已试));
        memset(活度, 0, sizeof(活度));
        memset(活有, 0, sizeof(活有));
        扫阶段 = 0; 扫键 = 0; 锁槽 = -1;
        return;
    }

    // 短名单明细（带类型前缀）
    for (int o = 0; o < 扫对象数; ++o) {
        char 串[420] = {0};
        int 位 = 0;
        for (int i = 0; i < 短数[o] && 位 < 360; ++i) {
            int idx = 短单[o][i] / 4;
            if (短类[o][i] == 0)
                位 += snprintf(串 + 位, sizeof(串) - 位, "i+0x%X=%d ",
                               短单[o][i], 扫统[o][idx].上值);
            else
                位 += snprintf(串 + 位, sizeof(串) - 位, "f+0x%X=%.3f ",
                               短单[o][i], 扫统[o][idx].上F);
        }
        日志("短名单 对象%d %s", o, 串);
    }
}

static void 输出扫描结果() {
    日志("=== 坐标自标定 实体=%llx 粗=%d 细=%d 对=%d ===",
         (unsigned long long)扫键, 扫粗计, 扫细计, 扫对数);
    bool 用[对上限];
    memset(用, 0, sizeof(用));
    int 出名 = 0;
    for (int 名 = 1; 名 <= 10; ++名) {
        int 最佳 = -1;
        double 最高 = -1e9;
        for (int i = 0; i < 扫对数; ++i) {
            if (用[i]) continue;
            对统& p = 扫对[i];
            if (p.帧数 < 扫细计 || p.帧数 == 0) continue;
            if (p.世变 < 2000) continue;
            double 内 = (double)p.屏内 / p.帧数;
            double 滑 = (double)p.屏平滑 / p.帧数;
            double 投 = (double)p.投影成 / p.帧数;
            double 分 = 内 * 2.0 + 滑 + 投 * 0.5 - (double)p.屏最大跳 / (扫屏宽 > 1 ? 扫屏宽 : 1);
            if (分 > 最高) { 最高 = 分; 最佳 = i; }
        }
        if (最佳 < 0) break;
        用[最佳] = true;
        出名++;
        对统& p = 扫对[最佳];
        日志("配对%d 对象%d %s%s X=+0x%X(%d) Z=+0x%X(%d) 分=%.2f 投=%d/%d 屏内=%d/%d 屏滑=%d 屏最大跳=%d 世变=%d",
             名, p.对象,
             p.类 == 0 ? "int " : "float ",
             p.类 == 0 ? "" : (p.倍率 > 0.5f ? "米" : "毫米"),
             p.甲期, p.上世X, p.乙期, p.上世Z, 最高,
             p.投影成, p.帧数, p.屏内, p.帧数, p.屏平滑, p.屏最大跳, p.世变);
    }
    if (出名 == 0)
        日志("配对 无合格候选（看看漏斗每一级的数，以及短名单里的值长什么样）");
    日志("=== 坐标自标定结束 ===");
}

static void 更新活度(int k, int x, int z) {
    if (k < 0 || k >= 24) return;
    if (活有[k]) {
        long long dx = (long long)x - (long long)上活X[k];
        long long dz = (long long)z - (long long)上活Z[k];
        double d = sqrt((double)(dx * dx + dz * dz));
        if (d > 30.0 && d <= 4000.0) {
            活度[k] += (int)d;
            if (活度[k] > 4000000) 活度[k] = 4000000;
        }
    }
    上活X[k] = x; 上活Z[k] = z; 活有[k] = true;
}

static void 坐标自标定(int k, uint64_t 实体, const float* 矩阵, float 宽, float 高,
                     int 原X, int 原Z) {
    if (扫阶段 >= 3 || 实体 == 0) return;

    更新活度(k, 原X, 原Z);

    if (扫阶段 == 0) {
        if (已试[k]) return;
        if (稳实体[k] == 实体) 稳连[k]++;
        else { 稳实体[k] = 实体; 稳连[k] = 1; }
        if (稳连[k] < 90) return;
        if (活度[k] < 8000) return;

        memset(扫统, 0, sizeof(扫统));
        memset(扫对, 0, sizeof(扫对));
        扫对数 = 0; 扫粗计 = 0; 扫细计 = 0;
        扫调粗 = 0; 扫调细 = 0; 扫空帧 = 0;
        扫屏宽 = 宽; 扫屏高 = 高;   // 与主流程 投影(..., 屏.x, 屏.y) 完全同源，不自作聪明
        扫键 = 实体;
        锁槽 = k;
        已试[k] = true;
        for (int o = 0; o < 扫对象数; ++o) 扫对象址[o] = 0;

        扫对象址[0] = 实体;
        const SDK::坐标链& 链 = SDK::坐标链表[0];
        uint64_t t = 实体;
        扫对象址[1] = 链步(&t, 链.一) ? t : 0;
        t = 扫对象址[1];
        扫对象址[2] = 链步(&t, 链.二) ? t : 0;
        t = 扫对象址[2];
        扫对象址[3] = 链步(&t, 链.三) ? t : 0;
        扫阶段 = 1;
        日志("自标定 锁定 k=%d 实体=%llx 一=%llx 二=%llx 三=%llx 活度=%d 屏=%.0fx%.0f 范围=0x%X",
             k, (unsigned long long)扫对象址[0], (unsigned long long)扫对象址[1],
             (unsigned long long)扫对象址[2], (unsigned long long)扫对象址[3],
             活度[k], 宽, 高, 扫范围);
        return;
    }

    if (k != 锁槽) return;

    if (实体 != 扫键) {
        if (++扫空帧 > 900) {
            日志("自标定 目标丢失，重置（准备换人）");
            扫阶段 = 0; 扫键 = 0; 锁槽 = -1; 扫空帧 = 0;
        }
        return;
    }
    扫空帧 = 0;

    if (扫阶段 == 1) {
        if (扫粗计 >= 扫粗帧) { 组长短名单(); if (扫阶段 == 1) 扫阶段 = 2; return; }
        if ((扫调粗++ & 1) != 0) return;
        for (int o = 0; o < 扫对象数; ++o) {
            uint64_t 址 = 扫对象址[o];
            if (!IsValidAddr(址)) continue;
            if (!readMemory(址, 扫块[o], 扫范围)) continue;
            for (int i = 0; i < 扫词数; ++i) {
                int v = 0;
                float f = 0.0f;
                memcpy(&v, 扫块[o] + i * 4, 4);
                memcpy(&f, 扫块[o] + i * 4, 4);
                偏移统& s = 扫统[o][i];

                if (s.帧数 > 0) {
                    // ---- int32 解释 ----
                    long long dd = (long long)v - (long long)s.上值;
                    if (dd < 0) dd = -dd;
                    if (dd > 100000) dd = 100000;
                    if (dd > 0) {
                        s.变++;
                        s.总变程 += (int)dd;
                        if (dd <= 4000) s.小变++;
                    }
                    if ((int)dd > s.最大差) s.最大差 = (int)dd;

                    // ---- float 解释 ----
                    if (isfinite(f) && isfinite(s.上F)) {
                        double df = fabs((double)f - (double)s.上F);
                        double 幅 = fabs((double)f);
                        double 限 = 0.05 * (幅 > 1.0 ? 幅 : 1.0);   // 相对 5%，至少 0.05
                        if (df > 0.0) {
                            s.变F++;
                            if (df <= 限) s.滑F++;
                            if (df > s.最大F) s.最大F = (int)(df > 2000000.0 ? 2000000.0 : df);
                        }
                    }
                }
                if (v > -110000 && v < 110000 && v != 0) s.界内++;
                if (浮点可用(f)) s.界F++;
                s.上值 = v;
                s.上F = f;
                s.帧数++;
            }
        }
        扫粗计++;
        return;
    }

    if (扫阶段 == 2) {
        if (扫细计 >= 扫细帧) { 输出扫描结果(); 扫阶段 = 3; return; }
        if ((扫调细++ & 1) != 0) return;

        bool 有[扫对象数] = {false, false, false, false};
        for (int o = 0; o < 扫对象数; ++o) {
            uint64_t 址 = 扫对象址[o];
            if (!IsValidAddr(址)) continue;
            if (!readMemory(址, 扫块[o], 扫范围)) continue;
            有[o] = true;
        }
        for (int i = 0; i < 扫对数; ++i) {
            对统& p = 扫对[i];
            if (!有[p.对象]) continue;

            double wx = 0.0, wz = 0.0;
            if (p.类 == 0) {
                int x = 0, z = 0;
                memcpy(&x, 扫块[p.对象] + p.甲期, 4);
                memcpy(&z, 扫块[p.对象] + p.乙期, 4);
                if (x <= -110000 || x >= 110000 || z <= -110000 || z >= 110000) continue;
                wx = (double)x; wz = (double)z;
            } else {
                float fx = 0.0f, fz = 0.0f;
                memcpy(&fx, 扫块[p.对象] + p.甲期, 4);
                memcpy(&fz, 扫块[p.对象] + p.乙期, 4);
                if (!浮点可用(fx) || !浮点可用(fz)) continue;
                // 统一换算成千分之一米（投影函数的分母就是 1000）
                wx = (double)fx * (double)p.倍率 * 1000.0;
                wz = (double)fz * (double)p.倍率 * 1000.0;
                if (fabs(wx) >= 110000.0 || fabs(wz) >= 110000.0) continue;
            }

            float sx = 0.0f, sy = 0.0f;
            if (!投影(矩阵, (int)wx, (int)wz, &sx, &sy, 扫屏宽, 扫屏高)) continue;
            p.投影成++;
            if (sx > -0.15f * 扫屏宽 && sx < 1.15f * 扫屏宽 &&
                sy > -0.15f * 扫屏高 && sy < 1.15f * 扫屏高) p.屏内++;
            if (p.帧数 > 0) {
                double dx = (double)sx - (double)p.上屏X;
                double dy = (double)sy - (double)p.上屏Y;
                double d = sqrt(dx * dx + dy * dy);
                if (d < 0.25 * (double)扫屏宽) p.屏平滑++;
                if ((int)d > p.屏最大跳) p.屏最大跳 = (int)d;
                double mx = wx - (double)p.上世X;
                double mz = wz - (double)p.上世Z;
                p.世变 += (int)(sqrt(mx * mx + mz * mz));
            }
            p.上屏X = (int)sx; p.上屏Y = (int)sy;
            p.上世X = (int)wx; p.上世Z = (int)wz;
            p.帧数++;
        }
        扫细计++;
        return;
    }
}

// ==================== v45：全槽坐标对照（只读、只打印，不参与绘制）====================
// v44 已经测出的事实（不需要再重复）：
//   ① 「三」= *(二+0x0) 在 10 个槽里是 10 个不同指针（图G0 三去重=10）→ 它不是类级/共享指针，
//      v36 里 k=4 与 k=5 共用「三」是那两槽同时指向同一个英雄，不是链的问题。
//   ② 坐标在「二」里，两组各一份：+0x2C≡+0x44、+0x34≡+0x4C，单位毫米，随移动平滑变化。
//   ③ v44 的「找不到我方槽」是探针自己的 bug：读阵营用了 +0xC0（垃圾 -1029978168），
//      真字段是 +52（主循环统计行 阵52=1 一直稳定）。
//   ④ 实战时 DisplaySize = 2796x1290（横屏），启动横幅那时是 1290x2796（竖屏）——
//      v42 那个「屏=2796x1290」的矛盾是朝向变了，不是代码错。
// 这一版只测一件事：谁是「我」，以及「二」里的坐标投影后是否落在我身上。
// 判据就是免费真值：相机跟着我走，我的投影必落在屏幕中心附近。全部 10 个槽都投影一遍，
// 离中心最近的那个就是我，它的距心值直接判定「偏移对不对」和「投影宽高对不对」。
#define 全槽样数 10
static int 全槽计 = 0;
static int 全槽帧 = 0;

static uint64_t 图解一(uint64_t 实体) { return IsValidAddr(实体) ? vm_read<uint64_t>(实体 + 0xa8) : 0; }
static uint64_t 图解二(uint64_t 一)   { return IsValidAddr(一) ? vm_read<uint64_t>(一 + 0x10) : 0; }
static uint64_t 图解三(uint64_t 二)   { return IsValidAddr(二) ? vm_read<uint64_t>(二 + 0x0) : 0; }

static void 图打印对象(uint64_t 址, const char* 名, int 槽) {
    if (!IsValidAddr(址)) {
        日志("图 %s 槽%d 址=%llx 无效", 名, 槽, (unsigned long long)址);
        return;
    }
    uint64_t q[8] = {0};
    if (!readMemory(址, q, sizeof(q))) {
        日志("图 %s 槽%d 址=%llx 读失败", 名, 槽, (unsigned long long)址);
        return;
    }
    char 串[440] = {0};
    int 位 = 0;
    for (int i = 0; i < 8 && 位 < 400; ++i)
        位 += snprintf(串 + 位, sizeof(串) - 位, "%llx ", (unsigned long long)q[i]);
    日志("图 %s 槽%d 址=%llx q0..7= %s", 名, 槽, (unsigned long long)址, 串);
}

static void 全槽对比(uint64_t 数组, int 数量, const float* 矩阵, float 宽, float 高) {
    if (全槽计 >= 全槽样数) return;
    if (++全槽帧 < 30) return;                 // 2Hz
    全槽帧 = 0;

    // 实体还没到齐时不算一次取样（开局前两秒槽位可能是空的）
    {
        int 齐 = 0;
        for (int i = 0; i < 数量 && i < 12; ++i)
            if (IsValidAddr(vm_read<uint64_t>(数组 + 24ULL * i))) ++齐;
        if (齐 < 6) return;
    }
    ++全槽计;

    const float 中X = 宽 * 0.5f, 中Y = 高 * 0.5f;
    int 最近槽 = -1;
    double 最近距 = 1e9;
    int 最近X = 0, 最近Z = 0, 最近阵 = 0;
    uint64_t 最近实体 = 0;

    char 串[470] = {0};
    int 位 = 0;
    for (int k = 0; k < 数量 && k < 12; ++k) {
        uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(e)) continue;
        uint64_t 二 = 图解二(图解一(e));
        if (!IsValidAddr(二)) continue;
        const int x = vm_read<int>(二 + 0x44);
        const int z = vm_read<int>(二 + 0x4C);
        const int 阵 = vm_read<int>(e + 52);
        float sx = 0.0f, sy = 0.0f;
        bool 成 = 投影(矩阵, x, z, &sx, &sy, 宽, 高);
        double 距 = 成 ? sqrt((double)(sx - 中X) * (sx - 中X) + (double)(sy - 中Y) * (sy - 中Y)) : -1.0;
        if (成 && 距 < 最近距) {
            最近距 = 距; 最近槽 = k; 最近X = x; 最近Z = z; 最近阵 = 阵; 最近实体 = e;
        }
        if (位 < 400)
            位 += snprintf(串 + 位, sizeof(串) - 位, "k%d阵%d(%d,%d)=%.0f ", k, 阵, x, z, 距);
    }
    日志("全槽 第%d次 中(%.0f,%.0f) %s", 全槽计, 中X, 中Y, 串);

    if (最近槽 < 0) {
        日志("全槽 第%d次 一个都投不出来", 全槽计);
        return;
    }

    // 最近槽 = 我。除了距心，再打三件事做交叉核对：
    //   ① (x,z) 与 (z,x) 两种顺序各自的距心 —— 若换序后明显更近，说明轴向反了
    //   ② 链读（安卓链）在同一帧的值 —— 与 二 的值摆在一起看差距
    {
        float ax = 0.0f, ay = 0.0f, bx = 0.0f, by = 0.0f;
        bool 成A = 投影(矩阵, 最近X, 最近Z, &ax, &ay, 宽, 高);
        bool 成B = 投影(矩阵, 最近Z, 最近X, &bx, &by, 宽, 高);
        double 距A = 成A ? sqrt((double)(ax - 中X) * (ax - 中X) + (double)(ay - 中Y) * (ay - 中Y)) : -1.0;
        double 距B = 成B ? sqrt((double)(bx - 中X) * (bx - 中X) + (double)(by - 中Y) * (by - 中Y)) : -1.0;
        unsigned 链X = 0, 链Z = 0;
        bool 链有 = 读坐标某链(最近实体, SDK::坐标链表[1], &链X, &链Z);   // 1 = S44
        日志("全槽 第%d次 我=k%d 阵=%d 二(%d,%d) 距心%.0f | 换序距心%.0f | 链读(%d,%d) 有=%d",
             全槽计, 最近槽, 最近阵, 最近X, 最近Z, 最近距, 距B,
             (int)链X, (int)链Z, 链有 ? 1 : 0);
    }

    if (全槽计 >= 全槽样数) {
        日志("全槽 完成 10 次取样，我=k%d 实体=%llx", 最近槽, (unsigned long long)最近实体);
        uint64_t 一 = 图解一(最近实体), 二 = 图解二(一), 三 = 图解三(二);
        图打印对象(最近实体, "实体", 最近槽);
        图打印对象(一, "一", 最近槽);
        图打印对象(二, "二", 最近槽);
        图打印对象(三, "三", 最近槽);
    }
}

// ==================== v46：我方英雄自检（免费真值）====================
// 相机跟着我方英雄走，所以我方英雄投影后必然落在屏幕中心附近。
// 这条判据不依赖任何外部数据，每 0.5 秒自证一次：
//   距心 < 150px  → 偏移对、投影对（偏移错的话这个数会是几千）
//   距心 恒定 300~800 且随朝向不变 → 坐标是局部坐标，需用矩阵反解常量偏移
//   距心 每次都不同且很大 → 二+0x44 不是位置，回到 q0..7 找字段
static int 自检帧 = 0, 自检计 = 0;
static void 我方自检(uint64_t 数组, int 数量, const float* 矩阵, float 宽, float 高, unsigned 我方) {
    if (数量 <= 0) return;
    if (++自检帧 < 30) return;               // 约 0.5 秒一次
    自检帧 = 0;

    const float 中X = 宽 * 0.5f, 中Y = 高 * 0.5f;
    int 我槽 = -1, 我X = 0, 我Z = 0;
    double 我距 = 1e9;
    bool 我屏 = false;
    int 敌数 = 0, 敌屏内 = 0;
    double 敌近 = 1e9;

    for (int k = 0; k < 数量 && k < 12; ++k) {
        uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(e)) continue;
        unsigned x = 0, z = 0;
        if (!读英雄坐标(e, &x, &z)) continue;
        float sx = 0.0f, sy = 0.0f;
        bool 成 = 投影(矩阵, (int)x, (int)z, &sx, &sy, 宽, 高);
        double 距 = 成 ? sqrt((double)(sx - 中X) * (sx - 中X) + (double)(sy - 中Y) * (sy - 中Y)) : -1.0;
        int 阵 = vm_read<int>(e + 52);
        if (阵 == (int)我方) {
            if (成 && 距 < 我距) { 我距 = 距; 我槽 = k; 我X = (int)x; 我Z = (int)z; 我屏 = 成; }
        } else if (阵 == 1 || 阵 == 2) {
            敌数++;
            if (成 && sx > 0.0f && sx < 宽 && sy > 0.0f && sy < 高) 敌屏内++;
            if (成 && 距 < 敌近) 敌近 = 距;
        }
    }

    ++自检计;
    if (自检计 <= 3 || (自检计 % 4) == 0)
        日志("自检 我=k%d 阵=%u 二(%d,%d) 距心=%.0f 屏内=%d | 敌=%d 屏内=%d 最近距心=%.0f",
             我槽, 我方, 我X, 我Z, (我槽 >= 0) ? 我距 : -1.0, 我屏 ? 1 : 0,
             敌数, 敌屏内, (敌近 > 1e8) ? -1.0 : 敌近);
}

// ==================== v54：屏心投影锚定（替掉 v53 的位移判据）====================
// v53 那套判据被这一局日志证伪（_ab_v53.log），不是「没命中」，是「判据本身错」：
//  ① 榜上 X 和 Z 落在同一个偏移上双份计票：二 X 次=59/302 +0x2c、二 Z 次=78/302 +0x2c。
//     真坐标的 X 和 Z 不可能共用一个偏移 —— 这说明计到的是噪声，不是坐标对。
//  ② 只有 int 解释上榜，float 米 / float 毫米 一次都没中。
//  ③ 拿「屏心世界点的帧间位移」当真值，本身就是错的：
//     屏心点 = 我 + L×相机前向，相机一转向它就绕着我转，位移里混进了旋转项。
//     实测 23:03:40 (2407,1656) → 23:03:45 (10117,9650)，5 秒算出来走 11 米；
//     同一局 23:06:05~23:06:15 站着不动时连续三拍 Δ=(0,0)，说明相机不动它就不动 ——
//     即它是「相机的点」，不是「我的位置」。
// 这一局真正的发现（决定性，不需要再猜）：
//   整局 快照 里 10 个槽的 二 组A/组B 全部是小数或计时器或乱码，没有一个是 ±5 万的世界值：
//     k6(我) 732,786 → 1027,1030 → 1271,72 → -1083857384,859
//     k0     1276,1261 全程一字不变（静态字段）
//     k9     5811,8 → 22912,8（A 单调涨、每秒约 +1100 = 毫秒计时器）
//     k2     403378440,403378440（X 与 Z 完全相等 —— 两个不相干字段被拼成一对）
//   而同一个我，屏心反解出来的位置在 (-53416,-55081) ~ (42246,50929) 之间正常跑动。
//   ⇒ 联机对局里 实体 → +0xa8 → +0x10 这条链指的不再是「位置组件」，
//     而 v43 在人机局实测这条链「投=400/400、屏滑=399/400、屏最大跳=15px」是完美坐标。
//     这就是「离线人机正常、一进联机就开始跳」的真正机制：链指错了对象，不是值在跳。
// v55 修正 v54 的判据（实测发现）：
//   v54 用「加载期采样基准 ±200px」，但两局采到的基准差 322px ——
//   联机局 (1454,614)、离线局 (1128,1062)，采样时镜头还没落到跟随位，基准本身是错的。
//   离线局 15 分钟坐标全程正确时，「我」恒定投在 (1395,740)（±30px）。
//   所以 v55 改成硬编码比例带 px∈宽[0.44,0.56]、py∈高[0.50,0.70]，不采任何样。
// v54 换一个绝对判据，彻底不用「位移」：
//   相机第三人称跟随我 ⇒ 我永远投在屏幕上同一个像素位置。
//   加载期 二 还准（就是 v43 那次实测），先用它把这个像素位置量出来（24 次平均），
//   之后整局拿这个位置当尺子：谁的投影落在基准 ±80px 内，谁就是我的位置字段。
//   判据与位移、旋转、插值、帧率全无关，也不拿任何内存值当真值。
// 三组对照放在同一行输出，互相钉死，防止我再一次自证：
//   直读 0x2b8/0x2c0  → v37 实测英雄上是常量垃圾 (500,3213)，预期「偏」；
//   出生点 0x278/0x280 → v50 实测 65 秒一字不变，预期「偏」；
//   二 组A / 组B      → 人机局是完美坐标，这局若「偏」就直接证明链已指错对象。
// 另外每张榜打 4 层 vtable：对象类型一换 vtable 立刻变，这是「指错对象」的铁证。
#define 锚层数 4
static const int   锚长表[锚层数] = {0x40000, 0x8000, 0x4000, 0x4000};
static const char* 锚层名[锚层数] = {"本体", "一", "二", "三"};
#define 锚格 0x10000                      // 0x40000 / 4
static unsigned short 锚扫计[锚层数][3][锚格];
static unsigned char  锚扫今[0x40000];
static int   锚扫样 = 0, 锚扫报 = 0, 锚扫轮 = 0, 锚扫帧 = 0;
static int   锚扫样层[锚层数] = {0};   // 轮转扫，每层样本要分开算，否则命中率虚低 4 倍
static float 锚基X = 0.0f, 锚基Y = 0.0f;
static int   锚基样 = 0, 锚基试 = 0;
static bool  锚基有 = false;
static uint64_t 锚我 = 0;
static bool     锚有初 = false;

// ---------------- v55 新增 ----------------
// 锚真v：加载期第一次见到的「二」的 vtable。这是唯一的结构差异来源 ——
//   联机局（_ab_v54.log）里它在 23:25:16~23:29:11 之间换了 8 次：
//     2c6e17f88 → 2c6e104e0 → 2c6e19810 → 2c6ac0c88
//     → 2c67133a0 → 2c64cc910 → 2c64d35b0 → 2c64de848，间隔 25~35 秒；
//   离线局（_ab_off.log，16 分钟）里它从头到尾只有一个 2ce5a5be8。
//   同期 本体(118b06b28)/一(118b036d8)/三(118b02ba0) 两局都全程不变。
static uint64_t 锚真v = 0;
// 锁二址：加载期锁定的「一+0x10」地址。整局盯住它，区分两种可能：
//   地址不变但 vtable 变 → 那块内存被释放后原地重建（use-after-free）；
//   地址本身变了      → 一+0x10 换绑到了别的对象。
static uint64_t 锁二址 = 0;
// 跨距表：X 与 Z 的内存间距。已知副本都是 8，但别的组件不一定，
// v54 只试了 4/8，这里把 0x10/0x20 也带上，免得漏掉「被别的字段隔开」的坐标对。
static const int 锚跨表[4] = {4, 8, 0x10, 0x20};
#define 锚跨数 4
static unsigned char 锚跨记[锚层数][锚格];   // 每格最后命中的跨距，榜上打出来

// 与 投影() 同式，省掉 isfinite 和重复的 /1000，扫描里要跑十几万次
static inline bool 锚投(const float* m, int X, int Z, float 宽, float 高,
                        float* px, float* py) {
    const float x = (float)X * 0.001f, z = (float)Z * 0.001f;
    const float w = m[2] * x + m[10] * z + m[14];
    if (!(w > 0.001f)) return false;
    const float inv = 1.0f / w;
    *px = ((m[0] * x + m[8] * z + m[12]) * inv + 1.0f) * 宽 * 0.5f;
    *py = (1.0f - (m[1] * x + m[9] * z + m[13]) * inv) * 高 * 0.5f;
    return true;
}

// 容差 ±200px，不是 ±80：基准是加载期采的，那时相机更高更远，人物在屏幕上的
// 位置和实战期可能差一两百像素。放宽不影响判断 —— 随机投影落进 400×400 区域的
// 概率只有 (400/1290)×(400/2796)≈4.3%，而真位置字段的命中率接近 100%，
// 榜上「次/样本」一看就分得开。噪声底 4%，命中率 >70% 才算数。
#define 锚容 200.0f
static inline bool 锚基上(float px, float py) {
    return px > 锚基X - 锚容 && px < 锚基X + 锚容 &&
           py > 锚基Y - 锚容 && py < 锚基Y + 锚容;
}

// ============ v55：判据换成硬编码屏幕带 ============
// v54 用「加载期采样基准 ±200px」，两局实测证明这个基准根本不能当尺子：
//   联机局采到 (1454,614)，离线局采到 (1128,1062) —— 同一个我在两个位置差 322px。
//   原因是采样发生在加载期，那时镜头还没落到第三人称跟随位。
// 而 _ab_off.log（离线局 15 分钟、坐标全程正确）里，「我」的投影稳稳落在
//   px 1363~1424（宽 2796 的 0.488~0.509）、py 724~816（高 1290 的 0.561~0.633），
//   全程波动只有 ±30px。这就是第三人称相机的跟随点。
// 所以判据不采任何样，直接用比例带：px∈[0.44,0.56]、py∈[0.50,0.70]。
//   随机命中率 0.12×0.20 = 2.4%，而真位置字段接近 100%，榜上一眼分得开。
//   带宽比实测范围（±30px）宽了 4~5 倍，专门留给联机时镜头可能的不同。
static inline bool 锚带上(float px, float py, float 宽, float 高) {
    return px > 宽 * 0.44f && px < 宽 * 0.56f &&
           py > 高 * 0.50f && py < 高 * 0.70f;
}

static void 锚照(const char* 名, bool 有, int X, int Z,
                 const float* m, float 宽, float 高) {
    if (!有) { 日志("锚照 %s 无值", 名); return; }
    float px = 0.0f, py = 0.0f;
    if (!锚投(m, X, Z, 宽, 高, &px, &py)) {
        日志("锚照 %s 值=(%d,%d) w<=0 投不到", 名, X, Z);
        return;
    }
    日志("锚照 %s 值=(%d,%d) 投=(%.0f,%.0f) 距基=(%.1f,%.1f) %s",
         名, X, Z, px, py, px - 锚基X, py - 锚基Y, 锚基上(px, py) ? "命中" : "偏");
}

// ---- v55：在「一」里找还活着的正确类型对象 ----
// 二 被池回收后有两种可能：
//   ① 位置组件彻底被释放 → 一 里不会再有 vtable == 锚真v 的引用；
//   ② 只是 一+0x10 换了指向，组件本身还活着 → 一 里能找到别的引用。
// 扫 一 的所有 8 字节位置，挑 vtable 恰好等于锚真v 的，把它的 +0x2c/+0x34 打出来。
// 找到且坐标正常 → v56 直接改读那一处，问题结束；一条都没有 → 这层可以彻底排掉。
static void 一内找活(uint64_t 一址) {
    if (!IsValidAddr(一址) || !锚真v) return;
    int 长 = 0x8000;
    while (长 >= 0x800 && !readMemory(一址, 锚扫今, 长)) 长 /= 2;
    if (长 < 0x800) { 日志("找活 读不到一 长=%d", 长); return; }
    int 条 = 0;
    for (int o = 0; o + 8 <= 长 && 条 < 6; o += 8) {
        uint64_t p = 0;
        memcpy(&p, 锚扫今 + o, 8);
        if (!IsValidAddr(p)) continue;
        if (vm_read<uint64_t>(p) != 锚真v) continue;
        int x = 0, z = 0;
        if (!readMemory(p + 0x2c, &x, 4)) continue;
        if (!readMemory(p + 0x34, &z, 4)) continue;
        日志("找活 一+0x%x -> %llx 坐标=(%d,%d)", o, (unsigned long long)p, x, z);
        ++条;
    }
    if (条 == 0) 日志("找活 一 内无 vtable=%llx 的引用", (unsigned long long)锚真v);
}

static void 锚榜(const uint64_t* 层址, const float* m, float 宽, float 高) {
    ++锚扫报;

    // ① 四层 vtable：指错对象 / 换类型，这里第一个看出来
    {
        const uint64_t 本 = vm_read<uint64_t>(层址[0]);
        const uint64_t 一v = IsValidAddr(层址[1]) ? vm_read<uint64_t>(层址[1]) : 0;
        const uint64_t 二v = IsValidAddr(层址[2]) ? vm_read<uint64_t>(层址[2]) : 0;
        const uint64_t 三v = IsValidAddr(层址[3]) ? vm_read<uint64_t>(层址[3]) : 0;
        日志("锚层 vtable 本=%llx 一=%llx 二=%llx 三=%llx 样本=%d",
             (unsigned long long)本, (unsigned long long)一v,
             (unsigned long long)二v, (unsigned long long)三v, 锚扫样);
    }

    // ①b 盯住加载期锁定的 二 地址 —— 这是区分「原地重建」和「换绑」的唯一办法
    if (锁二址) {
        const uint64_t v = vm_read<uint64_t>(锁二址);
        int x = 0, z = 0;
        readMemory(锁二址 + 0x2c, &x, 4);
        readMemory(锁二址 + 0x34, &z, 4);
        日志("锁二址 %llx v=%llx %s 坐标=(%d,%d)",
             (unsigned long long)锁二址, (unsigned long long)v,
             (v == 锚真v) ? "同" : "异", x, z);
    }

    // ② 三组对照
    {
        unsigned ux = 0, uz = 0;
        const bool 直有 = 读坐标值(锚我 + SDK::坐标X, &ux, &uz);
        锚照("直读0x2b8", 直有, (int)ux, (int)uz, m, 宽, 高);
        int bx = 0, bz = 0;
        if (readMemory(锚我 + 0x278, &bx, 4) && readMemory(锚我 + 0x280, &bz, 4))
            锚照("出生点0x278", true, bx, bz, m, 宽, 高);
        else 锚照("出生点0x278", false, 0, 0, m, 宽, 高);
        const 二十四 r = 读二四(层址[2]);
        if (r.有) {
            锚照("二A(0x2c,0x34)", true, r.A, r.B, m, 宽, 高);
            锚照("二B(0x44,0x4c)", true, r.C, r.D, m, 宽, 高);
        } else {
            锚照("二A(0x2c,0x34)", false, 0, 0, m, 宽, 高);
            锚照("二B(0x44,0x4c)", false, 0, 0, m, 宽, 高);
        }
    }

    // ③ 榜：每层每种解释取前 2 名。次/样本 接近 1 的那一项就是位置字段。
    for (int t = 0; t < 锚层数; ++t) {
        if (!IsValidAddr(层址[t])) continue;
        for (int md = 0; md < 3; ++md) {
            int 上次 = 65536;
            for (int 序 = 0; 序 < 2; ++序) {
                int 最好 = -1, 次 = 0;
                for (int o = 0; o < 锚格; ++o) {
                    const int v = (int)锚扫计[t][md][o];
                    if (v > 次 && v < 上次) { 次 = v; 最好 = o; }
                }
                if (最好 < 0 || 次 < 12) break;
                上次 = 次;
                int 甲 = 0, 乙4 = 0, 乙8 = 0;
                readMemory(层址[t] + 最好 * 4, &甲, 4);
                readMemory(层址[t] + 最好 * 4 + 4, &乙4, 4);
                readMemory(层址[t] + 最好 * 4 + 8, &乙8, 4);
                日志("锚 %s %s 次=%d/%d +0x%x 跨=%d 值4=(%d,%d) 值8=(%d,%d)",
                     锚层名[t], md == 0 ? "int" : (md == 1 ? "f米" : "f毫米"),
                     次, 锚扫样层[t], 最好 * 4,
                     md == 0 ? 锚跨表[锚跨记[t][最好] & 3] : 0,
                     甲, 乙4, 甲, 乙8);
            }
        }
    }
}

static void 锚扫描(uint64_t 数组, int 数量, const float* m, float 宽, float 高, unsigned 我方) {
    if (锚扫报 >= 400) return;                    // 一局最多扫 33 分钟，别中途断
    if (++锚扫帧 % 60 != 0) return;              // v56: 降到约 1Hz —— 扫描只是留证据, 不能抢主路径

    // ---- v55：每槽 vtable + 坐标。联机/离线两局唯一的差异就在这里 ----
    // 联机局里 二 的 vtable 每 25~35 秒换一个（池回收后原地重建），
    // 离线局 16 分钟只有一个值。所以这一行是「有没有被抢」的直接指示。
    {
        static double 上槽表 = 0.0;
        const double 现s = CACurrentMediaTime();
        if (现s - 上槽表 >= 5.0) {
            上槽表 = 现s;
            char 行[640];
            int 位 = 0;
            int 异 = 0, 共 = 0;
            行[0] = 0;
            for (int k = 0; k < 数量 && k < 10; ++k) {
                uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
                if (!IsValidAddr(e)) continue;
                const uint64_t 一k = vm_read<uint64_t>(e + 0xa8);
                if (!IsValidAddr(一k)) continue;
                const uint64_t 二k = vm_read<uint64_t>(一k + 0x10);
                if (!IsValidAddr(二k)) continue;
                const uint64_t v = vm_read<uint64_t>(二k);
                if (锚真v == 0) 锚真v = v;
                ++共;
                const bool 同 = (v == 锚真v);
                if (!同) ++异;
                int x = 0, z = 0;
                readMemory(二k + 0x2c, &x, 4);
                readMemory(二k + 0x34, &z, 4);
                if (位 < (int)sizeof(行) - 48)
                    位 += snprintf(行 + 位, sizeof(行) - 位, "k%d%s(%d,%d) ",
                                  k, 同 ? "同" : "异", x, z);
            }
            日志("槽表 真v=%llx 异=%d/%d %s",
                 (unsigned long long)锚真v, 异, 共, 行);
        }
    }

    // ---- 锁「我」：加载期 二 还准，取投在屏幕中心 250px 内、离得最近的我方实体 ----
    if (!IsValidAddr(锚我)) {
        float 最小 = 1e18f;
        int 我槽 = -1;
        for (int k = 0; k < 数量 && k < 12; ++k) {
            uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
            if (!IsValidAddr(e)) continue;
            if (vm_read<int>(e + 52) != (int)我方) continue;
            unsigned x = 0, z = 0;
            if (!读英雄坐标(e, &x, &z)) continue;
            float sx = 0, sy = 0;
            if (!投影(m, (int)x, (int)z, &sx, &sy, 宽, 高)) continue;
            const float dx = sx - 宽 * 0.5f, dy = sy - 高 * 0.5f;
            const float d = dx * dx + dy * dy;
            if (d < 250.0f * 250.0f && d < 最小) { 最小 = d; 我槽 = k; 锚我 = e; }
        }
        if (IsValidAddr(锚我) && !锚有初) {
            锚有初 = true;
            const uint64_t 一锁 = vm_read<uint64_t>(锚我 + 0xa8);
            if (IsValidAddr(一锁)) 锁二址 = vm_read<uint64_t>(一锁 + 0x10);
            if (IsValidAddr(锁二址)) 锚真v = vm_read<uint64_t>(锁二址);
            日志("锚 锁定我 实体=%llx 槽=%d 锁二址=%llx 真v=%llx",
                 (unsigned long long)锚我, 我槽,
                 (unsigned long long)锁二址, (unsigned long long)锚真v);
        }
        return;                                   // 锁定这一拍不扫
    }

    // ---- 基准：把我自己在屏幕上的像素位置量出来 ----
    if (!锚基有) {
        ++锚基试;
        unsigned x = 0, z = 0;
        float sx = 0, sy = 0;
        if (读英雄坐标(锚我, &x, &z) && 投影(m, (int)x, (int)z, &sx, &sy, 宽, 高)) {
            锚基X += sx; 锚基Y += sy; ++锚基样;
        }
        if (锚基样 >= 24) {
            锚基X /= 24.0f; 锚基Y /= 24.0f; 锚基有 = true;
            日志("锚基 (%.0f,%.0f) 采到 %d 次", 锚基X, 锚基Y, 锚基样);
        } else if (锚基试 >= 60) {
            锚基X = 宽 * 0.5f; 锚基Y = 高 * 0.6f; 锚基有 = true;
            日志("锚基 采样失败(%d/%d) 退回屏心 (%.0f,%.0f)", 锚基样, 锚基试, 锚基X, 锚基Y);
        }
        return;
    }

    // ---- 四层轮转，每拍扫一层。绝对判据不需要相邻帧，轮转不丢信息 ----
    uint64_t 层址[锚层数];
    层址[0] = 锚我;
    const uint64_t 一 = vm_read<uint64_t>(锚我 + 0xa8);
    层址[1] = 一;
    层址[2] = IsValidAddr(一) ? vm_read<uint64_t>(一 + 0x10) : 0;
    层址[3] = IsValidAddr(层址[2]) ? vm_read<uint64_t>(层址[2]) : 0;

    const int t = (锚扫轮++) % 锚层数;
    if (!IsValidAddr(层址[t])) return;
    int 长 = 锚长表[t];
    while (长 >= 0x800 && !readMemory(层址[t], 锚扫今, 长)) 长 /= 2;
    if (长 < 0x800) return;
    ++锚扫样;
    ++锚扫样层[t];

    for (int o = 0; o + 12 <= 长; o += 4) {
        // ---- int32 解释：X 与 Z 可能隔 4 或 8 字节（已知副本都是隔 8）----
        int 甲 = 0;
        memcpy(&甲, 锚扫今 + o, 4);
        if (甲 != 0 && 甲 > -103500 && 甲 < 103500) {
            for (int 跨 = 0; 跨 < 锚跨数; ++跨) {
                const int 距 = 锚跨表[跨];
                if (o + 距 + 4 > 长) break;
                int 乙 = 0;
                memcpy(&乙, 锚扫今 + o + 距, 4);
                if (乙 == 0 || 乙 <= -103500 || 乙 >= 103500) continue;
                float px = 0.0f, py = 0.0f;
                if (!锚投(m, 甲, 乙, 宽, 高, &px, &py)) continue;
                if (!锚带上(px, py, 宽, 高)) continue;
                const int 格 = o / 4;
                if (锚扫计[t][0][格] < 65535) ++锚扫计[t][0][格];
                锚跨记[t][格] = (unsigned char)跨;
            }
        }
        // ---- float 解释：米（×1000）/ 毫米（×1）----
        float fa = 0.0f;
        memcpy(&fa, 锚扫今 + o, 4);
        if (!isfinite(fa) || fa == 0.0f) continue;
        for (int md = 1; md <= 2; ++md) {
            const float 倍 = (md == 1) ? 1000.0f : 1.0f;
            const float 甲f = fa * 倍;
            if (!(甲f > -103500.0f && 甲f < 103500.0f)) continue;
            for (int 跨 = 0; 跨 < 锚跨数; ++跨) {
                const int 距f = 锚跨表[跨];
                if (o + 距f + 4 > 长) break;
                float fb = 0.0f;
                memcpy(&fb, 锚扫今 + o + 距f, 4);
                if (!isfinite(fb) || fb == 0.0f) continue;
                const float 乙f = fb * 倍;
                if (!(乙f > -103500.0f && 乙f < 103500.0f)) continue;
                float px = 0.0f, py = 0.0f;
                if (!锚投(m, (int)甲f, (int)乙f, 宽, 高, &px, &py)) continue;
                if (!锚带上(px, py, 宽, 高)) continue;
                const int 格 = o / 4;
                if (锚扫计[t][md][格] < 65535) ++锚扫计[t][md][格];
            }
        }
    }

    static double 上锚榜 = 0.0;
    const double 现 = CACurrentMediaTime();
    if (现 - 上锚榜 >= 5.0) { 上锚榜 = 现; 锚榜(层址, m, 宽, 高); }

    // ---- v55：一 里找还活着的正确类型对象（每 10 秒一次）----
    // 放在扫描之后调用：它会覆盖 锚扫今，而扫描循环已经跑完了。
    {
        static double 上找活 = 0.0;
        const double 现f = CACurrentMediaTime();
        if (锚真v && 现f - 上找活 >= 10.0) {
            上找活 = 现f;
            一内找活(一);
        }
    }
}

// ==================== v47：两跳指针轨迹 + 野怪已知真值对照 ====================
// v46 实测（_ab_v46.log）留了三个必须解释的事实：
//  ① 同一个槽（槽世键未变，实体不变）的 二+0x44 仍在两组值之间跳：
//     k3 (47770,-27742) → (2027,418) → (38221,-34237) → (36500,34000)，最大距 68259。
//  ② `二失=375/1750`，约 21% 的槽帧读不到 二，那一帧退回三链投票，
//     于是输出里又出现 v36 的老僵尸值 (53395,56435)/(54045,54045)/(56368,53358)。
//  ③ 我方自检的「最近者即我」不可靠：自身那一帧读失败时，它会挑到站泉水的队友
//     （k4 二(1300,1299) 恒定、距心 323→2578 一路涨），所以「距心」不能单独用来判死偏移。
// 要分清 ① 是「指针在换人」还是「对象里存了两份」，只能逐帧看指针本身：
//   二 在两个地址间换 → 指针级换人（链的某一跳不稳）
//   二 恒定、值在两组间换 → 同一对象里两份状态（逻辑位/插值位）
// 另加一条对照：野怪用 +0x2B8 读出来一直是真坐标（v24 起用小地图 20 点标定过），
//   把野怪的 0x2B8 与 野怪的二+0x44 并排打出来，就能判断 +0x44 到底是不是位置字段。
static int 轨迹帧 = 0, 轨迹计 = 0;
static void __attribute__((unused)) 指针轨迹(uint64_t 数组, int 数量) {
    if (轨迹计 >= 400) return;
    if (++轨迹帧 < 6) return;               // 约 10Hz
    轨迹帧 = 0;
    for (int k = 0; k < 数量 && k < 12 && 轨迹计 < 400; ++k) {
        uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(e)) continue;
        uint64_t 一 = vm_read<uint64_t>(e + 0xa8);
        uint64_t 二 = IsValidAddr(一) ? vm_read<uint64_t>(一 + 0x10) : 0;
        int x = 0, z = 0;
        if (IsValidAddr(二)) {
            x = vm_read<int>(二 + 0x44);
            z = vm_read<int>(二 + 0x4C);
        }
        日志("轨迹 k=%d 实体=%llx 一=%llx 二=%llx v(%d,%d)", k,
             (unsigned long long)e, (unsigned long long)一, (unsigned long long)二, x, z);
        轨迹计++;
    }
}

static int 对照帧 = 0, 对照计 = 0;
static void __attribute__((unused)) 野怪对照(void) {
    if (对照计 >= 12) return;
    if (++对照帧 < 20) return;
    对照帧 = 0;
    ++对照计;

    uint64_t 根 = 0;
    uint64_t a = vm_read<uint64_t>(模块基址 + SDK::根野怪);
    if (IsValidAddr(a)) {
        uint64_t b = vm_read<uint64_t>(a + 952);
        if (IsValidAddr(b)) {
            uint64_t c = vm_read<uint64_t>(b + 136);
            if (IsValidAddr(c)) 根 = vm_read<uint64_t>(c + 320);
        }
    }
    if (!IsValidAddr(根)) { 日志("野怪对照 第%d次 根无效", 对照计); return; }

    char 串[460] = {0};
    int 位 = 0;
    for (int i = 0; i < 20 && 位 < 400; ++i) {
        uint64_t 怪 = vm_read<uint64_t>(根 + 24ULL * i);
        if (!IsValidAddr(怪)) continue;
        int x = vm_read<int>(怪 + SDK::坐标X);
        int z = vm_read<int>(怪 + SDK::坐标Y);
        if ((!x && !z) || x < -200000 || x > 200000 || z < -200000 || z > 200000) continue;
        uint64_t 一 = vm_read<uint64_t>(怪 + 0xa8);
        uint64_t 二 = IsValidAddr(一) ? vm_read<uint64_t>(一 + 0x10) : 0;
        int bx = 0, bz = 0;
        if (IsValidAddr(二)) { bx = vm_read<int>(二 + 0x44); bz = vm_read<int>(二 + 0x4C); }
        位 += snprintf(串 + 位, sizeof(串) - 位, "[%d]2B8(%d,%d)二44(%d,%d) ", i, x, z, bx, bz);
    }
    日志("野怪对照 第%d次 %s", 对照计, 串);
}

// ==================== v48：跳变帧四份读数 + 整局快照 ====================
// v47 的 400 行上限只覆盖了开局 5 秒，恰好错过了「跳」爆发的时段（07:50:30 之后）。
// 这两个探针改成「按事件打 + 定期快照 + 上限拉高」，覆盖整局：
//   跳四值：每次世界跳变（>3000）打一行，把 二 的四份值同帧列出，
//           看交替的两组数是「同一字段双缓冲」还是「组A/组B 不同步」。
//   整局快照：每 5 秒打 10 槽的 阵/组A/组B，用来确认哪一组在连续变化。
static int 跳探计 = 0;
static void 跳变四值(int k, uint64_t 实体, unsigned 原X, unsigned 原Z, double 距) {
    if (跳探计 >= 240) return;
    if (k < 0 || k >= 24) return;
    uint64_t 一 = vm_read<uint64_t>(实体 + 0xa8);
    uint64_t 二 = IsValidAddr(一) ? vm_read<uint64_t>(一 + 0x10) : 0;
    const 二十四 r = 读二四(二);
    跳探计++;
    日志("跳四值 k=%d 阵=%d 距%.0f 用(%d,%d) 组A(%d,%d) 组B(%d,%d) 锁组=%d 锁源=%d 二=%llx",
         k, vm_read<int>(实体 + 52), 距, (int)原X, (int)原Z,
         r.A, r.B, r.C, r.D, 槽组[k], 槽锁[k] ? 1 : 0, (unsigned long long)二);
}

static int 快照帧 = 0, 快照计 = 0;
static void 整局快照(uint64_t 数组, int 数量) {
    if (快照计 >= 900) return;
    if (++快照帧 < 300) return;               // 约 5 秒一次
    快照帧 = 0;
    ++快照计;
    char 串[900] = {0};
    int 位 = 0;
    for (int k = 0; k < 数量 && k < 12 && 位 < 820; ++k) {
        uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(e)) continue;
        uint64_t 一 = vm_read<uint64_t>(e + 0xa8);
        uint64_t 二 = IsValidAddr(一) ? vm_read<uint64_t>(一 + 0x10) : 0;
        const 二十四 r = 读二四(二);
        位 += snprintf(串 + 位, sizeof(串) - 位, "k%d/阵%d/%d,%d|%d,%d ", k,
                       vm_read<int>(e + 52), r.A, r.B, r.C, r.D);
    }
    int 跳A = 0, 跳B = 0, 失总 = 0, 二变总 = 0, 一变总 = 0;
    char 失串[240] = {0}, 针串[300] = {0};
    int 失位 = 0, 针位 = 0;
    for (int k = 0; k < 24; ++k) {
        跳A += 槽A跳[k]; 跳B += 槽B跳[k];
        槽A跳[k] = 0; 槽B跳[k] = 0;
        失总 += 槽二失[k];
        二变总 += 槽二指针变[k]; 一变总 += 槽一指针变[k];
        if (k < 12) {
            失位 += snprintf(失串 + 失位, sizeof(失串) - 失位, "%d:%d ", k, 槽二失[k]);
            针位 += snprintf(针串 + 针位, sizeof(针串) - 针位, "%d:%d/%d ",
                             k, 槽二指针变[k], 槽一指针变[k]);
        }
        槽二失[k] = 0;
        槽二指针变[k] = 0; 槽一指针变[k] = 0;
    }
    日志("快照 %d n=%d A跳=%d B跳=%d %s", 快照计, 数量, 跳A, 跳B, 串);
    // v49：分槽的二读失败数（本 5 秒窗口内），看 20% 到底是谁在失败
    日志("二失槽 %d 总=%d %s", 快照计, 失总, 失串);
    // v49：二变 = 「二」的低 32 位在本窗口变了多少次（换对象）；一变 = 「一」的。
    //     二变=0 而 A 值在跳 → 同一对象里两份状态在交替，指针这条路可以彻底排除。
    日志("指针变 %d 二变=%d 一变=%d %s", 快照计, 二变总, 一变总, 针串);
}

// ==================== v52：四槽帧 —— 同帧 4 槽对照 ====================
// 环 dump 每块只装 1 个槽，看不出「跳的这一帧别的槽是什么」。而这局最缺的正是同帧对照：
// 21:49:30 f=2888 四个槽同时跳，但 4 块是分开 dump 的，无法确认「k1 跳后的新值
// 是不是 k3 跳前的旧值」。本行每 3 帧把前 4 个有效槽的 二地址低 32 位 + A/B/C/D
// 打在同一行，最多 400 行（约 20 秒），足够完整覆盖一次跳变前后。
static int 四槽帧 = 0;
static void __attribute__((unused)) 四槽行(uint64_t 数组, int 数量, unsigned 帧) {
    if (四槽帧 >= 400) return;
    if (帧 % 3 != 0) return;
    char 串[700] = {0};
    int 位 = 0, n = 0;
    for (int k = 0; k < 数量 && n < 4 && 位 < 620; ++k) {
        uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(e)) continue;
        uint64_t 一 = vm_read<uint64_t>(e + 0xa8);
        uint64_t 二 = IsValidAddr(一) ? vm_read<uint64_t>(一 + 0x10) : 0;
        if (!IsValidAddr(二)) continue;
        const 二十四 r = 读二四(二);
        位 += snprintf(串 + 位, sizeof(串) - 位, "k%d/%x A(%d,%d) B(%d,%d) | ", k,
                      (unsigned)(二 & 0xFFFFFFFF), r.A, r.B, r.C, r.D);
        ++n;
    }
    if (n == 0) return;
    ++四槽帧;
    日志("四槽 f=%u %s", 帧, 串);
}

// ==================== v50：坐标猎人（真值反查）====================
// v49 实测（_ab_v49.log，50 个环 dump × 40 帧 = 2000 个样本）：
//   ① 指针变 二变=0 一变=0 整整 2000 个样本 —— 每个槽的「一」「二」地址整局一次没变
//      k1 一=dd0a6cb0 二=dbdd9498 / k3 一=dd0a52f0 二=dbddaef4 /
//      k5 一=dd0c48f0 二=dbdb974c / k8 一=dd0b4df0 二=dbdd9c9c / k4 一=dd0c62b0 二=dbdb494c（均低 32 位）
//      → 「指针换人」这条假说彻底排除，对象从头到尾是同一个。
//   ② 但同一帧里两个不同槽会读出完全相同的 8 字节值，连续几十帧：
//      f=5813~5816 k3 与 k8 同为 A(2146,3476)
//      f=5817~5822 k1 与 k8 同为 A(41139,-39956) 接着同变为 A(40582,-40507)
//      f=5951~5956 k1 与 k8 同为 A(-40750,-40750)
//      全日志「值跨槽流转」102 次（A(34430,-45759) 先在 k3，20:17:43 出现在 k5）
//      → 地址不变、内容换人，只能是对象被复用或指向同一份共享数据，不是该实体私有位置。
//   ③ 二失槽 总=300 全部落在 k4 一个槽（其余槽 0）→ 那 20% 失败率是 k4 的垃圾值，
//      不是普遍现象，不能拿它解释全局抖动。
//   ④ 全槽 我=k6 阵=1 二(-57673,-55764) 距心40 → 「二」对本地玩家是对的。
// 于是只剩一个问题：敌方实体自己的坐标存在哪。
// 做法不猜：拿「我」当已知真值（距屏心 < 400px 才采信），扫 实体本体 / 一 / 二 三层，
// 找 int32 恰好等于我方坐标 X 或 Z 的偏移；找到后立刻用同一偏移读全部槽位做交叉验证。
static unsigned char 猎人缓冲[0x4000];
static int 猎人计 = 0;
static int 猎人X层 = -1, 猎人X偏 = -1, 猎人Z层 = -1, 猎人Z偏 = -1;
static void __attribute__((unused)) 坐标猎人(uint64_t 数组, int 数量, const float* 矩阵, float 宽, float 高, unsigned 我方) {
    if (猎人计 >= 60) return;
    static double 上次 = 0.0;
    const double 现时 = CACurrentMediaTime();
    if (现时 - 上次 < 5.0) return;
    上次 = 现时;
    ++猎人计;

    const float 中X = 宽 * 0.5f, 中Y = 高 * 0.5f;
    int 我槽 = -1; double 我距 = 1e9; int 真X = 0, 真Z = 0; uint64_t 我实体 = 0;
    for (int k = 0; k < 数量 && k < 24; ++k) {
        uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(e)) continue;
        if ((unsigned)vm_read<int>(e + 52) != 我方) continue;
        uint64_t 二 = 图解二(图解一(e));
        if (!IsValidAddr(二)) continue;
        const 二十四 r = 读二四(二);
        int x, z;
        if (组可用(r.A, r.B)) { x = r.A; z = r.B; }
        else if (组可用(r.C, r.D)) { x = r.C; z = r.D; }
        else continue;
        float sx = 0.0f, sy = 0.0f;
        if (!投影(矩阵, x, z, &sx, &sy, 宽, 高)) continue;
        double 距 = sqrt((double)(sx - 中X) * (sx - 中X) + (double)(sy - 中Y) * (sy - 中Y));
        if (距 < 我距) { 我距 = 距; 我槽 = k; 真X = x; 真Z = z; 我实体 = e; }
    }
    if (我槽 < 0) { 日志("猎人 %d 找不到我方槽(我方阵营=%u)", 猎人计, 我方); return; }
    if (我距 > 400.0) {
        日志("猎人 %d 我方槽 k=%d 距心%.0f 超过 400px，本拍不采信真值", 猎人计, 我槽, 我距);
        return;
    }

    const uint64_t 一 = 图解一(我实体);
    const uint64_t 二 = 图解二(一);
    const uint64_t 对象[3] = { 我实体, 一, 二 };
    const int      长[3]   = { 0x4000, 0x2000, 0x2000 };
    const char*    层名[3] = { "本体", "一", "二" };

    char 串[700] = {0}; int 位 = 0, 命中 = 0;
    for (int t = 0; t < 3; ++t) {
        if (!IsValidAddr(对象[t])) continue;
        if (!readMemory(对象[t], 猎人缓冲, 长[t])) continue;
        for (int o = 0; o + 4 <= 长[t] && 命中 < 12; o += 4) {
            int v; memcpy(&v, 猎人缓冲 + o, 4);
            if (v > -500 && v < 500) continue;          // 0 / 小值巧合一律不算
            const bool 是X = (v == 真X), 是Z = (v == 真Z);
            if (!是X && !是Z) continue;
            if (是X && 猎人X层 < 0) { 猎人X层 = t; 猎人X偏 = o; }
            if (是Z && 猎人Z层 < 0) { 猎人Z层 = t; 猎人Z偏 = o; }
            位 += snprintf(串 + 位, sizeof(串) - 位, "%s+0x%x=%d%s ",
                           层名[t], o, v, 是X ? (是Z ? "(XZ)" : "(X)") : "(Z)");
            ++命中;
        }
    }
    日志("猎人 %d 我=k%d 阵=%u 距心%.0f 真(%d,%d) 一=%llx 二=%llx 命中%d: %s",
         猎人计, 我槽, 我方, 我距, 真X, 真Z,
         (unsigned long long)一, (unsigned long long)二, 命中, 命中 ? 串 : "无");

    // 命中后立刻交叉验证：同一层同一偏移，读全部槽位，看敌方是否也得到合理且连续的坐标
    if (猎人X层 >= 0 && 猎人X偏 >= 0) {
        char s2[520] = {0}; int p2 = 0;
        for (int k = 0; k < 数量 && k < 12 && p2 < 470; ++k) {
            uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
            if (!IsValidAddr(e)) continue;
            uint64_t o = (猎人X层 == 0) ? e : (猎人X层 == 1 ? 图解一(e) : 图解二(图解一(e)));
            if (!IsValidAddr(o)) continue;
            const int gx = vm_read<int>(o + 猎人X偏);
            int gz = 0;
            if (猎人Z层 == 猎人X层 && 猎人Z偏 >= 0) gz = vm_read<int>(o + 猎人Z偏);
            p2 += snprintf(s2 + p2, sizeof(s2) - p2, "k%d阵%d(%d,%d) ",
                           k, vm_read<int>(e + 52), gx, gz);
        }
        日志("猎人 %d 反查 %s+0x%x / %s+0x%x → %s",
             猎人计, 层名[猎人X层], 猎人X偏,
             (猎人Z层 >= 0 ? 层名[猎人Z层] : "?"), 猎人Z偏, s2);
    }
}

// ==================== v51：猎人2（扩范围 + 三种解释 + 邻域变化）====================
// v50 实测（_ab_v50.log）：
//   ① 命中 9 处，全部是「同一对坐标的副本」：
//      本体+0x278/+0x280、一+0x970/+0x978、二+0x2c/+0x34、二+0x44/+0x4c（间距都是 8 字节）
//   ② 但反查行当场给出反证：本体+0x278/+0x280 在 20:40:25~20:41:30 共 65 秒里
//      k0(-53416,-56414) k1(53395,56435) k2(-53911,-53939) k3(57668,55750)
//      k4(55757,57652) k5(56368,53358) k7(-55764,-57574) k8(54045,54045) 一字未变 ——
//      这些正是加载期 20:16:06「坐标对照」里那批常量 → 本体 0x278 是出生点，不是实时位置。
//   ③ 20:40:55 起我方真值开始变（-57673,-55764 → -41914,-33369 → -28307,-3208 …），
//      命中的 9 处只剩 二+0x2c/+0x34/+0x44/+0x4c 四个 ——
//      说明「实时位置」只在二对象里，实体本体里只有出生点。
//   ④ 但 二 是共享池（v49 已证），且同一帧内读两次值都不同：
//      跳四值 k=1 用(12942,13440) 组A(12758,13272) 组B(12942,13440) —— 锁组=1 却用上了组B，
//      说明判定组A可用时读到的是越界垃圾、打印时重读又变回界内，一帧内被改写多次。
// 于是 v51 补两件测量（仍不改绘制）：
//   A. 把扫描范围从 0x4000/0x2000/0x2000 扩到 0x8000/0x6000/0x3000，
//      并且不只认 int32 精确相等，同时认 float（毫米）与 float（米）三种解释 ——
//      v50 只认 int32，若实体里存的是浮点，就会 0 命中。
//   B. 邻域变化：每 5 秒对每槽读一遍本体 0x8000，只打印「变了、界内、单步幅度 50~6000」
//      的偏移。不管单位是什么，实时位置一定在这个集合里 —— 这能把范围从 32KB 缩到几个偏移。
static inline float 绝对值f(float x) { return x < 0.0f ? -x : x; }
static unsigned char 猎2缓冲[0x8000];
static int 猎2计 = 0;
static int 猎2X层 = -1, 猎2X偏 = -1, 猎2X型 = 0, 猎2Z层 = -1, 猎2Z偏 = -1, 猎2Z型 = 0;
static void __attribute__((unused)) 坐标猎人2(uint64_t 数组, int 数量, const float* 矩阵, float 宽, float 高, unsigned 我方) {
    if (猎2计 >= 40) return;
    static double 上次 = 0.0;
    const double 现时 = CACurrentMediaTime();
    if (现时 - 上次 < 8.0) return;
    上次 = 现时;
    ++猎2计;

    const float 中X = 宽 * 0.5f, 中Y = 高 * 0.5f;
    int 我槽 = -1; double 我距 = 1e9; int 真X = 0, 真Z = 0; uint64_t 我实体 = 0;
    for (int k = 0; k < 数量 && k < 24; ++k) {
        uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(e)) continue;
        if ((unsigned)vm_read<int>(e + 52) != 我方) continue;
        uint64_t 二 = 图解二(图解一(e));
        if (!IsValidAddr(二)) continue;
        const 二十四 r = 读二四(二);
        int x, z;
        if (组可用(r.A, r.B)) { x = r.A; z = r.B; }
        else if (组可用(r.C, r.D)) { x = r.C; z = r.D; }
        else continue;
        float sx = 0.0f, sy = 0.0f;
        if (!投影(矩阵, x, z, &sx, &sy, 宽, 高)) continue;
        double 距 = sqrt((double)(sx - 中X) * (sx - 中X) + (double)(sy - 中Y) * (sy - 中Y));
        if (距 < 我距) { 我距 = 距; 我槽 = k; 真X = x; 真Z = z; 我实体 = e; }
    }
    if (我槽 < 0 || 我距 > 400.0) {
        日志("猎2 %d 无真值(我槽=%d 距心%.0f)", 猎2计, 我槽, 我距);
        return;
    }

    const uint64_t 一 = 图解一(我实体);
    const uint64_t 二 = 图解二(一);
    const uint64_t 对象[3] = { 我实体, 一, 二 };
    const int      长[3]   = { 0x8000, 0x6000, 0x3000 };
    const char*    层名[3] = { "本体", "一", "二" };

    char 串[820] = {0}; int 位 = 0, 命中 = 0;
    for (int t = 0; t < 3; ++t) {
        if (!IsValidAddr(对象[t])) continue;
        int 实长 = 长[t];
        while (实长 >= 0x400 && !readMemory(对象[t], 猎2缓冲, 实长)) 实长 /= 2;   // 跨页读不到就降档，别整层丢掉
        if (实长 < 0x400) continue;
        for (int o = 0; o + 4 <= 实长 && 命中 < 14; o += 4) {
            int v; memcpy(&v, 猎2缓冲 + o, 4);
            float f; memcpy(&f, &v, 4);
            char 型[16] = {0};
            bool 是X = false, 是Z = false;
            // ① int32 精确相等（v50 用的就是这一条）
            if (v > -500 && v < 500) {
                // 落到 ±500 内的一律不认 int，交给浮点解释，避免 0 / 小值巧合
            } else if (v == 真X) {
                是X = true; snprintf(型, sizeof(型), "i");
            } else if (v == 真Z) {
                是Z = true; snprintf(型, sizeof(型), "i");
            }
            // ② 浮点解释：毫米 float 与 米 float 两种都试
            if (!是X && !是Z) {
                if (绝对值f(f) > 500.0f && 绝对值f(f - (float)真X) < 0.6f) {
                    是X = true; snprintf(型, sizeof(型), "f%.1f", (double)f);
                } else if (绝对值f(f) > 500.0f && 绝对值f(f - (float)真Z) < 0.6f) {
                    是Z = true; snprintf(型, sizeof(型), "f%.1f", (double)f);
                } else if (绝对值f(f) > 0.5f && 绝对值f(f * 1000.0f - (float)真X) < 6.0f) {
                    是X = true; snprintf(型, sizeof(型), "f%.2f", (double)f);
                } else if (绝对值f(f) > 0.5f && 绝对值f(f * 1000.0f - (float)真Z) < 6.0f) {
                    是Z = true; snprintf(型, sizeof(型), "f%.2f", (double)f);
                }
            }
            if (!是X && !是Z) continue;
            if (是X && 猎2X层 < 0) { 猎2X层 = t; 猎2X偏 = o; 猎2X型 = 型[0]; }
            if (是Z && 猎2Z层 < 0) { 猎2Z层 = t; 猎2Z偏 = o; 猎2Z型 = 型[0]; }
            位 += snprintf(串 + 位, sizeof(串) - 位, "%s+0x%x=%s%s ",
                           层名[t], o, 型, 是X ? (是Z ? "(XZ)" : "(X)") : "(Z)");
            ++命中;
        }
    }
    日志("猎2 %d 我=k%d 真(%d,%d) 距心%.0f 命中%d: %s",
         猎2计, 我槽, 真X, 真Z, 我距, 命中, 命中 ? 串 : "无");
}

// 邻域变化：不管单位是什么，实时位置一定「每帧在变且单步幅度小」。每 5 秒对比一次。
static unsigned char 邻前[12][0x8000];
static int  邻长[12] = {0};
static bool 邻就绪[24] = {false};
static int  邻计 = 0;
static void __attribute__((unused)) 邻域变化(uint64_t 数组, int 数量) {
    if (邻计 >= 100) return;
    static double 上次 = 0.0;
    const double 现时 = CACurrentMediaTime();
    if (现时 - 上次 < 5.0) return;
    上次 = 现时;
    ++邻计;
    for (int k = 0; k < 数量 && k < 12; ++k) {
        uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(e)) { 邻就绪[k] = false; continue; }
        int 实长 = 0x8000;
        while (实长 >= 0x400 && !readMemory(e, 猎2缓冲, 实长)) 实长 /= 2;
        if (实长 < 0x400) { 邻就绪[k] = false; continue; }
        if (!邻就绪[k] || 邻长[k] != 实长) {
            memcpy(邻前[k], 猎2缓冲, 实长);
            邻长[k] = 实长;
            邻就绪[k] = true;
            continue;
        }
        char 串[560] = {0}; int 位 = 0, 条 = 0;
        for (int o = 0; o + 4 <= 实长 && 条 < 6; o += 4) {
            int a, b;
            memcpy(&a, 邻前[k] + o, 4);
            memcpy(&b, 猎2缓冲 + o, 4);
            if (a == b) continue;
            if (b <= -110000 || b >= 110000) continue;
            long long d = (long long)b - (long long)a;
            if (d < 0) d = -d;
            if (d < 50 || d > 6000) continue;
            位 += snprintf(串 + 位, sizeof(串) - 位, "+0x%x %d->%d ", o, a, b);
            ++条;
        }
        memcpy(邻前[k], 猎2缓冲, 实长);
        日志("邻 %d k=%d 阵=%d 变%d: %s", 邻计, k, vm_read<int>(e + 52), 条, 条 ? 串 : "无");
    }
}

// ==================== v52：层邻 —— 逐帧扫 一/二/三 三层，找「每帧都在动」的坐标字段 ====================
// 依据 _ab_v51.log（21:47:34~21:53 联机局）：
//  (1) 21:49:01~21:49:26（快照 4~9）A 组与 B 组逐采样完全相同，k1 从 (53395,56435) 连续跑到
//      (3741,3972)，五个采样点线性下降 —— 这是真位置，也正是打离线人机时的状态；
//  (2) 21:49:30 f=2888 同一帧，k1/k3/k8/k6 四个槽同时跳，A≠B，B 从此冻结在分叉瞬间的值
//      （k1 的 B=(2649,2586) 整局一动不动），A 每 34~40 帧整块换成另一个位置；
//  (3) 环 dump 1480 个样本：k1 有 5 段「34 帧一字未变」、2 段「40 帧一字未变」，
//      而 k3 有 9 段只有 3 帧 —— 假值卡住不动、真值每帧微动，这是可以用来自动判别的指纹；
//  (4) 实体本体 0x8000 内没有任何「变了 + 界内 + 单步 50~6000」的 X/Z 联动（450 行全是
//      每次 +76 的计时器和 ±1000 的方向分量）→ 本体里没有实时坐标；
//  (5) 链中间：k5 的链读末址 2c1c55c40 = k3 的「二」2c1c55c14 + 0x2C，所以 21:49:56 两槽读出
//      完全相同的 (56368,53358) 不是巧合 —— k5 二读失败退化到链读，正好读到 k3 的字段。
// 缺口：v51 只扫了实体本体，没扫 一/二/三。而游戏能把人画得平滑，必然存在一个「每帧更新」的
// 位置。本探针就去这三层里找它：只统计「变了 + 新旧都界内 + 单步 1~3000」的偏移，
// 每 5 秒按命中次数出一张 top 榜。10Hz 采样，纯读，不参与绘制。
#define 层邻层数 3
static const int   层长表[层邻层数] = {0x6000, 0x3000, 0x2000};   // 一 / 二 / 三
static const char* 层名表[层邻层数] = {"一", "二", "三"};
#define 层邻半长 0x1800
static unsigned short 层次[层邻层数][层邻半长];
static int            层旧[层邻层数][层邻半长];
static int            层新[层邻层数][层邻半长];
static unsigned char  层今[0x6000];
static unsigned char  层前[4][层邻层数][0x6000];
static bool           层有前[4][层邻层数];
static int            层实长[4][层邻层数];
static unsigned       层上帧 = 0;
static int            层轮数 = 0;
static int            层汇总计 = 0;

static void 层邻汇总(void) {
    ++层汇总计;
    for (int t = 0; t < 层邻层数; ++t) {
        char 串[600] = {0};
        int 位 = 0, 打 = 0;
        bool 用过[层邻半长];
        memset(用过, 0, sizeof(用过));
        while (打 < 8) {
            int 最好 = -1, 最次 = 0;
            for (int o = 0; o < 层邻半长; ++o) {
                if (用过[o]) continue;
                if (层次[t][o] > 最次) { 最次 = 层次[t][o]; 最好 = o; }
            }
            if (最好 < 0) break;
            用过[最好] = true;
            位 += snprintf(串 + 位, sizeof(串) - 位, "+0x%x %d/%d %d->%d  ",
                         最好 * 4, (int)层次[t][最好], 层轮数, 层旧[t][最好], 层新[t][最好]);
            ++打;
        }
        日志("层频 %d %s %s", 层汇总计, 层名表[t], 打 ? 串 : "无");
    }
}

static void __attribute__((unused)) 层邻(uint64_t 数组, int 数量) {
    if (层上帧++ % 6 != 0) return;                 // 10Hz 采样
    if (层汇总计 >= 400) return;

    uint64_t 实体[4] = {0, 0, 0, 0};
    int n = 0;
    for (int k = 0; k < 数量 && n < 4; ++k) {
        uint64_t e = vm_read<uint64_t>(数组 + 24ULL * k);
        if (IsValidAddr(e)) 实体[n++] = e;
    }
    if (n == 0) return;
    ++层轮数;

    static double 上次汇总 = 0.0;
    const double 现时 = CACurrentMediaTime();
    if (现时 - 上次汇总 >= 5.0) {
        上次汇总 = 现时;
        层邻汇总();
    }

    for (int i = 0; i < n; ++i) {
        uint64_t 一 = vm_read<uint64_t>(实体[i] + 0xa8);
        if (!IsValidAddr(一)) continue;
        uint64_t 二 = vm_read<uint64_t>(一 + 0x10);
        uint64_t 三 = IsValidAddr(二) ? vm_read<uint64_t>(二 + 0x0) : 0;
        uint64_t 层址[层邻层数] = {一, 二, 三};

        for (int t = 0; t < 层邻层数; ++t) {
            if (!IsValidAddr(层址[t])) continue;
            int 实长 = 层长表[t];
            while (实长 >= 0x400 && !readMemory(层址[t], 层今, 实长)) 实长 /= 2;
            if (实长 < 0x400) continue;
            if (!层有前[i][t] || 层实长[i][t] != 实长) {
                memcpy(层前[i][t], 层今, 实长);
                层实长[i][t] = 实长;
                层有前[i][t] = true;
                continue;
            }
            for (int o = 0; o + 4 <= 实长; o += 4) {
                int a, b;
                memcpy(&a, 层前[i][t] + o, 4);
                memcpy(&b, 层今 + o, 4);
                if (a == b) continue;
                if (a <= -60000 || a >= 60000) continue;   // 两端都要像坐标
                if (b <= -60000 || b >= 60000) continue;
                if (a == 0 || b == 0) continue;             // 0 是初始化，不是位置
                long long d = (long long)b - (long long)a;
                if (d < 0) d = -d;
                if (d < 1 || d > 3000) continue;            // 单步 1~3 米
                const int 格 = o / 4;
                if (层次[t][格] < 65535) 层次[t][格]++;
                层旧[t][格] = a; 层新[t][格] = b;
            }
            memcpy(层前[i][t], 层今, 实长);
        }
    }
}

// ==================== v39：锁定实体逐帧坐标序列 ====================
// 扫描候选表要 20 秒才出，先打 200 帧原始序列，肉眼就能看出「交替」的周期，
// 以及交替两组值里哪一组在连续。
static uint64_t 序列键 = 0;
static int      序列计 = 0;
static void 记坐标序列(int k, uint64_t 实体, unsigned 原X, unsigned 原Z, int 链号,
                     unsigned 直X, unsigned 直Z, bool 直有) {
    if (序列计 >= 200) return;
    if (序列键 == 0) 序列键 = 实体;
    if (实体 != 序列键) return;
    日志("序列 k=%d 链=%s (%d,%d) 直=%s(%d,%d)", k, 链名(链号), (int)原X, (int)原Z,
         直有 ? "" : "无", 直有 ? (int)直X : 0, 直有 ? (int)直Z : 0);
    序列计++;
    if (序列计 == 200) 日志("=== 坐标序列 200 帧记录完毕 ===");
}

// 诊断：把当前链每一步解出来的指针打出来，用来判断「两个位置」是不是
// 中间某一跳指向了不同对象（打印前 8 次，开销可忽略）
static void 记链中间(int k, uint64_t 实体) {
    if (当前链 < 0 || 当前链 >= 3) return;
    const SDK::坐标链& 链 = SDK::坐标链表[当前链];
    uint64_t p = 实体, a = 0, b = 0, c = 0, d = 0;
    if (!链步(&p, 链.一)) return; a = p;
    if (!链步(&p, 链.二)) return; b = p;
    if (!链步(&p, 链.三)) return; c = p;
    if (!链步(&p, 链.四)) return; d = p;
    日志("链中间 k=%d 实体=%llx 一=%llx 二=%llx 三=%llx 址=%llx",
         k, (unsigned long long)实体, (unsigned long long)a, (unsigned long long)b,
         (unsigned long long)c, (unsigned long long)d);
}
static int 稳定英雄ID(int k, uint64_t 实体, int 血上限) {
    if (k < 0 || k >= 24) return 0;
    // 槽位换人 → 重置（血量上限也变说明同槽位被另一个对象复用）
    bool 换人 = (槽实体[k] != 实体);
    if (!换人 && 槽上限[k] > 0 && 血上限 > 0) {
        int 差 = 槽上限[k] - 血上限;
        if (差 < 0) 差 = -差;
        if (差 > 槽上限[k] / 4) 换人 = true;
    }
    if (换人) { 槽实体[k] = 实体; 槽上限[k] = 血上限; 槽英雄ID[k] = 0; }
    if (槽英雄ID[k] <= 0) {
        long long 原始 = vm_read<long long>(实体 + 40);
        if (原始 >= 100 && 原始 <= 999) 槽英雄ID[k] = (int)原始;
    }
    return 槽英雄ID[k];
}

static unsigned 读召唤技能ID(uint64_t 技能对象) {
    uint64_t a = vm_read<uint64_t>(技能对象 + SDK::技能对象);
    if (!IsValidAddr(a)) return 0;
    uint64_t b = vm_read<uint64_t>(a + SDK::技能中转);
    if (!IsValidAddr(b)) return 0;
    int id = vm_read<int>(b + SDK::技能ID);
    if (id <= 0 || id >= 100000) return 0;
    return (unsigned)id;
}

// CD：技能对象+偏移 → +248 → +60，秒 = (原始+8191999)/8192000 封顶 999
static unsigned 读CD秒(uint64_t 技能对象, uint64_t 偏移) {
    uint64_t a = vm_read<uint64_t>(技能对象 + 偏移);
    if (!IsValidAddr(a)) return 0;
    uint64_t b = vm_read<uint64_t>(a + 248);
    if (!IsValidAddr(b)) return 0;
    int 原始 = vm_read<int>(b + 60);
    if (原始 <= 0) return 0;
    unsigned 秒 = (unsigned)((原始 + 8191999) / 8192000);
    if (秒 > 999) return 0;
    return 秒;
}

// 回城检测：技能对象+360 → +272 ≥0x128 且 (值-296)==1
// 返回 0=不在回城 1=指针链命中 2=直读字段命中 3=状态字段(非零)
// 注意：SDK 写的是「实体+360」，以前调用方传的是技能对象（实体+488 解出来的那个），
// 层级错了一级，所以判值永远是 0、来源永远是 0 —— 回城横幅自然一次都不弹。
// ===== 回城轨迹（完全不依赖 SDK 偏移）=====
// 回城 = 站定不动约 8 秒 → 瞬移回泉水。用两条判据组合，跟内存结构无关，换赛季也不会失效：
//   静止 >= 5 秒                    → 候选（小地图头像旁打一个黄色 ?）
//   静止 >= 5 秒之后的瞬移 > 25000   → 确认回城（顶部横幅 6 秒）
// 25000 这个门槛：闪现/位移技能最大约 8000，泉水瞬移 40000 以上，中间不会误判。
struct 回城轨迹 {
    long long 英雄 = 0;
    int 上X = 0, 上Z = 0;
    double 静止起 = 0.0;
    double 确认到 = 0.0;
    bool 候选 = false;
};
static 回城轨迹 轨迹表[24];

static int 读回城来源(uint64_t 实体) {
    uint64_t a = vm_read<uint64_t>(实体 + SDK::回城对象);
    if (IsValidAddr(a)) {
        uint64_t b = vm_read<uint64_t>(a + SDK::回城状态);
        if (IsValidAddr(b) && b >= 0x128 && vm_read<int>(b - 296) == 1) return 1;
        // SDK 注释："+272 非零即在回城"，把那个字段直接当状态读
        int 状态 = vm_read<int>(a + SDK::回城状态);
        if (状态 == 1) return 3;
    }
    // 最外层兜底：实体+360 本身就是状态字（指针低 32 位不可能恰好等于 1，误报可忽略）
    if (vm_read<int>(实体 + SDK::回城对象) == 1) return 2;
    return 0;
}

// ==================== v28 倒数扫描 ====================
// v27 的教训：实体 +0x0..+0x3000 里只有坐标/动画/指针，没有任何 8→0 的浮点读条。
// 两种可能：① 读条是「毫秒整数」（8000→0），按 float 解释是 4e-41 这种次正规数，
// 按整数看又被 >4096 的阈值挡掉 —— v27 两套探测器同时漏掉它；② 状态在组件对象里。
// v28 把两条路一起补上：同一块内存同时按 float 和 int 解释，只报「连续两秒以上在降」；
// 并且从实体里挑出堆指针（高 32 位 == 2，即 0x2xxxxxxxx），对子对象也做同样的扫描。
static const int 扫主长 = 0x4000;
static const int 扫子长 = 0x2000;
static const int 扫子数 = 4;

struct 扫表 {
    unsigned char* 前;    // 上一秒的原始 4 字节快照
    unsigned char* 计;    // 连续下降秒数
    float* 起;            // 本轮连续下降的起点值
    int 长;
    uint64_t 对象;
    double 时;
    bool 就绪;
};

static 扫表 扫表集[24][1 + 扫子数];
static unsigned char 扫前池[24][扫主长 + 扫子数 * 扫子长];
static unsigned char 扫计池[24][扫主长 / 4 + 扫子数 * 扫子长 / 4];
static float 扫起池[24][扫主长 / 4 + 扫子数 * 扫子长 / 4];
static unsigned char 扫读缓冲[扫主长];
static uint64_t 扫实体键[24] = {0};

// 命中回传给调用方（候选台是函数内变量，这里只能先记全局）
static int 命中偏移 = -1;
static uint64_t 命中对象 = 0;
static float 命中起值 = 0.0f;
static bool 命中浮点 = false;

static void 扫绑定(int k, uint64_t 实体) {
    扫实体键[k] = 实体;
    unsigned char* 前基 = 扫前池[k];
    unsigned char* 计基 = 扫计池[k];
    float* 起基 = 扫起池[k];
    for (int t = 0; t <= 扫子数; ++t) {
        扫表& 表 = 扫表集[k][t];
        const int 长 = (t == 0) ? 扫主长 : 扫子长;
        表.前 = 前基 + (t == 0 ? 0 : 扫主长 + (t - 1) * 扫子长);
        表.计 = 计基 + (t == 0 ? 0 : (扫主长 / 4) + (t - 1) * (扫子长 / 4));
        表.起 = 起基 + (t == 0 ? 0 : (扫主长 / 4) + (t - 1) * (扫子长 / 4));
        表.长 = 长;
        表.对象 = 0;
        表.时 = 0.0;
        表.就绪 = false;
    }
    扫表集[k][0].对象 = 实体;
    // 从实体头部挑子对象：高 32 位 == 2 的 8 字节值就是 0x2xxxxxxxx 堆指针。
    // 尾部跨页读不到就降档重试，别因为读不满 16KB 就一条子链都不找。
    for (int 试 = 扫主长; 试 >= 0x1000; 试 /= 2) {
        if (!readMemory(实体, 扫读缓冲, 试)) continue;
        int 用 = 0;
        for (int o = 0; o + 8 <= 试 && 用 < 扫子数; o += 8) {
            uint64_t v; memcpy(&v, 扫读缓冲 + o, 8);
            if ((v >> 32) != 2ULL) continue;
            if (v == 实体) continue;
            扫表集[k][1 + 用].对象 = v;
            ++用;
        }
        break;
    }
}

static void 扫一遍(int k, int 阵营, 扫表& 表, bool 是子, double 现时) {
    if (!表.对象) return;
    if (!表.就绪) {
        if (!readMemory(表.对象, 扫读缓冲, 表.长)) {
            if (表.长 > 0x1000) 表.长 /= 2;      // 跨页读不到就降档，别整个放弃
            return;
        }
        memcpy(表.前, 扫读缓冲, 表.长);
        memset(表.计, 0, 表.长 / 4);
        memset(表.起, 0, (表.长 / 4) * sizeof(float));
        表.就绪 = true;
        表.时 = 现时;
        if (是子)
            日志("子扫就绪 k=%d 阵=%d 对象=%llx 长=0x%x", k, 阵营, 表.对象, 表.长);
        return;
    }
    if (现时 - 表.时 < 1.0) return;
    表.时 = 现时;
    if (!readMemory(表.对象, 扫读缓冲, 表.长)) return;

    int 行 = 0;
    for (int o = 0; o + 4 <= 表.长; o += 4) {
        const int i = o >> 2;
        int 旧, 新;
        memcpy(&旧, 表.前 + i * 4, 4);
        memcpy(&新, 扫读缓冲 + o, 4);
        memcpy(表.前 + i * 4, 扫读缓冲 + o, 4);
        if (旧 == 新) { 表.计[i] = 0; 表.起[i] = 0.0f; continue; }
        float 旧f, 新f;
        memcpy(&旧f, &旧, 4);
        memcpy(&新f, &新, 4);
        // ① 浮点倒数：0.02 ~ 12.5，每秒掉 > 0.05
        if (旧f > 0.02f && 旧f < 12.5f && 新f > 0.02f && 新f < 12.5f && (旧f - 新f) > 0.05f) {
            if (表.计[i] == 0) 表.起[i] = 旧f;
            if (表.计[i] < 250) ++表.计[i];
            if (表.计[i] >= 2 && 行 < 6) {
                日志("倒f%s k=%d 阵=%d +0x%03x %.2f->%.2f 连降%d",
                     是子 ? "子" : "", k, 阵营, o, 旧f, 新f, (int)表.计[i]);
                ++行;
            }
            if (新f < 0.5f && 表.计[i] >= 3 && 表.起[i] >= 6.0f) {
                命中偏移 = o; 命中对象 = 表.对象; 命中起值 = 表.起[i]; 命中浮点 = true;
            }
            continue;
        }
        // ② 整数倒数：毫秒计时器 8000→0 这种，float 解释是次正规数看不见，整数又过不了阈值
        if (旧 > 100 && 旧 < 30000 && 新 >= 0 && 新 < 旧 && (旧 - 新) > 30 && (旧 - 新) < 3000) {
            if (表.计[i] == 0) 表.起[i] = (float)旧;
            if (表.计[i] < 250) ++表.计[i];
            if (表.计[i] >= 2 && 行 < 6) {
                日志("倒i%s k=%d 阵=%d +0x%03x %d->%d 连降%d",
                     是子 ? "子" : "", k, 阵营, o, 旧, 新, (int)表.计[i]);
                ++行;
            }
            if (新 < 60 && 表.计[i] >= 3 && 表.起[i] >= 3000.0f) {
                命中偏移 = o; 命中对象 = 表.对象; 命中起值 = 表.起[i]; 命中浮点 = false;
            }
            continue;
        }
        表.计[i] = 0; 表.起[i] = 0.0f;
    }
}

// ==================== 矩阵 / 投影 ====================

// 读相机矩阵：根相机(或备) → +184 → +0 → +8 → 矩阵@+296（16 float）
static bool 读相机矩阵(uint64_t 模块, uint64_t 相机偏移, float* 矩阵) {
    uint64_t a = vm_read<uint64_t>(模块 + 相机偏移);
    if (!IsValidAddr(a)) return false;
    uint64_t b = vm_read<uint64_t>(a + 184);
    if (!IsValidAddr(b)) return false;
    uint64_t c = vm_read<uint64_t>(b);
    if (!IsValidAddr(c)) return false;
    相机内层 = c;
    uint64_t d = vm_read<uint64_t>(c + 8);
    if (!IsValidAddr(d)) return false;
    // v38：一次读 64 字节。原来是 16 次独立 vm_read，读到一半相机更新了，
    // 就会拼出「半新半旧」的矩阵 —— 所有实体一起抖，也是一种「闪」。
    unsigned char 快照[64];
    if (!readMemory(d + 296, 快照, sizeof(快照))) return false;
    memcpy(矩阵, 快照, sizeof(快照));
    for (int i = 0; i < 16; ++i)
        if (!isfinite(矩阵[i]) || 绝对值f(矩阵[i]) > 10000000.0f) return false;
    if (绝对值f(矩阵[0]) > 0.000001f && 绝对值f(矩阵[5]) > 0.000001f && 绝对值f(矩阵[15]) > 0.000001f) {
        相机节点 = d;
        return true;
    }
    return false;
}

// 读矩阵（主相机失败自动切备并记住）
// v39 诊断：矩阵帧间变化（判断投影本身是否在抖）
static float 上矩阵[16] = {0};
static bool  上矩阵有 = false;
static float 矩阵最大变[16] = {0};

static bool 读矩阵(uint64_t 模块, float* 矩阵) {
    if (用备相机) {
        if (读相机矩阵(模块, SDK::根相机, 矩阵)) return true;
        if (读相机矩阵(模块, SDK::根相机备, 矩阵)) { 用备相机 = false; return true; }
        return false;
    } else {
        if (读相机矩阵(模块, SDK::根相机备, 矩阵)) return true;
        if (读相机矩阵(模块, SDK::根相机, 矩阵)) { 用备相机 = true; return true; }
        return false;
    }
}

// 投影：世界坐标(int/1000) → 屏幕像素
static bool 投影(const float* m, int 世界X, int 世界Z, float* 屏X, float* 屏Y, float 宽, float 高) {
    float x = 世界X / 1000.0f;
    float z = 世界Z / 1000.0f;
    float w = m[2] * x + m[10] * z + m[14];
    if (!isfinite(w) || w < 0.001f) return false;
    float inv = 1.0f / w;
    float px = (m[0] * x + m[8] * z + m[12]) * inv;
    float py = (m[1] * x + m[9] * z + m[13]) * inv;
    if (!isfinite(px) || !isfinite(py)) return false;
    *屏X = (px + 1.0f) * 宽 * 0.5f;
    *屏Y = (1.0f - py) * 高 * 0.5f;
    return true;
}

// 矩阵列长（相机节点的 Z 列长度）
static float 矩阵列长(const float* m) {
    return sqrtf(m[4] * m[4] + m[5] * m[5] + m[6] * m[6]);
}
// 列长 → fovY 弧度
static float 列长转视距(const float* m) {
    float len = 矩阵列长(m);
    return len > 0.05f ? 2.0f * atanf(1.0f / len) : 0.0f;
}

// ==================== 相机探测 ====================

// 目的：找出游戏的小地图相机（正交、视口在小地图那块），拿到它的视口矩形后
// 就不用再拿屏幕短边乘系数去猜小地图的位置和大小了。
// 纯读，10 秒一次，failsafe：地址不合法就跳过，不会写任何内存。
static void 相机探测(uint64_t 模块) {
    static double 上次 = 0;
    double now = CACurrentMediaTime();
    if (now - 上次 < 10.0) return;
    上次 = now;

    const uint64_t 根表[2] = { SDK::根相机, SDK::根相机备 };
    for (int r = 0; r < 2; ++r) {
        uint64_t a = vm_read<uint64_t>(模块 + 根表[r]);
        if (!IsValidAddr(a)) continue;
        uint64_t b = vm_read<uint64_t>(a + 184);
        if (!IsValidAddr(b)) continue;
        日志("相机探测 根%d a=0x%llx b=0x%llx", r, a, b);
        for (int i = 0; i < 8; ++i) {
            uint64_t c = vm_read<uint64_t>(b + 8ULL * i);
            if (!IsValidAddr(c)) continue;
            uint64_t d = vm_read<uint64_t>(c + 8);
            if (!IsValidAddr(d)) continue;
            float m[16];
            bool 正常 = true;
            for (int k = 0; k < 16; ++k) {
                m[k] = vm_read<float>(d + 296 + 4ULL * k);
                if (!isfinite(m[k]) || 绝对值f(m[k]) > 10000000.0f) { 正常 = false; break; }
            }
            if (!正常) continue;
            bool 正交 = 绝对值f(m[11]) < 0.0001f && 绝对值f(m[15] - 1.0f) < 0.0001f;
            日志("  [%d.%d] b=0x%llx c=0x%llx d=0x%llx m11=%.4f m15=%.4f 列长=%.3f %s",
                 r, i, b, c, d, m[11], m[15], 矩阵列长(m), 正交 ? "正交★" : "透视");
            // 视口候选：Unity 的 Camera.rect 是 4 个 0..1 的 float，在物体附近扫一遍
            for (int off = 0; off <= 80; off += 4) {
                float vx = vm_read<float>(d + off);
                float vy = vm_read<float>(d + off + 4);
                float vw = vm_read<float>(d + off + 8);
                float vh = vm_read<float>(d + off + 12);
                if (!isfinite(vx) || !isfinite(vy) || !isfinite(vw) || !isfinite(vh)) continue;
                if (vx < 0.0f || vx > 1.0f || vy < 0.0f || vy > 1.0f) continue;
                if (vw <= 0.0f || vw > 1.0f || vh <= 0.0f || vh > 1.0f) continue;
                if (vw < 0.05f || vh < 0.05f) continue;
                日志("    视口候选 d+%d = (%.3f, %.3f, %.3f, %.3f)", off, vx, vy, vw, vh);
            }
        }
    }
}

// ==================== 视距 ====================

// 写视距：fov_addr 有效才写；单位支持度/弧度
static bool 写视距(float fov) {
    if (!视距地址) {
        static double 上次提示 = 0;
        double now = CACurrentMediaTime();
        if (now - 上次提示 > 60.0) {
            上次提示 = now;
            日志("视距未配置 fov_addr（H5 没有任何写内存函数，这个偏移只能实测）：把 fov_probe=1 打开跑一局，日志会列出相机附近所有可疑 FOV 浮点");
        }
        return false;
    }
    float 目标 = 视距是度 ? fov * 57.296f : fov;
    float 当前 = vm_read<float>(视距地址);
    if (!(isfinite(当前) && 当前 > 0.0f && 当前 <= 200.0f)) {
        static double 上次坏值 = 0;
        double now = CACurrentMediaTime();
        if (now - 上次坏值 > 30.0) {
            上次坏值 = now;
            日志("视距地址 0x%llx 读出来不是合理的浮点（%.4f）→ 不写，换地址再试", 视距地址, 当前);
        }
        return false;
    }
    if (绝对值f(当前 - 目标) < 0.0005f) return true;
    bool ok = writeMemory(视距地址, &目标, 4);
    static double 上次写日志 = 0;
    double now = CACurrentMediaTime();
    if (now - 上次写日志 > 5.0) {
        上次写日志 = now;
        日志("视距 %s 址=0x%llx 原=%.4f 新=%.4f%s 任务端口=%d",
             ok ? "已写" : "写失败", 视距地址, 当前, 目标,
             视距是度 ? "（度）" : "（弧度）", 任务端口 != 0);
    }
    return ok;
}

// 回写视距址到 plist（自校准命中后）
static void 回写视距址(uint64_t 地址, bool 是度) {
    NSString* path = @(设置路径);
    NSMutableDictionary* dict = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if (!dict) dict = [NSMutableDictionary dictionary];
    dict[@"fov_addr"] = [NSString stringWithFormat:@"0x%llx", 地址];
    dict[@"fov_deg"] = @(是度 ? 1 : 0);
    [dict writeToFile:path atomically:YES];
}

// 视距自校准：逐候选写测试，观察列长变化
static bool 视距自校准(const float* 矩阵, float fov) {
    // 已锁定：确认地址仍合理
    if (锁定视距址) {
        float 当前 = vm_read<float>(锁定视距址);
        bool 弧度合理 = isfinite(当前) && 当前 > 0.05f && 当前 < 3.0f;
        bool 度合理   = isfinite(当前) && 当前 > 5.0f && 当前 < 170.0f;
        if (弧度合理 || 度合理) return true;
        日志("视距自校准：锁定地址 0x%llx 失效（读到 %.4f）→ 重新校准", 锁定视距址, 当前);
        锁定视距址 = 0;
        视距地址 = 0;
        视距自校准状态 = 0;
        校准候选数 = 0;
        校准候选索引 = 0;
        校准等待时间 = 0;
    }
    float 当前fov = 列长转视距(矩阵);
    if (当前fov <= 0.05f) return false;
    double now = CACurrentMediaTime();
    if (!视距自校准状态) {
        if (!相机节点) return false;
        校准候选索引 = 0;
        float 目标度 = 当前fov * 57.296f;
        uint64_t 基准[2] = { 相机节点, 相机内层 };
        int 半径[2] = { 768, 768 };
        for (int i = 0; i < 2 && 校准候选数 < 24; ++i) {
            if (!基准[i]) continue;
            for (int off = -半径[i]; off <= 半径[i] && 校准候选数 < 24; off += SDK::视距扫描步进) {
                if (i == 0 && off >= 296 && off < 360) continue;   // 跳过矩阵区
                uint64_t 址径 = 基准[i] + off;
                float v = vm_read<float>(址径);
                if (!isfinite(v)) continue;
                bool 像度 = false;
                if (目标度 <= 6.0f || 绝对值f(v - 目标度) > 目标度 * 0.03f) {
                    if (绝对值f(v - 当前fov) > 当前fov * 0.03f) continue;
                } else {
                    像度 = true;
                }
                校准候选址[校准候选数] = 址径;
                校准候选值[校准候选数] = v;
                校准候选是度[校准候选数] = 像度;
                校准候选数++;
            }
        }
        视距自校准状态 = 校准候选数 ? 1 : 3;
        日志("视距自校准：当前 FOV≈%.1f°（弧度 %.3f），相机附近同值浮点 %d 个",
             目标度, 当前fov, 校准候选数);
        if (!校准候选数) return false;
    }
    if (视距自校准状态 != 1) return false;
    // 每 0.35s 处理一个候选
    if (校准等待时间 > 0.0 && now - 校准等待时间 >= 0.35) {
        int i = 校准候选索引 - 1;
        float 期望 = 1.0f / tanf(fov * 0.5f);
        float 列长 = 矩阵列长(矩阵);
        bool 命中 = false;
        if (期望 > 0.05f) 命中 = (绝对值f(列长 - 期望) / 期望) < 0.08f;
        if (命中 && i >= 0) {
            锁定视距址 = 校准候选址[i];
            视距地址 = 锁定视距址;
            视距是度 = 校准候选是度[i];
            视距自校准状态 = 2;
            回写视距址(锁定视距址, 视距是度);
            日志("视距自校准：命中 址=0x%llx（列长 %.3f → 期望 %.3f，单位%s），已写入 plist 的 fov_addr",
                 锁定视距址, 列长, 期望, 视距是度 ? "度" : "弧度");
            return true;
        }
        if (i >= 0) {
            float 原值 = 校准候选值[i];
            if (!writeMemory(校准候选址[i], &原值, 4))
                日志("视距自校准：0x%llx 还原失败", 校准候选址[i]);
        }
        校准等待时间 = 0;
    }
    if (校准候选索引 < 校准候选数) {
        if (校准等待时间 <= 0.0) {
            int i = 校准候选索引;
            float 目标 = 校准候选是度[i] ? fov * 57.296f : fov;
            float 原值 = vm_read<float>(校准候选址[i]);
            if (!writeMemory(校准候选址[i], &目标, 4)) {
                校准候选索引++;
                return false;
            }
            if (isfinite(原值) && 绝对值f(原值 - 校准候选值[i]) > 0.001f)
                校准候选值[i] = 原值;
            校准候选索引++;
            校准等待时间 = now;
        }
        return false;
    }
    视距自校准状态 = 3;
    日志("视距自校准：%d 个候选写完矩阵都没变 → 本机 FOV 不在相机节点这两层，视距滑条本局无效（把 fov_addr 手填成实测地址才能用）",
         校准候选数);
    return false;
}

// 视距探测扫：列一遍相机附近可疑 FOV 浮点
static void 视距探测扫(const float* 矩阵) {
    if (!相机节点) return;
    static double 上次 = 0;
    static uint64_t 上次节点 = 0;
    double now = CACurrentMediaTime();
    if (上次节点 == 相机节点 && now - 上次 < 60.0) return;
    上次 = now;
    上次节点 = 相机节点;
    float 列长 = 矩阵列长(矩阵);
    float 推算度 = 0.0f;
    if (列长 > 0.05f) 推算度 = 2.0f * atanf(1.0f / 列长) * 180.0f / 3.1416f;
    日志("视距探测：相机节点=0x%llx（矩阵 +0x%llx）列长=%.4f → 推算 fovY≈%.1f 度 / %.4f 弧度",
         相机节点, 296ULL, 列长, 推算度, 推算度 * 3.1416f / 180.0f);
    int 命中 = 0;
    for (int off = -768; off <= 768 && 命中 < 12; off += SDK::视距扫描步进) {
        if (off >= 296 && off < 360) continue;
        uint64_t 址 = 相机节点 + off;
        float v = vm_read<float>(址);
        if (!isfinite(v)) continue;
        bool 像度 = v > 20.0f && v < 100.0f;
        bool 像弧 = v > 0.35f && v < 1.6f;
        if (像度 || 像弧) {
            float 参考 = 像度 ? 推算度 : 推算度 * 3.1416f / 180.0f;
            float 偏差 = 推算度 > 0.0f ? (v / 参考 - 1.0f) * 100.0f : 0.0f;
            日志("  FOV候选 %+dx → 0x%llx = %.4f%s 偏差=%+.1f%%",
                 off, 址, v, 像度 ? "（度）" : "（弧度）", 偏差);
            命中++;
        }
    }
    日志("视距探测结束：命中 %d 个。挑最像的那个，把它的地址填进 fov_addr", 命中);
}

// ==================== 找进程 / getbbz ====================

static uint64_t 全盘扫(uint64_t* 基址出, mach_port_t* 端口出, char* 名字出, int* 扫过数) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    *扫过数 = 0;
    if (sysctl(mib, 4, nullptr, &size, nullptr, 0) || !size) return -1;
    void* buf = malloc(size);
    if (!buf) return -1;
    if (sysctl(mib, 4, buf, &size, nullptr, 0)) { free(buf); return -1; }
    int 自身 = getpid();
    size_t count = size / 0x288;
    int 带框架数 = 0;
    uint64_t 结果 = -1;
    for (size_t i = 0; i < count; ++i) {
        int pid = *(int*)((char*)buf + 648 * i + 40);
        if (pid <= 1 || pid == 自身) continue;
        (*扫过数)++;
        char 名字[64] = {0};
        char 路径[256] = {0};
        mach_port_t 端口 = 0;
        uint64_t 基址 = 找模块基址(pid, &端口, 名字, 路径);
        if (!基址) continue;
        带框架数++;
        bool 指纹 = 基址是MachO(pid, 基址);
        bool 指纹2 = 指纹 ? 指纹成立(pid, 基址) : false;
        bool 路径对 = 路径像游戏(路径);
        if (!指纹 || (!指纹2 && !路径对)) {
            日志("  跳过 pid=%d 名=%s 指纹=%d 路径=0（有 UnityFramework 但不对）", pid, 名字, 指纹2 ? 1 : 0);
            continue;
        }
        if (基址出) *基址出 = 基址;
        if (端口出) *端口出 = 端口;
        if (名字出) strncpy(名字出, *名字 ? 名字 : "?", 63);
        日志("  命中 pid=%d 名=%s 指纹=%d 路径=%d 基=0x%llx 路径串=%s",
             pid, 名字, 指纹2 ? 1 : 0, 路径对 ? 1 : 0, 基址, 路径);
        结果 = pid;
        break;
    }
    if (结果 == (uint64_t)-1)
        日志("全盘扫完 %d 个进程，其中 %d 个带 UnityFramework，都不匹配", *扫过数, 带框架数);
    free(buf);
    return 结果;
}

static bool getbbz() {
    DOJailbreaker* jb = DOJailbreaker.sharedInstance;
    if (!jb.isSuccess) {
        if (模块基址 || 游戏pid > 1) {
            日志("内核已清除 → 作废 pid=%d 模块=0x%llx", 游戏pid, 模块基址);
            模块基址 = 0;
            游戏pid = -1;
            当前链 = -1;
            释放任务端口();
        }
        状态文字 = "等待内核";
        return false;
    }
    // 内核通路自检（最多 5 秒一次）：确认 kread 真能读到内核内存、allproc 符号已解析
    {
        static double 上次自检时刻 = 0;
        double 现在 = CACurrentMediaTime();
        if (现在 - 上次自检时刻 > 5.0) {
            上次自检时刻 = 现在;
            内核自检();
        }
    }
    // 已有基址：校验 MachO
    if (模块基址 && 游戏pid > 1) {
        if (基址是MachO(游戏pid, 模块基址)) {
            校验链();
            return true;
        }
        日志("模块失效（原=0x%llx），重新找", 模块基址);
        模块基址 = 0;
        当前链 = -1;
        状态文字 = "模块失效，重找";
        释放任务端口();
    }
    // 找 pid：sysctl 精确 → sysctl 模糊 → 内核 allproc（fullscan）→ 全盘扫
    pid_t pid = sysctl精确找pid("smoba");
    const char* 命中方式 = "sysctl精确";
    if (pid <= 1) { pid = sysctl模糊找pid(); 命中方式 = "sysctl模糊"; }
    if (pid <= 1) {
        NSDictionary* cfg = [NSDictionary dictionaryWithContentsOfFile:@(设置路径)];
        bool fullscan = cfg && [[cfg objectForKey:@"fullscan"] boolValue];
        if (fullscan) {
            日志("找进程③: 名字没命中 → 走内核 allproc 遍历（fullscan=1 已开，可能卡死）");
            pid = 内核找pid();
            命中方式 = "内核allproc";
        }
    }
    static pid_t 上次命中pid = 0;
    if (pid > 1 && pid != 上次命中pid) {
        上次命中pid = pid;
        日志("找进程: pid=%d（%s命中）", pid, 命中方式);
    }
    if (pid > 1) {
        游戏pid = pid;
        当前链 = -1;
        状态文字 = "找 UnityFramework";
        char 主名[64] = {0};
        char 主路径[256] = {0};
        mach_port_t 端口 = 0;
        uint64_t 基址 = 找模块基址(游戏pid, &端口, 主名, 主路径);
        if (基址 && 基址是MachO(游戏pid, 基址)) {
            模块基址 = 基址;
            校验链();
            bool 指纹 = 指纹成立(游戏pid, 基址);
            日志("就绪：pid=%d（%s命中 主名=%s）基=0x%llx 指纹=%d 路径=%s",
                 游戏pid, 命中方式, 主名, 基址, 指纹 ? 1 : 0, 主路径);
            状态文字 = 指纹 ? "就绪" : "世界根读不到";
            return true;
        }
        游戏pid = pid;
        状态文字 = "两条路线都没拿到模块基址";
        static double 上次失败 = 0;
        double now = CACurrentMediaTime();
        if (now - 上次失败 > 30.0) {
            上次失败 = now;
            日志("名字命中 pid=%d（走%s），但任务端口和内核路线都没拿到基址：基=0x%llx 主名=%s",
                 游戏pid, 命中方式, 基址, 主名);
        }
        return false;
    }
    // 名字没命中
    游戏pid = -1;
    状态文字 = "没找到 smoba 进程";
    static double 上次列表 = 0;
    double now = CACurrentMediaTime();
    if (上次列表 == 0.0 || now - 上次列表 > 60.0) {
        上次列表 = now;
        日志("找进程: 按名字没找到（精确=%d 模糊=%d）→ 列一遍系统进程名", pid, -1);
        列进程表();
    }
    NSDictionary* cfg = [NSDictionary dictionaryWithContentsOfFile:@(设置路径)];
    bool fullscan = cfg && [[cfg objectForKey:@"fullscan"] boolValue];
    if (fullscan) {
        状态文字 = "全盘搜进程（手动开启）";
        uint64_t 基址 = 0;
        mach_port_t 端口 = 0;
        char 名字[64] = {0};
        int 扫过 = 0;
        pid_t 命中 = (pid_t)全盘扫(&基址, &端口, 名字, &扫过);
        if (命中 > 1) {
            游戏pid = 命中;
            模块基址 = 基址;
            当前链 = -1;
            状态文字 = "就绪";
            日志("全盘扫命中 pid=%d 名=%s 基=0x%llx", 命中, 名字, 基址);
            return true;
        }
    }
    return false;
}

// ==================== 野怪 ====================

struct 野怪信息 {
    int x;        // 世界X
    int z;        // 世界Z
    int cd;       // 冷却/重生剩余（秒+3）
    int 刷新;     // 刷新点（秒+3）
    int camp;     // 阵营
};

// 读野怪：根野怪 → +952 → +136 → +320（备链根野怪备），每项 24 字节
static int 读野怪(uint64_t 模块, 野怪信息* 输出, int 上限) {
    uint64_t 根 = 0;
    uint64_t a = vm_read<uint64_t>(模块 + SDK::根野怪);
    if (IsValidAddr(a)) {
        uint64_t b = vm_read<uint64_t>(a + 952);
        if (IsValidAddr(b)) {
            uint64_t c = vm_read<uint64_t>(b + 136);
            if (IsValidAddr(c)) 根 = vm_read<uint64_t>(c + 320);
        }
    }
    if (!IsValidAddr(根)) {
        uint64_t a2 = vm_read<uint64_t>(模块 + SDK::根野怪备);
        if (IsValidAddr(a2)) {
            uint64_t b2 = vm_read<uint64_t>(a2 + 952);
            if (IsValidAddr(b2)) {
                uint64_t c2 = vm_read<uint64_t>(b2 + 136);
                if (IsValidAddr(c2)) 根 = vm_read<uint64_t>(c2 + 320);
            }
        }
    }
    if (!IsValidAddr(根)) return 0;
    int 数 = 0;
    for (int i = 0; i < 20 && 数 < 上限; ++i) {
        uint64_t 怪 = vm_read<uint64_t>(根 + 24ULL * i);
        if (!IsValidAddr(怪)) continue;
        int x = vm_read<int>(怪 + SDK::坐标X);
        int z = vm_read<int>(怪 + SDK::坐标Y);
        if (x < -200000 || x > 200000 || z < -200000 || z > 200000 || (!x && !z)) continue;
        int cd = vm_read<int>(怪 + SDK::技能CD);
        int hp = vm_read<int>(怪 + 484);   // 野怪刷新原始值（0x1E4）
        if (hp <= 0 || hp > 600000) continue;
        野怪信息& m = 输出[数++];
        m.x = x;
        m.z = z;
        m.camp = vm_read<int>(怪 + SDK::阵营);
        m.cd = cd / 1000 + 3;
        m.刷新 = hp / 1000 + 3;
    }
    return 数;
}

// 世界半程：世界坐标取 ±世界半程 时正好落在小地图矩形边界上。
// 英雄的落点是按 109000 标定的，野怪原先单独用 100000，等于把整张图放大 9%，
// 越靠地图边缘偏得越多，只靠平移滑条永远补不回来 —— 现在英雄/野怪共用这一个常量。
//
// v24 重新标定（109000 → 115200 → 103500）：
// 前两版都是「反推」出来的，绕了远路。v24 换成最直接的测法 ——
// v23 把野怪点画成洋红实心点，于是可以从用户的对局截图里把「HUD 画的点」和
// 「游戏自己画的小苗图标」直接配对：20 个野怪里有 18 个在 30px 内配上对，
// 残差随离图心的距离严格线性变化（x 从 -14.3 单调走到 -2.0，y 从 -5.1 走到 +4.4），
// 这就是纯比例错。最小二乘：x 斜率 1.0344、y 斜率 1.0337（两轴只差 0.07%，可信）。
// 也就是说 HUD 的点比游戏近了 3.4%。当时配置里还压着 107.6% 的「小图比例」，
// 所以真实半程 = 115200 / (1.034 × 1.0759758) ≈ 103,500。
// 同一批数据还量出：HUD 框中心比原生小地图中心右移 8.8px（见下方几何复位）。
static const float 世界半程 = 103500.0f;

// 世界坐标 → 小地图逻辑坐标（未乘缩放）。翻转 = ±1，-1 时整体旋转 180°。
// 小图比例（cfg_monsterScale，面板「小图比例%」）在这里统一生效：
// 英雄、野怪、回城标记、屏外指示线全走这一个函数，比例一起缩放，不会再出现
// 「野怪调好了英雄又歪了」。
static void 世界转小图(int x, int z, float 翻转, const ImVec4& 地图, float* 出X, float* 出Y) {
    const float 图心X = 地图.x + 地图.w * 0.5f;
    const float 图心Y = 地图.y + 地图.w * 0.5f;
    const float 比 = (cfg_monsterScale > 0.2f) ? cfg_monsterScale : 1.0f;
    *出X = 图心X + ((x * 翻转) / 世界半程) * 地图.w * 比;
    *出Y = 图心Y - ((z * 翻转) / 世界半程) * 地图.w * 比;
}

// 小图坐标（英雄）
static void 小图坐标(int x, int z, unsigned 阵营, const ImVec4& 地图, float* 出X, float* 出Y) {
    世界转小图(x, z, 阵营符号(阵营), 地图, 出X, 出Y);
}

// 严格在框内才算数（旧的「±一个地图宽」容忍度会把点画到框外，出现框外飘数字）
static bool 在框内(const ImVec4& 地图, float x, float y) {
    return x >= 地图.x && x <= 地图.x + 地图.w
        && y >= 地图.y && y <= 地图.y + 地图.w;
}

static float 阵营符号(unsigned 阵营) {
    return 阵营 == 1 ? -1.0f : 1.0f;
}

// ==================== 对局状态 ====================

static void 对局状态(bool 进了对局, bool 掉出, double now) {
    if (进了对局) {
        在对局 = true;
        掉出对局时刻 = 0;
        状态行[0] = 0;
    } else if (掉出) {
        if (掉出对局时刻 <= 0.0) 掉出对局时刻 = now;
        if (now - 掉出对局时刻 > 20.0) 在对局 = false;
    } else {
        掉出对局时刻 = 0;
    }
}

// 状态浮层（第一行详情，节流 5s）
static void 状态浮层(unsigned 代码, const char* 文案) {
    static double 上次 = 0;
    static unsigned 上次代码 = 0;
    double now = CACurrentMediaTime();
    if (代码 != 上次代码 || now - 上次 >= 5.0) {
        上次 = now;
        上次代码 = 代码;
        bool 内核 = [[DOJailbreaker sharedInstance] isSuccess];
        pid_t sysctl见 = sysctl精确找pid("smoba");
        snprintf(状态行, sizeof(状态行),
                 "%d %s | 内核%d 模块%llx pid%d 见%d 任务%d 找%d/%d",
                 代码, 文案, 内核 ? 1 : 0, 模块基址, 游戏pid,
                 sysctl见, 任务端口 != 0, 找进程调用.load(), 找进程完成.load());
        日志("状态[%d/%s] 内核=%d 模块=0x%llx pid=%d sysctl见smoba=%d 任务=%d 找进程=%d/%d 等=%s",
             代码, 文案, 内核 ? 1 : 0, 模块基址, 游戏pid, sysctl见,
             任务端口 != 0, 找进程调用.load(), 找进程完成.load(), 状态文字);
    }
}

// 底部状态文字（cfg_status 默认关：打开 app 不再自动弹出左下角提示）
static void 底部文字(const ImVec2& 屏, const char* 文案) {
    if (!cfg_status) return;
    画文字(14.0f * 缩放系数, 屏.y - 44.0f * 缩放系数, 文案, 0xFFFFFFFF, false, false);
    if (状态行[0])
        画文字(14.0f * 缩放系数, 屏.y - 70.0f * 缩放系数, 状态行, 0xC0FFFFFF, false, false);
}

// ==================== 找进程线程 ====================

+ (void)load {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        while (true) {
            找进程调用++;
            @autoreleasepool {
                getbbz();
            }
            找进程完成++;
            sleep(3);
        }
    });
}

// ==================== 主渲染 ====================

void Draw::StartBooks() {
    ImDrawList* dl = 画布();
    if (!dl) return;
    ImVec2 屏 = BBZGUI::GetIO().DisplaySize;
    if (屏.x < 1.0f || 屏.y < 1.0f) return;

    读限流计数 = 0;
    double now = CACurrentMediaTime();

    // 缩放系数 = 逻辑短边 / 物理短边
    CGRect 物理屏 = [UIScreen mainScreen].bounds;
    float 短边 = MIN(屏.x, 屏.y);
    float 物理短边 = MIN(物理屏.size.width, 物理屏.size.height);
    if (物理短边 > 1.0f) {
        float 比 = 短边 / 物理短边;
        if (比 > 0.5f && 比 < 8.0f) 缩放系数 = 比;
    }
    float 缩放 = 缩放系数;

    // 1s 读一次配置
    if (now - 上次读配置 > 1.0) {
        上次读配置 = now;
        读配置();
    }

    // 小地图自适配：位置和尺寸各自独立
    //   判定只看开关，不再看"plist 里有没有值"——旧逻辑一旦自动写过一次，
    //   下一帧就把自己算出的值当成人手调的，从此再也不自动算（v17 之前一直踩这个坑）。
    //   尺寸：mapsize_on 关 → 跟屏幕自动算；开 → 用滑条的 mapSize
    //   位置：mappos_on  关 → 跟屏幕自动算；开 → 用滑条的 mapX / mapY
    {
        bool 用自动尺寸 = !cfg_mapsize_on;
        bool 用自动位置 = !cfg_mappos_on;
        if (用自动位置 || 用自动尺寸) {
            // 系数按原生小地图实测标定（截图像素 / 屏幕短边 1290）：
            //   原生小地图左边界 166px、上边界 3px、右边界 574px、下边界 410px
            //   → 宽 408px、高 407px（正方形），即 136.0pt。
            //   左边距 166/1290 = 0.1286；上边距 3/1290 = 0.0023；尺寸 408/1290 = 0.3163。
            // 上一版 0.2445 是从一张旧截图里量出来的，量到的其实是 HUD 自己画的框（315px），
            // 结果自动模式把框画得比原生小一圈 —— 这就是"改了还是不对齐"的真正原因。
            float 基准 = 短边 / 缩放;
            float 新X = 用自动位置 ? 基准 * 0.1286f : cfg_mapX;
            float 新Y = 用自动位置 ? 基准 * 0.0023f : cfg_mapY;
            float 新尺寸 = 用自动尺寸 ? 基准 * 0.3163f : cfg_mapSize;
            cfg_mapX = 新X;
            cfg_mapY = 新Y;
            cfg_mapSize = 新尺寸;
            回写地图配置(新X, 新Y, 新尺寸, 用自动尺寸, 用自动位置);
        }
    }

    // 启动横幅：每次启动写一行，把版本、缩放、屏幕尺寸和日志落地路径都记下来。
    // 这样"日志到底写没写成功"不用猜，屏幕上和日志里都能看到。
    {
        static bool 已记启动 = false;
        if (!已记启动) {
            已记启动 = true;
            初始化日志();
            日志("=== smobaKFD v57 启动 日志=%s 缩放=%.3f 屏=%.0fx%.0f 短边=%.0f",
                 日志可用 ? 日志路径串 : "失败", 缩放, 屏.x, 屏.y, 短边);
        }
    }

    // 找进程看门狗：12 秒没推进就另起线程
    int 调用 = 找进程调用.load();
    if (调用 == 找进程调用快照) {
        if (上次找进程推进 > 0.0 && now - 上次找进程推进 > 12.0) {
            上次找进程推进 = now;
            日志("找进程看门狗：调用=%d 完成=%d，12 秒没往前走 → 另起一个找进程线程",
                 找进程调用.load(), 找进程完成.load());
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                @autoreleasepool { getbbz(); }
                找进程完成++;
            });
        }
    } else {
        找进程调用快照 = 调用;
        上次找进程推进 = now;
    }

    if (![[DOJailbreaker sharedInstance] isSuccess]) {
        状态浮层(1, "内核未就绪");
        底部文字(屏, "等待内核");
        return;
    }
    if (!模块基址) {
        状态浮层(2, "没拿到模块基址");
        底部文字(屏, "等待进入对局");
        return;
    }

    // v2p 缓存 1s 清一次
    static double 上次清缓存 = 0;
    if (now - 上次清缓存 > 1.0) {
        上次清缓存 = now;
        exploit_v2p_cache_clear();
    }

    // 世界根 → 实体容器 → 数组
    uint64_t 根世界 = vm_read<uint64_t>(模块基址 + SDK::根世界);
    uint64_t 容器 = IsValidAddr(根世界) ? vm_read<uint64_t>(根世界 + 312) : 0;
    uint64_t 数组 = IsValidAddr(容器) ? vm_read<uint64_t>(容器 + 120) : 0;
    int 数量 = IsValidAddr(容器) ? vm_read<int>(容器 + 148) : 0;

    float 矩阵[16];
    if (!读矩阵(模块基址, 矩阵)) {
        状态浮层(3, "矩阵读不到");
        if (!在对局) 底部文字(屏, "等待进入对局");
        return;
    }
    // v39 诊断：矩阵各项的帧间最大变化。如果 m12/m13/m14（相机平移）每窗口都在
    // 大幅变化，说明投影本身在抖，所有实体就会整体前后跳 —— 和坐标无关。
    {
        if (上矩阵有) {
            for (int i = 0; i < 16; ++i) {
                float d = 绝对值f(矩阵[i] - 上矩阵[i]);
                if (d > 矩阵最大变[i]) 矩阵最大变[i] = d;
            }
        }
        memcpy(上矩阵, 矩阵, sizeof(上矩阵));
        上矩阵有 = true;
    }

    // 视距：fov_on 时写/自校准，失败或未开时按需探测
    if (cfg_camprobe) 相机探测(模块基址);
    if (cfg_fov_on) {
        if (!写视距(cfg_fov) && !视距自校准(矩阵, cfg_fov))
            视距探测扫(矩阵);
    } else if (cfg_fov_probe) {
        视距探测扫(矩阵);
    }

    bool 数组有效 = IsValidAddr(根世界) && IsValidAddr(容器) && IsValidAddr(数组)
                 && 数量 > 0 && 数量 <= 512;

    if (!数组有效) {
        对局状态(false, true, now);
        状态浮层(4, "实体数组无效");
        if (!在对局) 底部文字(屏, "等待进入对局");
        return;
    }

    // 我方阵营：配置指定 or 按相机朝向猜（矩阵[0]<=0 → 2，否则 1）
    // v33：不再裸算，走带滞回的防抖判定（详见 判定我方阵营 处的注释）
    unsigned 我方阵营 = 判定我方阵营(矩阵);

    if (!cfg_draw) return;

    // 小地图边框
    if (cfg_map) {
        画框(0xFF00FFFF, cfg_mapX * 缩放, cfg_mapY * 缩放,
             cfg_mapSize * 缩放, cfg_mapSize * 缩放, 2.0f);
    }

    // 对齐辅助：只剩四角白色 L 括号。
    // v27 按用户要求砍掉：紫色对角线大 X、中心红十字、小地图下方三行数值读标。
    // 括号本身仍用于把框跟原生金色描边对齐，不再要求「小地图」开关同时打开。
    if (cfg_mapalign) {
        const float 左 = cfg_mapX * 缩放, 上 = cfg_mapY * 缩放;
        const float 宽 = cfg_mapSize * 缩放;
        const float 右 = 左 + 宽, 下 = 上 + 宽;
        const float 臂 = 24.0f * 缩放;
        const float 粗 = 2.8f * 缩放;
        const ImU32 角 = 0xFFFFFFFF;      // 白
        // ImGui 的 ImU32 是 0xAABBGGRR（低字节才是红），上次写成 0xFFFF4040 结果画出来是蓝的。
        // v27：按用户要求，只留四角白色 L 括号 —— 紫色对角线 X、中心红十字、
        // 小地图下方那三行数值读标全部去掉，对局里不再挡视线。
        // 四角 L 括号
        画线(角, 左, 上, 左 + 臂, 上, 粗);
        画线(角, 左, 上, 左, 上 + 臂, 粗);
        画线(角, 右, 上, 右 - 臂, 上, 粗);
        画线(角, 右, 上, 右, 上 + 臂, 粗);
        画线(角, 左, 下, 左 + 臂, 下, 粗);
        画线(角, 左, 下, 左, 下 - 臂, 粗);
        画线(角, 右, 下, 右 - 臂, 下, 粗);
        画线(角, 右, 下, 右, 下 - 臂, 粗);
    }

    // ==================== 实体循环 ====================
    int 有效实体 = 0, 有坐标实体 = 0, 屏内实体 = 0;
    int 阵营直方[9] = {0};           // -1..7
    int 野怪数 = 0;
    bool 有首个 = false;
    int 首个阵营 = 0, 首个血当前 = 0, 首个血上限 = 0, 首个链 = -1;
    int 首个阵营C0 = 0, 首个阵营52 = 0;   // v33 对照：实体+0xC0（SDK）与 实体+52（代码）
    long long 首个英雄ID = 0;
    int 图标序号 = 0;
    // 小地图标定样本：前 3 个有坐标的敌人，原始坐标 + 换算后的小图坐标
    int 小图样数 = 0;
    int 小图样阵营[3] = {0, 0, 0};
    unsigned 小图样世X[3] = {0, 0, 0}, 小图样世Z[3] = {0, 0, 0};
    float 小图样屏X[3] = {0, 0, 0}, 小图样屏Y[3] = {0, 0, 0};
    // 敌方回城：本轮收集（最多 5 个，够一队了）
    int 回城数 = 0;
    long long 回城英雄[5] = {0, 0, 0, 0, 0};
    // 回城链诊断：3 秒一次，把 技能对象 / +360 / +272 三层指针和判定值打出来。
    // 回城检测要是偏移不对，只有这行日志能证明到底错在哪一层。
    static double 上次回城日志 = 0.0;
    const bool 打回城日志 = (cfg_recall || cfg_camprobe)
                          && (CACurrentMediaTime() - 上次回城日志 > 3.0);
    if (打回城日志) 上次回城日志 = CACurrentMediaTime();

    SLIconCache* 图标缓存 = SLIconCache.共用;
    // 地图矩形一律用「未乘缩放」的逻辑值：小图坐标算出来是逻辑点，之后统一乘一次 缩放。
    // 曾误传 cfg_mapX*缩放，导致坐标被乘两次，所有图标飞出小地图 3 倍远。
    ImVec4 地图 = ImVec4(cfg_mapX, cfg_mapY, cfg_mapSize, cfg_mapSize);

    // ===== v24 回城位标定：内存差分 + 三连确认 =====
    // 上一版「旗标」（只列 1..12 的整数）在真实对局里一条都没抓到 —— 回城状态要么是
    // 位标志（整数值很大，比如 0x200），要么在 +0x400 之外。
    // 改成差分：把实体 +0x0..+0x600 整块读出来和上一次比，记录所有「变化且像状态」的字段。
    // 并且就地做自动标定，判据三连（缺一不可）：
    //   ① 某偏移出现 0 → N（N ≤ 64）
    //   ② 6~10 秒后该偏移回到 0        ← 回城读条正好 8 秒
    //   ③ 紧接着这个实体坐标瞬移 > 25000 ← 传到泉水
    // 三条同时命中才认定，之后就能做到「按下回城立刻提示」。
    static const int 差分长 = 0x3000;
    static unsigned char 差分旧[24][0x3000];
    static unsigned char 差分已记[24][0x3000 / 4];
    static unsigned char 差分新[0x3000];
    static bool 差分就绪[24] = {false};
    static int 差分实长[24] = {0};
    static uint64_t 差分键[24] = {0};

    static uint64_t 标定键[24] = {0};
    static unsigned 标定X[24] = {0}, 标定Z[24] = {0};
    static bool 标定有[24] = {false};

    // v28：倒数扫描的基准表已提到文件作用域（扫表集 / 扫前池 / 扫计池 / 扫起池），
    // 因为子链扫描也要用同一套逻辑，放函数里没法复用。

    struct 开关项 { uint64_t 实体; int 偏移; int 值; double 开时; bool 浮点; };
    static 开关项 开关台[96];
    struct 候选项 { uint64_t 实体; int 偏移; int 值; double 关时; bool 浮点; bool 倒数; };
    static 候选项 候选台[16];
    static int 开关指针 = 0, 候选指针 = 0;
    static int 回城位偏移 = -1;
    static int 回城位值 = 0;
    static bool 回城位是浮点 = false;
    static bool 回城位是倒数 = false;      // 学到的偏移是「读条计时器」而不是开关

    static double 上次差分 = 0.0;
    static int 本拍行数 = 0;                   // 一个采样周期内最多打 12 行，防日志爆掉
    static int 本拍浮点行 = 0;                 // 浮点单独限额，免得读条时把整数行挤没
    const bool 做差分 = cfg_recall && (CACurrentMediaTime() - 上次差分 > 0.2);
    if (做差分) { 上次差分 = CACurrentMediaTime(); 本拍行数 = 0; 本拍浮点行 = 0; }

    // v45：全槽坐标对照（纯读、纯打印；2Hz 采 10 次，挑离屏幕中心最近的槽当「我」）
    全槽对比(数组, 数量, 矩阵, 屏.x, 屏.y);
    // v46：我方英雄自检（相机跟人走 = 免费真值，用来判定 二+0x44 是否真的可用）
    我方自检(数组, 数量, 矩阵, 屏.x, 屏.y, 我方阵营);
    // v48：整局快照（每 5 秒 10 槽 阵/组A/组B）。v47 的两跳轨迹 400 行已打满、
    // 只覆盖开局 5 秒、且恰好错过抖动时段，停用；野怪对照每次都「根无效」，也停用。
    整局快照(数组, 数量);
    // v51：猎人2（扩范围 + int32/float 三解释）+ 邻域变化（只报「变了、界内、单步 50~6000」的偏移）
    // v52 停用：本体 0x8000 已扫完（450 行全是每次 +76 的计时器和 ±1000 的方向分量），
    // 结论是本体里没有实时坐标，继续扫只是重复。函数保留备查。
    // 坐标猎人2(数组, 数量, 矩阵, 屏.x, 屏.y, (unsigned)我方阵营);
    // 邻域变化(数组, 数量);
    // v52：改成扫 一/二/三 三层（本体里没有实时坐标，但那三层里被证实有坐标副本），
    // 逐帧比「变了 + 新旧都界内 + 单步 1~3000」，每 5 秒出一张命中次数榜。
    // v54：屏心投影锚定 —— 相机跟随我 ⇒ 我恒投在屏幕同一像素位置。
    // 加载期用「二」把这个位置量出来当基准，整局找投影落基准 ±80px 的字段。
    // v53 的「屏心点位移」判据已废（它混了相机旋转项，见函数头注释）。
    // 层邻 停用：v52 已给出结论（一/三 前 8 名全是毫秒计时器，二 只有两对副本），函数保留备查。
    锚扫描(数组, 数量, 矩阵, 屏.x, 屏.y, 我方阵营);
    // v52：同帧 4 槽对照（每 3 帧一行，400 行封顶），用来判定「跳后的新值是否等于别的槽的旧值」。
    四槽行(数组, 数量, 帧序);

    // v49：帧级诊断的帧号 / 毫秒推进，以及上一帧打标记的环 dump。
    // 放在逐槽循环外，保证一轮所有槽处理完才推进一帧 —— 环里的「相邻帧」是真正的相邻绘制帧。
    {
        if (时基 == 0.0) 时基 = CACurrentMediaTime();
        ++帧序;
        毫秒计 = (unsigned)((CACurrentMediaTime() - 时基) * 1000.0);
        for (int j = 0; j < 24; ++j) {
            if (待dump[j] && 帧序 >= 待dump[j]) {
                环dump(j, 待dump[j] - 6);
                上次dump帧[j] = 待dump[j] - 6;
                槽dump数[j]++;
                待dump[j] = 0;
            }
        }
    }

    for (int k = 0; k < 数量 && k < 24; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(实体)) continue;
        有效实体++;

        int 阵营 = 稳定阵营(k, 实体);
        if (阵营 >= -1 && 阵营 <= 7) 阵营直方[阵营 + 1]++;
        // v33 对照：SDK 写的是 +0xC0，代码一直用 +52。两个都打出来，一眼能看出谁是真的。
        if (首个阵营C0 == 0) {
            首个阵营C0 = vm_read<int>(实体 + 0xC0);
            首个阵营52 = vm_read<int>(实体 + 52);
        }

        // ---- 回城位标定：内存差分（5 次/秒，覆盖实体 +0x0..+0x600）----
        // 尾部跨页读不到时自动降档（0x600→0x300→0x180→0x100），保证一定有输出。
        if (做差分) {
            const double 现时 = CACurrentMediaTime();

            // 1) 坐标：只为抓「瞬移」那一帧。自己人也跟，标定必须从自己的回城学。
            bool 瞬移 = false;
            unsigned 现X = 0, 现Z = 0;
            if (读实体坐标(k, 实体, &现X, &现Z) >= 0) {
                if (标定键[k] != 实体) {
                    标定键[k] = 实体;
                    标定X[k] = 现X; 标定Z[k] = 现Z; 标定有[k] = true;
                } else if (标定有[k]) {
                    long long 差X = (long long)现X - (long long)标定X[k];
                    long long 差Z = (long long)现Z - (long long)标定Z[k];
                    if ((double)差X * 差X + (double)差Z * 差Z > 25000.0 * 25000.0) 瞬移 = true;
                    标定X[k] = 现X; 标定Z[k] = 现Z;
                }
            }

            // 2) 瞬移 = 一次回城收尾。看候选台里有没有「3 秒内关上、时长 6~10 秒」的开关
            if (瞬移 && 回城位偏移 < 0) {
                for (int i = 0; i < 16; ++i) {
                    if (候选台[i].实体 != 实体 || 候选台[i].值 == 0) continue;
                    if (现时 - 候选台[i].关时 > 3.0) continue;
                    // v27 的教训：整数开关那条路会把坐标噪声（实体+0x1160 0→71→0）学成
                    // 「回城位」，横幅从此全是假的。v28 起只认倒数型候选。
                    if (!候选台[i].倒数) continue;
                    回城位偏移 = 候选台[i].偏移;
                    回城位值 = 候选台[i].值;
                    回城位是浮点 = 候选台[i].浮点;
                    回城位是倒数 = 候选台[i].倒数;
                    日志("★学到回城位 实体+0x%x 值=%d 类型=%s 瞬移距关=%.1fs k=%d",
                         回城位偏移, 回城位值,
                         回城位是倒数 ? (回城位是浮点 ? "浮点读条" : "毫秒读条") : "整数开关",
                         现时 - 候选台[i].关时, k);
                    break;
                }
            }

            // 3) 全字段差分
            if (差分键[k] != 实体) {          // 槽位换人了，旧快照作废
                差分键[k] = 实体;
                差分就绪[k] = false;
                memset(差分已记[k], 0xFF, sizeof(差分已记[k]));
            }
            int 试长 = 差分实长[k] > 0 ? 差分实长[k] : 差分长;
            bool 读到 = readMemory(实体, 差分新, 试长);
            if (!读到) {
                for (int 备 = 试长 / 2; 备 >= 0x100; 备 /= 2) {
                    if (readMemory(实体, 差分新, 备)) {
                        试长 = 备; 差分实长[k] = 备; 读到 = true;
                        break;
                    }
                }
            }
            if (读到) {
                if (差分就绪[k]) {
                    int 记数 = 0, 省略 = 0;
                    for (int o = 0; o + 4 <= 试长; o += 4) {
                        int 旧值, 新值;
                        memcpy(&旧值, 差分旧[k] + o, 4);
                        memcpy(&新值, 差分新 + o, 4);
                        if (旧值 == 新值) continue;

                        // 台账：0→N 记开，N→0 记关并算时长（6~10 秒的进候选台）
                        // v25：阈值 64 → 4096，位标志（0x200/0x800）现在也能进台账
                        if (旧值 == 0 && 新值 > 0 && 新值 <= 4096) {
                            int 位 = -1;
                            for (int i = 0; i < 96; ++i)
                                if (开关台[i].实体 == 实体 && 开关台[i].偏移 == o) { 位 = i; break; }
                            if (位 < 0) { 位 = 开关指针; 开关指针 = (开关指针 + 1) % 96; }
                            开关台[位].实体 = 实体; 开关台[位].偏移 = o;
                            开关台[位].值 = 新值; 开关台[位].开时 = 现时;
                            开关台[位].浮点 = false;
                        } else if (旧值 > 0 && 旧值 <= 4096 && 新值 == 0) {
                            for (int i = 0; i < 96; ++i) {
                                if (开关台[i].实体 != 实体 || 开关台[i].偏移 != o) continue;
                                double 时长 = 现时 - 开关台[i].开时;
                                if (时长 >= 5.5 && 时长 <= 11.5) {
                                    候选台[候选指针].实体 = 实体;
                                    候选台[候选指针].偏移 = o;
                                    候选台[候选指针].值 = 旧值;
                                    候选台[候选指针].关时 = 现时;
                                    候选台[候选指针].浮点 = false;
                                    候选台[候选指针].倒数 = false;
                                    候选指针 = (候选指针 + 1) % 16;
                                    日志("候选开关 实体+0x%x 值=%d 时长%.1fs k=%d", o, 旧值, 时长, k);
                                }
                                开关台[i].实体 = 0;
                                break;
                            }
                        }

                        const int 旧绝 = 旧值 < 0 ? -旧值 : 旧值;
                        const int 新绝 = 新值 < 0 ? -新值 : 新值;
                        const unsigned 异或 = (unsigned)(旧值 ^ 新值);
                        // v25：整数阈值从 64 放宽到 4096 —— 回城状态大概率是位标志
                        // （0x200 / 0x800 这种），旧阈值把它们全挡了。
                        const bool 小整数 = (旧绝 <= 4096 || 新绝 <= 4096);
                        const bool 单位 = (异或 != 0) && ((异或 & (异或 - 1)) == 0)
                                       && (新绝 <= 0x100000);
                        if (!小整数 && !单位) {
                            // v25 浮点捕获（这是本轮最关键的一条）：
                            // 回城读条本质是一个 8.0 → 0.0 的浮点计时器，按整数解读是
                            // 0x41000000（十亿级），上一条 continue 把它当垃圾扔了 ——
                            // 连按两次回城只捞到朝向变化，根因就在这里。
                            // 只扫 +0x000..+0x1C0：坐标在 +0x2B8、血量对象在 +0x1D0，都在范围外，
                            // 不会把走动产生的坐标噪音带进来。
                            if (o < 0x1C0) {
                                float 旧f, 新f;
                                memcpy(&旧f, 差分旧[k] + o, 4);
                                memcpy(&新f, 差分新 + o, 4);
                                if (旧f == 旧f && 新f == 新f) {          // 排除 NaN
                                    const float 新绝f = 新f < 0 ? -新f : 新f;
                                    if (新绝f > 0.0001f && 新绝f < 12000.0f) {
                                        float 差f = 新f - 旧f;
                                        if (差f < 0) 差f = -差f;
                                        if (差f > 0.5f) {                 // 整数量级才记，滤掉抖动
                                            // 浮点台账：读条计时器是 0→8→0，和整数开关同构，
                                            // 所以走同一张台账，只多一个「浮点」标记。
                                            const float 旧绝f2 = 旧f < 0 ? -旧f : 旧f;
                                            if (旧绝f2 < 0.05f && 新绝f > 0.5f) {
                                                int 位 = -1;
                                                for (int i = 0; i < 96; ++i)
                                                    if (开关台[i].实体 == 实体 && 开关台[i].偏移 == o) { 位 = i; break; }
                                                if (位 < 0) { 位 = 开关指针; 开关指针 = (开关指针 + 1) % 96; }
                                                开关台[位].实体 = 实体; 开关台[位].偏移 = o;
                                                开关台[位].值 = 1; 开关台[位].开时 = 现时;
                                                开关台[位].浮点 = true;
                                            } else if (旧绝f2 > 0.5f && 新绝f < 0.05f) {
                                                for (int i = 0; i < 96; ++i) {
                                                    if (开关台[i].实体 != 实体 || 开关台[i].偏移 != o) continue;
                                                    double 时长 = 现时 - 开关台[i].开时;
                                                    if (开关台[i].浮点 && 时长 >= 5.5 && 时长 <= 11.5) {
                                                        候选台[候选指针].实体 = 实体;
                                                        候选台[候选指针].偏移 = o;
                                                        候选台[候选指针].值 = 1;
                                                        候选台[候选指针].关时 = 现时;
                                                        候选台[候选指针].浮点 = true;
                                                        候选台[候选指针].倒数 = false;
                                                        候选指针 = (候选指针 + 1) % 16;
                                                        日志("候选开关f 实体+0x%x 峰值%.2f 时长%.1fs k=%d",
                                                             o, 旧f, 时长, k);
                                                    }
                                                    开关台[i].实体 = 0;
                                                    break;
                                                }
                                            }
                                            if (本拍浮点行 < 6 && 本拍行数 < 16) {
                                                日志("差分f k=%d 阵=%d +0x%03x %.2f->%.2f",
                                                     k, 阵营, o, 旧f, 新f);
                                                ++本拍浮点行; ++本拍行数;
                                            }
                                        }
                                    }
                                }
                            }
                            continue;      // 整数条件不成立；浮点分支已在上面处理
                        }
                        const unsigned char 码 = (unsigned char)(新值 < 0 ? 0 : (新值 > 254 ? 254 : 新值));
                        if (差分已记[k][o >> 2] == 码) continue;   // 同值不重复刷
                        差分已记[k][o >> 2] = 码;
                        if (记数 < 8 && 本拍行数 < 12) {
                            日志("差分 k=%d 阵=%d +0x%03x %d->%d", k, 阵营, o, 旧值, 新值);
                            ++本拍行数;
                        } else {
                            ++省略;
                        }
                        ++记数;
                    }
                    if (省略) 日志("差分 k=%d 阵=%d 另有 %d 条变化省略", k, 阵营, 省略);
                }
                memcpy(差分旧[k], 差分新, 试长);
                差分就绪[k] = true;
            } else {
                差分就绪[k] = false;   // 这一帧读不到，下次重新建基准
            }
        }

        // ---- v28 倒数扫描（1Hz）：本体 16KB + 最多 4 条子链各 8KB ----
        // v27 只扫了本体 12KB、只认浮点，结果 0 条 —— 实体里没有 8→0 的浮点读条。
        // v28 一次读、两种解释（float / 毫秒整数），并且顺着实体里的堆指针
        // 把组件对象也扫一遍。命中「连降 ≥3 秒且落到 0」就回传，交给候选台/瞬移定标。
        if (cfg_recall) {
            const double 现时2 = CACurrentMediaTime();
            if (扫实体键[k] != 实体) 扫绑定(k, 实体);
            for (int t = 0; t <= 扫子数; ++t) {
                扫表& 表 = 扫表集[k][t];
                if (!表.对象) continue;
                扫一遍(k, 阵营, 表, t != 0, 现时2);
            }
            if (命中偏移 >= 0 && 命中对象 == 实体 && 回城位偏移 < 0) {
                候选台[候选指针].实体 = 实体;
                候选台[候选指针].偏移 = 命中偏移;
                候选台[候选指针].值 = (int)命中起值;
                候选台[候选指针].关时 = 现时2;
                候选台[候选指针].浮点 = 命中浮点;
                候选台[候选指针].倒数 = true;
                候选指针 = (候选指针 + 1) % 16;
                日志("候选倒数 实体+0x%x 起%.0f 类型=%s k=%d",
                     命中偏移, 命中起值, 命中浮点 ? "浮点" : "毫秒整数", k);
                命中偏移 = -1;
            }
        }

        if (阵营 == (int)我方阵营) continue;

        // v41：自标定挪到「链读之后」，直接复用已经读到的坐标算活度，不额外增加系统调用

        int 血当前 = 读血量当前(实体);
        int 血上限 = 读血量上限(实体);
        int 原始上限 = (血上限 > 0 && 血上限 < 2000000) ? 血上限 : 0;  // 给槽位锁定用，别被下面的兜底 1 污染
        bool 血有效 = 血上限 > 0 && 血上限 < 2000000
                   && !(血当前 & 0x80000000) && (unsigned)血当前 <= (unsigned)血上限;
        // v35：单帧读到 0 就跳过太激进。血量对象指针偶尔读到 0/旧值，那一帧头像
        // 就整个消失、下一帧又回来 —— 这也是「闪」的一种形态，而且和坐标抖动
        // 叠加在一起，看起来就像一直在动。改成连续 3 帧归零（约 50ms）才认死。
        if (血有效 && 血当前 == 0) {
            if (++零血连续[k] < 3) { 血当前 = 1; if (血上限 <= 0) 血上限 = 1; }
            else continue;                  // 真死：连续 3 帧都是 0
        } else {
            零血连续[k] = 0;
        }
        if (!血有效) { 血当前 = 1; 血上限 = 1; }  // 血量读不到 → 按满血画

        unsigned 样X = 0, 样Z = 0;
        int 链 = 读实体坐标(k, 实体, &样X, &样Z);
        写环(k);            // v49：成功失败都记 —— 「读不到」本身就是这次要查的东西
        if (链 < 0 || 样X == 1000000) continue;
        const unsigned 原X = 样X, 原Z = 样Z;   // 原始值留着做诊断
        记坐标序列(k, 实体, 原X, 原Z, 链, 上次直X, 上次直Z, 上次直有);
        // v46：自标定扫描已停用 —— 坐标已在 v43/v44 定位到 二+0x44，继续扫只是白烧系统调用
        // （每 3 帧 4 对象 × 2KB），留着代码只为回溯。
        稳定坐标(k, &样X, &样Z);                // 见下：新数据源若连续，稳定压计应为 0

        // v34 诊断：世界坐标帧间位移。一帧 16ms 英雄最多走几百单位，
        // 超过 3000 只可能是脏读/链跳。同时记录本窗口最大值（不看阈值）。
        {
            if (槽世键[k] == 实体) {
                // v36：坐标可能是负数（-200000~0），存成 unsigned 后直接相减会变成 42 亿，
                // 之前那些「距4294967030」「最大世跳=6073950821」全是这个符号问题造成的假跳。
                long long wx = (long long)(int)原X - (long long)(int)槽世X[k];
                long long wz = (long long)(int)原Z - (long long)(int)槽世Z[k];
                double 距 = sqrt((double)wx * wx + (double)wz * wz);
                if (距 > 槽世最大跳[k]) 槽世最大跳[k] = 距;
                if (距 > 3000.0) {
                    世界跳计++;
                    // v49：位移向量与上一次跳变向量点积 < 0 = 方向反转 = 来回跳。
                    // 来回跳最值得看，优先 dump；方向不变的按 1 秒抽一次。
                    bool 反转 = false;
                    if (槽有向[k]) {
                        long long dot = wx * 上向X[k] + wz * 上向Z[k];
                        反转 = (dot < 0);
                    }
                    上向X[k] = wx; 上向Z[k] = wz; 槽有向[k] = true;
                    if (槽dump数[k] < 10 && 待dump[k] == 0 &&
                        (反转 || (unsigned)(帧序 - 上次dump帧[k]) >= 60))
                        待dump[k] = 帧序 + 6;
                    if (世界跳计 <= 30)
                        日志("世界跳变 k=%d 从(%d,%d)到(%d,%d) 距%.0f 链=%s",
                             k, (int)槽世X[k], (int)槽世Z[k],
                             (int)原X, (int)原Z, 距, 链名(链));
                    if (世界跳计 <= 8) 记链中间(k, 实体);
                    跳变四值(k, 实体, 原X, 原Z, 距);   // v48：同帧四份读数
                }
                // v38：滤波输出后的帧间位移（真正画到屏幕上的量）
                long long ox = (long long)(int)样X - (long long)(int)槽出X[k];
                long long oz = (long long)(int)样Z - (long long)(int)槽出Z[k];
                double 出距 = sqrt((double)ox * ox + (double)oz * oz);
                if (出距 > 槽出最大跳[k]) 槽出最大跳[k] = 出距;
            }
            // v48：槽位换了实体就重置单源锁 —— 新实体重新评估用组A还是组B，
            // 但不允许「同一个实体在两套源之间来回切」（那正是跳的来源）。
            if (槽世键[k] != 0 && 槽世键[k] != 实体) {
                槽锁[k] = false;
                槽组[k] = 0;
                槽失[k] = 0;                         // v57：换实体 = 保持基准作废
                槽保有[k] = false;
                槽上态[k] = 0;           // 换人就重开两组比较，别拿上一个实体的值当基准
                槽稳有[k] = false;       // 顺带清掉 v39 门控的旧基准，避免新实体被旧位置压住
                离群连[k] = 0;
                槽有向[k] = false;       // v49：换实体 = 位移方向作废，不然第一帧会误判反转
                槽有上[k] = false;       // v49：指针比较的基准也作废
                待dump[k] = 0;
                槽dump数[k] = 0;
                上次dump帧[k] = 0;
            }
            槽世键[k] = 实体; 槽世X[k] = 原X; 槽世Z[k] = 原Z;
            槽出X[k] = 样X; 槽出Z[k] = 样Z;
        }

        有坐标实体++;
        if (!有首个) {
            有首个 = true;
            首个阵营 = 阵营;
            首个血当前 = 血当前;
            首个血上限 = 血上限;
            首个链 = 链;
            首个英雄ID = vm_read<long long>(实体 + 40);
        }

        float 比例 = (float)血当前 / (float)(血上限 > 0 ? 血上限 : 1);
        比例 = clamp01(比例);

        float sx = 0.0f, sy = 0.0f;
        bool 屏内 = 投影(矩阵, (int)样X, (int)样Z, &sx, &sy, 屏.x, 屏.y);
        if (屏内) 屏内实体++;

        // v32：不再直接读 `实体+40`。那个字段对部分实体会周期性变化（日志实证），
        // 拿它当图标 key 会让纹理永远 miss、编号数字乱跳 —— 头像"闪"的根因。
        long long 英雄ID = 稳定英雄ID(k, 实体, 原始上限);
        uint64_t 技能对象 = vm_read<uint64_t>(实体 + 488);

        // 回城检测放在这里：原来它藏在小地图图标那段（if cfg_map）里面，
        // 小地图一关就完全不检测，横幅自然永远不出来。现在与 cfg_map 解耦。
        // 参数用「实体」：SDK 里 回城对象(0x168) 是实体字段，不是技能对象字段。
        //
        // v23：SDK 偏移这条链在这台机器上是断的（实体+360 读出来是 7ffffffd…，
        // 不是一个合法指针），所以加了「轨迹判定」当主力，偏移链只当附加信号。
        double 现在时 = CACurrentMediaTime();
        回城轨迹& 轨 = 轨迹表[k];
        if (轨.英雄 != 英雄ID) {
            轨.英雄 = 英雄ID;
            轨.上X = (int)样X; 轨.上Z = (int)样Z;
            轨.静止起 = 现在时; 轨.确认到 = 0.0; 轨.候选 = false;
        }
        {
            long long 移X = (long long)样X - 轨.上X, 移Z = (long long)样Z - 轨.上Z;
            double 位移2 = (double)移X * 移X + (double)移Z * 移Z;
            if (位移2 > 25000.0 * 25000.0) {
                if (现在时 - 轨.静止起 >= 5.0) 轨.确认到 = 现在时 + 6.0;   // 站定够了才瞬移 = 回城
                轨.静止起 = 现在时;
            } else if (位移2 > 300.0 * 300.0) {
                轨.静止起 = 现在时;                                        // 在走 = 不是回城
            }
            轨.上X = (int)样X; 轨.上Z = (int)样Z;
            轨.候选 = (现在时 - 轨.静止起 >= 5.0);
        }
        const bool 轨迹确认 = (现在时 < 轨.确认到);
        const bool 轨迹候选 = 轨.候选;

        int 回城来源 = 读回城来源(实体);
        // v24：轨迹判定（站定 5 秒 + 瞬移 > 25000）本质上是「已经传到泉水了」才成立，
        // 正好是用户不要的那个时间点，已降级为诊断信号。横幅只认两样：
        //   ① 本局学到的回城位（按下回城那一刻就为真）
        //   ② 老 SDK 偏移链（这台机器上目前是死的，留着以防哪天复活）
        // 读条型偏移（8.0→0 或 8000→0）只要「值还在区间内」就是在回城 —— 按下那一刻
        // 计时器从满值开始往下走，横幅立刻亮；掉到 0 说明读完/被打断，横幅自然消失。
        const bool 学到回城 = (回城位偏移 >= 0) &&
            (回城位是倒数
                 ? (回城位是浮点
                        ? (绝对值f(vm_read<float>(实体 + 回城位偏移)) > 0.5f)
                        : (vm_read<int>(实体 + 回城位偏移) >= 50 &&
                           vm_read<int>(实体 + 回城位偏移) < 30000))
                 : (回城位是浮点 ? (绝对值f(vm_read<float>(实体 + 回城位偏移)) > 0.5f)
                                 : (vm_read<int>(实体 + 回城位偏移) == 回城位值)));
        bool 在回城 = 学到回城 || 回城来源 != 0;
        if (在回城 && 回城数 < 5) 回城英雄[回城数++] = 英雄ID;
        if (打回城日志 && k < 3) {
            uint64_t 链A = vm_read<uint64_t>(实体 + SDK::回城对象);
            uint64_t 链B = IsValidAddr(链A) ? vm_read<uint64_t>(链A + SDK::回城状态) : 0;
            int 判值 = (IsValidAddr(链B) && 链B >= 0x128) ? vm_read<int>(链B - 296) : -999;
            int 字段值 = IsValidAddr(链A) ? vm_read<int>(链A + SDK::回城状态) : -999;
            日志("回城链 k=%d 英雄=%lld 实体=%llx A=%llx B=%llx 判值=%d 状态字段=%d 来源=%d 轨迹=%d/%d 回城位=%d 学到=%d",
                 k, 英雄ID, 实体, 链A, 链B, 判值, 字段值, 回城来源,
                 (int)轨迹候选, (int)轨迹确认, 回城位偏移, (int)学到回城);
            // v26：把邻域放宽到 +0x100..+0x1A0（原来只到 0x118）。
            // SDK 里 回城对象=0x168，它到底是不是一个能读的指针，这里能直接看出来
            // （十进制十几位、约 1e13 量级的就是 0x2a... 的堆指针）。
            {
                char 邻[760] = {0};
                char 段邻[28];
                for (int o = 0x100; o <= 0x1A0; o += 4) {
                    snprintf(段邻, sizeof(段邻), " %x:%d", o, vm_read<int>(实体 + o));
                    if (strlen(邻) + strlen(段邻) < sizeof(邻) - 1) strcat(邻, 段邻);
                }
                日志("回城邻域 k=%d 阵=%d%s", k, 阵营, 邻);
            }
            // 偏移猜不准时，把实体 +0x150 起的 12 个 int 打出来：
            // 让用户按一次回城，对比这串数字哪一位从 0 变 1，就能反推真正的状态偏移。
            if (cfg_camprobe) {
                char 扫[220] = {0};
                char 段[24];
                for (int o = 0; o < 11; ++o) {
                    snprintf(段, sizeof(段), " %d", vm_read<int>(实体 + 0x150 + o * 4));
                    if (strlen(扫) + strlen(段) < sizeof(扫) - 1) strcat(扫, 段);
                }
                日志("回城扫描 实体+0x150:%s", 扫);
            }
        }

        // 技能图标列（屏幕上方）—— 对齐游戏记分板尺寸
        if (cfg_skill && IsValidAddr(技能对象)) {
            float px = (技能列系数[图标序号 % 6] * 技能列步长 + 技能列基准 + cfg_skillX) * 缩放;
            float py = cfg_skillY * 缩放;
            float 图标大小 = 17.0f * 缩放;          // 原 24，缩小到接近游戏自带头像
            float 英雄中心 = py + 15.0f * 缩放;      // 行中心不变，CD 数字对齐
            float 召唤中心 = py + 42.0f * 缩放;
            float 圆心x = px + 图标大小 * 0.5f;
            char 编号[8] = {0};
            if (英雄ID > 0) snprintf(编号, sizeof(编号), "%d", (int)(英雄ID % 1000));

            id 英雄纹理 = [图标缓存 英雄:(int)英雄ID];
            画图标(英雄纹理, 0x60000000, 英雄ID > 0 ? 编号 : nullptr,
                   px, 英雄中心 - 图标大小 * 0.5f, 图标大小);

            unsigned 召唤ID = 读召唤技能ID(技能对象);
            char 召唤串[8] = {0};
            if ((int)召唤ID > 0) snprintf(召唤串, sizeof(召唤串), "%d", 召唤ID);
            id 召唤纹理 = [图标缓存 召唤师:召唤ID];
            画图标(召唤纹理, 0x60000000, (int)召唤ID > 0 ? 召唤串 : nullptr,
                   px, 召唤中心 - 图标大小 * 0.5f, 图标大小);

            unsigned CD1 = 读CD秒(技能对象, 264);
            unsigned CD2 = 读CD秒(技能对象, 336);
            char 秒串[16];
            float 圈半径 = 图标大小 * 0.5f;
            if ((int)CD2 > 0) {
                snprintf(秒串, sizeof(秒串), "%d", CD2);
                画CD底(圆心x, py + 42.0f * 缩放, 圈半径);
                画文字(圆心x, py + 42.0f * 缩放, 秒串, 0xFFFFFFFF, true);
            }
            if ((int)CD1 > 0) {
                snprintf(秒串, sizeof(秒串), "%d", CD1);
                画CD底(圆心x, py + 15.0f * 缩放, 圈半径);
                画文字(圆心x, py + 15.0f * 缩放, 秒串, 0xFFFFFF00, true);  // 黄
            }
        }
        图标序号++;

        // 小地图图标
        if (cfg_map) {
            float mx = 0.0f, my = 0.0f;
            小图坐标((int)样X, (int)样Z, 阵营, 地图, &mx, &my);
            mx *= 缩放;
            my *= 缩放;
            // 敌方头像 + 绿环的整体外径对齐游戏原生小地图头像。
            // 截图实测（原生 3x）：蓝环外径 53px、里面人像 38px、环带 ~6px；
            // 上一版 14pt+3px 环 = 外径 45px，比原生小一圈 → 头像 42px、环 4px、
            // 环内缘留 2px 间隙，外径 ≈ 54px。
            const float 图标大小 = 14.0f * 缩放;                  // 42 px @3x
            const float 环粗 = 1.35f * 缩放;                      // ≈4 px @3x
            const float 环半径 = 图标大小 * 0.5f + 0.65f * 缩放 + 环粗 * 0.5f;
            char 编号[8] = {0};
            if (英雄ID > 0) snprintf(编号, sizeof(编号), "%d", (int)(英雄ID % 1000));
            id 英雄纹理 = [图标缓存 英雄:(int)英雄ID];
            if (英雄纹理) 图标命中计++; else 图标未命中计++;
            // v33 诊断：帧间位移 > 40pt 记一次「跳」。阵营翻转时整片头像会横跨半个地图，
            // 一定会被这里抓到；正常走位则不会。
            {
                const float 跳阈 = 8.0f;   // v34：40 → 8。地图 200pt 时 8pt 已是 4% 图宽，肉眼很明显
                if (槽小图X[k] > 0.0f) {
                    float dx = (mx - 槽小图X[k]) / 缩放, dy = (my - 槽小图Y[k]) / 缩放;
                    if (dx * dx + dy * dy > 跳阈 * 跳阈) {
                        位置跳计++;
                        if (位置跳计 <= 12)
                            日志("小图跳变 k=%d 英雄=%d 从(%.1f,%.1f)到(%.1f,%.1f) 差%.0fpt",
                                 k, (int)英雄ID, 槽小图X[k] / 缩放, 槽小图Y[k] / 缩放,
                                 mx / 缩放, my / 缩放, sqrtf(dx * dx + dy * dy));
                    }
                }
                槽小图X[k] = mx; 槽小图Y[k] = my;
            }
            画图标(英雄纹理, 0x80000000, 英雄ID > 0 ? 编号 : nullptr,
                   mx - 图标大小 * 0.5f, my - 图标大小 * 0.5f, 图标大小);
            // 血环（绿）：线宽随缩放走，环外径 = 图标 + 间隙 + 环粗
            画血环(0xFF00FF00, mx, my, 环半径, 比例, 环粗);
            if (小图样数 < 3) {
                小图样阵营[小图样数] = 阵营;
                小图样世X[小图样数] = 样X;
                小图样世Z[小图样数] = 样Z;
                小图样屏X[小图样数] = mx;
                小图样屏Y[小图样数] = my;
                小图样数++;
            }
            if (在回城) 画文字(mx, my - 6.0f * 缩放, "回城", 0xFFFFFF00, true);
            else if (轨迹候选) 画文字(mx, my - 6.0f * 缩放, "?", 0xFF00FFFF, true);
        }

        // 屏内：射线点 + 方框 + 血条 + 头像 + 文字
        if (cfg_line && 屏内) {
            画线(0xFF00FFFF, 屏.x * 0.5f, 屏.y * 0.5f, sx, sy - 6.0f * 缩放, 2.0f * 缩放);
            画实心圆(0xFF0000FF, sx, sy - 6.0f * 缩放, 4.0f * 缩放);
        }

        if (屏内 && sx >= -100.0f * 缩放 && sy >= -200.0f * 缩放
            && sx <= 屏.x + 100.0f * 缩放 && sy <= 屏.y + 200.0f * 缩放) {
            float 框宽 = 40.0f * 缩放;
            float 框高 = 60.0f * 缩放;
            float 框x = sx - 框宽 * 0.5f;
            float 框y = sy - 50.0f * 缩放;

            if (cfg_box)
                画角框(0xFFFFFF00, 框x, 框y, 框宽, 框高, 2.0f);

            if (cfg_health) {
                float 条宽 = 3.0f * 缩放;
                float 条x = 框x - 6.0f * 缩放;
                画实心矩形(0x90000000, 条x, 框y, 条宽, 框高);
                画实心矩形(0xFF0000FF, 条x, 框y + 框高 * (1.0f - 比例), 条宽, 框高 * 比例);
                画框(0xFF000080, 条x, 框y, 条宽, 框高, 1.0f);
            }

            if (cfg_avatar) {
                float 头像大小 = 16.0f * 缩放;
                char 编号[8] = {0};
                if (英雄ID > 0) snprintf(编号, sizeof(编号), "%d", (int)(英雄ID % 1000));
                id 英雄纹理 = [图标缓存 英雄:(int)英雄ID];
                画图标(英雄纹理, 0x80000000, 英雄ID > 0 ? 编号 : nullptr,
                       sx - 头像大小 * 0.5f, 框y - 10.0f * 缩放, 头像大小);
            }

            if (屏内) {
                char 血文字[48];
                snprintf(血文字, sizeof(血文字), "%d血 %d", 血当前, (int)英雄ID);
                画文字(sx, 框y + 框高 + 8.0f * 缩放, 血文字, 0xFFFFFFFF, true);
            }
        }
    }

    // ==================== 敌方回城提示 ====================
    // 屏幕顶部居中的横幅：谁在回城、几个，一眼能看到；边框红度脉动，抓眼角。
    if (cfg_recall) {
        // 待命指示：没人回城时在这里留一行很淡的字，用来证明开关确实读到了
        // （看不到横幅时能立刻分清是"没人回城"还是"功能没生效"）
        画文字(屏.x * 0.5f, 70.0f * 缩放, "回城提示 待命", 0x38FFFFFF, true, true, 9.0f * 缩放);
    }
    if (cfg_recall && 回城数 > 0) {
        const float 图 = 16.0f * 缩放;
        const float 缝 = 4.0f * 缩放;
        const float 边 = 8.0f * 缩放;
        const float 字宽 = 30.0f * 缩放;
        const float 宽 = 边 * 2.0f + 字宽 + 缝 + 回城数 * 图 + (回城数 - 1) * 缝;
        const float 高 = 图 + 边 * 2.0f;
        const float 左 = 屏.x * 0.5f - 宽 * 0.5f;
        const float 顶 = 70.0f * 缩放;
        float 闪 = 0.45f + 0.55f * (0.5f + 0.5f * sinf((float)now * 6.0f));
        ImU32 框色 = ((ImU32)(60.0f + 195.0f * 闪) << 24) | 0x000000FF;
        画实心矩形(0xB8100C10, 左, 顶, 宽, 高);
        画框(框色, 左, 顶, 宽, 高, 1.6f * 缩放);
        画文字(左 + 边 + 字宽 * 0.5f, 顶 + 高 * 0.5f, "回城", 0xFFFFFFFF, true, true);
        for (int i = 0; i < 回城数; ++i) {
            float ix = 左 + 边 + 字宽 + 缝 + i * (图 + 缝);
            char 编号[8] = {0};
            if (回城英雄[i] > 0) snprintf(编号, sizeof(编号), "%d", (int)(回城英雄[i] % 1000));
            id 纹 = [图标缓存 英雄:(int)回城英雄[i]];
            画图标(纹, 0xE0000000, 回城英雄[i] > 0 ? 编号 : nullptr, ix, 顶 + 边, 图);
        }
    }

    // ==================== 野怪 ====================
    int 野怪计 = 0;
    if (cfg_monster && cfg_map && 数量 == 10) {
        野怪信息 野怪[20];
        for (int i = 0; i < 20; ++i) 野怪[i] = {0, 0, 0, 0, 0};
        野怪计 = 读野怪(模块基址, 野怪, 20);
        // 诊断日志：3 秒一次，打印前 4 个野怪的原始世界坐标 → 小图逻辑坐标，方便对照
        static double 上次野怪日志 = 0;
        double 野怪日志时 = CACurrentMediaTime();
        bool 打野怪日志 = (野怪日志时 - 上次野怪日志 > 3.0);
        if (打野怪日志) 上次野怪日志 = 野怪日志时;
        for (int m = 0; m < 野怪计; ++m) {
            // 正 / 反两种朝向各算一次：野怪阵营字段（0/1/2）到底是哪边不确定，
            // 按阵营取一路，落框外就换另一路，两路都落框外说明坐标无效，直接不画。
            float 正X = 0.0f, 正Y = 0.0f, 反X = 0.0f, 反Y = 0.0f;
            世界转小图(野怪[m].x, 野怪[m].z, 1.0f, 地图, &正X, &正Y);
            世界转小图(野怪[m].x, 野怪[m].z, -1.0f, 地图, &反X, &反Y);
            float mx, my;
            if (阵营符号(野怪[m].camp) > 0.0f) { mx = 正X; my = 正Y; }
            else                                { mx = 反X; my = 反Y; }
            if (!在框内(地图, mx, my)) {
                if (在框内(地图, 正X, 正Y))      { mx = 正X; my = 正Y; }
                else if (在框内(地图, 反X, 反Y)) { mx = 反X; my = 反Y; }
                else continue;
            }
            // 全部野怪都记（原来只记前 4 个，导致截图里能看到的点没法逐个配对）
            if (打野怪日志)
                日志("野怪%d 世=(%d,%d) 阵=%d → 图=(%.1f,%.1f) 框=(%.1f,%.1f,%.1f) 缩=%.2f",
                     m, 野怪[m].x, 野怪[m].z, 野怪[m].camp, mx, my,
                     cfg_mapX, cfg_mapY, cfg_mapSize, 缩放);
            // 缩放校正：v23 起「小图比例」已经在 世界转小图() 里统一乘过了，
            // 这里再乘一次会变成平方 —— 删掉。
            // 面板「野怪点位对齐微调」：手动平移，单位是逻辑点，最后一起乘缩放
            if (cfg_monsteroff_on) {
                mx += cfg_monsterOffX;
                my += cfg_monsterOffY;
            }
            mx *= 缩放;
            my *= 缩放;
            if (野怪[m].cd > 0 && 野怪[m].cd < 野怪[m].刷新 && 野怪[m].cd <= 600) {
                char 秒串[16];
                snprintf(秒串, sizeof(秒串), "%d", 野怪[m].cd);
                画实心圆(0xFFFF00FF, mx, my, 3.0f * 缩放);   // 洋红底点：和游戏原生绿苗区分开
                画文字(mx, my - 10.0f * 缩放, 秒串, 0xFFFFFFFF, true);
            } else {
                画实心圆(0xFFFF00FF, mx, my, 3.0f * 缩放);
            }
        }
    }

    // ==================== 对局判定 & 统计 ====================
    bool 判在对局 = 数量 >= 8 && 数量 <= 12
                 && 有坐标实体 >= 1
                 && 首个英雄ID > 0
                 && 首个血上限 > 0
                 && 首个血当前 > 0 && 首个血当前 <= 首个血上限;
    对局状态(判在对局, false, now);
    if (!在对局) 底部文字(屏, "等待进入对局");

    double 统计时刻 = CACurrentMediaTime();
    if (统计时刻 - 上次对局统计 > 5.0) {
        上次对局统计 = 统计时刻;
        float fps = BBZGUI::GetIO().DeltaTime > 0.0f ? 1.0f / BBZGUI::GetIO().DeltaTime : 0.0f;
        double 全槽最大 = 0.0;
        for (int i = 0; i < 24; ++i) if (槽世最大跳[i] > 全槽最大) 全槽最大 = 槽世最大跳[i];
        日志("n=%d 敌=%d 屏=%d 野=%d 阵[-1:%d 0:%d 1:%d 2:%d 3:%d] 血样%d/%d 链=%s 英雄=%d 我=%d 读=%d 限=%d 任务=%d 链=%s fps=%.0f m00=%.3f 阵切=%d 跳=%d 阵52=%d 阵C0=%d 体切=%d 世跳=%d 最大世跳=%.0f 稳压=%d 稳接=%d 瞬移=%d 直=%d 链=%d 不符=%d 用链=%d 用二=%d 二失=%d 二链不符=%d 投票=%d/%d 矩变=%.2f/%.2f/%.2f",
             数量, 有坐标实体, 屏内实体, 野怪计,
             阵营直方[0], 阵营直方[1], 阵营直方[2], 阵营直方[3], 阵营直方[4],
             首个血当前, 首个血上限, 链名(首个链), (int)首个英雄ID, 我方阵营,
             (int)读总数, 读限流计数, 任务端口 != 0, 链名(当前链), fps,
             矩阵[0], 阵营切换计, 位置跳计, 首个阵营52, 首个阵营C0, 实体阵营切换计,
             世界跳计, 全槽最大, 稳定压计, 稳定接计, 瞬移认计,
             直读成功计, 链读成功计, 直链不符计, 用链计,
             用二计, 二失败计, 二链不符计, 投票一致计, 投票分歧计,
             矩阵最大变[12], 矩阵最大变[13], 矩阵最大变[14]);
        直读成功计 = 0; 链读成功计 = 0; 直链不符计 = 0; 用直计 = 0; 用链计 = 0;
        用二计 = 0; 二失败计 = 0; 二链不符计 = 0;
        投票一致计 = 0; 投票分歧计 = 0;
        for (int i = 0; i < 16; ++i) 矩阵最大变[i] = 0.0f;
        // v38：直读值（对照用，已不参与输出）与滤波后的输出值
        {
            char 串[300] = {0};
            int 位 = 0;
            for (int i = 0; i < 10 && 位 < 270; ++i) {
                if (!槽直遥有[i] && !槽稳有[i]) continue;
                位 += snprintf(串 + 位, sizeof(串) - 位, "k%d直(%d,%d)[%d]出(%d,%d) ",
                               i, (int)槽直遥X[i], (int)槽直遥Z[i], 槽直分[i],
                               (int)槽稳X[i], (int)槽稳Z[i]);
            }
            日志("坐标对照 %s", 串);
        }
        // v34：逐槽位世界坐标最大帧间位移（本窗口），单位是世界坐标。
        // 正常走位一帧几百；上一千说明读到的坐标在抖，跟原生头像就会错位。
        {
            char 世串[240] = {0};
            int 写位 = 0;
            for (int i = 0; i < 10 && 写位 < 220; ++i) {
                写位 += snprintf(世串 + 写位, sizeof(世串) - 写位, "%d:%.0f ",
                                 i, 槽世最大跳[i]);
                槽世最大跳[i] = 0.0;      // 每窗口重置，下一窗口重新统计
            }
            日志("世界跳幅[0..9]= %s", 世串);
        }
        // v38：滤波后「实际画出去」的帧间位移。这个数才是眼睛看到的抖动幅度。
        {
            char 出串[240] = {0};
            int 写位2 = 0;
            for (int i = 0; i < 10 && 写位2 < 220; ++i) {
                写位2 += snprintf(出串 + 写位2, sizeof(出串) - 写位2, "%d:%.0f ",
                                  i, 槽出最大跳[i]);
                槽出最大跳[i] = 0.0;
            }
            日志("输出跳幅[0..9]= %s", 出串);
        }
        // 小地图标定：图矩形 / 缩放 / 前 3 个样本的 世界坐标 → 小图坐标
        日志("地图标定 图=%.1f/%.1f/%.1f 缩=%.2f 框=(%.0f,%.0f,%.0f)",
             cfg_mapX, cfg_mapY, cfg_mapSize, 缩放,
             cfg_mapX * 缩放, cfg_mapY * 缩放, cfg_mapSize * 缩放);
        for (int s = 0; s < 小图样数; ++s) {
            日志("  样本%d 阵=%d 世界=(%d,%d) 小图=(%.1f,%.1f)",
                 s + 1, 小图样阵营[s], (int)小图样世X[s], (int)小图样世Z[s],
                 小图样屏X[s], 小图样屏Y[s]);
        }
        // v32 诊断：槽位锁定的英雄 ID（应当整局不变）+ 纹理命中率。
        // 命中=0 且空=N 说明头像还在走占位圆；ID 一列来回变说明锁定失效。
        {
            char 锁串[180] = {0};
            int 上限数 = 数量 < 10 ? 数量 : 10;
            for (int i = 0; i < 上限数; ++i) {
                char 段[16];
                snprintf(段, sizeof(段), " %d", 槽英雄ID[i]);
                if (strlen(锁串) + strlen(段) < sizeof(锁串) - 1) strcat(锁串, 段);
            }
            日志("图标锁定 槽位ID[0..%d]=%s 命中=%d 空=%d", 上限数 - 1, 锁串,
                 图标命中计, 图标未命中计);
            图标命中计 = 0;
            图标未命中计 = 0;
        }
    }
}

// CD 数字底圈（半径跟图标一致，超出图标会变成一圈黑晕）
static void 画CD底(float cx, float cy, float 半径) {
    画实心圆(0x90000000, cx, cy, 半径);
}

static float clamp01(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}

@end
