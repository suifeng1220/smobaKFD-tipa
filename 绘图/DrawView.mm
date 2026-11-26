//
//  DrawView.mm - S45 王者荣耀(smoba) 渲染核心  [S45 重建版]
//
//  由 AB_WZRY_S45重建版.tipa 内 Books 二进制反编译还原
//  （对应 __ZN4Draw10StartBooksEv 0x100082DB0 及周边辅助函数）
//

#include "DrawView.hpp"
#include <mutex>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
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
static int cfg_scan_max = 96;              // 每帧最多扫的实体槽（联机实体多，原来写死 24 会把英雄漏掉）
static int cfg_id_pick = 1;                // 只画“像英雄”的实体（英雄ID 1..999 且 ID 不重复）
static bool 地图已手调 = false;            // 0x100223580（plist 里有 mapX/mapY/mapSize 就不自动回写）
static bool cfg_fov_probe = false;         // 0x100223590
static bool cfg_status = false;            // 左下角状态浮层开关（默认关，不自动弹出）

static const char* 设置路径 = "/var/mobile/Library/Preferences/com.map.settings.plist";

// StartBooks 局部静态
static float 缩放系数 = 1.0f;              // 缩放 = 短边/物理短边
static double 上次读配置 = 0;              // 读配置节流
static double 上次找进程推进 = 0;          // 看门狗
static unsigned 找进程调用快照 = 0;
static double 上次对局统计 = 0;            // 5s 统计日志
static int 技能列系数[6] = {1, 2, 3, 4, 5, 6};  // StartBooks::系数表

// ===== 联机稳定化状态 =====
// 联机对局的实体数组里混着小兵/野怪/召唤物，阵营会逐帧抖动。
// 下面几个计数器给我方阵营加滞回。
static unsigned 阵营锁定 = 0;              // 锁定的我方阵营（0=未定）
static int 阵营异见连计 = 0;               // 与锁定值不一致的连续帧数
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
    NSDictionary* cfg = [NSDictionary dictionaryWithContentsOfFile:@(设置路径)];
    if (!cfg) return;
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
    cfg_scan_max  = (int)读浮点(cfg, @"scan_max", 96.0f);
    cfg_id_pick   = (int)读浮点(cfg, @"id_pick", 1.0f);
    if (cfg_scan_max < 12) cfg_scan_max = 12;
    if (cfg_scan_max > 512) cfg_scan_max = 512;

    // 用户手动调过地图位置 → 停止小地图自适配回写
    地图已手调 = [cfg objectForKey:@"mapX"] != nil
              || [cfg objectForKey:@"mapY"] != nil
              || [cfg objectForKey:@"mapSize"] != nil;

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
static void 回写地图配置(float mapX, float mapY, float mapSize) {
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
    if (fabsf(旧X - mapX) >= 1.0f || fabsf(旧Y - mapY) >= 1.0f || fabsf(旧S - mapSize) >= 1.0f) {
        dict[@"mapX"]    = @(roundf(mapX * 10.0f) / 10.0f);
        dict[@"mapY"]    = @(roundf(mapY * 10.0f) / 10.0f);
        dict[@"mapSize"] = @(roundf(mapSize * 10.0f) / 10.0f);
        BOOL ok = [dict writeToFile:path atomically:YES];
        cfg_mapX = mapX; cfg_mapY = mapY; cfg_mapSize = mapSize;
        if (ok) 地图已手调 = true;
        日志("小地图自适配 %.1f/%.1f/%.1f 回写 plist=%d", mapX, mapY, mapSize, ok ? 1 : 0);
    }
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

// ==================== 坐标读取（单一来源：实测直读） ====================

// 世界坐标合理区间：地图半幅约 109000（小图换算 /109000），留 40% 余量。
// 原来放到 ±200000/400000 太松，联机时错位解引用的垃圾值也能通过 → 坐标在真/假之间闪。
static inline bool 坐标合理(int v) {
    return v != 1000000 && v > -150000 && v < 150000;
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

// 三套多平台坐标链（H5 / S44 / 安卓）连同 链步 / 读坐标某链 / 链样点统计 / 链打分
// 已于 2026-11-26 整段删除。理由见 SDK.h 顶部注释：三条链在 iOS 实测全是垃圾值，
// 每帧互相打分还会切链，是"画面闪来闪去"的噪声源之一。


// 坐标来源名称。现在只有一条路：实测直读（索引 4）。
static const char* 链名(int i) {
    return i >= 0 ? "直读" : "-";
}

// ===== 英雄坐标：实测直读 实体+0x278 / +0x280 =====
//
// 2026-11-26 状态：这条偏移**已证伪为静态值**，不是当前位置。
//   - fields_dump2.txt（555 快照）：10 个英雄的 +0x278/+0x280 两两不同、全在 ±60000、
//     阵营 1 全负 / 阵营 2 全正 → 它确实是一组真实坐标（两组对角出生点）；
//   - fields_dump3.txt（782 快照 / 约 6.5 分钟，玩家全程走动）：10 个槽的 X、Z
//     唯一值个数全是 1，一个字节都没变 → 它是静态数据，不是位置。
//   - 真实动态位置等 fields_dump4.txt 的动态搜索给出；在那之前这里不假装能用。
//
// 旧的 H5 / S44 / 安卓 三条四段指针链已整段删除，理由见 SDK.h 顶部注释。
static const uint64_t 坐标偏移X = 0x278;
static const uint64_t 坐标偏移Y = 0x27C;
static const uint64_t 坐标偏移Z = 0x280;

static bool 读实测坐标(uint64_t 实体, unsigned* X, unsigned* Z) {
    if (!IsValidAddr(实体)) return false;
    return 读坐标值(实体 + 坐标偏移X, X, Z);
}

// 读实体坐标：只有实测直读一条路，读不到返回 -1（没有链兜底了）
static int 读实体坐标(uint64_t 实体, unsigned* X, unsigned* Z) {
    return 读实测坐标(实体, X, Z) ? 4 : -1;
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
static bool 读回城(uint64_t 技能对象) {
    uint64_t a = vm_read<uint64_t>(技能对象 + SDK::回城对象);
    if (!IsValidAddr(a)) return false;
    uint64_t b = vm_read<uint64_t>(a + SDK::回城状态);
    if (!IsValidAddr(b)) return false;
    return b >= 0x128 && vm_read<int>(b - 296) == 1;
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
            return true;
        }
        日志("模块失效（原=0x%llx），重新找", 模块基址);
        模块基址 = 0;
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
        状态文字 = "找 UnityFramework";
        char 主名[64] = {0};
        char 主路径[256] = {0};
        mach_port_t 端口 = 0;
        uint64_t 基址 = 找模块基址(游戏pid, &端口, 主名, 主路径);
        if (基址 && 基址是MachO(游戏pid, 基址)) {
            模块基址 = 基址;
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

// 小图坐标（英雄，/109000，阵营 1 时 y 取反）
static void 小图坐标(int x, int z, unsigned 阵营, const ImVec4& 地图, float* 出X, float* 出Y) {
    float 翻转 = 阵营符号(阵营);
    float half = 地图.w * 0.5f;
    *出X = ((x * 翻转) / 109000.0f) * 地图.w + 地图.x + half;
    *出Y = ((z * 翻转) / 109000.0f) * (-地图.w) + 地图.y + half;
}

// 野怪小图坐标（/100000）
static void 野怪小图坐标(int x, int z, unsigned 阵营, const ImVec4& 地图, float* 出X, float* 出Y) {
    float 翻转 = 阵营符号(阵营);
    float half = 地图.w * 0.5f;
    *出X = ((x * 翻转) / 100000.0f) * 地图.w + 地图.x + half;
    *出Y = ((z * 翻转) / 100000.0f) * (-地图.w) + 地图.y + half;
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

// ==================== 运行时字段取证 ====================
//
// 依据（可自校验，不是推断）：
//   il2cpp 对象头 [+0] = Il2CppClass*
//   Il2CppClass 内部存有 FieldInfo* 字段表
//   FieldInfo = { const char* name;          // +0
//                 const Il2CppType* type;    // +8
//                 Il2CppClass* parent;       // +16
//                 int32_t offset;            // +24  ← 真实 C# 字段偏移
//                 uint32_t token; }          // +28      共 32 字节
// 所以从任意实体指针出发，就能反推它所属类的全部字段名与真实偏移。
//
// 校验手段（三条同时成立才认）：
//   1. 字段名指针指向可读 ASCII 字符串（0x20~0x7E，40 字节内有结束符）
//   2. offset 落在 [-0x100, 0x20000]
//   3. 连续 6 项都满足，且 FieldInfo.parent 多数等于本类指针
// 命中的表会把真实名字打印出来，名字对不上就说明没命中——不存在“看起来对”。
static bool 读字段名(uint64_t 地址, char* 出, int 上限) {
    if (!IsValidAddr(地址) || 上限 < 2) return false;
    char 缓冲[64];
    int 需 = 上限 < 64 ? 上限 : 64;
    if (!readMemory(地址, 缓冲, 需)) return false;
    for (int i = 0; i < 需; ++i) {
        unsigned char c = (unsigned char)缓冲[i];
        if (c == 0) {
            出[i] = 0;
            return i > 0;
        }
        if (c < 0x20 || c > 0x7E) return false;   // 字段名只可能是可见 ASCII
        出[i] = (char)c;
    }
    return false;                                  // 无结束符，不像字段名
}

// 在 klass 内存里找 FieldInfo 表，返回表地址；*出字段数 为连续有效项数
static uint64_t 找字段表(uint64_t 类, int* 出字段数) {
    unsigned char 类体[0x800];
    if (!readMemory(类, 类体, sizeof(类体))) return 0;

    uint64_t 最佳 = 0;
    int 最佳分 = 0, 最佳数 = 0;

    for (int 位 = 0x40; 位 + 8 <= 0x800; 位 += 8) {
        uint64_t 表 = 0;
        memcpy(&表, 类体 + 位, 8);
        if (!IsValidAddr(表) || (表 & 7)) continue;

        // 先只读一项做快速筛查，避免无谓的大块读
        unsigned char 首项[32];
        if (!readMemory(表, 首项, 32)) continue;
        uint64_t 名0;
        int32_t 偏0;
        memcpy(&名0, 首项, 8);
        memcpy(&偏0, 首项 + 24, 4);
        if (偏0 < -0x100 || 偏0 > 0x20000) continue;
        char 试名[48];
        if (!读字段名(名0, 试名, 40)) continue;

        // 连续 64 项逐项验证
        unsigned char 全表[32 * 64];
        if (!readMemory(表, 全表, sizeof(全表))) continue;
        int 好 = 0, 父命中 = 0;
        for (int i = 0; i < 64; ++i) {
            unsigned char* e = 全表 + i * 32;
            uint64_t 名p, 父p;
            int32_t 偏;
            memcpy(&名p, e, 8);
            memcpy(&父p, e + 16, 8);
            memcpy(&偏, e + 24, 4);
            if (偏 < -0x100 || 偏 > 0x20000) break;
            char 名[48];
            if (!读字段名(名p, 名, 40)) break;
            好++;
            if (父p == 类) 父命中++;
        }
        if (好 < 6) continue;
        int 分 = 好 * 2 + 父命中;
        if (分 > 最佳分) {
            最佳分 = 分;
            最佳 = 表;
            最佳数 = 好;
        }
    }
    if (出字段数) *出字段数 = 最佳数;
    return 最佳;
}

// 从 klass 取 名称 + 命名空间
static bool 读类名(uint64_t 类, char* 名, char* 空间) {
    char a[64] = {0}, b[64] = {0};
    if (读字段名(vm_read<uint64_t>(类 + 16), a, 48)
        && 读字段名(vm_read<uint64_t>(类 + 24), b, 48)) {
        strncpy(名, a, 63); strncpy(空间, b, 63);
        return true;
    }
    // 兜底：klass 头部找相邻的两个字符串指针
    for (int 位 = 0; 位 < 0x100; 位 += 8) {
        uint64_t p1 = vm_read<uint64_t>(类 + 位);
        uint64_t p2 = vm_read<uint64_t>(类 + 位 + 8);
        if (!IsValidAddr(p1) || !IsValidAddr(p2)) continue;
        if (读字段名(p1, a, 48) && 读字段名(p2, b, 48)) {
            strncpy(名, a, 63); strncpy(空间, b, 63);
            return true;
        }
    }
    名[0] = 0;
    空间[0] = 0;
    return false;
}

// 一次性导出实体的类结构到 Documents/fields_dump.txt
static bool 字段取证(uint64_t 数组, int 数量) {
    const char* 家 = getenv("HOME");
    if (!家 || !IsValidAddr(数组) || 数量 <= 0) return false;
    char 路径[512];
    snprintf(路径, sizeof(路径), "%s/Documents/fields_dump.txt", 家);
    FILE* fp = fopen(路径, "a");
    if (!fp) return false;

    fprintf(fp, "\n########## 字段取证 ##########\n");
    fprintf(fp, "数组=%#llx  槽数=%d\n", (unsigned long long)数组, 数量);

    uint64_t 见过[8] = {0};
    int 见过数 = 0, 打印类 = 0;

    for (int i = 0; i < 数量 && 打印类 < 4; ++i) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * i);
        if (!IsValidAddr(实体)) continue;
        uint64_t 类 = vm_read<uint64_t>(实体);
        if (!IsValidAddr(类)) continue;

        bool 重复 = false;
        for (int k = 0; k < 见过数; ++k) if (见过[k] == 类) 重复 = true;
        if (重复) continue;
        if (见过数 < 8) 见过[见过数++] = 类;

        char 名[64] = {0}, 空间[64] = {0};
        读类名(类, 名, 空间);
        int 字段数 = 0;
        uint64_t 表 = 找字段表(类, &字段数);
        if (!表) {
            fprintf(fp, "\n--- 槽%d 实体=%#llx 类=%#llx %s.%s ：未找到 FieldInfo 表 ---\n",
                    i, (unsigned long long)实体, (unsigned long long)类, 空间, 名);
            continue;
        }

        fprintf(fp, "\n--- 槽%d  实体=%#llx  类=%#llx  %s.%s  有效项=%d  表=%#llx ---\n",
                i, (unsigned long long)实体, (unsigned long long)类, 空间, 名,
                字段数, (unsigned long long)表);

        // 代码里正在用的五个偏移，把当时的值一起打出来做对照
        fprintf(fp, "  对照 +0x28(id64)=%lld  +0x34(camp32)=%d  +0xC0(camp32)=%d  +0x1D0=%#llx  +0x1E8=%#llx\n",
                (long long)vm_read<long long>(实体 + 0x28),
                vm_read<int>(实体 + 0x34),
                vm_read<int>(实体 + 0xC0),
                (unsigned long long)vm_read<uint64_t>(实体 + 0x1D0),
                (unsigned long long)vm_read<uint64_t>(实体 + 0x1E8));

        for (int f = 0; f < 512; ++f) {
            unsigned char e[32];
            if (!readMemory(表 + 32ULL * f, e, 32)) break;
            uint64_t 名p, 父p;
            int32_t 偏;
            memcpy(&名p, e, 8);
            memcpy(&父p, e + 16, 8);
            memcpy(&偏, e + 24, 4);
            if (偏 < -0x100 || 偏 > 0x20000) break;
            char 字段[48] = {0};
            if (!读字段名(名p, 字段, 40)) break;
            const char* 标 = "";
            if (偏 == 0x28 || 偏 == 0x34 || 偏 == 0xC0 || 偏 == 0x1D0 || 偏 == 0x1E8) 标 = "   <<< 代码在用的偏移";
            fprintf(fp, "   [%3d] +%#06x  %-34s %s%s\n", f, (unsigned)偏, 字段,
                    (父p == 类 ? "本类" : "他类"), 标);
        }
        打印类++;
    }

    fprintf(fp, "########## 结束 ##########\n");
    fclose(fp);
    return 打印类 > 0;
}

// ==================== 取证 v3（坐标时序 + 活局原始字节对拍） ====================
//
// v2 已经交出了硬结论，v3 只做验证和补盲，不再重复扫类结构：
//   * 每 0.5 秒一行/槽：英雄ID(+0x28)、阵营(+0x34)、坐标(+0x278/+0x27C/+0x280)、
//     0x288/0x290 那对小值、血量 —— 用来看坐标是否随走位变化、槽位和英雄ID 是否对得上
//   * 在第 20/21、80/81、200/201 份快照时把这 10 个实体各 0x380 字节整块导出，
//     两两对拍就能列出「活局里真正在变的字段」，位置/视野/朝向都在里面
static FILE* 取证3文件 = nullptr;
static int   取证3帧计 = 0;
static int   取证3快照 = 0;
static bool  取证3完成 = false;

static void 原始十六进制(FILE* fp, uint64_t 址, int 字节数) {
    if (!IsValidAddr(址) || 字节数 <= 0) {
        fprintf(fp, "  <地址无效 %#llx>\n", (unsigned long long)址);
        return;
    }
    if (字节数 > 0x600) 字节数 = 0x600;
    unsigned char 缓冲[0x600];
    if (!readMemory(址, 缓冲, (size_t)字节数)) {
        fprintf(fp, "  <读失败 %#llx>\n", (unsigned long long)址);
        return;
    }
    for (int i = 0; i < 字节数; i += 16) {
        fprintf(fp, "  %04x:", i);
        for (int j = 0; j < 16 && i + j < 字节数; ++j) fprintf(fp, " %02x", 缓冲[i + j]);
        fprintf(fp, "\n");
    }
}

static void 取证3(uint64_t 世界, uint64_t 容器, uint64_t 数组, int 数量) {
    if (取证3完成) return;
    if (++取证3帧计 % 30) return;

    if (!取证3文件) {
        const char* 家 = getenv("HOME");
        if (!家) return;
        char 路径[512];
        snprintf(路径, sizeof(路径), "%s/Documents/fields_dump3.txt", 家);
        取证3文件 = fopen(路径, "w");
        if (!取证3文件) return;
        setvbuf(取证3文件, nullptr, _IOLBF, 0);
        fprintf(取证3文件, "=== 取证 v3（坐标时序）===\n");
        fprintf(取证3文件, "pid=%d  模块基址=%#llx  世界槽=%#llx\n",
                游戏pid, (unsigned long long)模块基址,
                (unsigned long long)(模块基址 + SDK::根世界));
        fprintf(取证3文件, "世界=%#llx  容器=%#llx  数组=%#llx  数量=%d  跳=%s\n",
                (unsigned long long)世界, (unsigned long long)容器,
                (unsigned long long)数组, 数量,
                (数组 & 7) ? "错位" : "对齐");
        fprintf(取证3文件, "格式: [槽] ent id camp p=(x,y,z)@0x278 q=(a,b)@0x288 hp\n");
    }

    fprintf(取证3文件, "### 快照 %d\n", 取证3快照);
    for (int k = 0; k < 数量 && k < 32; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * (uint64_t)k);
        if (!IsValidAddr(实体)) {
            fprintf(取证3文件, " [%2d] 实体无效\n", k);
            continue;
        }
        int id   = vm_read<int>(实体 + 0x28);
        int camp = vm_read<int>(实体 + 0x34);
        int px   = vm_read<int>(实体 + 0x278);
        int py   = vm_read<int>(实体 + 0x27C);
        int pz   = vm_read<int>(实体 + 0x280);
        int qa   = vm_read<int>(实体 + 0x288);
        int qb   = vm_read<int>(实体 + 0x290);
        int 血   = 读血量当前(实体), 血上 = 读血量上限(实体);
        fprintf(取证3文件,
                " [%2d] %#llx id=%-4d camp=%d p=(%d,%d,%d) q=(%d,%d) hp=%d/%d\n",
                k, (unsigned long long)实体, id, camp, px, py, pz, qa, qb, 血, 血上);
    }

    // 活局对拍：这两份相邻快照的整块内存差异 = 真正在更新的字段
    bool 要整块 = (取证3快照 == 20 || 取证3快照 == 21 ||
                   取证3快照 == 80 || 取证3快照 == 81 ||
                   取证3快照 == 200 || 取证3快照 == 201);
    if (要整块) {
        for (int k = 0; k < 数量 && k < 32; ++k) {
            uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * (uint64_t)k);
            if (!IsValidAddr(实体)) continue;
            fprintf(取证3文件, "  --- 实体 %#llx 整块 0x380（快照 %d）---\n",
                    (unsigned long long)实体, 取证3快照);
            原始十六进制(取证3文件, 实体, 0x380);
        }
    }

    取证3快照++;
    if (取证3快照 >= 900) {
        取证3完成 = true;
        fprintf(取证3文件, "\n=== 取证结束（%d 份快照）===\n", 取证3快照);
        fclose(取证3文件);
        取证3文件 = nullptr;
    }
}

// ==================== 取证 v4（实时坐标动态搜索） ====================
//
// v3 的硬结论（782 份快照 / 6.5 分钟，10 个槽全部稳定）：
//   * 实体指针 10/10 恒定不变
//   * +0x278/+0x280 的 X/Z 在这 6.5 分钟里各自只有 1 个取值 → 那不是实时位置，
//     是静态数据（出生点/配置）；旧链 0xa8→0x10→0x0→0x78→+0x2B8 也已证伪
//   * 实体 0x0..0x380 内随时间变化的只有 +0x8(递增计数)、+0xC、+0x28(ID)、+0x10C(阶段)
//     → 位置不在实体前 0x380 里
// 所以 v4 只做一件事：动态找位置。
//   A. 实体 0x0..0x1200 直扫，找「地图量级」的 int32
//   B. 实体持有一级指针（0x0..0x600 步长 8）解引用后 0x0..0x200 直扫，同条件
// 相隔约 15 秒采三次样，交叉比对，只把「值变过」的候选写进文件。
// 人在走，位置一定在动；不动的一律不是位置。
struct 坐标候选 {
    uint64_t 实体;
    int      槽;
    int32_t  指针偏移;    // -1 = 实体自身
    uint64_t 子对象;
    int32_t  内偏移;
    int32_t  a, b, c;
};

#define 取证4候选上限 6000
static 坐标候选* 取证4当轮 = nullptr;
static int       取证4当轮数 = 0;
static 坐标候选* 取证4上轮 = nullptr;
static int       取证4上轮数 = 0;
static FILE*     取证4文件 = nullptr;
static int       取证4帧计 = 0;
static int       取证4等帧 = 0;
static int       取证4采样序 = 0;
static bool      取证4完成 = false;
static int       取证4变化数 = 0;

static inline bool 地图量级(int32_t v) {
    return (v > 100 && v < 250000) || (v < -100 && v > -250000);
}

static void 记候选(uint64_t 实体, int 槽, int32_t 指针偏移, uint64_t 子对象,
                   int32_t 内偏移, const unsigned char* p) {
    if (!取证4当轮 || 取证4当轮数 >= 取证4候选上限) return;
    int32_t a = *(const int32_t*)(p);
    int32_t b = *(const int32_t*)(p + 4);
    int32_t c = *(const int32_t*)(p + 8);
    if (!地图量级(a)) return;
    // x 与 z 之间常常夹一个 Y，所以比较 a 与 b、a 与 c
    if (!地图量级(b) && !地图量级(c)) return;
    坐标候选& q = 取证4当轮[取证4当轮数++];
    q.实体 = 实体; q.槽 = 槽; q.指针偏移 = 指针偏移; q.子对象 = 子对象;
    q.内偏移 = 内偏移; q.a = a; q.b = b; q.c = c;
}

static void 扫缓冲(uint64_t 实体, int 槽, int32_t 指针偏移, uint64_t 子对象,
                   const unsigned char* buf, int 长度) {
    for (int off = 0; off + 12 <= 长度; off += 4)
        记候选(实体, 槽, 指针偏移, 子对象, off, buf + off);
}

static void 取证4采样(uint64_t 数组, int 数量) {
    取证4当轮数 = 0;
    unsigned char buf[0x200];
    for (int k = 0; k < 数量 && k < 32; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * (uint64_t)k);
        if (!IsValidAddr(实体)) continue;

        // A. 实体自身 0x0..0x1200
        for (int base = 0; base < 0x1200; base += 0x200) {
            if (!readMemory(实体 + (uint64_t)base, buf, 0x200)) continue;
            扫缓冲(实体, k, -1, 0, buf, 0x200);
        }

        // B. 一级指针解引用（每个子对象扫满 0x600，旧链曾把位置指到 +0x2B8）
        for (int po = 0; po < 0x600; po += 8) {
            uint64_t 子 = vm_read<uint64_t>(实体 + (uint64_t)po);
            if (!IsValidAddr(子)) continue;
            for (int base = 0; base < 0x600; base += 0x200) {
                if (!readMemory(子 + (uint64_t)base, buf, 0x200)) break;
                扫缓冲(实体, k, po, 子, buf, 0x200);
            }
        }
    }
}

static void 取证4对比(void) {
    if (!取证4文件 || !取证4当轮 || !取证4上轮) return;
    for (int i = 0; i < 取证4当轮数; ++i) {
        坐标候选& n = 取证4当轮[i];
        // 按 (槽, 指针偏移, 子对象, 内偏移) 找上一轮的同一条
        for (int j = 0; j < 取证4上轮数; ++j) {
            坐标候选& o = 取证4上轮[j];
            if (o.槽 != n.槽 || o.指针偏移 != n.指针偏移 ||
                o.子对象 != n.子对象 || o.内偏移 != n.内偏移) continue;
            if (o.a == n.a && o.b == n.b && o.c == n.c) break;   // 没变
            取证4变化数++;
            if (n.指针偏移 < 0) {
                fprintf(取证4文件, "[D] 槽%d ent=%#llx self +%#05x  (%d,%d,%d) -> (%d,%d,%d)\n",
                        n.槽, (unsigned long long)n.实体, n.内偏移,
                        o.a, o.b, o.c, n.a, n.b, n.c);
            } else {
                fprintf(取证4文件, "[P] 槽%d ent=%#llx @+%#05x->%#llx +%#05x  (%d,%d,%d) -> (%d,%d,%d)\n",
                        n.槽, (unsigned long long)n.实体, n.指针偏移,
                        (unsigned long long)n.子对象, n.内偏移,
                        o.a, o.b, o.c, n.a, n.b, n.c);
            }
            break;
        }
    }
    fflush(取证4文件);
}

static void 取证4(uint64_t 世界, uint64_t 容器, uint64_t 数组, int 数量) {
    if (取证4完成) return;
    if (++取证4帧计 % 30) return;   // 0.5 秒一次
    if (取证4采样序 > 0) {          // 首次立即采样，之后每 30 个节拍（约 15 秒）一次
        if (++取证4等帧 < 30) return;
        取证4等帧 = 0;
    }

    if (!取证4文件) {
        const char* 家 = getenv("HOME");
        if (!家) return;
        if (!取证4当轮) 取证4当轮 = (坐标候选*)malloc(sizeof(坐标候选) * 取证4候选上限);
        if (!取证4上轮) 取证4上轮 = (坐标候选*)malloc(sizeof(坐标候选) * 取证4候选上限);
        if (!取证4当轮 || !取证4上轮) return;
        char 路径[512];
        snprintf(路径, sizeof(路径), "%s/Documents/fields_dump4.txt", 家);
        取证4文件 = fopen(路径, "w");
        if (!取证4文件) return;
        setvbuf(取证4文件, nullptr, _IOLBF, 0);
        fprintf(取证4文件, "=== 取证 v4（实时坐标动态搜索）===\n");
        fprintf(取证4文件, "pid=%d 模块基址=%#llx 世界=%#llx 容器=%#llx 数组=%#llx 数量=%d\n",
                游戏pid, (unsigned long long)模块基址,
                (unsigned long long)世界, (unsigned long long)容器,
                (unsigned long long)数组, 数量);
        fprintf(取证4文件, "只输出「相隔约 15 秒、值发生过变化」的地图量级候选\n");
        fprintf(取证4文件, "[D]=实体自身字段  [P]=一级指针解引用  self +off = 实体+off\n");
        fflush(取证4文件);
    }

    int 序号 = 取证4采样序++;
    取证4采样(数组, 数量);
    if (序号 == 0) {
        memcpy(取证4上轮, 取证4当轮, sizeof(坐标候选) * (size_t)取证4当轮数);
        取证4上轮数 = 取证4当轮数;
        fprintf(取证4文件, "--- 采样0（基准）候选 %d 条 ---\n", 取证4当轮数);
        fflush(取证4文件);
        return;
    }

    取证4对比();
    memcpy(取证4上轮, 取证4当轮, sizeof(坐标候选) * (size_t)取证4当轮数);
    取证4上轮数 = 取证4当轮数;
    fprintf(取证4文件, "--- 采样%d 候选 %d 条，累计变化 %d 条 ---\n",
            序号, 取证4当轮数, 取证4变化数);
    fflush(取证4文件);

    if (序号 >= 7) {   // 8 次采样 × 15 秒 ≈ 105 秒
        取证4完成 = true;
        fprintf(取证4文件, "\n=== 取证结束：%d 次采样，变化候选 %d 条 ===\n", 序号 + 1, 取证4变化数);
        fclose(取证4文件);
        取证4文件 = nullptr;
    }
}

// ==================== 取证 v5：用相机矩阵反证真坐标 ====================
//
// 之前几版的教训：
//   v3 证明实体 +0x278/+0x280 在 782 份快照里纹丝不动 —— 不是坐标。
//   v4 只按「int 落在 100~250000」筛，捞到的全是血量(+0x1d0→+0xc0)、
//      毫秒计时(+0xa8→+0x0d4)、朝向(+0x260→+0x160)，一条真坐标都没有。
//      原因：坐标要么是 /1000 后成大整数（超上限被砍），要么根本是 float。
//
// v5 不猜值域，改用几何反证：
//   真坐标 (x,z) 用「当前这一帧相机矩阵」投影，必须落在屏幕内；
//   同一字段在 10 个实体槽上投影，屏幕位置必须真的散开（不是全挤中心）。
//   血量/计时/朝向过不了这一关。
//
// 同时支持三种数值类型（v4 只支持第一种，这是它漏掉 float 坐标的直接原因）：
//   0 = int 原值即米      1 = int/1000 为米      2 = float 即米
//
// 输出 Documents/fields_dump5.txt：预筛候选 + 每个候选的 (x,z) 时间序列，
// 便于人工确认「跟着走位连续变化」还是「乱跳/死值」。

#define 取证5指针项   193                                   // 0=实体自身，1..192=(0x600/8)
#define 取证5偏移项   384                                   // 0..0x600，每 4 字节
#define 取证5配对项   3                                     // (a,c) (a,b) (b,c)
#define 取证5类型项   3
#define 取证5键数     (取证5指针项 * 取证5偏移项 * 取证5配对项 * 取证5类型项)
#define 取证5样本数   8
#define 取证5候选上限 4000
#define 取证5最短米   1.0f
#define 取证5最长米   20000.0f                              // 20 公里，任何 MOBA 地图都够

// 预筛表：只统计「有多少槽落屏内」以及屏幕坐标范围，用来判断是否散开
struct 屏界 {
    int16_t 槽数;
    int16_t 最小x, 最大x, 最小y, 最大y;
};
static 屏界*  取证5界   = nullptr;
static FILE*  取证5文件 = nullptr;
static int    取证5帧计 = 0, 取证5等帧 = 0, 取证5采样序 = 0;
static int    取证5预筛轮 = 0;
static bool   取证5完成 = false;

struct 候选项 {
    uint16_t p;
    uint16_t off;
    uint8_t  配对;
    uint8_t  类型;
    uint8_t  命中;                                  // 有效样本数（槽命中>=5 才算）
    uint8_t  槽命中[取证5样本数];
    float    序x[取证5样本数], 序z[取证5样本数];    // 取该样本第一个有效槽的值
};
static 候选项* 取证5候选   = nullptr;
static int     取证5候选数 = 0;
static int     取证5分桶头[取证5指针项];
static int     取证5分桶下[取证5候选上限];

static inline int 取证5索引(int p, int off, int 配对, int 类型) {
    if (p < 0 || p >= 取证5指针项) return -1;
    if (off < 0 || off >= 取证5偏移项 * 4) return -1;
    return ((p * 取证5偏移项 + off / 4) * 取证5配对项 + 配对) * 取证5类型项 + 类型;
}

static inline bool 取证5屏内(float sx, float sy, float 宽, float 高) {
    float mx = 宽 * 0.15f, my = 高 * 0.15f;
    return sx >= -mx && sx <= 宽 + mx && sy >= -my && sy <= 高 + my;
}

// 世界坐标 → 屏幕（米制输入，矩阵列主序，Y 视为 0）
static inline bool 投影f(const float* m, float x, float z, float* 屏X, float* 屏Y, float 宽, float 高) {
    float w = m[2] * x + m[10] * z + m[14];
    if (!isfinite(w) || w < 0.01f) return false;
    float inv = 1.0f / w;
    float px = (m[0] * x + m[8] * z + m[12]) * inv;
    float py = (m[1] * x + m[9] * z + m[13]) * inv;
    if (!isfinite(px) || !isfinite(py)) return false;
    *屏X = (px + 1.0f) * 宽 * 0.5f;
    *屏Y = (1.0f - py) * 高 * 0.5f;
    return true;
}

// 按类型取一个「米」值
static inline bool 取米(const unsigned char* b, int off, int 类型, float* 出) {
    float v;
    if (类型 == 2) {
        v = *(const float*)(b + off);
        if (!isfinite(v)) return false;
    } else {
        int32_t i = *(const int32_t*)(b + off);
        if (i <= 0) return false;
        v = (类型 == 1) ? (float)i / 1000.0f : (float)i;
    }
    if (v < 取证5最短米 || v > 取证5最长米) return false;
    *出 = v;
    return true;
}

// 预筛：整块扫描，只记「多少槽落屏内 + 屏幕坐标范围」
static void 取证5扫(int p, const unsigned char* 块, int 长度, const float* m, float 宽, float 高) {
    for (int off = 0; off + 12 <= 长度; off += 4) {
        for (int t = 0; t < 取证5类型项; ++t) {
            float v[3];
            bool ok[3];
            for (int i = 0; i < 3; ++i) ok[i] = 取米(块, off + i * 4, t, &v[i]);
            if (!ok[0] && !ok[1] && !ok[2]) continue;
            for (int k = 0; k < 取证5配对项; ++k) {
                int xi = (k == 0) ? 0 : ((k == 1) ? 0 : 1);
                int zi = (k == 0) ? 2 : ((k == 1) ? 1 : 2);
                if (!ok[xi] || !ok[zi]) continue;
                if (v[xi] == v[zi]) continue;           // x==z：同一份数据被当两轴取
                float sx, sy;
                if (!投影f(m, v[xi], v[zi], &sx, &sy, 宽, 高)) continue;
                if (!取证5屏内(sx, sy, 宽, 高)) continue;
                int idx = 取证5索引(p, off, k, t);
                if (idx < 0) continue;
                屏界& e = 取证5界[idx];
                int16_t ix = (int16_t)fmaxf(-30000.0f, fminf(30000.0f, sx));
                int16_t iy = (int16_t)fmaxf(-30000.0f, fminf(30000.0f, sy));
                if (e.槽数 == 0) {
                    e.最小x = e.最大x = ix;
                    e.最小y = e.最大y = iy;
                } else {
                    if (ix < e.最小x) e.最小x = ix;
                    if (ix > e.最大x) e.最大x = ix;
                    if (iy < e.最小y) e.最小y = iy;
                    if (iy > e.最大y) e.最大y = iy;
                }
                if (e.槽数 < 30000) e.槽数++;
            }
        }
    }
}

// 一轮预筛：读 10 个实体的自身 + 一级子对象
static void 取证5预筛(uint64_t 数组, int 数量, const float* m, float 宽, float 高) {
    unsigned char 块[0x600];
    if (数量 > 16) 数量 = 16;
    for (int k = 0; k < 数量; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * (uint64_t)k);
        if (!IsValidAddr(实体)) continue;
        if (readMemory(实体, 块, 0x600)) 取证5扫(0, 块, 0x600, m, 宽, 高);
        for (int po = 0; po < 0x600; po += 8) {
            uint64_t 子 = vm_read<uint64_t>(实体 + (uint64_t)po);
            if (!IsValidAddr(子)) continue;
            if (!readMemory(子, 块, 0x600)) continue;
            取证5扫(po / 8 + 1, 块, 0x600, m, 宽, 高);
        }
    }
}

// 预筛结果 → 候选表（要求 >=5 槽落屏、且屏幕坐标真的散开）
static int 取证5收集(int 槽数) {
    int 需要 = 槽数 >= 6 ? 5 : (槽数 >= 3 ? 2 : 1);
    取证5候选数 = 0;
    if (!取证5候选) return 0;
    // 按「落屏槽数」从高到低分轮收，槽数=全部实体的优先，避免被地址靠前的杂项占满配额
    for (int 门槛 = 槽数; 门槛 >= 需要 && 取证5候选数 < 取证5候选上限; --门槛)
    for (int i = 0; i < 取证5键数 && 取证5候选数 < 取证5候选上限; ++i) {
        屏界& e = 取证5界[i];
        if (e.槽数 != 门槛) continue;
        if (e.最大x - e.最小x < 60 && e.最大y - e.最小y < 60) continue;   // 挤成一坨 = 假命中
        int t = i % 取证5类型项;
        int r = i / 取证5类型项;
        int k = r % 取证5配对项;
        r /= 取证5配对项;
        int off = (r % 取证5偏移项) * 4;
        int p = r / 取证5偏移项;
        候选项& c = 取证5候选[取证5候选数];
        c.p = (uint16_t)p;
        c.off = (uint16_t)off;
        c.配对 = (uint8_t)k;
        c.类型 = (uint8_t)t;
        c.命中 = 0;
        memset(c.槽命中, 0, sizeof(c.槽命中));
        memset(c.序x, 0, sizeof(c.序x));
        memset(c.序z, 0, sizeof(c.序z));
        取证5候选数++;
    }
    // 分桶：按 p 建链，第 2 阶段每个槽只读需要的那几个指针
    for (int i = 0; i < 取证5指针项; ++i) 取证5分桶头[i] = -1;
    for (int i = 取证5候选数 - 1; i >= 0; --i) {
        int p = 取证5候选[i].p;
        取证5分桶下[i] = 取证5分桶头[p];
        取证5分桶头[p] = i;
    }
    return 取证5候选数;
}

// 读一个候选在某实体槽上的 (x,z)
static inline bool 取证5读值(uint64_t 实体, const 候选项& c, float* x, float* z) {
    uint64_t 基 = 实体;
    if (c.p > 0) {
        uint64_t 子 = vm_read<uint64_t>(实体 + (uint64_t)(c.p - 1) * 8ULL);
        if (!IsValidAddr(子)) return false;
        基 = 子;
    }
    unsigned char t[12];
    if (!readMemory(基 + (uint64_t)c.off, t, 12)) return false;
    float v[3];
    bool ok[3];
    for (int i = 0; i < 3; ++i) ok[i] = 取米(t, i * 4, c.类型, &v[i]);
    int xi = (c.配对 == 2) ? 1 : 0;
    int zi = (c.配对 == 1) ? 1 : 2;
    if (!ok[xi] || !ok[zi]) return false;
    if (v[xi] == v[zi]) return false;
    *x = v[xi];
    *z = v[zi];
    return true;
}

// 第 2 阶段：逐候选逐槽验证，记录值序列
static void 取证5跟踪(uint64_t 数组, int 数量, const float* m, float 宽, float 高, int 序) {
    if (数量 > 16) 数量 = 16;
    static uint8_t 槽计[取证5候选上限];
    memset(槽计, 0, sizeof(uint8_t) * (size_t)取证5候选数);
    for (int k = 0; k < 数量; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * (uint64_t)k);
        if (!IsValidAddr(实体)) continue;
        for (int c = 0; c < 取证5候选数; ++c) {
            float x, z, sx, sy;
            if (!取证5读值(实体, 取证5候选[c], &x, &z)) continue;
            if (!投影f(m, x, z, &sx, &sy, 宽, 高)) continue;
            if (!取证5屏内(sx, sy, 宽, 高)) continue;
            if (槽计[c] < 250) 槽计[c]++;
            if (取证5候选[c].序x[序] == 0.0f) { 取证5候选[c].序x[序] = x; 取证5候选[c].序z[序] = z; }
        }
    }
    int 需要 = 数量 >= 6 ? 5 : (数量 >= 3 ? 2 : 1);
    for (int c = 0; c < 取证5候选数; ++c) {
        取证5候选[c].槽命中[序] = 槽计[c];
        if (槽计[c] >= 需要) 取证5候选[c].命中++;
    }
}

static void 取证5结算(void) {
    fprintf(取证5文件, "\n=== 结果：候选 %d 条，按有效样本数排序 ===\n", 取证5候选数);
    fprintf(取证5文件, "格式: 命中/8样本  位置  配对  类型  槽命中序列  值序列(x,z)\n");
    for (int 轮 = 0; 轮 < 30; ++轮) {
        int 最佳 = -1, 最佳分 = 0;
        for (int i = 0; i < 取证5候选数; ++i) {
            if (取证5候选[i].命中 > 最佳分) { 最佳分 = 取证5候选[i].命中; 最佳 = i; }
        }
        if (最佳 < 0 || 最佳分 < 2) break;
        候选项& c = 取证5候选[最佳];
        const char* 配对名 = (c.配对 == 0) ? "x=a,z=c" : ((c.配对 == 1) ? "x=a,z=b" : "x=b,z=c");
        const char* 类型名 = (c.类型 == 0) ? "int" : ((c.类型 == 1) ? "int/1000" : "float");
        if (c.p == 0)
            fprintf(取证5文件, "命中%d/8  实体 +%#05x  %s %s  ", 最佳分, c.off, 配对名, 类型名);
        else
            fprintf(取证5文件, "命中%d/8  子对象@+%#05x->+%#05x  %s %s  ",
                    最佳分, (c.p - 1) * 8, c.off, 配对名, 类型名);
        fprintf(取证5文件, "槽:");
        for (int s = 0; s < 取证5样本数; ++s) fprintf(取证5文件, "%d,", c.槽命中[s]);
        fprintf(取证5文件, "  值:");
        for (int s = 0; s < 取证5样本数; ++s)
            fprintf(取证5文件, "(%.2f,%.2f)", c.序x[s], c.序z[s]);
        fprintf(取证5文件, "\n");
        c.命中 = -1;
    }
    fflush(取证5文件);
}

static void 取证5(uint64_t 数组, int 数量, const float* m, float 宽, float 高) {
    if (取证5完成) return;
    if (!取证5界) {
        取证5界 = (屏界*)calloc((size_t)取证5键数, sizeof(屏界));
        取证5候选 = (候选项*)calloc(取证5候选上限, sizeof(候选项));
        if (!取证5界 || !取证5候选) return;
    }

    // 预筛阶段：每 120 帧（约 2 秒）跑一轮，跑 2 轮都空就直接报结论，不空转
    if (取证5候选数 == 0 && 取证5采样序 == 0) {
        if (++取证5帧计 < 120) return;
        取证5帧计 = 0;
        if (!取证5文件) {
            const char* 家 = getenv("HOME");
            if (!家) return;
            char 路径[512];
            snprintf(路径, sizeof(路径), "%s/Documents/fields_dump5.txt", 家);
            取证5文件 = fopen(路径, "w");
            if (!取证5文件) return;
            setvbuf(取证5文件, nullptr, _IOLBF, 0);
            fprintf(取证5文件, "=== 取证 v5（相机矩阵投影反证）===\n");
            fprintf(取证5文件, "屏幕=%.0fx%.0f  实体数量=%d\n", 宽, 高, 数量);
            fprintf(取证5文件, "矩阵:");
            for (int i = 0; i < 16; ++i) fprintf(取证5文件, " %.5f", m[i]);
            fprintf(取证5文件, "\n判据: 投影落屏内(含15%%边距) + 至少5槽 + 屏幕坐标散开>60px\n");
            fprintf(取证5文件, "类型: int=原值即米, int/1000, float=米。值域 1~20000 米\n");
            fflush(取证5文件);
        }
        memset(取证5界, 0, sizeof(屏界) * (size_t)取证5键数);
        取证5预筛(数组, 数量, m, 宽, 高);
        int n = 取证5收集(数量);
        取证5预筛轮++;
        fprintf(取证5文件, "[预筛轮%d] 候选 %d 条\n", 取证5预筛轮, n);
        fflush(取证5文件);
        if (n == 0) {
            if (取证5预筛轮 >= 3) {
                取证5完成 = true;
                fprintf(取证5文件, "三轮预筛全空：可疑点不在坐标值域，而在【相机矩阵】本身\n");
                fprintf(取证5文件, "=== 取证结束 ===\n");
                fclose(取证5文件);
                取证5文件 = nullptr;
            } else {
                取证5帧计 = 60;      // 缩短下一轮等待
            }
            return;
        }
    }

    // 跟踪阶段：等 40 帧（约 0.5~1 秒）采一次，共 8 次
    if (++取证5等帧 < 40) return;
    取证5等帧 = 0;
    int 序 = 取证5采样序;
    if (序 >= 取证5样本数) return;
    取证5跟踪(数组, 数量, m, 宽, 高, 序);
    取证5采样序++;
    fprintf(取证5文件, "[样本%d] 槽数=%d 已完成\n", 序, 数量);
    fflush(取证5文件);
    if (取证5采样序 >= 取证5样本数) {
        取证5完成 = true;
        取证5结算();
        fprintf(取证5文件, "=== 取证结束 ===\n");
        fclose(取证5文件);
        取证5文件 = nullptr;
    }
}

// ==================== 主渲染 ====================

static bool 点在小地图(const ImVec4& 地图, float x, float y) {
    float 边距 = 地图.w;
    return x > 地图.x - 边距
        && x < 地图.x + 地图.w + 边距
        && y > 地图.y - 边距
        && y < 地图.y + 地图.w + 边距;
}

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

    // 小地图自适配（没手调过才回写）
    if (!地图已手调) {
        float 基准 = 短边 / 缩放;
        cfg_mapX = 基准 * 0.085333f;
        cfg_mapY = 基准 * 0.0053333f;
        cfg_mapSize = 基准 * 0.328f;
        回写地图配置(cfg_mapX, cfg_mapY, cfg_mapSize);
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

    // 取证 v3：坐标时序 + 活局整块对拍 → Documents/fields_dump3.txt
    // 每 0.5 秒一行/槽（ID/阵营/+0x278 坐标/血量），第 20/80/200 份快照整块导出。
    static bool 已提示取证 = false;
    if (数量 >= 2) {
        取证5(数组, 数量, 矩阵, 屏.x, 屏.y);
        if (!已提示取证 && 取证5文件) {
            已提示取证 = true;
            日志("取证v5 已开跑 → Documents/fields_dump5.txt（矩阵投影反证坐标）");
        }
    }

    // 我方阵营：配置指定 or 按相机朝向猜（矩阵[0]<=0 → 2，否则 1）
    // 相机会随视角转，矩阵[0] 的符号会跟着抖：直接用会让"敌/我"逐帧翻转，
    // 画面上表现为一半目标忽有忽无、位置乱跳。这里锁定阵营，连续 30 帧都不同意才改判。
    unsigned 我方阵营;
    if (cfg_team) {
        我方阵营 = (unsigned)cfg_team;
        阵营锁定 = 我方阵营;
        阵营异见连计 = 0;
    } else {
        unsigned 猜测 = 矩阵[0] <= 0.0f ? 2u : 1u;
        if (阵营锁定 == 0) {
            阵营锁定 = 猜测;
            阵营异见连计 = 0;
        } else if (猜测 != 阵营锁定) {
            if (++阵营异见连计 >= 30) {
                日志("我方阵营改判 %u → %u（连续%d帧）", 阵营锁定, 猜测, 阵营异见连计);
                阵营锁定 = 猜测;
                阵营异见连计 = 0;
            }
        } else {
            阵营异见连计 = 0;
        }
        我方阵营 = 阵营锁定;
    }

    if (!cfg_draw) return;

    // 小地图边框
    if (cfg_map) {
        画框(0xFF00FFFF, cfg_mapX * 缩放, cfg_mapY * 缩放,
             cfg_mapSize * 缩放, cfg_mapSize * 缩放, 2.0f);
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

    SLIconCache* 图标缓存 = SLIconCache.共用;
    // 地图矩形一律用「未乘缩放」的逻辑值：小图坐标算出来是逻辑点，之后统一乘一次 缩放。
    // 曾误传 cfg_mapX*缩放，导致坐标被乘两次，所有图标飞出小地图 3 倍远。
    ImVec4 地图 = ImVec4(cfg_mapX, cfg_mapY, cfg_mapSize, cfg_mapSize);

    // 同一英雄ID 只画一次：联机数组里同一英雄可能有多个实体（影子/预测体/重复槽），
    // 不去重就会出现"一个英雄两个图标、位置还不一样"，看起来就是乱跳。
    long long 已画ID[20] = {0};
    int 已画X[20] = {0}, 已画Z[20] = {0};
    int 已画数 = 0;

    // 诊断采样：每 5 秒把画出来的敌方逐条打进日志（含槽位号），用来判断
    // "坐标不对"到底是槽位选错、链选错，还是服务器只下发视野内的位置。
    int 诊断槽[12] = {0}, 诊断阵[12] = {0}, 诊断数 = 0;
    long long 诊断ID[12] = {0};
    int 诊断X[12] = {0}, 诊断Z[12] = {0};
    int 诊断屏[12] = {0};

    for (int k = 0; k < 数量 && k < cfg_scan_max; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 24ULL * k);
        if (!IsValidAddr(实体)) continue;
        有效实体++;

        int 阵营 = vm_read<int>(实体 + 52);
        if (阵营 < -1 || 阵营 > 7) 阵营 = vm_read<int>(实体 + (int)SDK::阵营);  // 联机部分实体阵营在 +0xC0
        if (阵营 < -1 || 阵营 > 7) continue;   // 阵营读不出来的是垃圾实体，以前会被当成敌人画出来（乱跳的来源之一）
        阵营直方[阵营 + 1]++;

        if (阵营 == (int)我方阵营) continue;

        // 英雄ID 实测在 +0x28，是 32 位（紧跟的 +0x2C 是另一个小整数 25/8/13）。
        // 原来读 8 字节会把 +0x2C 一起吞进来，值必然 > 1000，去重条件永远不成立。
        long long 英雄ID = vm_read<int>(实体 + 0x28);

        int 血当前 = 读血量当前(实体);
        int 血上限 = 读血量上限(实体);
        bool 血有效 = 血上限 > 0 && 血上限 < 2000000
                   && !(血当前 & 0x80000000) && (unsigned)血当前 <= (unsigned)血上限;
        if (血有效 && 血当前 == 0) continue;   // 血量归零 → 已死亡，跳过
        if (!血有效) { 血当前 = 1; 血上限 = 1; }  // 血量读不到 → 按满血画

        unsigned 样X = 0, 样Z = 0;
        int 链 = 读实体坐标(实体, &样X, &样Z);
        if (链 < 0 || 样X == 1000000) continue;

        // 同一英雄只画一次：必须「ID 相同 + 位置几乎重合」才算重复。
        // 依据 fields_dump2.txt：奇数槽（阵营 2）的 +0x28 会在 {110,111,175,506,581}
        // 之间来回变，光按 ID 去重会把真实敌人整批吞掉；带上位置条件才不会误杀。
        if (cfg_id_pick && 英雄ID > 0 && 英雄ID < 1000) {
            bool 重复 = false;
            for (int d = 0; d < 已画数; ++d) {
                if (已画ID[d] != 英雄ID) continue;
                long long dx = (long long)(int)样X - 已画X[d];
                long long dz = (long long)(int)样Z - 已画Z[d];
                if (dx * dx + dz * dz < 8000LL * 8000LL) { 重复 = true; break; }
            }
            if (重复) continue;
            if (已画数 < 20) {
                已画ID[已画数] = 英雄ID;
                已画X[已画数] = (int)样X;
                已画Z[已画数] = (int)样Z;
                已画数++;
            }
        }

        有坐标实体++;
        if (!有首个) {
            有首个 = true;
            首个阵营 = 阵营;
            首个血当前 = 血当前;
            首个血上限 = 血上限;
            首个链 = 链;
            首个英雄ID = 英雄ID;
        }

        float 比例 = (float)血当前 / (float)(血上限 > 0 ? 血上限 : 1);
        比例 = clamp01(比例);

        float sx = 0.0f, sy = 0.0f;
        bool 屏内 = 投影(矩阵, (int)样X, (int)样Z, &sx, &sy, 屏.x, 屏.y);
        if (屏内) 屏内实体++;

        if (诊断数 < 12) {
            诊断槽[诊断数] = k;
            诊断阵[诊断数] = 阵营;
            诊断ID[诊断数] = 英雄ID;
            诊断X[诊断数] = (int)样X;
            诊断Z[诊断数] = (int)样Z;
            诊断屏[诊断数] = 屏内 ? 1 : 0;
            诊断数++;
        }

        uint64_t 技能对象 = vm_read<uint64_t>(实体 + 488);

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
            if (IsValidAddr(技能对象) && 读回城(技能对象))
                画文字(mx, my - 6.0f * 缩放, "回城", 0xFFFFFF00, true);
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

    // ==================== 野怪 ====================
    int 野怪计 = 0;
    if (cfg_monster && cfg_map && 数量 >= 8) {
        野怪信息 野怪[20];
        for (int i = 0; i < 20; ++i) 野怪[i] = {0, 0, 0, 0, 0};
        野怪计 = 读野怪(模块基址, 野怪, 20);
        for (int m = 0; m < 野怪计; ++m) {
            float mx = 0.0f, my = 0.0f;
            野怪小图坐标(野怪[m].x, 野怪[m].z, 野怪[m].camp, 地图, &mx, &my);
            // 先在逻辑坐标上判断/翻折，最后再乘一次缩放（否则与 地图 的量纲不一致）
            if (!点在小地图(地图, mx, my)) {
                // 镜像翻折（对面半图）
                mx = 2.0f * (地图.x + 地图.w * 0.5f) - mx;
                my = 2.0f * (地图.y + 地图.w * 0.5f) - my;
            }
            if (点在小地图(地图, mx, my)) {
                mx *= 缩放;
                my *= 缩放;
                if (野怪[m].cd < 野怪[m].刷新) {
                    char 秒串[16];
                    snprintf(秒串, sizeof(秒串), "%d", 野怪[m].cd > 0 ? 野怪[m].cd : 0);
                    画文字(mx, my - 10.0f * 缩放, 秒串, 0xFFFFFFFF, true);
                } else {
                    画实心圆(0xFF00FF00, mx, my, 2.0f * 缩放);
                }
            }
        }
    }

    // ==================== 对局判定 & 统计 ====================
    // 原来卡 数量<=12（假设容器里只有 10 个英雄）。联机时容器里还有小兵/野怪/召唤物，
    // 数量会超过 12 → 判成"没进对局"，野怪与统计同时关掉。只保留下限。
    bool 判在对局 = 数量 >= 8
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
        日志("n=%d 敌=%d 屏=%d 野=%d 阵[-1:%d 0:%d 1:%d 2:%d 3:%d] 血样%d/%d 源=%s 英雄=%d 我=%d 读=%d 限=%d 任务=%d fps=%.0f",
             数量, 有坐标实体, 屏内实体, 野怪计,
             阵营直方[0], 阵营直方[1], 阵营直方[2], 阵营直方[3], 阵营直方[4],
             首个血当前, 首个血上限, 链名(首个链), (int)首个英雄ID, 我方阵营,
             (int)读总数, 读限流计数, 任务端口 != 0, fps);
        日志("扫描 %d/%d 槽 去重后=%d 屏内=%d", 有效实体, 数量, 已画数, 屏内实体);
        for (int s = 0; s < 诊断数; ++s) {
            日志("  槽%-3d 阵=%d ID=%-4d 世界=(%d,%d) 屏=%d",
                诊断槽[s], 诊断阵[s], (int)诊断ID[s],
                 诊断X[s], 诊断Z[s], 诊断屏[s]);
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
