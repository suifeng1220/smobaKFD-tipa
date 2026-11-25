//
//  SLIconCache.h - 英雄/召唤师图标缓存（S45 新增类）
//
//  从 AB_WZRY_S45重建版.tipa 的 Books 二进制还原
//  （类 SLIconCache，方法 纹理:URL: / 英雄: / 召唤师: / 共用）
//

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>

@interface SLIconCache : NSObject

// 单例
+ (instancetype)共用;

// 纹理缓存核心：键 -> MTLTexture（带下载中/失败退避/下次重试）
- (id)纹理:(NSString*)键 URL:(NSString*)URL;

// 英雄头像（键 "h%d"，URL game.gtimg.cn heroimg）
- (id)英雄:(int)英雄ID;

// 召唤师技能图标（键 "s%d"，URL summonero，含 ID 重映射）
- (id)召唤师:(int)召唤ID;

@property (nonatomic, retain) NSMutableDictionary* 纹理表;
@property (nonatomic, retain) NSMutableSet* 下载中;
@property (nonatomic, retain) NSMutableDictionary* 失败次数;
@property (nonatomic, retain) NSMutableDictionary* 下次试;

@end
