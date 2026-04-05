/// C helper for HEVC encode parameter submission + packed NAL header generation.
/// Zig can't import va_enc_hevc.h due to bitfield union issues in translate-c.
///
/// The Intel iHD HEVC EncSliceLP requires packed VPS/SPS/PPS NAL units
/// submitted as VAEncPackedHeaderSequence alongside the encode parameters.
/// Without them, the coded buffer is always 0 bytes.

#include <va/va.h>
#include <va/va_enc_hevc.h>
#include <string.h>
#include "hevc_params.h"

// ── Bitstream writer for HEVC NAL unit generation ───────────────────────

typedef struct {
    unsigned char *buf;
    int capacity;
    int byte_pos;
    int bit_pos; // bits remaining in current byte (8..1)
} BitstreamWriter;

static void bs_init(BitstreamWriter *bs, unsigned char *buf, int capacity) {
    bs->buf = buf;
    bs->capacity = capacity;
    bs->byte_pos = 0;
    bs->bit_pos = 8;
    if (capacity > 0) buf[0] = 0;
}

static void bs_write(BitstreamWriter *bs, int n, unsigned int val) {
    for (int i = n - 1; i >= 0; i--) {
        if (bs->byte_pos >= bs->capacity) return;
        bs->buf[bs->byte_pos] |= ((val >> i) & 1) << (bs->bit_pos - 1);
        bs->bit_pos--;
        if (bs->bit_pos == 0) {
            bs->bit_pos = 8;
            bs->byte_pos++;
            if (bs->byte_pos < bs->capacity) bs->buf[bs->byte_pos] = 0;
        }
    }
}

// Exp-Golomb unsigned
static void bs_write_ue(BitstreamWriter *bs, unsigned int val) {
    unsigned int v = val + 1;
    int bits = 0;
    unsigned int tmp = v;
    while (tmp > 0) { bits++; tmp >>= 1; }
    // Write (bits-1) zeros, then v in (bits) bits
    for (int i = 0; i < bits - 1; i++) bs_write(bs, 1, 0);
    bs_write(bs, bits, v);
}

// Exp-Golomb signed
static void bs_write_se(BitstreamWriter *bs, int val) {
    unsigned int mapped;
    if (val <= 0)
        mapped = (unsigned int)(-val) * 2;
    else
        mapped = (unsigned int)(val) * 2 - 1;
    bs_write_ue(bs, mapped);
}

static int bs_length_bytes(BitstreamWriter *bs) {
    return bs->bit_pos == 8 ? bs->byte_pos : bs->byte_pos + 1;
}

static int bs_length_bits(BitstreamWriter *bs) {
    return bs->byte_pos * 8 + (8 - bs->bit_pos);
}

// RBSP trailing bits
static void bs_trailing_bits(BitstreamWriter *bs) {
    bs_write(bs, 1, 1); // stop bit
    while (bs->bit_pos != 8) bs_write(bs, 1, 0); // align to byte
}

// ── NAL unit writers ────────────────────────────────────────────────────

// Write NAL unit header: forbidden_zero_bit(1) + nal_unit_type(6) + nuh_layer_id(6) + nuh_temporal_id_plus1(3)
static void write_nal_header(BitstreamWriter *bs, int nal_type) {
    bs_write(bs, 1, 0);       // forbidden_zero_bit
    bs_write(bs, 6, nal_type); // nal_unit_type
    bs_write(bs, 6, 0);       // nuh_layer_id
    bs_write(bs, 3, 1);       // nuh_temporal_id_plus1
}

// Profile tier level (simplified for Main profile, 8-bit, 4:2:0)
static void write_profile_tier_level(BitstreamWriter *bs, int level_idc) {
    bs_write(bs, 2, 0);  // general_profile_space
    bs_write(bs, 1, 0);  // general_tier_flag
    bs_write(bs, 5, 1);  // general_profile_idc (Main = 1)

    // general_profile_compatibility_flag[0..31]
    // Main profile: flag[1]=1, flag[2]=1 (compatible with Main Still)
    for (int i = 0; i < 32; i++) {
        bs_write(bs, 1, (i == 1 || i == 2) ? 1 : 0);
    }

    // general_constraint_flags (48 bits)
    bs_write(bs, 1, 1);  // progressive_source_flag
    bs_write(bs, 1, 0);  // interlaced_source_flag
    bs_write(bs, 1, 1);  // non_packed_constraint_flag
    bs_write(bs, 1, 1);  // frame_only_constraint_flag
    // remaining 44 constraint bits = 0
    for (int i = 0; i < 44; i++) bs_write(bs, 1, 0);

    bs_write(bs, 8, level_idc); // general_level_idc
}

static void write_vps(BitstreamWriter *bs, int level_idc, int fps) {
    write_nal_header(bs, 32); // VPS

    bs_write(bs, 4, 0);  // vps_video_parameter_set_id
    bs_write(bs, 1, 1);  // vps_base_layer_internal_flag
    bs_write(bs, 1, 1);  // vps_base_layer_available_flag
    bs_write(bs, 6, 0);  // vps_max_layers_minus1
    bs_write(bs, 3, 0);  // vps_max_sub_layers_minus1
    bs_write(bs, 1, 1);  // vps_temporal_id_nesting_flag
    bs_write(bs, 16, 0xFFFF); // vps_reserved_0xffff_16bits

    write_profile_tier_level(bs, level_idc);

    bs_write(bs, 1, 0);  // vps_sub_layer_ordering_info_present_flag
    bs_write_ue(bs, 2);  // vps_max_dec_pic_buffering_minus1[0] (= max_b_depth + 1 = 0 + 1 + 1 = 2 for safety)
    bs_write_ue(bs, 0);  // vps_max_num_reorder_pics[0]
    bs_write_ue(bs, 0);  // vps_max_latency_increase_plus1[0]
    bs_write(bs, 6, 0);  // vps_max_layer_id
    bs_write_ue(bs, 0);  // vps_num_layer_sets_minus1

    bs_write(bs, 1, 0);  // vps_timing_info_present_flag
    bs_write(bs, 1, 0);  // vps_extension_flag

    bs_trailing_bits(bs);
}

static void write_sps(BitstreamWriter *bs, unsigned int width, unsigned int height,
                       int level_idc, unsigned int idr_period) {
    write_nal_header(bs, 33); // SPS

    bs_write(bs, 4, 0);  // sps_video_parameter_set_id
    bs_write(bs, 3, 0);  // sps_max_sub_layers_minus1
    bs_write(bs, 1, 1);  // sps_temporal_id_nesting_flag

    write_profile_tier_level(bs, level_idc);

    int ctu_size = 64;
    unsigned int w_aligned = ((width + ctu_size - 1) / ctu_size) * ctu_size;
    unsigned int h_aligned = ((height + ctu_size - 1) / ctu_size) * ctu_size;

    bs_write_ue(bs, 0);  // sps_seq_parameter_set_id
    bs_write_ue(bs, 1);  // chroma_format_idc (4:2:0)
    bs_write_ue(bs, w_aligned);  // pic_width_in_luma_samples (CTU-aligned)
    bs_write_ue(bs, h_aligned);  // pic_height_in_luma_samples (CTU-aligned)

    // conformance_window_flag — crop back to actual dimensions
    int need_crop = (w_aligned != width) || (h_aligned != height);
    bs_write(bs, 1, need_crop);
    if (need_crop) {
        // Offsets in SubWidthC/SubHeightC units (=2 for 4:2:0)
        bs_write_ue(bs, 0);                            // conf_win_left_offset
        bs_write_ue(bs, (w_aligned - width) / 2);      // conf_win_right_offset
        bs_write_ue(bs, 0);                            // conf_win_top_offset
        bs_write_ue(bs, (h_aligned - height) / 2);     // conf_win_bottom_offset
    }

    bs_write_ue(bs, 0);  // bit_depth_luma_minus8
    bs_write_ue(bs, 0);  // bit_depth_chroma_minus8
    bs_write_ue(bs, 8);  // log2_max_pic_order_cnt_lsb_minus4 (=8, giving max POC LSB of 4096)

    // sub_layer_ordering_info
    bs_write(bs, 1, 0);  // sps_sub_layer_ordering_info_present_flag
    bs_write_ue(bs, 2);  // sps_max_dec_pic_buffering_minus1[0]
    bs_write_ue(bs, 0);  // sps_max_num_reorder_pics[0]
    bs_write_ue(bs, 0);  // sps_max_latency_increase_plus1[0]

    // Coding block sizes — matching ffmpeg's working config
    bs_write_ue(bs, 0);  // log2_min_luma_coding_block_size_minus3 (min CB = 8)
    bs_write_ue(bs, 3);  // log2_diff_max_min_luma_coding_block_size (CTU = 64)
    bs_write_ue(bs, 0);  // log2_min_luma_transform_block_size_minus2 (min TB = 4)
    bs_write_ue(bs, 3);  // log2_diff_max_min_luma_transform_block_size (max TB = 32)
    bs_write_ue(bs, 2);  // max_transform_hierarchy_depth_inter
    bs_write_ue(bs, 2);  // max_transform_hierarchy_depth_intra

    bs_write(bs, 1, 0);  // scaling_list_enabled_flag
    bs_write(bs, 1, 1);  // amp_enabled_flag
    bs_write(bs, 1, 1);  // sample_adaptive_offset_enabled_flag
    bs_write(bs, 1, 0);  // pcm_enabled_flag

    // Short-term reference picture sets — we use 0 sets (driver handles internally)
    bs_write_ue(bs, 0);  // num_short_term_ref_pic_sets

    bs_write(bs, 1, 0);  // long_term_ref_pics_present_flag
    bs_write(bs, 1, 1);  // sps_temporal_mvp_enabled_flag
    bs_write(bs, 1, 0);  // strong_intra_smoothing_enabled_flag

    bs_write(bs, 1, 0);  // vui_parameters_present_flag
    bs_write(bs, 1, 0);  // sps_extension_present_flag

    bs_trailing_bits(bs);
}

static void write_pps(BitstreamWriter *bs) {
    write_nal_header(bs, 34); // PPS

    bs_write_ue(bs, 0);  // pps_pic_parameter_set_id
    bs_write_ue(bs, 0);  // pps_seq_parameter_set_id
    bs_write(bs, 1, 0);  // dependent_slice_segments_enabled_flag
    bs_write(bs, 1, 0);  // output_flag_present_flag
    bs_write(bs, 3, 0);  // num_extra_slice_header_bits
    bs_write(bs, 1, 0);  // sign_data_hiding_enabled_flag
    bs_write(bs, 1, 0);  // cabac_init_present_flag
    bs_write_ue(bs, 0);  // num_ref_idx_l0_default_active_minus1
    bs_write_ue(bs, 0);  // num_ref_idx_l1_default_active_minus1
    // init_qp_minus26 = pic_init_qp - 26; with pic_init_qp=26, this is 0
    bs_write_ue(bs, 0);  // init_qp_minus26 (se, but 0 has same encoding as ue)
    bs_write(bs, 1, 0);  // constrained_intra_pred_flag
    bs_write(bs, 1, 1);  // transform_skip_enabled_flag
    bs_write(bs, 1, 0);  // cu_qp_delta_enabled_flag
    // no diff_cu_qp_delta_depth since cu_qp_delta_enabled_flag=0
    // pps_cb_qp_offset, pps_cr_qp_offset (se)
    bs_write_ue(bs, 0);  // pps_cb_qp_offset (se=0)
    bs_write_ue(bs, 0);  // pps_cr_qp_offset (se=0)
    bs_write(bs, 1, 0);  // pps_slice_chroma_qp_offsets_present_flag
    bs_write(bs, 1, 0);  // weighted_pred_flag
    bs_write(bs, 1, 0);  // weighted_bipred_flag
    bs_write(bs, 1, 0);  // transquant_bypass_enabled_flag
    bs_write(bs, 1, 0);  // tiles_enabled_flag
    bs_write(bs, 1, 0);  // entropy_coding_sync_enabled_flag
    // no tile/wpp params since both flags are 0
    bs_write(bs, 1, 1);  // pps_loop_filter_across_slices_enabled_flag
    bs_write(bs, 1, 0);  // deblocking_filter_control_present_flag
    bs_write(bs, 1, 0);  // pps_scaling_list_data_present_flag
    bs_write(bs, 1, 0);  // lists_modification_present_flag
    bs_write_ue(bs, 0);  // log2_parallel_merge_level_minus2
    bs_write(bs, 1, 0);  // slice_segment_header_extension_present_flag
    bs_write(bs, 1, 0);  // pps_extension_present_flag

    bs_trailing_bits(bs);
}

// Write a minimal HEVC slice segment header NAL unit.
// Must match the PPS/SPS settings above.
static void write_slice_header(BitstreamWriter *bs, unsigned int width, unsigned int height,
                                unsigned int poc, int is_idr, int slice_type) {
    // NAL unit type: IDR_W_RADL=19 for IDR, TRAIL_R=1 for P
    int nal_type = is_idr ? 19 : 1;
    write_nal_header(bs, nal_type);

    // first_slice_segment_in_pic_flag
    bs_write(bs, 1, 1);

    // no_output_of_prior_pics_flag (only for IDR/BLA/CRA)
    if (is_idr) {
        bs_write(bs, 1, 0);
    }

    // slice_pic_parameter_set_id
    bs_write_ue(bs, 0);

    // dependent_slice_segment_flag: not present (dependent_slice_segments_enabled_flag=0 in PPS)

    // slice_type: 2=I, 1=P, 0=B
    bs_write_ue(bs, slice_type);

    // For non-IDR frames: need POC and reference picture info
    if (!is_idr) {
        // pic_order_cnt_lsb — log2_max_pic_order_cnt_lsb_minus4=8, so 12 bits
        bs_write(bs, 12, poc & 0xFFF);

        // short_term_ref_pic_set_sps_flag=0 (since num_short_term_ref_pic_sets=0 in SPS)
        // We need to send an inline short-term RPS
        bs_write(bs, 1, 0);

        // Inline short_term_ref_pic_set:
        // num_negative_pics
        bs_write_ue(bs, 1);
        // num_positive_pics
        bs_write_ue(bs, 0);
        // delta_poc_s0_minus1[0] = 0 (delta_poc = -(0+1) = -1)
        bs_write_ue(bs, 0);
        // used_by_curr_pic_s0_flag[0] = 1
        bs_write(bs, 1, 1);

        // slice_temporal_mvp_enabled_flag (sps_temporal_mvp_enabled_flag=1)
        bs_write(bs, 1, 1);
    }

    // sample_adaptive_offset_enabled_flag=1 in SPS, so:
    // slice_sao_luma_flag
    bs_write(bs, 1, 1);
    // slice_sao_chroma_flag
    bs_write(bs, 1, 1);

    // For P/B frames: reference picture list modification
    if (!is_idr && slice_type != 2) {
        // num_ref_idx_active_override_flag = 0
        bs_write(bs, 1, 0);

        // For B-slice: collocated_from_l0_flag
        if (slice_type == 0) {
            bs_write(bs, 1, 1); // collocated_from_l0_flag = 1
        }

        // five_minus_max_num_merge_cand = 0 (max_num_merge_cand=5)
        bs_write_ue(bs, 0);
    } else if (is_idr) {
        // I-slice: five_minus_max_num_merge_cand
        bs_write_ue(bs, 0);
    }

    // slice_qp_delta (se) = 0
    bs_write_se(bs, 0);

    // deblocking_filter_control_present_flag=0 in PPS, so no deblocking params

    // pps_loop_filter_across_slices_enabled_flag=1, slice_sao used, so:
    // slice_loop_filter_across_slices_enabled_flag
    bs_write(bs, 1, 1);

    // byte_alignment()
    bs_write(bs, 1, 1); // alignment bit
    while (bs->bit_pos != 8) bs_write(bs, 1, 0);
}

// ── Public API ──────────────────────────────────────────────────────────

// Convert raw RBSP to NAL unit with start code and emulation prevention bytes.
// Input: raw NAL data (NAL header + RBSP)
// Output: [00 00 00 01] + NAL header + RBSP with 0x03 bytes inserted after 00 00
static int rbsp_to_nal(const unsigned char *rbsp, int rbsp_len,
                       unsigned char *nal, int nal_capacity) {
    int pos = 0;
    // Start code
    if (pos + 4 > nal_capacity) return -1;
    nal[pos++] = 0x00;
    nal[pos++] = 0x00;
    nal[pos++] = 0x00;
    nal[pos++] = 0x01;

    // Copy NAL header (2 bytes) without emulation prevention
    if (rbsp_len < 2) return -1;
    nal[pos++] = rbsp[0];
    nal[pos++] = rbsp[1];

    // Copy rest of RBSP with emulation prevention
    int zeros = 0;
    for (int i = 2; i < rbsp_len; i++) {
        if (zeros == 2 && rbsp[i] <= 3) {
            if (pos >= nal_capacity) return -1;
            nal[pos++] = 0x03; // emulation prevention byte
            zeros = 0;
        }
        if (pos >= nal_capacity) return -1;
        nal[pos++] = rbsp[i];
        if (rbsp[i] == 0) zeros++;
        else zeros = 0;
    }
    return pos;
}

int vaapi_generate_packed_headers(
    unsigned int width, unsigned int height,
    unsigned int fps, unsigned int idr_period,
    unsigned char *vps_buf, int vps_capacity, int *vps_size,
    unsigned char *sps_buf, int sps_capacity, int *sps_size,
    unsigned char *pps_buf, int pps_capacity, int *pps_size)
{
    unsigned char tmp[256];
    BitstreamWriter bs;

    bs_init(&bs, tmp, sizeof(tmp));
    write_vps(&bs, 120, fps);
    *vps_size = rbsp_to_nal(tmp, bs_length_bytes(&bs), vps_buf, vps_capacity);

    bs_init(&bs, tmp, sizeof(tmp));
    write_sps(&bs, width, height, 120, idr_period);
    *sps_size = rbsp_to_nal(tmp, bs_length_bytes(&bs), sps_buf, sps_capacity);

    bs_init(&bs, tmp, sizeof(tmp));
    write_pps(&bs);
    *pps_size = rbsp_to_nal(tmp, bs_length_bytes(&bs), pps_buf, pps_capacity);

    return 0;
}

int vaapi_generate_packed_slice_header(
    unsigned int width, unsigned int height,
    unsigned int poc, int is_idr,
    unsigned char *buf, int capacity, int *out_size)
{
    unsigned char tmp[256];
    BitstreamWriter bs;
    bs_init(&bs, tmp, sizeof(tmp));
    int slice_type = is_idr ? 2 : 0; // I=2, B=0 (GPB for Intel EncSliceLP)
    write_slice_header(&bs, width, height, poc, is_idr, slice_type);
    *out_size = rbsp_to_nal(tmp, bs_length_bytes(&bs), buf, capacity);
    return 0;
}

VAStatus vaapi_submit_packed_header(
    VADisplay display, VAContextID context,
    int header_type,
    unsigned char *data, int size_bytes)
{
    VAEncPackedHeaderParameterBuffer param;
    memset(&param, 0, sizeof(param));
    param.type = header_type;
    param.bit_length = size_bytes * 8;
    param.has_emulation_bytes = 1;

    VABufferID param_buf, data_buf;
    VAStatus st;

    st = vaCreateBuffer(display, context, VAEncPackedHeaderParameterBufferType,
                        sizeof(param), 1, &param, &param_buf);
    if (st != VA_STATUS_SUCCESS) return st;

    st = vaCreateBuffer(display, context, VAEncPackedHeaderDataBufferType,
                        size_bytes, 1, data, &data_buf);
    if (st != VA_STATUS_SUCCESS) return st;

    VABufferID bufs[2] = { param_buf, data_buf };
    return vaRenderPicture(display, context, bufs, 2);
}

// ── Encode parameter submission (unchanged API, updated to match ffmpeg) ─

VAStatus vaapi_submit_hevc_seq(
    VADisplay display, VAContextID context,
    unsigned int width, unsigned int height, unsigned int fps,
    unsigned int bitrate, unsigned int idr_period)
{
    VAEncSequenceParameterBufferHEVC seq;
    memset(&seq, 0, sizeof(seq));

    seq.general_profile_idc = 1;
    seq.general_level_idc = 120;
    seq.intra_period = idr_period;
    seq.intra_idr_period = idr_period;
    seq.ip_period = 1;
    seq.bits_per_second = bitrate;
    seq.pic_width_in_luma_samples = width;
    seq.pic_height_in_luma_samples = height;
    seq.seq_fields.bits.chroma_format_idc = 1;
    seq.seq_fields.bits.amp_enabled_flag = 1;
    seq.seq_fields.bits.sample_adaptive_offset_enabled_flag = 1;
    seq.seq_fields.bits.sps_temporal_mvp_enabled_flag = 1;
    seq.log2_min_luma_coding_block_size_minus3 = 0;
    seq.log2_diff_max_min_luma_coding_block_size = 3;
    seq.log2_min_transform_block_size_minus2 = 0;
    seq.log2_diff_max_min_transform_block_size = 3;
    seq.max_transform_hierarchy_depth_inter = 2;
    seq.max_transform_hierarchy_depth_intra = 2;

    VABufferID buf;
    VAStatus st = vaCreateBuffer(display, context, VAEncSequenceParameterBufferType,
                                  sizeof(seq), 1, &seq, &buf);
    if (st != VA_STATUS_SUCCESS) return st;
    return vaRenderPicture(display, context, &buf, 1);
}

VAStatus vaapi_submit_hevc_pic(
    VADisplay display, VAContextID context,
    VASurfaceID recon_surface, VASurfaceID ref_surface,
    VABufferID coded_buf,
    unsigned int pic_order_cnt, int is_idr)
{
    VAEncPictureParameterBufferHEVC pic;
    memset(&pic, 0, sizeof(pic));

    pic.decoded_curr_pic.picture_id = recon_surface;
    pic.decoded_curr_pic.pic_order_cnt = pic_order_cnt;
    pic.coded_buf = coded_buf;
    pic.collocated_ref_pic_index = is_idr ? 0xFF : 0;
    pic.pic_init_qp = 26;
    pic.nal_unit_type = is_idr ? 19 : 1;

    pic.pic_fields.bits.idr_pic_flag = is_idr ? 1 : 0;
    pic.pic_fields.bits.coding_type = is_idr ? 1 : 2;
    pic.pic_fields.bits.reference_pic_flag = 1;
    pic.pic_fields.bits.transform_skip_enabled_flag = 1;
    pic.pic_fields.bits.pps_loop_filter_across_slices_enabled_flag = 1;

    for (int i = 0; i < 15; i++) {
        pic.reference_frames[i].picture_id = VA_INVALID_SURFACE;
        pic.reference_frames[i].flags = VA_PICTURE_HEVC_INVALID;
    }

    if (!is_idr) {
        pic.reference_frames[0].picture_id = ref_surface;
        pic.reference_frames[0].pic_order_cnt = (pic_order_cnt > 0) ? pic_order_cnt - 1 : 0;
        pic.reference_frames[0].flags = VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE;
    }

    VABufferID buf;
    VAStatus st = vaCreateBuffer(display, context, VAEncPictureParameterBufferType,
                                  sizeof(pic), 1, &pic, &buf);
    if (st != VA_STATUS_SUCCESS) return st;
    return vaRenderPicture(display, context, &buf, 1);
}

VAStatus vaapi_submit_hevc_slice(
    VADisplay display, VAContextID context,
    VASurfaceID ref_surface, unsigned int ref_poc,
    unsigned int width, unsigned int height, int is_idr)
{
    VAEncSliceParameterBufferHEVC slice;
    memset(&slice, 0, sizeof(slice));

    unsigned int ctu_size = 64;
    slice.num_ctu_in_slice = ((width + ctu_size - 1) / ctu_size) * ((height + ctu_size - 1) / ctu_size);
    // GPB: Intel EncSliceLP requires B-slices (not P-slices) for non-IDR frames.
    // "Generalized P to B" — both L0 and L1 reference the same picture.
    slice.slice_type = is_idr ? 2 : 0; // I=2, B=0 (not P=1!)
    slice.max_num_merge_cand = 5;
    slice.slice_fields.bits.last_slice_of_pic_flag = 1;
    slice.slice_fields.bits.slice_sao_luma_flag = 1;
    slice.slice_fields.bits.slice_sao_chroma_flag = 1;

    for (int i = 0; i < 15; i++) {
        slice.ref_pic_list0[i].picture_id = VA_INVALID_SURFACE;
        slice.ref_pic_list0[i].flags = VA_PICTURE_HEVC_INVALID;
        slice.ref_pic_list1[i].picture_id = VA_INVALID_SURFACE;
        slice.ref_pic_list1[i].flags = VA_PICTURE_HEVC_INVALID;
    }

    if (!is_idr) {
        // GPB: L0 and L1 both reference the same picture
        slice.ref_pic_list0[0].picture_id = ref_surface;
        slice.ref_pic_list0[0].pic_order_cnt = ref_poc;
        slice.ref_pic_list0[0].flags = VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE;
        slice.ref_pic_list1[0].picture_id = ref_surface;
        slice.ref_pic_list1[0].pic_order_cnt = ref_poc;
        slice.ref_pic_list1[0].flags = VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE;
        slice.num_ref_idx_l0_active_minus1 = 0;
        slice.num_ref_idx_l1_active_minus1 = 0;
    }

    VABufferID buf;
    VAStatus st = vaCreateBuffer(display, context, VAEncSliceParameterBufferType,
                                  sizeof(slice), 1, &slice, &buf);
    if (st != VA_STATUS_SUCCESS) return st;
    return vaRenderPicture(display, context, &buf, 1);
}

VAStatus vaapi_submit_frame_rate(VADisplay display, VAContextID context, unsigned int fps) {
    unsigned char buf[sizeof(VAEncMiscParameterBuffer) + sizeof(VAEncMiscParameterFrameRate)];
    memset(buf, 0, sizeof(buf));
    ((VAEncMiscParameterBuffer *)buf)->type = VAEncMiscParameterTypeFrameRate;
    ((VAEncMiscParameterFrameRate *)(buf + sizeof(VAEncMiscParameterBuffer)))->framerate = (1 << 16) | fps;
    VABufferID id;
    VAStatus st = vaCreateBuffer(display, context, VAEncMiscParameterBufferType, sizeof(buf), 1, buf, &id);
    if (st != VA_STATUS_SUCCESS) return st;
    return vaRenderPicture(display, context, &id, 1);
}
