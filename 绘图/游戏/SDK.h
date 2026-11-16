//
//  SDK.h - 王者荣耀(smoba) SDK 偏移与数据表  [S45 重建版]
//
//  来源：AB_WZRY_S45重建版.tipa 中 Books 二进制静态还原
//  （__DATA 段全局变量 + IDA 反编译伪代码）
//

#ifndef SDK_h
#define SDK_h

namespace SDK {

    // ===== 进程 / 模块 =====
    static const char* 进程名 = "smoba";
    static const char* 模块名 = "UnityFramework";

    // ===== 元信息（界面/日志显示，换赛季只改这里） =====
    static const char* 赛季 = "S45";
    // 下面实际参与定位的偏移条目数：6 根对象 + 3 链×4 段 + 2 坐标 + 1 阵营
    // + 3 血量 + 3 技能 + 2 回城 + 1 技能CD + 2 视距参数
    static const int 偏移项数 = 32;

    // 进程名候选（getbbz 多路由查进程用：sysctl 精确 → sysctl 模糊 → 内核 allproc → 全盘扫）
    static const char* 名候选[7] = {
        "smoba", "smob", "wzry", "sgame", "honor", "王者荣耀", "pandora"
    };

    // ===== 根对象偏移（UnityFramework 模块内） =====
    static uint64_t 根世界   = 0x13E5C698;
    static uint64_t 根相机   = 0x138A2848;
    static uint64_t 根相机备 = 0x138AA580;
    static uint64_t 根野怪   = 0x134CC510;
    static uint64_t 根野怪备 = 0x133CD510;
    static uint64_t 根视距   = 0x12ACEE98;

    // ===== 坐标链 =====
    // 读实体坐标时按 链打分/选坐标链 动态选择一条链，
    // 按四段偏移从根世界逐级解引用到实体数组。
    struct 坐标链 {
        const char* 名字;   // 链名（链名/日志显示用）
        uint64_t 一;        // 根世界 + 一
        uint64_t 二;        // + 二
        uint64_t 三;        // + 三
        uint64_t 四;        // + 四（实体槽基址，逐实体 + 序号*槽距）
    };

    static 坐标链 坐标链表[3] = {
        { "H5",  0xa8, 0x10, 0x0, 0x78 },
        { "S44", 0x268, 0x10, 0x0, 0x78 },
        { "安卓", 0xa8, 0x10, 0x0, 0x60 },
    };

    // ===== 实体字段偏移 =====
    // 坐标（读坐标值：int 直读，或 float×1000 兜底）
    static const uint64_t 坐标X = 696;   // 0x2B8
    static const uint64_t 坐标Y = 704;   // 0x2C0

    // 阵营（阵营符号：0/1，camp==1 时小地图 y 取反）
    static const uint64_t 阵营 = 192;    // 0xC0

    // 血量：实体+464 → 对象，当前 +192 / 上限 +200（读血量当前/读血量上限）
    static const uint64_t 血量对象 = 464;         // 0x1D0
    static const uint64_t 血量当前 = 192;         // 0xC0
    static const uint64_t 血量上限 = 200;         // 0xC8

    // 召唤技能 ID：实体+336 → +224 → +16（读召唤技能ID）
    static const uint64_t 技能对象 = 336;         // 0x150
    static const uint64_t 技能中转 = 224;         // 0xE0
    static const uint64_t 技能ID   = 16;          // 0x10

    // 回城状态：实体+360 → +272 非零即在回城（读回城）
    static const uint64_t 回城对象 = 360;         // 0x168
    static const uint64_t 回城状态 = 272;         // 0x110

    // 技能 CD：实体+576，显示秒 = (原始值+8191999)/8192000，封顶 999（读CD秒）
    static const uint64_t 技能CD = 576;           // 0x240

    // ===== 视距自校准参数 =====
    // 视距探测扫：候选区 ±768，步进 4；写测试 + 期望列长 = 1/tan(fov/2)
    static const uint64_t 视距扫描半径 = 768;
    static const uint64_t 视距扫描步进 = 4;

} // namespace SDK

#endif /* SDK_h */
