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

    bs_write_ue(bs, 0);  // sps_seq_parameter_set_id
    bs_write_ue(bs, 1);  // chroma_format_idc (4:2:0)
    bs_write_ue(bs, width);  // pic_width_in_luma_samples
    bs_write_ue(bs, height); // pic_height_in_luma_samples

    // conformance_window_flag — needed if dimensions not CTU-aligned
    int ctu_size = 64;
    int need_crop = (width % ctu_size != 0) || (height % ctu_size != 0);
    bs_write(bs, 1, need_crop);
    if (need_crop) {
        int w_aligned = ((width + ctu_size - 1) / ctu_size) * ctu_size;
        int h_aligned = ((height + ctu_size - 1) / ctu_size) * ctu_size;
        bs_write_ue(bs, 0);                        // conf_win_left_offset
        bs_write_ue(bs, (w_aligned - width) / 2);  // conf_win_right_offset (in chroma units)
        bs_write_ue(bs, 0);                        // conf_win_top_offset
        bs_write_ue(bs, (h_aligned - height) / 2); // conf_win_bottom_offset
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

// ── Public API ──────────────────────────────────────────────────────────

int vaapi_generate_packed_headers(
    unsigned int width, unsigned int height,
    unsigned int fps, unsigned int idr_period,
    unsigned char *vps_buf, int vps_capacity, int *vps_size,
    unsigned char *sps_buf, int sps_capacity, int *sps_size,
    unsigned char *pps_buf, int pps_capacity, int *pps_size)
{
    BitstreamWriter bs;

    bs_init(&bs, vps_buf, vps_capacity);
    write_vps(&bs, 120, fps);
    *vps_size = bs_length_bytes(&bs);

    bs_init(&bs, sps_buf, sps_capacity);
    write_sps(&bs, width, height, 120, idr_period);
    *sps_size = bs_length_bytes(&bs);

    bs_init(&bs, pps_buf, pps_capacity);
    write_pps(&bs);
    *pps_size = bs_length_bytes(&bs);

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
    slice.slice_type = is_idr ? 2 : 1;
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
        slice.ref_pic_list0[0].picture_id = ref_surface;
        slice.ref_pic_list0[0].pic_order_cnt = ref_poc;
        slice.ref_pic_list0[0].flags = VA_PICTURE_HEVC_RPS_ST_CURR_BEFORE;
        slice.num_ref_idx_l0_active_minus1 = 0;
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
