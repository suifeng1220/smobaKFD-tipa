//
//  DrawView.mm - S45 王者荣耀(smoba) 渲染核心  [S45 重建版]
//
//  由 AB_WZRY_S45重建版.tipa 内 Books 二进制反编译还原
//  （对应 __ZN4Draw10StartBooksEv 0x100082DB0 及周边辅助函数）
//

#include "DrawView.hpp"
#include <mutex>
#include <atomic>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <cmath>
#include <mach/mach.h>
#include <sys/sysctl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
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
// 越狱 jbserver 交棒：内核已被 Dopamine 利用，本进程只要一次 physrw，不再跑 exploit
int jbclient_initialize_primitives(void);
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
static const char* 状态文字 = "启动中";  // _ZL12____
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
static int cfg_scan_max = 128;             // 每帧最多扫的实体槽（下限强制 128，不依赖容器里的数量字段）
static int cfg_id_pick = 1;                // 只画“像英雄”的实体（英雄ID 1..999 且 ID 不重复）
// 从 TrollSpeed 抄来的三个硬阈值（它的 GetPlayers 里就是这三条）：
//   coord_max   坐标绝对值上限 80000 mm = 80 米，超了直接丢（它连 1000000 都当哨兵值）。
//   camp_strict 阵营只认 1 / 2，其它一律当垃圾实体 —— 我们以前允许 -1..7，
//               等于把"阵营读成 0 或 3"的野怪/召唤物/影子体也画成敌人。
//   dedup_mm    同英雄ID + 相距小于这个毫米数才算重复（原来 8000 = 8 米，把两个真英雄也合掉了）。
static int cfg_coord_max  = 80000;
static int cfg_camp_strict = 1;
static int cfg_dedup_mm    = 1500;
static bool 地图已手调 = false;            // 0x100223580（plist 里有 mapX/mapY/mapSize 就不自动回写）
static bool cfg_fov_probe = false;         // 0x100223590
static bool cfg_status = false;            // 左下角状态浮层开关（默认关，不自动弹出）

// 小地图世界换算：坐标为毫米，地图全幅跨度（毫米）。实测我方/敌方泉水在 ±55400 mm，
// 泉水在原生小图上距边约 12%，故全幅 ≈ 150000（= 王者 12000 单位 × 12.5mm）。
// 不写死，改为可运行时调：读 Documents/tune.txt 的 mapSpan=xxx，改完 2 秒内生效，不用重编。
static float cfg_mapSpan = 120000.0f;   // 世界直径(毫米)；峡谷约 120m，泉水 ±55m 落在角落
static bool  调参定地图 = false;   // tune.txt 里给了 mapX/mapY/mapSize → 关掉自适配，别覆盖手工值
static int   cfg_flip = 0;                 // 0=按我方阵营自动；1=强制不翻转；-1=强制翻转
// 翻转只在「第一次拿到我方阵营样本」时标定一次，之后锁死。
// 以前的写法每帧按我方 X 均值重算 —— 队伍推过中线，符号一变，整张小地图瞬间镜像，
// 表现就是"打着打着所有人跳到对面半图"。样本（TrollSpeed）的翻转取自 ViewMatrix 符号，
// 一局之内恒定，本质等价于"按我方阵营定一次"，所以这里改成一次标定 + 锁。
static bool 小图翻转已锁 = false;
static unsigned 小图翻转锁定阵营 = 0;

// ★ 配置落盘路径修正：原来写 /var/mobile/Library/Preferences/com.map.settings.plist，
//   但本程序是注入到游戏进程里的 dylib，受游戏沙盒限制，那个目录根本写不进去
//   （实测该文件从未生成）→ 所有设置关游戏就丢，小地图尺寸也永远改不动。
//   改为游戏容器自己的 Documents，读写都通。
static const char* 设置路径取() {
    static char 缓存[512] = {0};
    if (!缓存[0]) {
        const char* 家 = getenv("HOME");
        if (家) snprintf(缓存, sizeof(缓存), "%s/Documents/settings.plist", 家);
        else   snprintf(缓存, sizeof(缓存), "/var/mobile/Library/Preferences/com.map.settings.plist");
    }
    return 缓存;
}
// 旧路径仅用于一次性迁移读取
static const char* 旧设置路径 = "/var/mobile/Library/Preferences/com.map.settings.plist";

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

// 跨进程读：唯一通道 = task_for_pid 拿到的任务端口 + vm_read_overwrite。
// 设备已由 Dopamine(roothide) 越狱接管内核，本进程一个内核动作都不做，
// 所以这里也绝不退回 exploit_mach_readbuf —— 那条路内部 proc_find/kreadbuf
// 依赖 gPrimitives，没初始化时直接走空函数指针。
static bool 目标读(pid_t pid, uint64_t 地址, void* 输出, size_t 大小) {
    mach_port_t 端口 = 取任务端口(pid);
    if (!端口) return false;
    vm_size_t 读出 = 0;
    return vm_read_overwrite(端口, (vm_address_t)地址, (vm_size_t)大小,
                             (vm_address_t)输出, &读出) == KERN_SUCCESS
           && 读出 == (vm_size_t)大小;
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
    if (游戏pid <= 1) return false;
    mach_port_t 端口 = 取任务端口(游戏pid);
    if (!端口) return false;
    return vm_write(端口, address, (vm_offset_t)data, (vm_size_t)size) == KERN_SUCCESS;
}

// ==================== 内核原语（已停用，仅保留空壳） ====================
// 设备由 Dopamine 越狱接管内核，本进程不再初始化任何原语，所以 内核来源 永远是 0，
// 下面这几个读函数会一路返回 0 —— 它们只被「内核 allproc 遍历」那条已停用的路用到。
// 来源：0=未接 1=越狱内核 2=App 内 kfd exploit（后两种都不会再出现）
static std::atomic<int> 内核来源{0};

static inline bool 内核可读() {
    return 内核来源.load(std::memory_order_acquire) != 0 && gPrimitives.kreadbuf != nullptr;
}

// 内核读统一入口：只在 gPrimitives 真有时才走，空指针一律返回 0（kfd 的 kread 空指针会崩）
static inline uint32_t 核读32(uint64_t 地址) {
    if (!内核可读()) return 0;
    uint32_t v = 0;
    return gPrimitives.kreadbuf(地址, &v, sizeof(v)) == 0 ? v : 0;
}

static inline uint64_t 核读64(uint64_t 地址) {
    if (!内核可读()) return 0;
    uint64_t v = 0;
    return gPrimitives.kreadbuf(地址, &v, sizeof(v)) == 0 ? v : 0;
}

static inline bool 核读缓冲(uint64_t 地址, void* 输出, size_t 大小) {
    if (!内核可读()) return false;
    return gPrimitives.kreadbuf(地址, 输出, 大小) == 0;
}

// 内核指针（PAC 解签）
#define BIT(b) (1ULL << (b))
uint64_t kread_ptr(uint64_t va) {
    uint64_t v = 核读64(va);
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

// ==================== 连接状态（不再有任何内核初始化） ====================
// Dopamine(roothide) 在开机时就完成了内核利用（kfd + physrw 已生效）。
// 本进程只是「另一个进程」：靠 entitlements 里的 task_for_pid-allow 直接
// 拿游戏的任务端口读内存，不跑 exploit、不接管 gPrimitives、不连 jailbreakd。
// 原来那套 接注入原语()/接越狱内核()/jbclient_initialize_primitives() 已整段删除。

extern "C" bool kfd_jailbreak_primitives_ready(void) {
    static std::atomic<bool> 已说明{false};
    if (!已说明.exchange(true))
        日志("内核：由越狱持有，本进程不做任何内核初始化（不跑 exploit/不接管原语表/不连 jailbreakd）");
    return false;   // 恒 false：调用方因此永远不会去跑 [DOJailbreaker run]
}

// UI 用：绘制是否已经连上游戏进程（模块基址 + pid + 任务端口三件齐）
extern "C" bool 游戏已连接(void) {
    return 模块基址 != 0 && 游戏pid > 1 && 任务端口 != 0;
}

// UI 用：手动重连 —— 只清空任务端口与模块缓存，后台找进程线程 3 秒内重扫。
// 不涉及任何内核动作。
extern "C" void 重连游戏进程(void) {
    释放任务端口();
    模块基址 = 0;
    游戏pid = -1;
    状态文字 = "重连中";
    日志("手动重连：已清空任务端口与模块缓存（无内核动作），等待后台线程重扫");
}

// ==================== 绘制原语 ====================

static ImDrawList* 画布() { return BBZGUI::GetBackgroundDrawList(); }

static void 画框(ImU32 color, float x, float y, float w, float h, float thick) {
    ImVec2 a(x, y), b(x + w, y + h);
    画布()->AddRect(a, b, color, 0.0f, 0, thick);
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


// 首次启动没有 settings.plist 时，旧代码直接 return —— cfg_draw/cfg_map 全是 false，
// 结果就是"App 开着但屏幕上什么都不画"，看起来像挂没生效。重装一次必然复现。
// 现在缺文件就先落一份完整默认值再继续读，保证任何一次重装都是可见状态。
static void 写默认配置() {
    NSString* path = @(设置路径取());
    NSDictionary* 默认 = @{
        @"draw": @YES, @"line": @YES, @"box": @YES, @"health": @YES,
        @"map": @YES, @"skill": @YES, @"monster": @YES,
        @"avatar": @NO, @"livemode": @NO, @"status": @NO,
        @"team": @0, @"fov": @1.2, @"scan_max": @96,
    };
    BOOL ok = [默认 writeToFile:path atomically:YES];
    日志("没有 settings.plist → 写入默认配置 (%s)", ok ? "成功" : "失败");
}

static void 读配置() {
    NSString* 主路径 = @(设置路径取());
    if (![[NSFileManager defaultManager] fileExistsAtPath:主路径]) 写默认配置();
    NSDictionary* cfg = [NSDictionary dictionaryWithContentsOfFile:主路径];
    if (!cfg) cfg = [NSDictionary dictionaryWithContentsOfFile:@(旧设置路径)];
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
    cfg_scan_max  = (int)读浮点(cfg, @"scan_max", 128.0f);
    cfg_id_pick   = (int)读浮点(cfg, @"id_pick", 1.0f);
    cfg_coord_max = (int)读浮点(cfg, @"coord_max", 80000.0f);
    cfg_camp_strict = (int)读浮点(cfg, @"camp_strict", 1.0f);
    cfg_dedup_mm  = (int)读浮点(cfg, @"dedup_mm", 1500.0f);
    if (cfg_scan_max < 128) cfg_scan_max = 128;     // 下限抬到 128：不依赖数量字段，跟样本一致
    if (cfg_scan_max > 512) cfg_scan_max = 512;
    if (cfg_coord_max < 20000) cfg_coord_max = 20000;
    if (cfg_coord_max > 300000) cfg_coord_max = 300000;
    if (cfg_dedup_mm < 200) cfg_dedup_mm = 200;
    if (cfg_dedup_mm > 20000) cfg_dedup_mm = 20000;

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

// 运行时调参：Documents/tune.txt，每行 key=value，每 2 秒重读一次。
// 支持 mapSpan（小地图世界全幅，毫米）、flip（0自动/1不翻转/-1翻转）。
// 目的：小地图比例可以在电脑端改文件直接生效，不用重编重装。
static void 读调参() {
    static double 上次 = 0;
    double now = CACurrentMediaTime();
    if (now - 上次 < 2.0) return;
    上次 = now;
    const char* 家 = getenv("HOME");
    if (!家) return;
    char p[512];
    snprintf(p, sizeof(p), "%s/Documents/tune.txt", 家);
    FILE* f = fopen(p, "r");
    if (!f) return;
    char 行[256];
    while (fgets(行, sizeof(行), f)) {
        char* eq = strchr(行, '=');
        if (!eq) continue;
        *eq = 0;
        const char* k = 行;
        while (*k == ' ' || *k == '\t') ++k;
        float v = strtof(eq + 1, nullptr);
        if (!strncmp(k, "mapSpan", 7)) {
            if (v >= 20000.0f && v <= 400000.0f) cfg_mapSpan = v;
        } else if (!strncmp(k, "flip", 4)) {
            cfg_flip = (int)v;
        } else if (!strncmp(k, "mapX", 4)) {
            if (v >= 0.0f && v <= 2000.0f) { cfg_mapX = v; 调参定地图 = true; }
        } else if (!strncmp(k, "mapY", 4)) {
            if (v >= 0.0f && v <= 2000.0f) { cfg_mapY = v; 调参定地图 = true; }
        } else if (!strncmp(k, "mapSize", 7)) {
            if (v >= 20.0f && v <= 999.0f) { cfg_mapSize = v; 调参定地图 = true; }
        } else if (!strncmp(k, "coord_max", 9)) {
            if (v >= 20000.0f && v <= 300000.0f) cfg_coord_max = (int)v;
        } else if (!strncmp(k, "camp_strict", 11)) {
            cfg_camp_strict = (v > 0.5f) ? 1 : 0;
        } else if (!strncmp(k, "dedup", 5)) {
            if (v >= 200.0f && v <= 20000.0f) cfg_dedup_mm = (int)v;
        } else if (!strncmp(k, "reaminimap", 10)) {
            // 手动要求重标定小地图翻转（改了 camp 判断或换了模式后用）
            小图翻转已锁 = false;
        }
    }
    fclose(f);
}

// ==================== 运行时可替换偏移表 ====================
//
// 做法来自 TrollSpeed 成品（BackendAdapter.dylib 里那张明文 JSON）：
// 它整个工具没有一条偏移是编进代码的，全从 {"actorArray":120,...} 里读，
// 那张表还能从后端下发，本地另有 _LocalOffsets 兜底 —— 换赛季只改数据，不重编译。
//
// 我们照这个来：Documents/offsets.json 存在就用它覆盖内置默认值，
// 每 2 秒看一次文件修改时间，电脑端改完存盘即生效，不用重装 App。
// 键名同时接受样本原始 key（actorArray / posPrimary / coordBase …）和中文名，
// 把 TrollSpeed 的表直接倒进来也能吃（冲突项故意不映射，见下）。
// 文件不存在时自动写一份带全部键的样例出去，直接照着改即可。
static SDK::偏移表结构 偏移表 = SDK::默认偏移表();
static char 偏移来源[80] = "内置默认";
static int 偏移覆盖数 = 0;
static int 偏移未知键 = 0;

struct 偏移键项 { const char* 样本名; const char* 中文名; uint64_t* 位; };

// 键表：{TrollSpeed 样本 key, 我们的中文 key, 字段}
// 样本里 team=52 / monsterHp=576 / skill4=336 三项与我们的实测冲突（我们阵营 192、技能CD 576），
// 语义没核准之前不映射，避免把它的表倒进来时改错字段。
#define 偏移键_定义(t)                                                        \
    const 偏移键项 表[] = {                                                    \
        {"gameStruct",    "根野怪备",  &(t)->根野怪备},                         \
        {"matrix",        "根相机",    &(t)->根相机},                           \
        {nullptr,         "根世界",    &(t)->根世界},                           \
        {nullptr,         "根相机备",  &(t)->根相机备},                         \
        {nullptr,         "根野怪",    &(t)->根野怪},                           \
        {nullptr,         "根视距",    &(t)->根视距},                           \
        {nullptr,         "容器中转",  &(t)->容器中转},                         \
        {"actorArray",    "实体数组",  &(t)->实体数组},                         \
        {nullptr,         "数组数量",  &(t)->数组数量},                         \
        {"entityStride",  "槽距",      &(t)->槽距},                             \
        {nullptr,         "坐标节点",  &(t)->节点},                             \
        {nullptr,         "节点X",     &(t)->节点X},                            \
        {nullptr,         "节点Y",     &(t)->节点Y},                            \
        {"coordBase",     "坐标基",    &(t)->坐标基},                           \
        {"coordHop2",     "坐标跳2",   &(t)->坐标跳2},                          \
        {"coordHop3",     "坐标跳3",   &(t)->坐标跳3},                          \
        {"coordHop4",     "坐标跳4",   &(t)->坐标跳4},                          \
        {"posComponent",  "坐标组件",  &(t)->坐标组件},                         \
        {"posPrimary",    "坐标主",    &(t)->坐标主},                           \
        {"posMirror",     "坐标镜像",  &(t)->坐标镜像},                         \
        {"posX",          "坐标内X",   &(t)->坐标内X},                          \
        {"posY",          "坐标内Y",   &(t)->坐标内Y},                          \
        {nullptr,         "直接X",     &(t)->直接X},                            \
        {nullptr,         "直接Y",     &(t)->直接Y},                            \
        {nullptr,         "直接Z",     &(t)->直接Z},                            \
        {"heroId",        "英雄ID",    &(t)->英雄ID},                           \
        {nullptr,         "阵营",      &(t)->阵营},                             \
        {nullptr,         "回城标记",  &(t)->回城标记},                         \
        {"hpBase",        "血量对象",  &(t)->血量对象},                         \
        {"hp",            "血量当前",  &(t)->血量当前},                         \
        {"maxHp",         "血量上限",  &(t)->血量上限},                         \
        {nullptr,         "技能对象",  &(t)->技能对象},                         \
        {nullptr,         "技能中转",  &(t)->技能中转},                         \
        {nullptr,         "技能ID",    &(t)->技能ID},                           \
        {nullptr,         "技能CD",    &(t)->技能CD},                           \
        {"recallRoot",    "回城对象",  &(t)->回城对象},                         \
        {nullptr,         "回城状态",  &(t)->回城状态},                         \
        {"matrixHop1",    "矩阵跳1",   &(t)->矩阵跳1},                          \
        {"matrixHop2",    "矩阵跳2",   &(t)->矩阵跳2},                          \
        {"matrixHop3",    "矩阵跳3",   &(t)->矩阵跳3},                          \
        {nullptr,         "矩阵字段",  &(t)->矩阵字段},                         \
        {"monsterArray",  "野怪数组",  &(t)->野怪数组},                         \
        {"monsterList1",  "野怪列表1", &(t)->野怪列表1},                        \
        {"monsterPosX",   "野怪坐标X", &(t)->野怪坐标X},                        \
        {"monsterPosY",   "野怪坐标Y", &(t)->野怪坐标Y},                        \
        {"monsterRoot",   "野怪根",    &(t)->野怪根},                           \
        {"monsterMaxHp",  "野怪刷新",  &(t)->野怪刷新},                         \
    };                                                                        \
    const int 表数 = (int)(sizeof(表) / sizeof(表[0]));

static bool 取偏移值(NSDictionary* d, NSString* k, uint64_t* 出) {
    id v = [d objectForKey:k];
    if (!v) return false;
    if ([v isKindOfClass:[NSString class]]) {
        const char* s = [v UTF8String];
        if (!s || !*s) return false;
        int 进制 = (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) ? 16 : 10;
        char* 尾 = nullptr;
        unsigned long long x = strtoull(s, &尾, 进制);
        if (尾 == s) return false;
        *出 = (uint64_t)x;
        return true;
    }
    if ([v isKindOfClass:[NSNumber class]]) { *出 = (uint64_t)[v unsignedLongLongValue]; return true; }
    return false;
}

// 首次没有文件时落一份样例，键全列出来，用户照着改就行
static void 写偏移样例(const char* 路径) {
    SDK::偏移表结构 t = SDK::默认偏移表();
    偏移键_定义(&t)
    NSMutableDictionary* d = [NSMutableDictionary dictionary];
    for (int i = 0; i < 表数; ++i) d[@(表[i].中文名)] = @(*(表[i].位));
    d[@"_说明"] = @"本文件覆盖内置偏移；每2秒自动重读，改完存盘即生效。值可写十进制或 0x 十六进制。删掉本文件即回到内置默认。";
    NSData* data = [NSJSONSerialization dataWithJSONObject:d
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    if (data && [data writeToFile:@(路径) atomically:YES])
        日志("偏移表：没有 offsets.json → 已写出样例（%d 个键），改它即可覆盖内置默认", 表数);
    else
        日志("偏移表：样例写出失败 %s", 路径);
}

static void 读偏移表() {
    static double 上次 = 0;
    static time_t 上次改 = 0;
    static bool 试过写样例 = false;
    double now = CACurrentMediaTime();
    if (now - 上次 < 2.0) return;
    上次 = now;
    const char* 家 = getenv("HOME");
    if (!家) return;
    char p[512];
    snprintf(p, sizeof(p), "%s/Documents/offsets.json", 家);
    struct stat st;
    memset(&st, 0, sizeof(st));
    if (stat(p, &st) != 0) {
        if (!试过写样例) { 试过写样例 = true; 写偏移样例(p); }
        return;
    }
    if (st.st_mtime == 上次改) return;
    上次改 = st.st_mtime;

    NSData* data = [NSData dataWithContentsOfFile:@(p)];
    if (!data) return;
    NSError* err = nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (![obj isKindOfClass:[NSDictionary class]]) {
        日志("偏移表：offsets.json 解析失败（%s），继续用上一份",
             err ? [[err localizedDescription] UTF8String] : "顶层不是字典");
        return;
    }
    NSDictionary* d = (NSDictionary*)obj;
    SDK::偏移表结构 t = SDK::默认偏移表();
    偏移键_定义(&t)
    int 命中 = 0;
    for (int i = 0; i < 表数; ++i) {
        uint64_t v = 0;
        bool 取到 = false;
        if (表[i].样本名 && 取偏移值(d, @(表[i].样本名), &v)) 取到 = true;
        else if (取偏移值(d, @(表[i].中文名), &v)) 取到 = true;
        if (!取到) continue;
        *(表[i].位) = v;
        命中++;
    }
    // 统计文件里我们不认识的键（多半是样本 ts* 那批 VM 补丁参数，留着不影响）
    int 未知 = 0;
    for (NSString* k in d) {
        if ([k hasPrefix:@"_"]) continue;
        bool 认识 = false;
        for (int i = 0; i < 表数 && !认识; ++i)
            if ((表[i].样本名 && [k isEqualToString:@(表[i].样本名)]) ||
                [k isEqualToString:@(表[i].中文名)]) 认识 = true;
        if (!认识) 未知++;
    }
    偏移表 = t;
    偏移覆盖数 = 命中;
    偏移未知键 = 未知;
    snprintf(偏移来源, sizeof(偏移来源), "offsets.json(%d键)", 命中);
    日志("偏移表：offsets.json 生效 覆盖=%d 未知=%d 世界=0x%llX 相机=0x%llX 节点=%llu 组件=%llu",
         命中, 未知, (unsigned long long)t.根世界, (unsigned long long)t.根相机,
         (unsigned long long)t.节点, (unsigned long long)t.坐标组件);
}

// 小地图自适配回写：参数变化 ≥1.0 才写 plist
static void 回写地图配置(float mapX, float mapY, float mapSize) {
    static double 上次 = 0;
    double now = CACurrentMediaTime();
    if (now - 上次 < 3.0) return;
    上次 = now;
    NSString* path = @(设置路径取());
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
    if (!内核可读()) { 日志("内核遍历: 内核原语未接入，跳过"); return -1; }
    const uint32_t 下个 = gSystemInfo.kernelStruct.proc.list_next;
    const uint32_t 上个 = gSystemInfo.kernelStruct.proc.list_prev;
    const uint32_t pid偏移 = gSystemInfo.kernelStruct.proc.pid;
    const uint32_t textvp偏移 = gSystemInfo.kernelStruct.proc.textvp;
    char 名字[64];

    auto 试一个 = [&](uint64_t p) -> pid_t {
        int pid = 核读32(p + pid偏移);
        if (pid <= 1) return -1;
        uint64_t textvp = kread_ptr(p + textvp偏移);
        if (!IsKernelAddr(textvp)) return -1;
        uint64_t 名字指针 = kread_ptr(textvp + 184);
        if (!IsKernelAddr(名字指针)) return -1;
        memset(名字, 0, sizeof(名字));
        if (!核读缓冲(名字指针, 名字, 63)) return -1;
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
        if (!任务或内核读(pid, 任务, 数组址 + 偏移表.槽距 * i, &项, 24)) continue;
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
    if ((int)核读32(起点 + pid偏移) == pid) {
        日志("链表(%s): 起点即目标 pid=%d", 来源, pid);
        return 起点;
    }
    uint64_t p = kread_ptr(起点 + 下个);
    int 后 = 0;
    for (int i = 0; i < 2048 && IsKernelAddr(p); ++i) {
        后++;
        if ((int)核读32(p + pid偏移) == pid) {
            日志("链表(%s): 向后命中 pid=%d（走了 %d 个）", 来源, pid, 后);
            return p;
        }
        p = kread_ptr(p + 下个);
    }
    p = kread_ptr(起点 + 上个);
    int 前 = 0;
    for (int i = 0; i < 2048 && IsKernelAddr(p); ++i) {
        前++;
        if ((int)核读32(p + pid偏移) == pid) {
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
                 allproc, 核读64(allproc), 核读64(allproc + 8));
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
        uint64_t 候选 = 核读64(task + i);
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
    if (!目标读(pid, 基址 + 偏移表.根世界, &世界, 8) || !IsValidAddr(世界)) return false;
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

// 世界坐标合理区间：照样本取 ±80000 mm（80 米）。
// TrollSpeed 的 GetPlayers 就是 `abs(x) > 80000 丢弃` —— 它那条链同样读 int32 毫米。
// 我们原来放到 ±150000，联机时错位解引用出来的垃圾值也能通过 → 坐标在真/假之间闪，
// 表现就是"目标位置乱跳"。要放宽就改 Documents/tune.txt 的 coord_max=（毫米）。
static inline bool 坐标合理(int v) {
    return v != 1000000 && v > -cfg_coord_max && v < cfg_coord_max;
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

// ==================== 坐标解密器（照 TrollSpeed 样本第八章的形态实现）====================
//
// 样本里的东西拆开是这样（报告 8.1~8.5）：
//   __ZGVZN14TersafeDecrypt5StateEvE1s = TersafeDecrypt::State() 内局部 static 变量 s 的
//   守卫字节（__ZGV 前缀 + 函数内局部实体 Z + 名字 E + 变量名 1s），配合 __cxa_guard_acquire/
//   release，就是标准的 C++ 函数内局部静态对象 —— Meyers 单例。
//   作者为什么做成单例（8.4）：task_for_pid 端口很贵，必须常驻复用不能每帧重 attach；
//   频繁 attach 容易被系统拒绝、也容易被反作弊看出调用模式；解密表/缓存/状态机要跨调用共享。
//   硬证据（8.5）：pid 和 task port 是 std::atomic<int>（_TersafeMachPID 用 ldar 读
//   @0x10041d9c0，_TersafeMachTask 用 ldar 读 @0x100418aa0；写入端 ldaxr/stlxr CAS，只在未绑定时写）。
//   还有 TersafeRO()（8.7）：只读扫描和可写修改拆成两套缓存，先只读定位再决定改哪里。
//
// 本类就按这个骨架来：单例 + 原子 pid/端口 + 三态状态机 + 只读扫描/解密读取两段式。
// 坐标链直接用报告附录 B 的表： 实体+0x90(坐标组件) → 组件+0x60(主) / 组件+0x78(镜像)，
// 元素是 {x@0, y@4, z@8} 的 int32 三元组 —— 和我们实测的 +0x128/+0x130 是同一种布局。
class 坐标解密器 {
public:
    // 对应样本 UI 上的 "初始化解密 / 正在解密中 / 已解密"（外加失败态）
    enum 阶段值 : int { 未初始化 = 0, 初始化解密中 = 1, 已解密 = 2, 解密失败 = 3 };

    // Meyers 单例：函数内局部静态对象，第一次调用 State() 才构造（编译器插守卫字节）
    static 坐标解密器& State() {
        static 坐标解密器 实例;
        return 实例;
    }

    int 取阶段() const { return 状态.load(std::memory_order_acquire); }

    const char* 阶段名() const {
        switch (状态.load(std::memory_order_acquire)) {
            case 初始化解密中: return "正在解密中";
            case 已解密:       return "已解密";
            case 解密失败:     return "解密失败";
            default:           return "未初始化";
        }
    }

    // 绑定目标进程：对应样本 0x100035e5c 那段 CAS —— 只在未绑定时写入，绑上就常驻
    bool 绑定进程(pid_t pid) {
        if (pid <= 1) return false;
        int 已绑 = 目标pid.load(std::memory_order_acquire);
        if (已绑 == pid && 目标端口.load(std::memory_order_acquire) > 0) return true;
        if (已绑 != 0 && 已绑 != pid) {   // 换了进程，先解绑
            目标端口.store(0, std::memory_order_release);
            目标pid.store(0, std::memory_order_release);
            状态.store(未初始化, std::memory_order_release);
        }
        int 期望 = 0;
        if (!目标pid.compare_exchange_strong(期望, pid, std::memory_order_acq_rel)) {
            // 别的线程先绑上了，用它绑的那个
            return 目标pid.load(std::memory_order_acquire) == pid;
        }
        mach_port_t 端 = 取任务端口(pid);   // 同一份端口复用，不重复 task_for_pid
        if (!端) { 目标pid.store(0, std::memory_order_release); return false; }
        目标端口.store((int)端, std::memory_order_release);
        return true;
    }

    // 只读扫描（样本的 TersafeRO）：确认坐标组件这一层在本版本还能用
    // 有了结果就把偏移表缓存下来，后面每帧只做读取，不再重新找
    void 只读扫描(uint64_t 数组, int 数量) {
        if (状态.load(std::memory_order_acquire) == 已解密) return;
        状态.store(初始化解密中, std::memory_order_release);
        int 通过 = 0, 试过 = 0;
        for (int i = 0; i < 数量 && i < 12; ++i) {
            uint64_t e = vm_read<uint64_t>(数组 + 偏移表.槽距 * (uint64_t)i);
            if (!IsValidAddr(e)) continue;
            试过++;
            uint64_t 组件 = vm_read<uint64_t>(e + 偏移表.坐标组件);
            if (!IsValidAddr(组件)) continue;
            int x = vm_read<int>(组件 + 偏移表.坐标主 + 偏移表.坐标内X);
            int z = vm_read<int>(组件 + 偏移表.坐标主 + 偏移表.坐标内Y);
            if (坐标合理(x) && 坐标合理(z) && !(x == 0 && z == 0)) 通过++;
        }
        状态.store(通过 > 0 ? 已解密 : 解密失败, std::memory_order_release);
        日志("坐标解密器：只读扫描 试过=%d 通过=%d → %s（组件=%llu 主=%llu 镜像=%llu）",
             试过, 通过, 阶段名(),
             (unsigned long long)偏移表.坐标组件,
             (unsigned long long)偏移表.坐标主,
             (unsigned long long)偏移表.坐标镜像);
    }

    // 解密读取（样本的每帧那段）：主/镜像两份都读，交叉校验，这是它"两套缓存"的用法
    bool 读(uint64_t 实体, unsigned* 出X, unsigned* 出Z, uint64_t* 来源) {
        if (状态.load(std::memory_order_acquire) != 已解密) return false;
        uint64_t 组件 = vm_read<uint64_t>(实体 + 偏移表.坐标组件);
        if (!IsValidAddr(组件)) { 未命中++; return false; }
        const uint64_t 主 = 偏移表.坐标主;
        const uint64_t 镜 = 偏移表.坐标镜像;
        int px = vm_read<int>(组件 + 主 + 偏移表.坐标内X);
        int pz = vm_read<int>(组件 + 主 + 偏移表.坐标内Y);
        int mx = vm_read<int>(组件 + 镜 + 偏移表.坐标内X);
        int mz = vm_read<int>(组件 + 镜 + 偏移表.坐标内Y);
        bool 主可 = 坐标合理(px) && 坐标合理(pz) && !(px == 0 && pz == 0);
        bool 镜可 = 坐标合理(mx) && 坐标合理(mz) && !(mx == 0 && mz == 0);
        // 两份都有值时必须一致（5 米内），不一致说明这层解出来的不是坐标 —— 直接判失败，不硬画
        if (主可 && 镜可) {
            if (llabs((long long)px - mx) > 5000 || llabs((long long)pz - mz) > 5000) {
                交叉失败++;
                return false;
            }
            *出X = (unsigned)px; *出Z = (unsigned)pz;
            *来源 = 偏移表.坐标组件 ; 主命中++;
            return true;
        }
        if (主可) { *出X = (unsigned)px; *出Z = (unsigned)pz; *来源 = 偏移表.坐标组件; 主命中++; return true; }
        if (镜可) { *出X = (unsigned)mx; *出Z = (unsigned)mz; *来源 = 偏移表.坐标组件 + 镜; 镜像命中++; return true; }
        未命中++;
        return false;
    }

    // 统计（跨调用共享的状态，写进 pos.log 表头用）
    long 统计主() const { return 主命中.load(std::memory_order_relaxed); }
    long 统计镜() const { return 镜像命中.load(std::memory_order_relaxed); }
    long 统计交叉失败() const { return 交叉失败.load(std::memory_order_relaxed); }
    long 统计未命中() const { return 未命中.load(std::memory_order_relaxed); }

private:
    坐标解密器() = default;
    // 样本 8.5 的 _TersafeMachPID / _TersafeMachTask 对应物
    std::atomic<int> 目标pid{0};
    std::atomic<int> 目标端口{0};
    std::atomic<int> 状态{未初始化};
    // 解密表不再缓存：偏移表现在是运行时可改的数据（offsets.json），
    // 缓存一份就等于把外置配置又变回硬编码，改了 JSON 也不生效。
    // 缓存/统计
    std::atomic<long> 主命中{0}, 镜像命中{0}, 交叉失败{0}, 未命中{0};
};

// 读实体坐标：实时位置在 实体+0x230 → 子对象 +0x128(x) / +0x130(z)，int32 毫米，可为负。
// 两局对照定的：#177 本链路走位 15 秒坐标连续变化、测速 3.3~3.9 m/s；#180 直读 +0x278 对局 238 秒零变化。
// +0x278 是静态锚点副本，静止时恰好等于当前位置，所以之前 10/10 对拍是被静止状态骗了。
// 命中偏移写 pos.log 表头，一眼看出本局走的是哪条链。
static uint64_t 坐标命中偏移 = 0;   // 0=未命中；否则记录实际生效的首个字段偏移

// ==================== 交叉校验（第 3 件事）====================
//
// 主链（0x230 / 解密器 0x90）是我们自己走位实测过的；样本 TrollSpeed 另给了一条
// coordBase 三跳链（168 → 16 → 0 → 96），入口不同但落在同一个 {x@0, y@8} 结构上。
// 两条链互相独立，正好拿来对拍：
//   · 都对且差 ≤5 米 → 说明两条链都健康，记一次"一致"
//   · 都对但差 >5 米 → 有一条在解错引用，记"不一致"并留最大偏差，但**仍采用主链**
//     （主链有 #177 走位数据背书，不因为一条没验证过的链去改画面）
//   · 主链全废、只有它有效 → 用它兜底，至少不至于一个人都不画
static long 互校一致 = 0, 互校不一致 = 0, 链B命中 = 0;
static int  互校最差米 = 0;

// 按跳表逐级解引用：e --跳[0]--> p1 --跳[1]--> p2 …
static uint64_t 解跳(uint64_t 实体, const uint64_t* 跳, int 数) {
    uint64_t p = 实体;
    for (int i = 0; i < 数; ++i) {
        p = vm_read<uint64_t>(p + 跳[i]);
        if (!IsValidAddr(p)) return 0;
    }
    return p;
}

// 链 B：实体+coordBase → +coordHop2 → +coordHop3 → +coordHop4 → {x@0, z@+8}
static bool 读坐标链B(uint64_t 实体, int* 出X, int* 出Z) {
    uint64_t 跳[3] = { 偏移表.坐标基, 偏移表.坐标跳2, 偏移表.坐标跳3 };
    uint64_t b = 解跳(实体, 跳, 3);
    if (!b) return false;
    uint64_t 址 = b + 偏移表.坐标跳4;
    int x = vm_read<int>(址 + 偏移表.坐标内X);
    int z = vm_read<int>(址 + 偏移表.坐标内Y);
    if (!坐标合理(x) || !坐标合理(z) || (x == 0 && z == 0)) return false;
    *出X = x;
    *出Z = z;
    return true;
}

// 读实体坐标：实时位置在 实体+0x230 → 子对象 +0x128(x) / +0x130(z)，int32 毫米，可为负。
// 两局对照定的：#177 本链路走位 15 秒坐标连续变化、测速 3.3~3.9 m/s；#180 直读 +0x278 对局 238 秒零变化。
// +0x278 是静态锚点副本，静止时恰好等于当前位置，所以之前 10/10 对拍是被静止状态骗了。
// 命中偏移写 pos.log 表头，一眼看出本局走的是哪条链。
static int 读实体坐标(uint64_t 实体, unsigned* X, unsigned* Z) {
    if (!IsValidAddr(实体)) return -1;

    unsigned ux = 0, uz = 0;
    bool 有主 = false;
    uint64_t 主源 = 0;

    // 一级（主路）：坐标解密器 —— 样本第八章那套"常驻单例 + 解密表 + 主/镜像交叉校验"。
    //   实体+0x90 → 组件+0x60(主) / +0x78(镜像)。两份都读，不一致就判失败，不硬画。
    {
        uint64_t 来源 = 0;
        if (坐标解密器::State().读(实体, &ux, &uz, &来源)) { 有主 = true; 主源 = 来源; }
    }
    // 二级：实测链。0x230 是主偏移，另带 +0x30 / +0x20 两个候选 ——
    //   #177 版实测有效的正是这套"取第一个能读出合法坐标的候选"，当时 pos.log 坐标连续变化、测速 3.5m/s。
    if (!有主) {
        const uint64_t 候选[3] = { 偏移表.节点, 偏移表.节点 + 0x30, 偏移表.节点 + 0x20 };
        for (int i = 0; i < 3; ++i) {
            uint64_t 位 = vm_read<uint64_t>(实体 + 候选[i]);
            if (!IsValidAddr(位)) continue;
            int x = vm_read<int>(位 + 偏移表.节点X);
            int z = vm_read<int>(位 + 偏移表.节点Y);
            if (坐标合理(x) && 坐标合理(z) && !(x == 0 && z == 0)) {
                ux = (unsigned)x; uz = (unsigned)z; 主源 = 候选[i]; 有主 = true;
                break;
            }
        }
    }

    // 交叉校验：独立再走一遍样本链 B，和主结果对拍
    int bx = 0, bz = 0;
    bool 有B = 读坐标链B(实体, &bx, &bz);
    if (有B) 链B命中++;
    if (有主 && 有B) {
        int dx = abs((int)ux - bx);
        int dz = abs((int)uz - bz);
        if (dx <= 5000 && dz <= 5000) {
            互校一致++;
        } else {
            互校不一致++;
            int 米 = (dx > dz ? dx : dz) / 1000;
            if (米 > 互校最差米) 互校最差米 = 米;
        }
    }

    if (有主) { 坐标命中偏移 = 主源; *X = ux; *Z = uz; return 4; }

    // 主链全废、链 B 有值 → 用它兜底
    if (有B) {
        坐标命中偏移 = 偏移表.坐标基;
        *X = (unsigned)bx;
        *Z = (unsigned)bz;
        return 4;
    }

    // 三级兜底：实体自身 +0x278 / +0x280（静态锚点）。只在前两级全废时用，避免"一部分人钉泉水"。
    {
        int x = vm_read<int>(实体 + 偏移表.直接X);
        int z = vm_read<int>(实体 + 偏移表.直接Z);
        if (坐标合理(x) && 坐标合理(z) && !(x == 0 && z == 0)) {
            坐标命中偏移 = 偏移表.直接X;
            *X = (unsigned)x;
            *Z = (unsigned)z;
            return 4;
        }
    }
    return -1;
}

// ==================== 实体字段 ====================

static int 读血量当前(uint64_t 实体) {
    uint64_t 对象 = vm_read<uint64_t>(实体 + 偏移表.血量对象);
    if (!IsValidAddr(对象)) return -1;
    return vm_read<int>(对象 + 偏移表.血量当前);
}
static int 读血量上限(uint64_t 实体) {
    uint64_t 对象 = vm_read<uint64_t>(实体 + 偏移表.血量对象);
    if (!IsValidAddr(对象)) return 0;
    return vm_read<int>(对象 + 偏移表.血量上限);
}
static int 读阵营(uint64_t 实体) { return vm_read<int>(实体 + 偏移表.阵营); }

static unsigned 读召唤技能ID(uint64_t 技能对象) {
    uint64_t a = vm_read<uint64_t>(技能对象 + 偏移表.技能对象);
    if (!IsValidAddr(a)) return 0;
    uint64_t b = vm_read<uint64_t>(a + 偏移表.技能中转);
    if (!IsValidAddr(b)) return 0;
    int id = vm_read<int>(b + 偏移表.技能ID);
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
    uint64_t a = vm_read<uint64_t>(技能对象 + 偏移表.回城对象);
    if (!IsValidAddr(a)) return false;
    uint64_t b = vm_read<uint64_t>(a + 偏移表.回城状态);
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
        if (读相机矩阵(模块, 偏移表.根相机, 矩阵)) return true;
        if (读相机矩阵(模块, 偏移表.根相机备, 矩阵)) { 用备相机 = false; return true; }
        return false;
    } else {
        if (读相机矩阵(模块, 偏移表.根相机备, 矩阵)) return true;
        if (读相机矩阵(模块, 偏移表.根相机, 矩阵)) { 用备相机 = true; return true; }
        return false;
    }
}

// 投影：世界坐标(int/1000) → 屏幕像素
static bool 投影(const float* m, int 世界X, int 世界Z, float* 屏X, float* 屏Y, float 宽, float 高) {
    float x = 世界X / 1000.0f;
    float z = 世界Z / 1000.0f;
    float w = m[3] * x + m[11] * z + m[15];
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
    NSString* path = @(设置路径取());
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
    // 没有内核环节：越狱已持有内核，这里只确保自己那条任务端口通道。
    {
        static std::atomic<bool> 已说明{false};
        if (!已说明.exchange(true))
            日志("内存通道：task_for_pid + vm_read_overwrite（越狱已持有内核，本进程零内核动作）");
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
    // 找 pid：sysctl 精确 → sysctl 模糊 → 全盘扫（内核 allproc 那条路已停用）
    pid_t pid = sysctl精确找pid("smoba");
    const char* 命中方式 = "sysctl精确";
    if (pid <= 1) { pid = sysctl模糊找pid(); 命中方式 = "sysctl模糊"; }
    if (pid <= 1) {
        NSDictionary* cfg = [NSDictionary dictionaryWithContentsOfFile:@(设置路径取())];
        bool fullscan = cfg && [[cfg objectForKey:@"fullscan"] boolValue];
        if (fullscan && 内核可读()) {   // 内核可读恒为 false（本进程不做内核初始化），此路自然不触发
            日志("找进程③: 名字没命中 → 走内核 allproc 遍历（fullscan=1）");
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
    NSDictionary* cfg = [NSDictionary dictionaryWithContentsOfFile:@(设置路径取())];
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
    uint64_t a = vm_read<uint64_t>(模块 + 偏移表.根野怪);
    if (IsValidAddr(a)) {
        uint64_t b = vm_read<uint64_t>(a + 偏移表.野怪根);
        if (IsValidAddr(b)) {
            uint64_t c = vm_read<uint64_t>(b + 偏移表.野怪列表1);
            if (IsValidAddr(c)) 根 = vm_read<uint64_t>(c + 偏移表.野怪数组);
        }
    }
    if (!IsValidAddr(根)) {
        uint64_t a2 = vm_read<uint64_t>(模块 + 偏移表.根野怪备);
        if (IsValidAddr(a2)) {
            uint64_t b2 = vm_read<uint64_t>(a2 + 偏移表.野怪根);
            if (IsValidAddr(b2)) {
                uint64_t c2 = vm_read<uint64_t>(b2 + 偏移表.野怪列表1);
                if (IsValidAddr(c2)) 根 = vm_read<uint64_t>(c2 + 偏移表.野怪数组);
            }
        }
    }
    if (!IsValidAddr(根)) return 0;
    int 数 = 0;
    for (int i = 0; i < 20 && 数 < 上限; ++i) {
        uint64_t 怪 = vm_read<uint64_t>(根 + 偏移表.槽距 * (uint64_t)i);
        if (!IsValidAddr(怪)) continue;
        int x = vm_read<int>(怪 + 偏移表.野怪坐标X);
        int z = vm_read<int>(怪 + 偏移表.野怪坐标Y);
        if (x < -200000 || x > 200000 || z < -200000 || z > 200000 || (!x && !z)) continue;
        int cd = vm_read<int>(怪 + 偏移表.技能CD);
        int hp = vm_read<int>(怪 + 偏移表.野怪刷新);   // 野怪刷新原始值（0x1E4）
        if (hp <= 0 || hp > 600000) continue;
        野怪信息& m = 输出[数++];
        m.x = x;
        m.z = z;
        m.camp = vm_read<int>(怪 + 偏移表.阵营);
        m.cd = cd / 1000 + 3;
        m.刷新 = hp / 1000 + 3;
    }
    return 数;
}

// 小地图翻转：全局唯一值。
// ★ 第一次拿到我方阵营样本时标定一次，然后锁死整局。
//   旧写法每帧按我方 X 均值重算：队伍推过中线 → 均值符号翻 → 整张小地图瞬间镜像，
//   表现就是"打着打着所有人跳到对面半图、小地图和目标对不上"。
//   样本（TrollSpeed 的 ToMiniMap）翻转取自 ViewMatrix 符号，一局内恒定，
//   本质就是"按我方阵营定一次 A 或 -A"，这里用第一次采样标定，效果一致且不抖。
static float 小图翻转值 = 1.0f;
static unsigned 调试我方阵营 = 0;      // 只用于 pos.log 表头，方便标定

static float 小图翻转() {
    if (cfg_flip > 0) return 1.0f;
    if (cfg_flip < 0) return -1.0f;
    return 小图翻转值;
}

// 每帧调用一次，但只在未锁定（或换边/手动重标定）时真正计算。
// 判据仍然是我方阵营英雄的平均 X：我方泉水在 X 正侧就整体翻 -1，让自家基地落到左下。
static void 推小图翻转(uint64_t 数组, int 扫描上限, unsigned 我方阵营) {
    if (cfg_flip != 0) return;
    if (小图翻转已锁) {
        if (小图翻转锁定阵营 == 我方阵营) return;   // 锁定的阵营没变 → 一直用这个值
        日志("小地图翻转重标定：我方阵营 %u → %u", 小图翻转锁定阵营, 我方阵营);
        小图翻转已锁 = false;
    }
    if (!IsValidAddr(数组)) return;
    long long 和 = 0;
    int 数 = 0;
    for (int k = 0; k < 扫描上限; ++k) {
        uint64_t e = vm_read<uint64_t>(数组 + 偏移表.槽距 * k);
        if (!IsValidAddr(e)) continue;
        int c = vm_read<int>(e + 52);
        if (c != 1 && c != 2) c = 读阵营(e);        // 与主循环同序：+0x34 先，不行再看 +0xC0
        if (c != (int)我方阵营) continue;
        uint64_t 位 = vm_read<uint64_t>(e + 偏移表.节点);
        if (!IsValidAddr(位)) continue;
        int x = vm_read<int>(位 + 偏移表.节点X);
        if (x <= -cfg_coord_max || x >= cfg_coord_max || x == 1000000) continue;
        和 += x;
        数++;
    }
    if (数 == 0) return;                       // 本帧没有我方样本，下帧再试
    小图翻转值 = (和 / 数 > 0) ? -1.0f : 1.0f;
    小图翻转锁定阵营 = 我方阵营;
    小图翻转已锁 = true;
    日志("小地图翻转标定：我方阵营=%u 我方X均值=%lld（%d 个样本）→ 翻转=%.0f（整局锁定）",
         我方阵营, 和 / 数, 数, 小图翻转值);
}

static void 小图坐标(int x, int z, const ImVec4& 地图, float* 出X, float* 出Y) {
    float 翻转 = 小图翻转();
    float half = 地图.w * 0.5f;
    *出X = ((x * 翻转) / cfg_mapSpan) * 地图.w + 地图.x + half;
    *出Y = ((z * 翻转) / cfg_mapSpan) * (-地图.w) + 地图.y + half;
}

// 野怪小图坐标：与小地图同一世界换算，不再单独用 /100000
static void 野怪小图坐标(int x, int z, const ImVec4& 地图, float* 出X, float* 出Y) {
    小图坐标(x, z, 地图, 出X, 出Y);
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
        if (now - 掉出对局时刻 > 20.0 && 在对局) {
            在对局 = false;
            // 一局结束：小地图翻转要重新标定（下一局我方可能在另一侧），阵营也重新猜。
            // 不重置的话，下一局如果换了边，地图会一直按上一局的翻转镜像。
            小图翻转已锁 = false;
            小图翻转锁定阵营 = 0;
            阵营锁定 = 0;
            日志("对局结束→小地图翻转与阵营锁定复位，下一局重新标定");
        }
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
        pid_t sysctl见 = sysctl精确找pid("smoba");
        snprintf(状态行, sizeof(状态行),
                 "%d %s | 端口%d 模块%llx pid%d 见%d 任务%d 找%d/%d",
                 代码, 文案, 游戏pid > 1 ? 1 : 0, 模块基址, 游戏pid,
                 sysctl见, 任务端口 != 0, 找进程调用.load(), 找进程完成.load());
        日志("状态[%d/%s] 端口pid=%d 模块=0x%llx pid=%d sysctl见smoba=%d 任务=%d 找进程=%d/%d 等=%s",
             代码, 文案, 游戏pid > 1 ? 1 : 0, 模块基址, 游戏pid, sysctl见,
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
        uint64_t 实体 = vm_read<uint64_t>(数组 + 偏移表.槽距 * i);
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
                (unsigned long long)(模块基址 + 偏移表.根世界));
        fprintf(取证3文件, "世界=%#llx  容器=%#llx  数组=%#llx  数量=%d  跳=%s\n",
                (unsigned long long)世界, (unsigned long long)容器,
                (unsigned long long)数组, 数量,
                (数组 & 7) ? "错位" : "对齐");
        fprintf(取证3文件, "格式: [槽] ent id camp p=(x,y,z)@0x278 q=(a,b)@0x288 hp\n");
    }

    fprintf(取证3文件, "### 快照 %d\n", 取证3快照);
    for (int k = 0; k < 数量 && k < 32; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 偏移表.槽距 * (uint64_t)k);
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
            uint64_t 实体 = vm_read<uint64_t>(数组 + 偏移表.槽距 * (uint64_t)k);
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
        uint64_t 实体 = vm_read<uint64_t>(数组 + 偏移表.槽距 * (uint64_t)k);
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

// ==================== 取证 v7：负坐标 + 正确 VP ====================
// v6 实测结论（用 P(0xE8) × V(0xA8) 逐元素复算 0x128 的 16 个 float）：
//   99.294  = 1.72167 × 57.673        (P00 × V03)
//   135.927 = 3.73205 × 36.4216       (P11 × V13)
//   95.701  = -1.0006 × (-96.2437) + (-0.60018)
//   96.244  = -1 × (-96.2437)
// → 0x128 就是合法的 VP（列主序）。上一轮「矩阵不对」的判断作废，矩阵一直是对的。
// 顺带算出相机世界位置 = -Rᵀ·t ≈ (-57.67, 37.33, -95.89) 米，地面落点在负半轴，
// 也就是英雄坐标本身带负号 —— 而 v4 的 100<v<250000、v5 的 1~20000 米全都要求必须为正，
// 这才是两轮 0 命中的真实原因，和矩阵无关。

#define 取证7指针项 97       // 0=实体自身，1..96 = 一级指针 @0x00..0x2F8
#define 取证7偏移项 576      // 0..0x900，每 4 字节
#define 取证7类型项 4        // 0=int/1000  1=int/100  2=int(米)  3=float(米)
#define 取证7配对项 2        // 0=(off,off+4)  1=(off+4,off)
#define 取证7样本数 6

struct 命中槽 { int16_t 屏内; int16_t 近中; };
static 命中槽* 取证7表 = nullptr;
static FILE*   取证7文件 = nullptr;
static int     取证7帧计 = 0, 取证7等帧 = 0, 取证7序 = 0;
static bool    取证7完成 = false;

static inline int 取证7索引(int p, int off4, int t, int k) {
    if (p < 0 || p >= 取证7指针项) return -1;
    if (off4 < 0 || off4 >= 取证7偏移项) return -1;
    return ((p * 取证7偏移项 + off4) * 取证7类型项 + t) * 取证7配对项 + k;
}

// 列主序 VP，Y 视为 0：clip.x=m[0]x+m[8]z+m[12]  clip.y=m[1]x+m[9]z+m[13]  w=m[3]x+m[11]z+m[15]
static inline bool 投影列(const float* m, float x, float z, float* 屏X, float* 屏Y, float 宽, float 高) {
    float w = m[3] * x + m[11] * z + m[15];
    if (!isfinite(w) || w < 0.05f) return false;
    float inv = 1.0f / w;
    float px = (m[0] * x + m[8] * z + m[12]) * inv;
    float py = (m[1] * x + m[9] * z + m[13]) * inv;
    if (!isfinite(px) || !isfinite(py)) return false;
    *屏X = (px + 1.0f) * 宽 * 0.5f;
    *屏Y = (1.0f - py) * 高 * 0.5f;
    return true;
}

static inline bool 取证7屏内(float sx, float sy, float 宽, float 高) {
    float mx = 宽 * 0.12f, my = 高 * 0.12f;
    return sx >= -mx && sx <= 宽 + mx && sy >= -my && sy <= 高 + my;
}

// 允许负数；int 可能是毫米/厘米/米，float 直接当米
static inline bool 取证7取值(const unsigned char* b, int off, int t, float* 出) {
    if (t == 3) {
        float v = *(const float*)(b + off);
        if (!isfinite(v) || v <= -20000.0f || v >= 20000.0f) return false;
        *出 = v;
        return true;
    }
    int32_t i = *(const int32_t*)(b + off);
    if (i == 0 || i <= -400000 || i >= 400000) return false;
    float v = (t == 0) ? (float)i * 0.001f : ((t == 1) ? (float)i * 0.01f : (float)i);
    if (v <= -20000.0f || v >= 20000.0f) return false;
    *出 = v;
    return true;
}

static void 取证7扫(int p, const unsigned char* 块, int 长度, const float* m,
                    float 宽, float 高, float 中X, float 中Y) {
    int 末 = 长度 / 4 - 2;
    for (int o = 0; o < 末; ++o) {
        for (int t = 0; t < 取证7类型项; ++t) {
            float v[3]; bool ok[3];
            for (int i = 0; i < 3; ++i) ok[i] = 取证7取值(块, (o + i) * 4, t, &v[i]);
            if (!ok[0] && !ok[1] && !ok[2]) continue;
            for (int k = 0; k < 取证7配对项; ++k) {
                int xi = (k == 0) ? 0 : 1;
                int zi = (k == 0) ? 2 : 0;
                if (!ok[xi] || !ok[zi] || v[xi] == v[zi]) continue;
                float sx, sy;
                if (!投影列(m, v[xi], v[zi], &sx, &sy, 宽, 高)) continue;
                if (!取证7屏内(sx, sy, 宽, 高)) continue;
                int idx = 取证7索引(p, o, t, k);
                if (idx < 0) continue;
                命中槽& e = 取证7表[idx];
                if (e.屏内 < 9000) e.屏内++;
                float dx = sx - 中X, dy = sy - 中Y;
                if (dx * dx + dy * dy < 200.0f * 200.0f && e.近中 < 9000) e.近中++;
            }
        }
    }
}

static void 取证7采样(uint64_t 数组, int 数量, const float* m, float 宽, float 高) {
    unsigned char* 块 = (unsigned char*)malloc(0x900);
    if (!块) return;
    float 中X = 宽 * 0.5f, 中Y = 高 * 0.5f;
    if (数量 > 32) 数量 = 32;
    for (int k = 0; k < 数量; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 偏移表.槽距 * (uint64_t)k);
        if (!IsValidAddr(实体)) continue;
        if (readMemory(实体, 块, 0x900)) 取证7扫(0, 块, 0x900, m, 宽, 高, 中X, 中Y);
        for (int po = 0; po < 0x300; po += 8) {
            uint64_t 子 = vm_read<uint64_t>(实体 + (uint64_t)po);
            if (!IsValidAddr(子)) continue;
            if (!readMemory(子, 块, 0x400)) continue;
            取证7扫(po / 8 + 1, 块, 0x400, m, 宽, 高, 中X, 中Y);
        }
    }
    free(块);
}

static void 取证7结算(uint64_t 数组, int 数量, const float* m, float 宽, float 高) {
    fprintf(取证7文件, "\n=== 结果  (%d 次采样 × %d 槽)  判据=投影落屏内 + 靠近屏幕中心 ===\n",
            取证7样本数, 数量);
    fprintf(取证7文件, "屏内=该字段投影落屏的槽次累计；近中=投影落在屏幕中心 200px 内的槽次累计\n");
    for (int 轮 = 0; 轮 < 32; ++轮) {
        int 最佳 = -1, 最佳分 = 0, 最佳次 = 0;
        for (int i = 0; i < 取证7指针项 * 取证7偏移项 * 取证7类型项 * 取证7配对项; ++i) {
            int a = 取证7表[i].屏内, b = 取证7表[i].近中;
            if (a <= 0) continue;
            int 分 = b * 1000 + a;
            if (分 > 最佳分) { 最佳分 = 分; 最佳次 = b; 最佳 = i; }
        }
        if (最佳 < 0 || 最佳分 < 8) break;
        int k = 最佳 % 取证7配对项;
        int t = (最佳 / 取证7配对项) % 取证7类型项;
        int r = 最佳 / (取证7配对项 * 取证7类型项);
        int off = (r % 取证7偏移项) * 4;
        int p = r / 取证7偏移项;
        const char* 类型名[4] = { "int/1000", "int/100", "int=米", "float=米" };
        const char* 配对名[2] = { "x=off,z=off+4", "x=off+4,z=off" };
        if (p == 0)
            fprintf(取证7文件, "\n[近中%2d 屏内%3d] 实体 +%#05x  %s  %s\n", 最佳次, 取证7表[最佳].屏内, off, 类型名[t], 配对名[k]);
        else
            fprintf(取证7文件, "\n[近中%2d 屏内%3d] 子对象@+%#05x -> +%#05x  %s  %s\n", 最佳次, 取证7表[最佳].屏内, (p - 1) * 8, off, 类型名[t], 配对名[k]);
        取证7表[最佳].屏内 = -1;   // 排掉，避免重复
        if (数量 > 32) 数量 = 32;
        for (int s = 0; s < 数量; ++s) {
            uint64_t 实体 = vm_read<uint64_t>(数组 + 偏移表.槽距 * (uint64_t)s);
            if (!IsValidAddr(实体)) continue;
            uint64_t 基 = 实体;
            if (p > 0) {
                基 = vm_read<uint64_t>(实体 + (uint64_t)((p - 1) * 8));
                if (!IsValidAddr(基)) continue;
            }
            float xv, zv;
            unsigned char 小[16];
            if (!readMemory(基 + (uint64_t)off, 小, 16)) continue;
            if (!取证7取值(小, 0, t, &xv)) continue;
            if (!取证7取值(小, 4, t, &zv)) continue;
            if (k == 1) { float tmp = xv; xv = zv; zv = tmp; }
            float sx = 0, sy = 0;
            bool ok = 投影列(m, xv, zv, &sx, &sy, 宽, 高);
            fprintf(取证7文件, "    槽%-2d  x=%9.2f z=%9.2f  →  %s %.0f,%.0f\n",
                    s, xv, zv, ok ? "屏" : "屏外", sx, sy);
        }
    }
    fprintf(取证7文件, "=== 取证结束 ===\n");
}

static void 取证7(uint64_t 数组, int 数量, const float* m, float 宽, float 高) {
    if (取证7完成) return;
    if (!取证7表) {
        size_t n = (size_t)取证7指针项 * 取证7偏移项 * 取证7类型项 * 取证7配对项;
        取证7表 = (命中槽*)calloc(n, sizeof(命中槽));
        if (!取证7表) return;
    }
    if (++取证7帧计 % 30) return;
    if (取证7序 > 0) {
        if (++取证7等帧 < 45) return;
        取证7等帧 = 0;
    }
    if (!取证7文件) {
        const char* 家 = getenv("HOME");
        if (!家) return;
        char 路径[512];
        snprintf(路径, sizeof(路径), "%s/Documents/fields_dump7.txt", 家);
        取证7文件 = fopen(路径, "w");
        if (!取证7文件) return;
        setvbuf(取证7文件, nullptr, _IOLBF, 0);
        fprintf(取证7文件, "=== 取证 v7（允许负坐标）===\n");
        fprintf(取证7文件, "屏幕=%.0fx%.0f  数量=%d\n", 宽, 高, 数量);
        fprintf(取证7文件, "VP:");
        for (int i = 0; i < 16; ++i) fprintf(取证7文件, " %.5f", m[i]);
        fprintf(取证7文件, "\n");
        // 由 V(0xA8) 反算相机世界位置，并求视线落地面点
        float v[16];
        int 有效 = 0;
        for (int i = 0; i < 16; ++i) {
            v[i] = vm_read<float>(相机节点 + 0xA8 + 4 * i);
            if (isfinite(v[i])) 有效++;
        }
        if (有效 == 16) {
            float tx = v[3], ty = v[7], tz = v[11];
            float cx = -(v[0] * tx + v[4] * ty + v[8] * tz);
            float cy = -(v[1] * tx + v[5] * ty + v[9] * tz);
            float cz = -(v[2] * tx + v[6] * ty + v[10] * tz);
            fprintf(取证7文件, "相机世界位置 ≈ (%.2f, %.2f, %.2f) 米\n", cx, cy, cz);
            float fx = -v[8], fy = -v[9], fz = -v[10];   // 视线方向
            if (fy < -0.05f) {
                float t = cy / -fy;
                fprintf(取证7文件, "视线地面点 ≈ (%.2f, %.2f) 米  → 毫米 (%.0f, %.0f)\n",
                        cx + fx * t, cz + fz * t, (cx + fx * t) * 1000, (cz + fz * t) * 1000);
            }
            fprintf(取证7文件, "V:");
            for (int i = 0; i < 16; ++i) fprintf(取证7文件, " %.5f", v[i]);
            fprintf(取证7文件, "\n");
        } else {
            fprintf(取证7文件, "V 读取失败（相机节点+0xA8）\n");
        }
        fflush(取证7文件);
    }

    取证7采样(数组, 数量, m, 宽, 高);
    int 序 = 取证7序++;
    fprintf(取证7文件, "--- 采样%d 完成 ---\n", 序);
    fflush(取证7文件);

    if (序 + 1 >= 取证7样本数) {
        取证7完成 = true;
        取证7结算(数组, 数量, m, 宽, 高);
        fclose(取证7文件);
        取证7文件 = nullptr;
    }
}



// ==================== 位置落盘（小地图标定用） ====================
// 每 0.5 秒写一次 10 个槽的世界坐标与屏幕坐标，用来和游戏原生小地图做对齐标定。
static void 位置日志(uint64_t 数组, int 数量, const float* m, float 宽, float 高) {
    static FILE* f = nullptr;
    static double 上次 = 0;
    double now = CACurrentMediaTime();
    if (now - 上次 < 0.5) return;
    上次 = now;
    if (!f) {
        const char* 家 = getenv("HOME");
        if (!家) return;
        char p2[512];
        snprintf(p2, sizeof(p2), "%s/Documents/pos.log", 家);
        f = fopen(p2, "w");
        if (!f) return;
        setvbuf(f, nullptr, _IOLBF, 0);
        fprintf(f, "# 槽 x(毫米) z(毫米) 屏x 屏y 有效  (屏幕 %.0fx%.0f 缩放=%.2f)\n", 宽, 高, 缩放系数);
        // 小地图框实际画到屏幕上的像素矩形，用来和截图里的原生面板逐像素比对（别再靠猜）
        fprintf(f, "# 小图框 像素 x=%.0f y=%.0f 边长=%.0f  (点 x=%.1f y=%.1f 边长=%.1f)\n",
                cfg_mapX * 缩放系数, cfg_mapY * 缩放系数, cfg_mapSize * 缩放系数,
                cfg_mapX, cfg_mapY, cfg_mapSize);
    }
    fprintf(f, "--- %.2f 命中=0x%llX 阵营=%u 翻转=%.0f(%s) 跨度=%.0f 边界=±%d 解密器=%s 主/镜/交叉失败/未命中=%ld/%ld/%ld/%ld ---\n",
            now, (unsigned long long)坐标命中偏移, 调试我方阵营, 小图翻转(),
            小图翻转已锁 ? "整局锁定" : "未标定", cfg_mapSpan, cfg_coord_max,
            坐标解密器::State().阶段名(),
            坐标解密器::State().统计主(), 坐标解密器::State().统计镜(),
            坐标解密器::State().统计交叉失败(), 坐标解密器::State().统计未命中());
    // 偏移表来源 + 样本链 B 的互校结果：一致涨=两条链都健康；
    // 不一致涨=有一条在解错引用，配合最差偏差看差多远；链B命中=0 说明那三跳在本版本不成立。
    fprintf(f, "### 偏移=%s 覆盖=%d 未知=%d | 互校 一致=%ld 不一致=%ld 最差=%d米 | 链B命中=%ld | 节点=%llu 组件=%llu 坐标基=%llu\n",
            偏移来源, 偏移覆盖数, 偏移未知键, 互校一致, 互校不一致, 互校最差米, 链B命中,
            (unsigned long long)偏移表.节点, (unsigned long long)偏移表.坐标组件,
            (unsigned long long)偏移表.坐标基);
    for (int i = 0; i < 数量 && i < 16; ++i) {
        uint64_t e = vm_read<uint64_t>(数组 + 偏移表.槽距 * (uint64_t)i);
        unsigned X = 0, Z = 0;
        if (读实体坐标(e, &X, &Z) < 0) { fprintf(f, "%d 0 0 0 0 0 0 0\n", i); continue; }
        float sx = 0, sy = 0;
        bool ok = 投影(m, (int)X, (int)Z, &sx, &sy, 宽, 高);
        // 第 7/8 列：小图坐标（像素）。与绘制走同一套换算，可以直接和原生小地图上的圆点对比。
        ImVec4 地图 = ImVec4(cfg_mapX, cfg_mapY, cfg_mapSize, cfg_mapSize);
        float mx = 0, my = 0;
        小图坐标((int)X, (int)Z, 地图, &mx, &my);
        fprintf(f, "%d %d %d %.0f %.0f %d %.0f %.0f\n", i, (int)X, (int)Z, sx, sy, ok ? 1 : 0,
                mx * 缩放系数, my * 缩放系数);
    }
    fflush(f);
}

// 链路诊断：把 根世界→容器→数组→实体→候选坐标节点 的原始指针全部落盘，
// 并每 3 秒对槽0 做一次指针扫描，找出真正形如 {x,z} 的坐标对。
// 写 Documents/chain.log，用于在没有任何调试器可用时定位字段。
static void 链路诊断(uint64_t 根世界, uint64_t 容器, uint64_t 数组, int 数量) {
    static FILE* f = nullptr;
    static double 上次 = 0, 上次扫 = 0;
    double now = CACurrentMediaTime();
    if (now - 上次 < 1.0) return;
    上次 = now;
    if (!f) {
        const char* 家 = getenv("HOME");
        if (!家) return;
        char p3[512];
        snprintf(p3, sizeof(p3), "%s/Documents/chain.log", 家);
        f = fopen(p3, "w");
        if (!f) return;
        setvbuf(f, nullptr, _IOLBF, 0);
        fprintf(f, "# 链路诊断：根世界/容器/数组/实体指针 + 候选坐标扫描\n");
    }
    fprintf(f, "=== %.2f 根世界=0x%llx 容器=0x%llx 数组=0x%llx 数量=%d\n", now,
            (unsigned long long)根世界, (unsigned long long)容器,
            (unsigned long long)数组, 数量);
    for (int i = 0; i < 数量 && i < 12; ++i) {
        uint64_t e = vm_read<uint64_t>(数组 + 偏移表.槽距 * (uint64_t)i);
        fprintf(f, "槽%-2d 实体=0x%llx", i, (unsigned long long)e);
        if (!IsValidAddr(e)) { fprintf(f, " [实体无效]\n"); continue; }
        uint64_t p230 = vm_read<uint64_t>(e + 偏移表.节点);
        uint64_t p1d0 = vm_read<uint64_t>(e + 偏移表.血量对象);
        unsigned v278 = vm_read<unsigned>(e + 偏移表.直接X);
        int v2b8 = vm_read<int>(e + 偏移表.野怪坐标X);
        int v2c0 = vm_read<int>(e + 偏移表.野怪坐标Y);
        fprintf(f, " +230=0x%llx +1D0=0x%llx +278=%u +2B8=%d +2C0=%d",
                (unsigned long long)p230, (unsigned long long)p1d0,
                v278, v2b8, v2c0);
        if (IsValidAddr(p230)) {
            fprintf(f, "\n      p230:");
            for (uint64_t o = 0x100; o <= 0x170; o += 8)
                fprintf(f, " %llx=%d", (unsigned long long)o, vm_read<int>(p230 + o));
        }
        fprintf(f, "\n");
    }
    // 指针扫描：只扫槽0，3 秒一次，避免拖慢帧率
    if (数量 > 0 && now - 上次扫 > 3.0) {
        上次扫 = now;
        uint64_t e = vm_read<uint64_t>(数组);
        if (IsValidAddr(e)) {
            fprintf(f, "-- 扫描槽0 实体=0x%llx --\n", (unsigned long long)e);
            for (uint64_t off = 0x180; off <= 0x340; off += 8) {
                uint64_t p = vm_read<uint64_t>(e + off);
                if (!IsValidAddr(p)) continue;
                int bx = 0, bz = 0;
                uint64_t bo = 0;
                bool 找到 = false;
                for (uint64_t o = 0x100; o <= 0x180; o += 4) {
                    int x = vm_read<int>(p + o);
                    int z = vm_read<int>(p + o + 4);
                    int ax = x < 0 ? -x : x, az = z < 0 ? -z : z;
                    if (ax > 1000 && ax < 200000 && az > 1000 && az < 200000) {
                        bx = x; bz = z; bo = o; 找到 = true; break;
                    }
                }
                if (找到)
                    fprintf(f, "   +0x%llx -> 0x%llx @0x%llx (%d, %d)\n",
                            (unsigned long long)off, (unsigned long long)p,
                            (unsigned long long)bo, bx, bz);
            }
        }
    }
    fflush(f);
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

    // 小地图自适配（没手调过、也没被 tune.txt 指定过才回写）
    if (调参定地图) 地图已手调 = true;
    if (!地图已手调) {
        float 基准 = 短边 / 缩放;
        // 实测标定（2796×1290 @3x 截图逐像素量原生小地图面板边界）：
        //   原生小地图 = 屏幕 (172,60) 起，边长 344 px；缩放前 = (57.3,20.0) 点，边长 114.7 点
        //   基准 = 短边/缩放 = 1290/3 = 430 点
        //   旧值 0.32721 → 边长 422 px，比如 344 大了 23%，还整体向左上偏 60/54 px，用户看到的就是"框比地图大一圈"
        cfg_mapX = 基准 * 0.133180f;
        cfg_mapY = 基准 * 0.046280f;
        cfg_mapSize = 基准 * 0.266420f;
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

    // 内核不再当门槛：越狱已就绪就直接用；拿不到就纯任务端口，照样画。
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
    uint64_t 根世界 = vm_read<uint64_t>(模块基址 + 偏移表.根世界);
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

    // 数组有效性只看指针。数量字段不再作为门槛 —— 样本（TrollSpeed GetPlayers）
    // 是固定遍历 128 个槽、完全不读数量字段，数量读成 0 或垃圾也照画。
    bool 数组有效 = IsValidAddr(根世界) && IsValidAddr(容器) && IsValidAddr(数组);

    if (!数组有效) {
        对局状态(false, true, now);
        状态浮层(4, "实体数组无效");
        if (!在对局) 底部文字(屏, "等待进入对局");
        return;
    }

    // 扫描槽数：下限写死 128（不依赖数量字段）；数量更多（联机小兵/召唤物/野怪）就按数量走，
    // 上限由 cfg_scan_max 兜住（默认 128，可在 settings.plist / tune.txt 抬到 512）。
    int 扫描数 = 128;
    if (数量 > cfg_scan_max) 扫描数 = cfg_scan_max;
    else if (数量 > 128)     扫描数 = 数量;

    // 坐标解密器：绑进程（原子 CAS，绑一次常驻）→ 拿到数组后做一次只读扫描，
    // 之后每帧只走"解密读取"那一段。对应样本里 State() 单例 + TersafeRO() 的两段式。
    {
        坐标解密器& 解 = 坐标解密器::State();
        解.绑定进程(游戏pid);
        if (解.取阶段() == 坐标解密器::未初始化) 解.只读扫描(数组, 数量);
    }

    // 取证 v3：坐标时序 + 活局整块对拍 → Documents/fields_dump3.txt
    // 每 0.5 秒一行/槽（ID/阵营/+0x278 坐标/血量），第 20/80/200 份快照整块导出。
    static bool 已提示取证 = false;
    // 不再用 数量>=2 当门槛：数量字段读成 0 时 pos.log 会整个不生成，等于自断诊断。
    if (数组有效) {
        位置日志(数组, 扫描数, 矩阵, 屏.x, 屏.y);
        链路诊断(根世界, 容器, 数组, 扫描数);
        if (!已提示取证) {
            已提示取证 = true;
            日志("坐标链：解密器(%s) → 0x230 → 0x278 兜底，位置写入 Documents/pos.log",
                 坐标解密器::State().阶段名());
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

    // 运行时调参（Documents/tune.txt，2 秒重读一次）与小地图翻转
    读调参();
    读偏移表();          // Documents/offsets.json，2 秒看一次 mtime，改完存盘即生效
    推小图翻转(数组, 扫描数, 我方阵营);
    调试我方阵营 = 我方阵营;

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
    // 技能列收集表：循环里只收集，循环外按稳定键排序后落位（否则联机槽位一变整列乱跳）
    struct 技能列项 { long long 英雄ID; uint64_t 技能对象; uint64_t 实体; };
    技能列项 技能列[20];
    int 技能列数 = 0;
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

    // 阵营严格模式（照样本）：只认 1 / 2。
    // 联机数组里混着野怪/召唤物/影子体，阵营常见 0 / 3 / -1；以前允许 -1..7，
    // 等于把这些垃圾实体一起画成敌人 —— 目标忽有忽无、位置乱跳的主因之一。
    // 自愈：严格模式连续 90 帧一个都过不了（个别玩法可能不用 1/2），自动放宽并记一次日志，
    // 免得换模式直接白板。放宽只作用于本次进程，不改 plist。
    static int 严格空帧 = 0;
    static bool 阵营已放宽 = false;
    static bool 已报放宽 = false;
    if (!cfg_camp_strict) { 严格空帧 = 0; 阵营已放宽 = false; 已报放宽 = false; }
    bool 严格阵营 = cfg_camp_strict && !阵营已放宽;
    int 严格通过 = 0;

    for (int k = 0; k < 扫描数; ++k) {
        uint64_t 实体 = vm_read<uint64_t>(数组 + 偏移表.槽距 * k);
        if (!IsValidAddr(实体)) continue;
        有效实体++;

        int 阵营 = vm_read<int>(实体 + 52);
        bool 阵营合法 = (阵营 == 1 || 阵营 == 2);
        if (!阵营合法) {
            int 备 = vm_read<int>(实体 + (int)偏移表.阵营);   // 联机部分实体阵营在 +0xC0
            if (备 == 1 || 备 == 2) { 阵营 = 备; 阵营合法 = true; }
            else if (备 >= -1 && 备 <= 7) 阵营 = 备;         // 只用于直方图，不参与绘制
        }
        if (阵营 >= -1 && 阵营 <= 7) 阵营直方[阵营 + 1]++;
        if (阵营合法) 严格通过++;
        if (严格阵营 && !阵营合法) continue;   // 严格模式：1/2 之外一律当垃圾实体
        if (!阵营合法 && (阵营 < -1 || 阵营 > 7)) continue;   // 连读都读不出来

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
        // 阈值从 8000（8 米）收到 1500（1.5 米）：团战时两个真英雄常常肩并肩站在 8 米内，
        // 旧阈值会把其中一个当影子体丢掉 → "队友/敌人少一个"。可 tune.txt 里 dedup=xxx 调。
        if (cfg_id_pick && 英雄ID > 0 && 英雄ID < 1000) {
            bool 重复 = false;
            long long 门限 = (long long)cfg_dedup_mm * (long long)cfg_dedup_mm;
            for (int d = 0; d < 已画数; ++d) {
                if (已画ID[d] != 英雄ID) continue;
                long long dx = (long long)(int)样X - 已画X[d];
                long long dz = (long long)(int)样Z - 已画Z[d];
                if (dx * dx + dz * dz < 门限) { 重复 = true; break; }
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

        // 技能图标列不在循环里排位，先收起来，循环结束后按英雄ID排序再画
        if (cfg_skill && IsValidAddr(技能对象) && 技能列数 < 20) {
            技能列[技能列数].英雄ID = 英雄ID;
            技能列[技能列数].技能对象 = 技能对象;
            技能列[技能列数].实体 = 实体;
            技能列数++;
        }

        // 小地图图标
        if (cfg_map) {
            float mx = 0.0f, my = 0.0f;
            小图坐标((int)样X, (int)样Z, 地图, &mx, &my);
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

    // ==================== 技能图标列（屏幕上方）====================
    // ★ 从实体循环里挪出来，先按稳定键排序再落位：
    //   原来按「实体数组扫描顺序」边扫边排，联机时容器槽位每帧都在变，
    //   一列图标就跟着左右乱跳（同一个敌人上帧第 2 列、下帧第 5 列）。
    //   排序键用英雄ID（相同再比实体地址），一局内稳定；
    //   超过 6 个目标就换行（原来 %6 会在同一格上叠画）。
    if (cfg_skill && 技能列数 > 0) {
        for (int i = 1; i < 技能列数; ++i) {
            技能列项 v = 技能列[i];
            int j = i - 1;
            while (j >= 0 && (技能列[j].英雄ID > v.英雄ID
                   || (技能列[j].英雄ID == v.英雄ID && 技能列[j].实体 > v.实体))) {
                技能列[j + 1] = 技能列[j];
                --j;
            }
            技能列[j + 1] = v;
        }
        for (int i = 0; i < 技能列数; ++i) {
            int 列 = i % 6, 行 = i / 6;
            uint64_t 技能对象 = 技能列[i].技能对象;
            long long 英雄ID = 技能列[i].英雄ID;
            float px = (技能列系数[列] * 技能列步长 + 技能列基准 + cfg_skillX) * 缩放;
            float py = (cfg_skillY + 行 * 58.0f) * 缩放;
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
    }

    // ==================== 野怪 ====================
    int 野怪计 = 0, 野怪越界 = 0;
    if (cfg_monster && cfg_map && 扫描数 >= 8) {
        野怪信息 野怪[20];
        for (int i = 0; i < 20; ++i) 野怪[i] = {0, 0, 0, 0, 0};
        野怪计 = 读野怪(模块基址, 野怪, 20);
        for (int m = 0; m < 野怪计; ++m) {
            float mx = 0.0f, my = 0.0f;
            野怪小图坐标(野怪[m].x, 野怪[m].z, 地图, &mx, &my);
            // ★ 删掉「算出框外就镜像到对面半图」那一手。
            //   小图坐标() 里已经按全局翻转换算过一次，这里再镜像等于翻两次，
            //   野怪会凭空出现在对面半图、同一个野怪两个位置，看着就是"野怪乱跑"。
            //   样本 ToMiniMap 也没有镜像逻辑，出框就是没在图上，直接不画。
            if (!点在小地图(地图, mx, my)) { 野怪越界++; continue; }
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

    // 阵营严格模式的空转自愈（每帧结算一次）
    if (严格阵营 && 有效实体 >= 3 && 严格通过 == 0) {
        if (++严格空帧 >= 90 && !已报放宽) {
            阵营已放宽 = true;
            已报放宽 = true;
            日志("阵营严格模式空转 %d 帧（有效实体 %d 个，阵营 1/2 一个都没有）→ 放宽阵营过滤", 严格空帧, 有效实体);
            严格空帧 = 0;
        }
    } else {
        严格空帧 = 0;
    }

    // ==================== 对局判定 & 统计 ====================
    // 原来卡 数量<=12（假设容器里只有 10 个英雄）。联机时容器里还有小兵/野怪/召唤物，
    // 数量会超过 12 → 判成"没进对局"，野怪与统计同时关掉。只保留下限。
    // 下限改用扫描数（≥128），不再依赖数量字段。
    bool 判在对局 = 扫描数 >= 8
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
        日志("n=%d 扫=%d 敌=%d 屏=%d 野=%d(越界%d) 阵[-1:%d 0:%d 1:%d 2:%d 3:%d] 血样%d/%d 源=%s 英雄=%d 我=%d 严=%d 翻=%.0f 读=%d 限=%d 任务=%d fps=%.0f",
             数量, 扫描数, 有坐标实体, 屏内实体, 野怪计, 野怪越界,
             阵营直方[0], 阵营直方[1], 阵营直方[2], 阵营直方[3], 阵营直方[4],
             首个血当前, 首个血上限, 链名(首个链), (int)首个英雄ID, 我方阵营,
             严格阵营 ? 1 : 0, 小图翻转(),
             (int)读总数, 读限流计数, 任务端口 != 0, fps);
        日志("扫描 %d/%d 槽 去重后=%d 屏内=%d 边界=±%d 去重阈值=%d",
             有效实体, 扫描数, 已画数, 屏内实体, cfg_coord_max, cfg_dedup_mm);
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
