//
//  SLIconCache.mm - 英雄/召唤师图标缓存实现（S45 新增类）
//
//  还原自二进制：
//    +[SLIconCache 共用]           0x10007F47C
//    -[SLIconCache 纹理:URL:]      0x10007F6C0
//    -[SLIconCache 英雄:]          0x100080A60
//    -[SLIconCache 召唤师:]        0x100080BE8
//    建纹理(NSData*)               0x10008046C
//    召唤师图标ID重映射             0x100080D64
//

#import "SLIconCache.h"
#import <objc/objc-sync.h>

static SLIconCache* SLIconCache共用实例 = nil;

// 召唤师图标 ID 重映射（老 ID → 新图 URL ID）
static unsigned 召唤师ID重映射(unsigned id) {
    switch (id) {
        case 80106: return 80107;
        case 80111: return 80110;
        case 80113: return 80115;
        case 80122: return 80115;
        case 80114: return 80103;
        case 80116: return 80104;
        case 80117: return 80118;
        case 80120: return 80118;
        case 80123: return 80104;
        default:    return id;
    }
}

// NSData → MTLTexture（缩到 ≤96，BGRA8Unorm）
static id 建纹理(NSData* 数据) {
    if ([数据 length] < 0x40) return nil;
    UIImage* 图 = [UIImage imageWithData:数据];
    if (!图) return nil;
    CGImageRef cg = 图.CGImage;
    if (!cg) return nil;
    size_t 宽 = CGImageGetWidth(cg);
    size_t 高 = CGImageGetHeight(cg);
    if (!宽 || !高 || 宽 > 0x400 || 高 > 0x400) return nil;

    // 超过 96 缩到 96
    if (宽 > 0x60 || 高 > 0x60) {
        float 大边 = 宽 > 高 ? (float)宽 : (float)高;
        float 比例 = 96.0f / 大边;
        宽 = (size_t)((float)宽 * 比例);
        高 = (size_t)((float)高 * 比例);
        if (!宽) 宽 = 1;
        if (!高) 高 = 1;
    }

    void* 像素 = calloc(4 * 宽 * 高, 1);
    if (!像素) return nil;
    CGColorSpaceRef 色域 = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(像素, 宽, 高, 8, 4 * 宽, 色域, 0x4001);
    CGColorSpaceRelease(色域);
    if (!ctx) { free(像素); return nil; }
    CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
    CGContextDrawImage(ctx, CGRectMake(0, 0, 宽, 高), cg);

    id 纹理 = nil;
    id<MTLDevice> 设备 = MTLCreateSystemDefaultDevice();
    if (设备) {
        MTLTextureDescriptor* 描述 = [MTLTextureDescriptor
            texture2DDescriptorWithPixelFormat:(MTLPixelFormat)70   // BGRA8Unorm
            width:宽 height:高 mipmapped:NO];
        描述.usage = MTLTextureUsageShaderRead;   // 1
        描述.storageMode = MTLStorageModeShared;  // 0
        id<MTLTexture> tex = [设备 newTextureWithDescriptor:描述];
        if (tex) {
            MTLRegion 区域 = MTLRegionMake2D(0, 0, 宽, 高);
            [tex replaceRegion:区域 mipmapLevel:0 withBytes:像素 bytesPerRow:4 * 宽];
            纹理 = tex;
        }
    }
    CGContextRelease(ctx);
    free(像素);
    return 纹理;
}

@implementation SLIconCache

+ (instancetype)共用 {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SLIconCache共用实例 = [SLIconCache new];
        SLIconCache共用实例.纹理表 = [NSMutableDictionary dictionary];
        SLIconCache共用实例.下载中 = [NSMutableSet set];
        SLIconCache共用实例.失败次数 = [NSMutableDictionary dictionary];
        SLIconCache共用实例.下次试 = [NSMutableDictionary dictionary];
    });
    return SLIconCache共用实例;
}

- (id)纹理:(NSString*)键 URL:(NSString*)URL {
    // 已有缓存直接返回
    id 已有 = self.纹理表[键];
    if (已有) return 已有;

    double now = CACurrentMediaTime();
    NSNumber* 等到 = self.下次试[键];
    if (等到 && now < [等到 doubleValue]) return nil;

    // 正在下载中 → 返回空（同帧/同局只发一次请求）
    __block BOOL 冲突 = NO;
    id 下载集合 = self.下载中;
    objc_sync_enter(下载集合);
    if ([self.下载中 containsObject:键]) {
        冲突 = YES;
    } else {
        [self.下载中 addObject:键];
    }
    objc_sync_exit(下载集合);
    if (冲突) return nil;

    NSURL* 地址 = [NSURL URLWithString:URL];
    if (!地址) {
        objc_sync_enter(下载集合);
        [self.下载中 removeObject:键];
        objc_sync_exit(下载集合);
        return nil;
    }

    __weak SLIconCache* 弱self = self;
    NSString* 键副本 = [键 copy];
    NSURLSession* 会话 = [NSURLSession sharedSession];
    NSURLSessionDataTask* 任务 = [会话 dataTaskWithURL:地址
        completionHandler:^(NSData* 数据, NSURLResponse* 响应, NSError* 错误) {
            (void)响应; (void)错误;
            SLIconCache* 强self = 弱self;
            if (!强self) return;
            // 结束下载标记
            id 下载集合 = 强self.下载中;
            objc_sync_enter(下载集合);
            [强self.下载中 removeObject:键副本];
            objc_sync_exit(下载集合);

            id 纹理 = 建纹理(数据);
            if (纹理) {
                // 成功：入表，清失败记录
                id 表 = 强self.纹理表;
                objc_sync_enter(表);
                强self.纹理表[键副本] = 纹理;
                [强self.失败次数 removeObjectForKey:键副本];
                [强self.下次试 removeObjectForKey:键副本];
                objc_sync_exit(表);
            } else {
                // 失败：计数 + 退避（≤3 次 2n 秒，4~8 次 10 秒，>8 次 60 秒）
                id 表 = 强self.纹理表;
                objc_sync_enter(表);
                NSInteger 次数 = [强self.失败次数[键副本] integerValue] + 1;
                强self.失败次数[键副本] = @(次数);
                NSTimeInterval 退避;
                if (次数 > 3)
                    退避 = 次数 <= 8 ? 10.0 : 60.0;
                else
                    退避 = 2.0 * (double)次数;
                强self.下次试[键副本] = @(CACurrentMediaTime() + 退避);
                objc_sync_exit(表);
            }
        }];
    [任务 resume];
    return nil;
}

- (id)英雄:(int)英雄ID {
    if (英雄ID <= 0) return nil;
    NSString* 键 = [NSString stringWithFormat:@"h%d", 英雄ID];
    NSString* URL = [NSString stringWithFormat:
        @"https://game.gtimg.cn/images/yxzj/img201606/heroimg/%d/%d.jpg",
        英雄ID, 英雄ID];
    return [self 纹理:键 URL:URL];
}

- (id)召唤师:(int)召唤ID {
    if (召唤ID <= 0) return nil;
    unsigned 映射后 = 召唤师ID重映射((unsigned)召唤ID);
    NSString* 键 = [NSString stringWithFormat:@"s%d", 映射后];
    NSString* URL = [NSString stringWithFormat:
        @"https://game.gtimg.cn/images/yxzj/img201606/summonero/%d.png",
        映射后];
    return [self 纹理:键 URL:URL];
}

@end
