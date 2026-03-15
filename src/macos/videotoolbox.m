// VideoToolbox HEVC encoder — ObjC wrapper exposing a C API to Zig.
// Encodes raw pixel buffers (CVPixelBuffer) to HEVC using hardware acceleration.

#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <stdint.h>
#import <string.h>

// ── Callback output buffer ──────────────────────────────────────────────

// The encoded output is written here by the compression callback.
// Single-threaded: only one frame in flight at a time.
static uint8_t *g_output_buf = NULL;
static size_t   g_output_len = 0;
static size_t   g_output_cap = 0;
static int      g_output_is_key = 0;

// ── Compression callback ────────────────────────────────────────────────

static void compressionCallback(
    void *outputCallbackRefCon,
    void *sourceFrameRefCon,
    OSStatus status,
    VTEncodeInfoFlags infoFlags,
    CMSampleBufferRef sampleBuffer
) {
    (void)outputCallbackRefCon;
    (void)sourceFrameRefCon;
    (void)infoFlags;

    if (status != noErr || sampleBuffer == NULL) {
        g_output_len = 0;
        return;
    }

    // Check if keyframe
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    g_output_is_key = 0;
    if (attachments && CFArrayGetCount(attachments) > 0) {
        CFDictionaryRef dict = CFArrayGetValueAtIndex(attachments, 0);
        CFBooleanRef notSync = CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync);
        if (notSync == NULL || !CFBooleanGetValue(notSync)) {
            g_output_is_key = 1;
        }
    }

    // Get the data buffer
    CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer);
    if (blockBuffer == NULL) {
        g_output_len = 0;
        return;
    }

    size_t totalLen = 0;
    char *dataPtr = NULL;
    OSStatus err = CMBlockBufferGetDataPointer(blockBuffer, 0, NULL, &totalLen, &dataPtr);
    if (err != noErr || dataPtr == NULL) {
        g_output_len = 0;
        return;
    }

    // Convert AVCC (length-prefixed NALUs) to Annex B (start-code-prefixed NALUs).
    // VideoToolbox outputs AVCC format; we need Annex B for raw .hevc files and
    // for libdatachannel's H.265 packetizer.
    //
    // Also prepend VPS/SPS/PPS from the format description on keyframes.

    // Ensure output buffer is large enough (NALUs + start codes + parameter sets)
    size_t needed = totalLen + 1024; // generous headroom for start codes + params
    if (needed > g_output_cap) {
        uint8_t *newBuf = realloc(g_output_buf, needed);
        if (!newBuf) { g_output_len = 0; return; }
        g_output_buf = newBuf;
        g_output_cap = needed;
    }

    size_t outPos = 0;
    static const uint8_t startCode[] = {0x00, 0x00, 0x00, 0x01};

    // On keyframes, prepend parameter sets (VPS, SPS, PPS)
    if (g_output_is_key) {
        CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);
        if (fmt) {
            size_t paramCount = 0;
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, 0, NULL, NULL, &paramCount, NULL);
            for (size_t i = 0; i < paramCount; i++) {
                const uint8_t *paramBuf = NULL;
                size_t paramLen = 0;
                err = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmt, i, &paramBuf, &paramLen, NULL, NULL);
                if (err == noErr && paramBuf && paramLen > 0) {
                    memcpy(g_output_buf + outPos, startCode, 4);
                    outPos += 4;
                    memcpy(g_output_buf + outPos, paramBuf, paramLen);
                    outPos += paramLen;
                }
            }
        }
    }

    // Convert each AVCC NALU to Annex B
    size_t srcPos = 0;
    while (srcPos + 4 <= totalLen) {
        // Read 4-byte big-endian length prefix
        uint32_t naluLen = ((uint32_t)(uint8_t)dataPtr[srcPos] << 24)
                         | ((uint32_t)(uint8_t)dataPtr[srcPos+1] << 16)
                         | ((uint32_t)(uint8_t)dataPtr[srcPos+2] << 8)
                         | ((uint32_t)(uint8_t)dataPtr[srcPos+3]);
        srcPos += 4;

        if (naluLen == 0 || srcPos + naluLen > totalLen) break;

        // Ensure capacity
        if (outPos + 4 + naluLen > g_output_cap) {
            size_t newCap = outPos + 4 + naluLen + 4096;
            uint8_t *newBuf = realloc(g_output_buf, newCap);
            if (!newBuf) { g_output_len = 0; return; }
            g_output_buf = newBuf;
            g_output_cap = newCap;
        }

        memcpy(g_output_buf + outPos, startCode, 4);
        outPos += 4;
        memcpy(g_output_buf + outPos, dataPtr + srcPos, naluLen);
        outPos += naluLen;
        srcPos += naluLen;
    }

    g_output_len = outPos;
}

// ── Public C API ────────────────────────────────────────────────────────

typedef struct {
    VTCompressionSessionRef session;
    int64_t frame_idx;
    uint32_t width;
    uint32_t height;
} VTEncoder;

VTEncoder *vt_encoder_create(uint32_t width, uint32_t height, uint32_t fps) {
    VTEncoder *enc = calloc(1, sizeof(VTEncoder));
    if (!enc) return NULL;

    enc->width = width;
    enc->height = height;

    OSStatus status = VTCompressionSessionCreate(
        NULL,                                       // allocator
        (int32_t)width,
        (int32_t)height,
        kCMVideoCodecType_HEVC,
        NULL,                                       // encoderSpecification (use default HW)
        NULL,                                       // sourceImageBufferAttributes
        NULL,                                       // compressedDataAllocator
        compressionCallback,
        NULL,                                       // outputCallbackRefCon
        &enc->session
    );

    if (status != noErr) {
        free(enc);
        return NULL;
    }

    // Configure for low-latency screen sharing
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_HEVC_Main_AutoLevel);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse);

    // Target bitrate: ~4 Mbps for 1080p, scale proportionally
    int64_t bitrate = (int64_t)width * height * 2; // ~2 bits/pixel
    if (bitrate < 1000000) bitrate = 1000000;
    CFNumberRef bitrateRef = CFNumberCreate(NULL, kCFNumberSInt64Type, &bitrate);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_AverageBitRate, bitrateRef);
    CFRelease(bitrateRef);

    // Max keyframe interval (seconds)
    int32_t maxKeyInterval = (int32_t)fps * 2;
    CFNumberRef maxKeyRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &maxKeyInterval);
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_MaxKeyFrameInterval, maxKeyRef);
    CFRelease(maxKeyRef);

    // Expected frame rate
    CFNumberRef fpsRef = CFNumberCreate(NULL, kCFNumberSInt32Type, &(int32_t){(int32_t)fps});
    VTSessionSetProperty(enc->session, kVTCompressionPropertyKey_ExpectedFrameRate, fpsRef);
    CFRelease(fpsRef);

    VTCompressionSessionPrepareToEncodeFrames(enc->session);

    return enc;
}

/// Encode a CVPixelBufferRef. Returns 0 on success, non-zero on error.
/// After success, call vt_encoder_get_output() to retrieve the encoded data.
int vt_encoder_encode(VTEncoder *enc, void *pixelBuffer, int force_keyframe) {
    if (!enc || !enc->session || !pixelBuffer) return -1;

    CVPixelBufferRef pb = (CVPixelBufferRef)pixelBuffer;

    CMTime pts = CMTimeMake(enc->frame_idx, 90000); // 90kHz timebase

    CFDictionaryRef frameProps = NULL;
    if (force_keyframe) {
        CFStringRef keys[] = { kVTEncodeFrameOptionKey_ForceKeyFrame };
        CFTypeRef values[] = { kCFBooleanTrue };
        frameProps = CFDictionaryCreate(NULL,
            (const void **)keys, (const void **)values, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }

    g_output_len = 0;

    OSStatus status = VTCompressionSessionEncodeFrame(
        enc->session,
        pb,
        pts,
        kCMTimeInvalid, // duration
        frameProps,
        NULL,           // sourceFrameRefCon
        NULL            // infoFlagsOut
    );

    if (frameProps) CFRelease(frameProps);

    if (status != noErr) return (int)status;

    // Force synchronous completion
    VTCompressionSessionCompleteFrames(enc->session, kCMTimeInvalid);

    enc->frame_idx++;
    return 0;
}

/// Get pointer to the last encoded frame's Annex B data.
const uint8_t *vt_encoder_get_output(VTEncoder *enc, size_t *out_len, int *out_is_key) {
    (void)enc;
    if (out_len) *out_len = g_output_len;
    if (out_is_key) *out_is_key = g_output_is_key;
    return g_output_buf;
}

void vt_encoder_destroy(VTEncoder *enc) {
    if (!enc) return;
    if (enc->session) {
        VTCompressionSessionInvalidate(enc->session);
        CFRelease(enc->session);
    }
    free(enc);
}

void vt_encoder_cleanup_globals(void) {
    free(g_output_buf);
    g_output_buf = NULL;
    g_output_len = 0;
    g_output_cap = 0;
}
