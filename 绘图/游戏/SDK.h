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
    // 下面实际参与定位的偏移条目数：6 根对象 + 2 坐标 + 1 阵营
    // + 3 血量 + 3 技能 + 2 回城 + 1 技能CD + 2 视距参数
    static const int 偏移项数 = 20;

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

    // ===== 坐标链（多平台遗留，已删除）=====
    // 原来这里有 3 条链：H5（根+0xa8→0x10→0x0→0x78）、S44（+0x268→…）、
    // 安卓（+0xa8→0x10→0x0→0x60）。三条都是原工程 AB_WZRY_S45重建版 里
    // 为 PC/H5/安卓 多端多赛季准备的偏移，iOS 版直接照抄了。
    //
    // 2026-11-26 依 fields_dump2.txt（555 快照 × 10 槽）实测全部作废：
    //   1) 运行期选中的 H5 链，末段读 +0x2B8 给出的值是 -2144158520 / 998836568 /
    //      2147483645(INT_MAX)，只有 158/555 份碰巧落进区间校验，且值恒定不变；
    //   2) 安卓链第四段 0x60 与 iOS 实测实体槽步进 24 字节(0x18) 不符；
    //   3) 三条链每帧互相打分还会来回切链，两套坐标交替写入 → 画面上"闪来闪去"。
    // 结论：这不是备用方案，是噪声源。整段删除，坐标只走实测直读。

    // ===== 实体字段偏移 =====
    // 坐标（读坐标值：int 直读，或 float×1000 兜底）
    // 注意：这两个偏移现在只有 读野怪() 在用；英雄坐标不走它（见 DrawView.mm 的 读实体坐标）。
    static const uint64_t 坐标X = 696;   // 0x2B8
    static const uint64_t 坐标Y = 704;   // 0x2C0

    // ===== 英雄坐标（2026-11-26 23:00 实测钉死，非猜测）=====
    // 坐标三元组就在实体自身：+0x278 = x(int32 毫米)，+0x27C = y(恒 0)，+0x280 = z(int32 毫米)。
    // 证据（新 chain.log / pos.log 同局同帧对拍，10 槽 10/10 完全相等）：
    //   槽0 +0x278=4294913880(-53416) = pos.log x -53416  ✓
    //   槽2 +0x278=4294909623(-57673) = pos.log x -57673  ✓ … 共 10 槽全中
    // 为什么之前走 实体+0x230 不行：那对象在本局 +0x128/+0x130 恒为 0，全槽失效。
    // 为什么 0x250 候选会"歪打正着"：实体+0x250 存的是 实体+0x150，
    //   而 +0x150+0x128 = +0x278，于是恰好读到了真坐标 —— 但靠的是巧合，不能依赖。
    // 交叉验证：槽2(-57673,-55764) 用实测 VP 投影 = 屏 (1398,692)，屏幕 2796×1290 中心 (1398,645)，
    //   正下方 47px，第三人称本人位置；且 x 与 V 反算的相机地面点 (-57673,-54400) 完全一致。
    static const uint64_t 坐标直接X = 632;   // 0x278
    static const uint64_t 坐标直接Y = 636;   // 0x27C
    static const uint64_t 坐标直接Z = 640;   // 0x280

    // 旧链路（实体 +0x230 → 子对象 +0x128/+0x130）保留为兜底，本局实测全 0
    static const uint64_t 坐标节点  = 560;   // 0x230
    static const uint64_t 坐标节点X = 296;   // 0x128
    static const uint64_t 坐标节点Y = 304;   // 0x130

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
