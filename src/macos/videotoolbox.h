// C API for VideoToolbox HEVC encoder (implementation in videotoolbox.m)
#ifndef ZEROCAST_VIDEOTOOLBOX_H
#define ZEROCAST_VIDEOTOOLBOX_H

#include <stdint.h>
#include <stddef.h>

typedef struct VTEncoder VTEncoder;

VTEncoder *vt_encoder_create(uint32_t width, uint32_t height, uint32_t fps);
int vt_encoder_encode(VTEncoder *enc, void *pixelBuffer, int force_keyframe);
const uint8_t *vt_encoder_get_output(VTEncoder *enc, size_t *out_len, int *out_is_key);
void vt_encoder_destroy(VTEncoder *enc);
void vt_encoder_cleanup_globals(void);

#endif
