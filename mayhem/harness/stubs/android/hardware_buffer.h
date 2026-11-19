/* Host stub of the NDK <android/hardware_buffer.h>: only the types lorie's headers name. */
#pragma once
#include <stdint.h>
typedef struct AHardwareBuffer AHardwareBuffer;
typedef struct AHardwareBuffer_Desc {
    uint32_t width, height, layers, format;
    uint64_t usage;
    uint32_t stride, rfu0;
    uint64_t rfu1;
} AHardwareBuffer_Desc;
typedef struct ARect { int32_t left, top, right, bottom; } ARect;
