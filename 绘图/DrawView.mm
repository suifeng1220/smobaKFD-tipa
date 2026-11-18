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
static bool 读坐标值(uint64_t 坐标址, unsigned* X, unsigned* Z) {
    if (!IsValidAddr(坐标址)) return false;
    int ix = vm_read<int>(坐标址);
    int iz = vm_read<int>(坐标址 + 8);
    if (坐标合理(ix) && 坐标合理(iz) && (ix || iz)) {
        *X = (unsigned)ix;
        *Z = (unsigned)iz;
        return true;
    }
    float fx = vm_read<float>(坐标址);
    float fz = vm_read<float>(坐标址 + 8);
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
    if (i < 0 || i >= 3) return "-";
    return SDK::坐标链表[i].名字;
}

// 读实体坐标（走当前链，无效时兜底链[0]）
static int 读实体坐标(uint64_t 实体, unsigned* X, unsigned* Z) {
    if (当前链 < 0 || 当前链 >= 3) {
        if (读坐标某链(实体, SDK::坐标链表[0], X, Z)) return 0;
        return -1;
    }
    if (读坐标某链(实体, SDK::坐标链表[当前链], X, Z)) return 当前链;
    return -1;
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
    for (int i = 0; i < 16; ++i) {
        矩阵[i] = vm_read<float>(d + 296 + 4 * i);
        if (!isfinite(矩阵[i]) || fabsf(矩阵[i]) > 10000000.0f) return false;
    }
    if (fabsf(矩阵[0]) > 0.000001f && fabsf(矩阵[5]) > 0.000001f && fabsf(矩阵[15]) > 0.000001f) {
        相机节点 = d;
        return true;
    }
    return false;
}

// 读矩阵（主相机失败自动切备并记住）
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
                if (!isfinite(m[k]) || fabsf(m[k]) > 10000000.0f) { 正常 = false; break; }
            }
            if (!正常) continue;
            bool 正交 = fabsf(m[11]) < 0.0001f && fabsf(m[15] - 1.0f) < 0.0001f;
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
    if (fabsf(当前 - 目标) < 0.0005f) return true;
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
                if (目标度 <= 6.0f || fabsf(v - 目标度) > 目标度 * 0.03f) {
                    if (fabsf(v - 当前fov) > 当前fov * 0.03f) continue;
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
        if (期望 > 0.05f) 命中 = (fabsf(列长 - 期望) / 期望) < 0.08f;
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
            if (isfinite(原值) && fabsf(原值 - 校准候选值[i]) > 0.001f)
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
            日志("=== smobaKFD v32 启动 日志=%s 缩放=%.3f 屏=%.0fx%.0f 短边=%.0f",
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
    unsigned 我方阵营;
    if (cfg_team) {
        我方阵营 = (unsigned)cfg_team;
    } else {
        我方阵营 = 矩阵[0] <= 0.0f ? 2 : 1;
    }

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

    for (int k = 0; k < 数量 && k < 24; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(实体)) continue;
        有效实体++;

        int 阵营 = vm_read<int>(实体 + 52);
        if (阵营 >= -1 && 阵营 <= 7) 阵营直方[阵营 + 1]++;

        // ---- 回城位标定：内存差分（5 次/秒，覆盖实体 +0x0..+0x600）----
        // 尾部跨页读不到时自动降档（0x600→0x300→0x180→0x100），保证一定有输出。
        if (做差分) {
            const double 现时 = CACurrentMediaTime();

            // 1) 坐标：只为抓「瞬移」那一帧。自己人也跟，标定必须从自己的回城学。
            bool 瞬移 = false;
            unsigned 现X = 0, 现Z = 0;
            if (读实体坐标(实体, &现X, &现Z) >= 0) {
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

        int 血当前 = 读血量当前(实体);
        int 血上限 = 读血量上限(实体);
        int 原始上限 = (血上限 > 0 && 血上限 < 2000000) ? 血上限 : 0;  // 给槽位锁定用，别被下面的兜底 1 污染
        bool 血有效 = 血上限 > 0 && 血上限 < 2000000
                   && !(血当前 & 0x80000000) && (unsigned)血当前 <= (unsigned)血上限;
        if (血有效 && 血当前 == 0) continue;   // 血量归零 → 已死亡，跳过
        if (!血有效) { 血当前 = 1; 血上限 = 1; }  // 血量读不到 → 按满血画

        unsigned 样X = 0, 样Z = 0;
        int 链 = 读实体坐标(实体, &样X, &样Z);
        if (链 < 0 || 样X == 1000000) continue;

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
                        ? (fabsf(vm_read<float>(实体 + 回城位偏移)) > 0.5f)
                        : (vm_read<int>(实体 + 回城位偏移) >= 50 &&
                           vm_read<int>(实体 + 回城位偏移) < 30000))
                 : (回城位是浮点 ? (fabsf(vm_read<float>(实体 + 回城位偏移)) > 0.5f)
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
        日志("n=%d 敌=%d 屏=%d 野=%d 阵[-1:%d 0:%d 1:%d 2:%d 3:%d] 血样%d/%d 链=%s 英雄=%d 我=%d 读=%d 限=%d 任务=%d 链=%s fps=%.0f",
             数量, 有坐标实体, 屏内实体, 野怪计,
             阵营直方[0], 阵营直方[1], 阵营直方[2], 阵营直方[3], 阵营直方[4],
             首个血当前, 首个血上限, 链名(首个链), (int)首个英雄ID, 我方阵营,
             (int)读总数, 读限流计数, 任务端口 != 0, 链名(当前链), fps);
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
