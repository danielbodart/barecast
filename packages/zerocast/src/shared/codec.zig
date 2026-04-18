/// Video codec identity. Shared across encoder backends (NVENC, VA-API)
/// and transport layers (session, recorder).
pub const Codec = enum {
    av1,
    hevc,

    pub fn name(self: Codec) []const u8 {
        return switch (self) {
            .av1 => "AV1",
            .hevc => "HEVC",
        };
    }

    /// File extension for recorded chunks.
    pub fn recordingExt(self: Codec) []const u8 {
        return switch (self) {
            .av1 => "ivf",
            .hevc => "h265",
        };
    }
};
