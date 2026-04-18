/// Video codec identity. AV1-only per R5 — HEVC path removed with T-009.
pub const Codec = enum {
    av1,

    pub fn name(self: Codec) []const u8 {
        return switch (self) {
            .av1 => "AV1",
        };
    }

    /// File extension for recorded chunks.
    pub fn recordingExt(self: Codec) []const u8 {
        return switch (self) {
            .av1 => "ivf",
        };
    }
};
