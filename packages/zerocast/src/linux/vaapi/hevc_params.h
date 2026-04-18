#pragma once
#include <va/va.h>

/// Generate packed VPS/SPS/PPS NAL units for HEVC encode.
/// These must be submitted as VAEncPackedHeaderSequence on every IDR frame.
/// Returns 0 on success.
int vaapi_generate_packed_headers(
    unsigned int width, unsigned int height,
    unsigned int fps, unsigned int idr_period,
    unsigned char *vps_buf, int vps_capacity, int *vps_size,
    unsigned char *sps_buf, int sps_capacity, int *sps_size,
    unsigned char *pps_buf, int pps_capacity, int *pps_size);

/// Generate a packed HEVC slice segment header NAL unit.
int vaapi_generate_packed_slice_header(
    unsigned int width, unsigned int height,
    unsigned int poc, unsigned int ref_poc, int is_idr,
    unsigned char *buf, int capacity, int *out_size);

/// Submit a packed header (VPS/SPS/PPS NAL unit) to the encoder.
VAStatus vaapi_submit_packed_header(
    VADisplay display, VAContextID context,
    int header_type,
    unsigned char *data, int size_bytes);

/// Submit HEVC sequence parameters (SPS). Call on IDR frames.
VAStatus vaapi_submit_hevc_seq(
    VADisplay display, VAContextID context,
    unsigned int width, unsigned int height, unsigned int fps,
    unsigned int bitrate, unsigned int idr_period);

/// Submit frame rate misc parameter. Call on IDR frames.
VAStatus vaapi_submit_frame_rate(
    VADisplay display, VAContextID context, unsigned int fps);

/// Submit HEVC picture parameters (PPS). Call every frame.
VAStatus vaapi_submit_hevc_pic(
    VADisplay display, VAContextID context,
    VASurfaceID recon_surface, VASurfaceID ref_surface,
    VABufferID coded_buf,
    unsigned int pic_order_cnt, unsigned int ref_poc, int is_idr);

/// Submit HEVC slice parameters. Call every frame.
VAStatus vaapi_submit_hevc_slice(
    VADisplay display, VAContextID context,
    VASurfaceID ref_surface, unsigned int ref_poc,
    unsigned int width, unsigned int height, int is_idr);
