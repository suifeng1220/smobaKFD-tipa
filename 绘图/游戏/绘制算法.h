//
//  绘制算法.h - 无畏契约坐标转换算法
//

#ifndef 绘制算法_h
#define 绘制算法_h

#include "绘制类型.h"
#include "SDK.h"

// 指针解密
static uintptr_t Decrypt_PTR(uintptr_t addr) {
    if (!IsValidAddr(addr)) return 0;
    uintptr_t result = 0;
    for(int i = 0; i < 8; i++) {
        int Offset = vm_read<int>(addr + 0x80 + i * 4);
        if (Offset == 0) return 0;
        uint8_t ByteValue = vm_read<uint8_t>(addr + Offset);
        result |= static_cast<uintptr_t>(ByteValue & 0xFF) << (i * 8);
    }
    if (!IsValidAddr(result)) return 0;
    return vm_read<uintptr_t>(result);
}

static float Dot(Vector3 lhs, Vector3 rhs) {
    return lhs.X * rhs.X + lhs.Y * rhs.Y + lhs.Z * rhs.Z;
}

static float GetDistance(Vector3 a, Vector3 b) {
    Vector3 v = a - b;
    return sqrt(v.X * v.X + v.Y * v.Y + v.Z * v.Z);
}

static FMatrix RotatorToMatrix(FRotator rotation) {
    float radPitch = rotation.Pitch * (M_PI / 180.0f);
    float radYaw = rotation.Yaw * (M_PI / 180.0f);
    float radRoll = rotation.Roll * (M_PI / 180.0f);
    float SP = sinf(radPitch), CP = cosf(radPitch);
    float SY = sinf(radYaw), CY = cosf(radYaw);
    float SR = sinf(radRoll), CR = cosf(radRoll);
    FMatrix matrix;
    matrix[0][0] = CP * CY; matrix[0][1] = CP * SY; matrix[0][2] = SP; matrix[0][3] = 0;
    matrix[1][0] = SR*SP*CY - CR*SY; matrix[1][1] = SR*SP*SY + CR*CY; matrix[1][2] = -SR*CP; matrix[1][3] = 0;
    matrix[2][0] = -(CR*SP*CY + SR*SY); matrix[2][1] = CY*SR - CR*SP*SY; matrix[2][2] = CR*CP; matrix[2][3] = 0;
    matrix[3][0] = 0; matrix[3][1] = 0; matrix[3][2] = 0; matrix[3][3] = 1;
    return matrix;
}

static Vector2 WorldToScreen(Vector3 worldLocation, CoViewInfo camViewInfo, int width, int height) {
    float fovRadian = camViewInfo.FOV * (M_PI / 360.0f);
    float tanFov = tanf(fovRadian);
    if (tanFov == 0) tanFov = 0.001f;  // 防止除0
    float screenCenterX = width / 2.0f;
    float screenCenterY = height / 2.0f;
    FMatrix tempMatrix = RotatorToMatrix(camViewInfo.Rotation);
    Vector3 vAxisX(tempMatrix[0][0], tempMatrix[0][1], tempMatrix[0][2]);
    Vector3 vAxisY(tempMatrix[1][0], tempMatrix[1][1], tempMatrix[1][2]);
    Vector3 vAxisZ(tempMatrix[2][0], tempMatrix[2][1], tempMatrix[2][2]);
    Vector3 vDelta = worldLocation - camViewInfo.Location;
    float transformedX = Dot(vDelta, vAxisY);
    float transformedY = Dot(vDelta, vAxisZ);
    float transformedZ = Dot(vDelta, vAxisX);
    if (transformedZ < 1.0f) transformedZ = 1.0f;
    return Vector2(screenCenterX + transformedX * (screenCenterX / tanFov) / transformedZ,
                   screenCenterY - transformedY * (screenCenterX / tanFov) / transformedZ);
}

static void BoxConversion(Vector3 worldLocation, VectorRect *rect, CoViewInfo camViewInfo, Vector2 canvasSize) {
    Vector3 worldLocation2 = worldLocation;
    worldLocation2.Z += 90.f;
    Vector2 calculate = WorldToScreen(worldLocation, camViewInfo, canvasSize.X, canvasSize.Y);
    Vector2 calculate2 = WorldToScreen(worldLocation2, camViewInfo, canvasSize.X, canvasSize.Y);
    rect->h = calculate.Y - calculate2.Y;
    rect->w = rect->h / 2.5;
    rect->x = calculate.X - rect->w;
    rect->y = calculate2.Y;
    rect->w = rect->w * 2;
    rect->h = rect->h * 2;
}

static Vector3 GetRelativeLocation(long actor) {
    if (!IsValidAddr(actor)) return Vector3();
    long root = vm_read<long>(actor + SDK::RootComponent);
    if (!IsValidAddr(root)) return Vector3();
    return vm_read<Vector3>(root + SDK::RelativeLocation);
}

static string GetPlayerName(long player) {
    string n = "";
    if (!IsValidAddr(player)) return n;
    long PlayerName = vm_read<long>(player + SDK::PlayerName);
    if (!IsValidAddr(PlayerName)) return n;
    char16_t utf16Buf[32] = {0};
    int len = 0;
    for (int i = 0; i < 31; i++) {
        char16_t ch = vm_read<char16_t>(PlayerName + i * 2);
        if (!ch) break;
        utf16Buf[i] = ch;
        len++;
    }
    if (len == 0) return n;
    NSString *str = [[NSString alloc] initWithBytes:utf16Buf length:len*2 encoding:NSUTF16LittleEndianStringEncoding];
    if (str) n = [str UTF8String];
    return n;
}

#endif
