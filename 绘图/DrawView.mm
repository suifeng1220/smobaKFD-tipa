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
        日志文件 = fopen("/var/mobile/Documents/ab_draw.log", "a");
        if (!日志文件) {
            const char* home = getenv("HOME");
            if (home) {
                char path[512] = {0};
                snprintf(path, sizeof(path), "%s/Documents/ab_draw.log", home);
                日志文件 = fopen(path, "a");
            }
        }
        if (!日志文件) 日志文件 = fopen("/tmp/ab_draw.log", "a");
    }
    char line[600];
    vsnprintf(line, sizeof(line), fmt, va);
    va_end(va);
    日志入环(line);
    KernelLogLine(line);
    if (日志文件) {
        time_t now = time(nullptr);
        struct tm tmv;
        localtime_r(&now, &tmv);
        fprintf(日志文件, "%02d:%02d:%02d %s\n", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, line);
        fflush(日志文件);
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
    NSMutableDictionary* 可变 = [[NSDictionary dictionaryWithContentsOfFile:@(设置路径)] mutableCopy];
    if (!可变) return;

    // v18 一次性迁移：以前自动适配写回的 mapX/mapY/mapSize 会被下一帧当成"用户手调"，
    // 于是自动适配第一次写就被永久锁死 —— 这就是"自动对齐改了没反应"的真正原因。
    // 这里把两个开关复位成自动，并打上版本号，之后永远按开关走。
    {
        id 版本 = [可变 objectForKey:@"mapAutoVer"];
        if (!版本 || [版本 intValue] < 2) {
            可变[@"mapsize_on"] = @NO;
            可变[@"mappos_on"] = @NO;
            可变[@"mapAutoVer"] = @2;
            [可变 writeToFile:@(设置路径) atomically:YES];
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
    if (!cfg_skillpos_on) {
        cfg_skillX = 11.0f;   // 关掉就回到内置默认位置
        cfg_skillY = 27.0f;
    }

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
}

// 小地图自适配回写：参数变化 ≥1.0 才写 plist
// 写尺寸/写位置分开控制：面板手动定了哪一项，自动适配就别把人家拖过的值冲掉。
static void 回写地图配置(float mapX, float mapY, float mapSize, bool 写尺寸, bool 写位置) {
    static double 上次 = 0;
    double now = CACurrentMediaTime();
    if (now - 上次 < 3.0) return;
    上次 = now;
    NSString* path = @(设置路径);
    NSMutableDictionary* dict = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    if (!dict) dict = [NSMutableDictionary dictionary];
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
    BOOL ok = [dict writeToFile:path atomically:YES];
    if (写位置) { cfg_mapX = mapX; cfg_mapY = mapY; }
    if (写尺寸) cfg_mapSize = mapSize;
    if (ok) {
        // 自动写回不算手调，两个标志保持 false，下一帧继续自动跟屏幕走
        有手调尺寸 = false;
        位置已手调 = false;
        地图已手调 = false;
    }
    日志("小地图自适配 %.1f/%.1f/%.1f 写尺寸=%d 写位置=%d 回写 plist=%d",
         mapX, mapY, mapSize, 写尺寸 ? 1 : 0, 写位置 ? 1 : 0, ok ? 1 : 0);
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
// 返回 0=不在回城 1=指针链命中 2=直读字段命中（两套判据都试，日志里标来源）
static int 读回城来源(uint64_t 技能对象) {
    uint64_t a = vm_read<uint64_t>(技能对象 + SDK::回城对象);
    if (IsValidAddr(a)) {
        uint64_t b = vm_read<uint64_t>(a + SDK::回城状态);
        if (IsValidAddr(b) && b >= 0x128 && vm_read<int>(b - 296) == 1) return 1;
    }
    // SDK 注释写的是「实体+360 → +272 非零即在回城」，与上面的指针链版本冲突。
    // 把 +360 本身当状态字段读一次做兜底：指针低 32 位不可能恰好等于 1，误报率可忽略。
    if (vm_read<int>(技能对象 + SDK::回城对象) == 1) return 2;
    return 0;
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
static const float 世界半程 = 109000.0f;

// 世界坐标 → 小地图逻辑坐标（未乘缩放）。翻转 = ±1，-1 时整体旋转 180°。
static void 世界转小图(int x, int z, float 翻转, const ImVec4& 地图, float* 出X, float* 出Y) {
    float half = 地图.w * 0.5f;
    *出X = ((x * 翻转) / 世界半程) * 地图.w + 地图.x + half;
    *出Y = ((z * 翻转) / 世界半程) * (-地图.w) + 地图.y + half;
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
            // 系数按原生小地图实测标定（截图像素 / 屏幕短边）：
            //   原生小地图宽 313px / 屏高 1280px = 0.2445；左边距 164px = 0.128 短边；上边距 ~5px。
            // 旧值 0.328 比原生大 34%，自动模式下必然对不齐 —— 所以以前只能靠手调大小滑条。
            float 基准 = 短边 / 缩放;
            float 新X = 用自动位置 ? 基准 * 0.128f : cfg_mapX;
            float 新Y = 用自动位置 ? 基准 * 0.004f : cfg_mapY;
            float 新尺寸 = 用自动尺寸 ? 基准 * 0.2445f : cfg_mapSize;
            cfg_mapX = 新X;
            cfg_mapY = 新Y;
            cfg_mapSize = 新尺寸;
            回写地图配置(新X, 新Y, 新尺寸, 用自动尺寸, 用自动位置);
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

    // 对齐辅助：高对比度取景框 + 中心十字 + 底部数值读标。
    // 旧版括号画在青色边框正上方、同色同粗，看起来和"只开了小地图"没区别 —— 等于没画。
    // 现在改成白色粗括号 + 红色十字 + 半透明对角线，并把 mapX/mapY/尺寸 直接打在屏幕上，
    // 关没关、调到多少，一眼可读。也不再要求「小地图」开关同时打开。
    if (cfg_mapalign) {
        const float 左 = cfg_mapX * 缩放, 上 = cfg_mapY * 缩放;
        const float 宽 = cfg_mapSize * 缩放;
        const float 右 = 左 + 宽, 下 = 上 + 宽;
        const float 臂 = 24.0f * 缩放;
        const float 粗 = 2.8f * 缩放;
        const ImU32 角 = 0xFFFFFFFF;      // 白
        const ImU32 叉 = 0xFFFF4040;      // 红（中心）
        // 对角线：判断中心偏没偏，比盯着四条边直观
        画线(0x50FF00FF, 左, 上, 右, 下, 1.2f * 缩放);
        画线(0x50FF00FF, 右, 上, 左, 下, 1.2f * 缩放);
        // 四角 L 括号
        画线(角, 左, 上, 左 + 臂, 上, 粗);
        画线(角, 左, 上, 左, 上 + 臂, 粗);
        画线(角, 右, 上, 右 - 臂, 上, 粗);
        画线(角, 右, 上, 右, 上 + 臂, 粗);
        画线(角, 左, 下, 左 + 臂, 下, 粗);
        画线(角, 左, 下, 左, 下 - 臂, 粗);
        画线(角, 右, 下, 右 - 臂, 下, 粗);
        画线(角, 右, 下, 右, 下 - 臂, 粗);
        // 中心十字
        const float 心X = (左 + 右) * 0.5f, 心Y = (上 + 下) * 0.5f;
        画线(叉, 心X - 臂, 心Y, 心X + 臂, 心Y, 粗);
        画线(叉, 心X, 心Y - 臂, 心X, 心Y + 臂, 粗);
        // 数值读标（逻辑点，未乘缩放）
        char 标[80];
        snprintf(标, sizeof(标), "X %.1f  Y %.1f  尺寸 %.1f",
                 cfg_mapX, cfg_mapY, cfg_mapSize);
        画文字(心X, 下 + 11.0f * 缩放, 标, 0xFFFFFFFF, true, true, 11.0f * 缩放);
        snprintf(标, sizeof(标), "自动 尺寸%s 位置%s",
                 cfg_mapsize_on ? "关" : "开", cfg_mappos_on ? "关" : "开");
        画文字(心X, 下 + 24.0f * 缩放, 标, 0xFF80FF80, true, true, 9.5f * 缩放);
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

    for (int k = 0; k < 数量 && k < 24; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(实体)) continue;
        有效实体++;

        int 阵营 = vm_read<int>(实体 + 52);
        if (阵营 >= -1 && 阵营 <= 7) 阵营直方[阵营 + 1]++;

        if (阵营 == (int)我方阵营) continue;

        int 血当前 = 读血量当前(实体);
        int 血上限 = 读血量上限(实体);
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

        long long 英雄ID = vm_read<long long>(实体 + 40);
        uint64_t 技能对象 = vm_read<uint64_t>(实体 + 488);

        // 回城检测放在这里：原来它藏在小地图图标那段（if cfg_map）里面，
        // 小地图一关就完全不检测，横幅自然永远不出来。现在与 cfg_map 解耦。
        int 回城来源 = IsValidAddr(技能对象) ? 读回城来源(技能对象) : 0;
        bool 在回城 = 回城来源 != 0;
        if (在回城 && 回城数 < 5) 回城英雄[回城数++] = 英雄ID;
        if (打回城日志 && k < 3) {
            uint64_t 链A = IsValidAddr(技能对象) ? vm_read<uint64_t>(技能对象 + SDK::回城对象) : 0;
            uint64_t 链B = IsValidAddr(链A) ? vm_read<uint64_t>(链A + SDK::回城状态) : 0;
            int 判值 = (IsValidAddr(链B) && 链B >= 0x128) ? vm_read<int>(链B - 296) : -999;
            日志("回城链 k=%d 英雄=%lld 技能=%llx A=%llx B=%llx 判值=%d 直读=%d 来源=%d",
                 k, 英雄ID, 技能对象, 链A, 链B, 判值,
                 vm_read<int>(技能对象 + SDK::回城对象), 回城来源);
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
        const float 图心X = 地图.x + 地图.w * 0.5f;
        const float 图心Y = 地图.y + 地图.w * 0.5f;
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
            if (打野怪日志 && m < 4)
                日志("野怪%d 世=(%d,%d) 阵=%d → 图=(%.1f,%.1f) 框=(%.1f,%.1f,%.1f) 缩=%.2f",
                     m, 野怪[m].x, 野怪[m].z, 野怪[m].camp, mx, my,
                     cfg_mapX, cfg_mapY, cfg_mapSize, 缩放);
            // 缩放校正：以图心为基准缩放，补的是比例误差（平移补不了）
            if (cfg_monsterScale < 0.999f || cfg_monsterScale > 1.001f) {
                mx = 图心X + (mx - 图心X) * cfg_monsterScale;
                my = 图心Y + (my - 图心Y) * cfg_monsterScale;
                if (!在框内(地图, mx, my)) continue;
            }
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
                画文字(mx, my - 10.0f * 缩放, 秒串, 0xFFFFFFFF, true);
            } else {
                画实心圆(0xFF00FF00, mx, my, 2.0f * 缩放);
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
