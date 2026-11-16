//
//  绘制类型.h - 无畏契约数据结构
//

#ifndef 绘制类型_h
#define 绘制类型_h

struct Vector2 {
    float X, Y;
    Vector2() : X(0), Y(0) {}
    Vector2(float x, float y) : X(x), Y(y) {}
};

struct Vector3 {
    float X, Y, Z;
    Vector3() : X(0), Y(0), Z(0) {}
    Vector3(float x, float y, float z) : X(x), Y(y), Z(z) {}
    Vector3 operator-(const Vector3 &v) const { return Vector3(X - v.X, Y - v.Y, Z - v.Z); }
};

struct Vector4 { float x, y, z, w; };
struct VectorRect { int x, y, w, h; };
struct FRotator { float Pitch, Yaw, Roll; };

struct CoViewInfo {
    Vector3 Location;
    Vector3 LocationLocalSpace;
    FRotator Rotation;
    float FOV;
};

struct FMatrix {
    float Matrix[4][4];
    float *operator[](int index) { return Matrix[index]; }
};

struct D3DXMATRIX {
    float _11, _12, _13, _14;
    float _21, _22, _23, _24;
    float _31, _32, _33, _34;
    float _41, _42, _43, _44;
};

struct FTransform {
    Vector4 rot;
    Vector3 translation;
    Vector3 scale;
    D3DXMATRIX ToMatrixWithScale() {
        D3DXMATRIX m;
        m._41 = translation.X; m._42 = translation.Y; m._43 = translation.Z;
        float x2 = rot.x + rot.x, y2 = rot.y + rot.y, z2 = rot.z + rot.z;
        float xx2 = rot.x * x2, yy2 = rot.y * y2, zz2 = rot.z * z2;
        m._11 = (1.0f - (yy2 + zz2)) * scale.X;
        m._22 = (1.0f - (xx2 + zz2)) * scale.Y;
        m._33 = (1.0f - (xx2 + yy2)) * scale.Z;
        float yz2 = rot.y * z2, wx2 = rot.w * x2;
        m._32 = (yz2 - wx2) * scale.Z; m._23 = (yz2 + wx2) * scale.Y;
        float xy2 = rot.x * y2, wz2 = rot.w * z2;
        m._21 = (xy2 - wz2) * scale.Y; m._12 = (xy2 + wz2) * scale.X;
        float xz2 = rot.x * z2, wy2 = rot.w * y2;
        m._31 = (xz2 + wy2) * scale.Z; m._13 = (xz2 - wy2) * scale.X;
        m._14 = 0; m._24 = 0; m._34 = 0; m._44 = 1;
        return m;
    }
    static D3DXMATRIX MatrixMultiplication(D3DXMATRIX pM1, D3DXMATRIX pM2) {
        D3DXMATRIX pOut;
        pOut._11 = pM1._11*pM2._11 + pM1._12*pM2._21 + pM1._13*pM2._31 + pM1._14*pM2._41;
        pOut._12 = pM1._11*pM2._12 + pM1._12*pM2._22 + pM1._13*pM2._32 + pM1._14*pM2._42;
        pOut._13 = pM1._11*pM2._13 + pM1._12*pM2._23 + pM1._13*pM2._33 + pM1._14*pM2._43;
        pOut._14 = pM1._11*pM2._14 + pM1._12*pM2._24 + pM1._13*pM2._34 + pM1._14*pM2._44;
        pOut._21 = pM1._21*pM2._11 + pM1._22*pM2._21 + pM1._23*pM2._31 + pM1._24*pM2._41;
        pOut._22 = pM1._21*pM2._12 + pM1._22*pM2._22 + pM1._23*pM2._32 + pM1._24*pM2._42;
        pOut._23 = pM1._21*pM2._13 + pM1._22*pM2._23 + pM1._23*pM2._33 + pM1._24*pM2._43;
        pOut._24 = pM1._21*pM2._14 + pM1._22*pM2._24 + pM1._23*pM2._34 + pM1._24*pM2._44;
        pOut._31 = pM1._31*pM2._11 + pM1._32*pM2._21 + pM1._33*pM2._31 + pM1._34*pM2._41;
        pOut._32 = pM1._31*pM2._12 + pM1._32*pM2._22 + pM1._33*pM2._32 + pM1._34*pM2._42;
        pOut._33 = pM1._31*pM2._13 + pM1._32*pM2._23 + pM1._33*pM2._33 + pM1._34*pM2._43;
        pOut._34 = pM1._31*pM2._14 + pM1._32*pM2._24 + pM1._33*pM2._34 + pM1._34*pM2._44;
        pOut._41 = pM1._41*pM2._11 + pM1._42*pM2._21 + pM1._43*pM2._31 + pM1._44*pM2._41;
        pOut._42 = pM1._41*pM2._12 + pM1._42*pM2._22 + pM1._43*pM2._32 + pM1._44*pM2._42;
        pOut._43 = pM1._41*pM2._13 + pM1._42*pM2._23 + pM1._43*pM2._33 + pM1._44*pM2._43;
        pOut._44 = pM1._41*pM2._14 + pM1._42*pM2._24 + pM1._43*pM2._34 + pM1._44*pM2._44;
        return pOut;
    }
};

#endif
