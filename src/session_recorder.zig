const std = @import("std");
const IvfWriter = @import("ivf").IvfWriter;
const build_options = @import("build_options");

const log = std.log.scoped(.recorder);

/// Chunked IVF recorder with round-robin disk management.
/// Each chunk is up to `chunk_duration_s` seconds of video. When a chunk
/// fills up, it is finalized and a new one opened. Old chunks are deleted
/// to stay within `max_total_bytes`.
///
/// Alongside each IVF chunk, a `.log` file captures structured session
/// diagnostics (events, timing summaries, stats).
pub const SessionRecorder = struct {
    dir: std.fs.Dir,
    seq: usize,
    keep_bytes: u64,
    chunk_duration_ns: u64,
    fps: u32,

    // Current chunk state
    ivf: ?IvfWriter,
    chunk_start_ns: u64,
    chunk_bytes: u64,
    width: u32,
    height: u32,

    // Diagnostic log buffer (flushed per chunk)
    log_buf: std.ArrayListUnmanaged(u8),

    // Session-level metadata (written into each log header)
    command: []const u8,
    session_start_ns: i128,

    const chunk_duration_default_s: u64 = 10 * 60; // 10 minutes
    const max_total_default: u64 = 600 * 1024 * 1024; // 600 MB
    const max_chunks: usize = 100;

    pub fn init(
        dir_path: []const u8,
        command: []const u8,
        fps: u32,
        width: u32,
        height: u32,
    ) ?SessionRecorder {
        const dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
            log.warn("cannot open recording dir {s}: {}", .{ dir_path, err });
            return null;
        };

        var self = SessionRecorder{
            .dir = dir,
            .seq = 0,
            .keep_bytes = max_total_default,
            .chunk_duration_ns = chunk_duration_default_s * std.time.ns_per_s,
            .fps = fps,
            .ivf = null,
            .chunk_start_ns = 0,
            .chunk_bytes = 0,
            .width = width,
            .height = height,
            .log_buf = .{},
            .command = command,
            .session_start_ns = std.time.nanoTimestamp(),
        };

        self.openChunk();
        return self;
    }

    /// Record one encoded frame. Handles chunk rotation automatically.
    pub fn writeFrame(self: *SessionRecorder, data: []const u8, pts_ms: u64, timer: *std.time.Timer) void {
        // Check if we need to rotate
        const elapsed_ns = timer.read();
        if (elapsed_ns - self.chunk_start_ns >= self.chunk_duration_ns and self.ivf != null) {
            self.rotateChunk(timer);
        }

        if (self.ivf) |*ivf| {
            ivf.writeFrame(data, pts_ms) catch |err| {
                log.warn("recording write failed: {}", .{err});
                return;
            };
            self.chunk_bytes += data.len + 12; // frame data + 12-byte IVF frame header
        }
    }

    /// Log a session event (viewer connect, resize, reinit, etc.)
    pub fn logEvent(self: *SessionRecorder, event: []const u8) void {
        const elapsed_ms = self.elapsedMs();
        const w = self.log_buf.writer(std.heap.c_allocator);
        std.fmt.format(w, "[{d}.{d}s] {s}\n", .{
            elapsed_ms / 1000, (elapsed_ms % 1000) / 100, event,
        }) catch {};
    }

    /// Log a formatted event with arguments.
    pub fn logFmt(self: *SessionRecorder, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.logEvent(msg);
    }

    /// Log pipeline timing summary (called from encoder every ~5s).
    pub fn logTimings(
        self: *SessionRecorder,
        cuda_avg: u64,
        encode_avg: u64,
        send_avg: u64,
        total_avg: u64,
        samples: u64,
        skipped: u64,
    ) void {
        const elapsed_ms = self.elapsedMs();
        const w = self.log_buf.writer(std.heap.c_allocator);
        std.fmt.format(w, "[{d}.{d}s] pipeline: cuda={d}us encode={d}us send={d}us total={d}us ({d} frames, {d} skipped)\n", .{
            elapsed_ms / 1000, (elapsed_ms % 1000) / 100,
            cuda_avg, encode_avg, send_avg, total_avg, samples, skipped,
        }) catch {};
    }

    /// Finalize current chunk and clean up.
    pub fn deinit(self: *SessionRecorder) void {
        self.closeChunk();
        self.log_buf.deinit(std.heap.c_allocator);
        self.dir.close();
    }

    // ── Internal ──────────────────────────────────────────────────────

    fn openChunk(self: *SessionRecorder) void {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d:0>3}.ivf", .{self.seq % max_chunks}) catch return;

        self.ivf = IvfWriter.initDir(self.dir, name) catch |err| {
            log.warn("cannot create recording chunk {s}: {}", .{ name, err });
            return;
        };

        self.chunk_start_ns = if (self.seq == 0) 0 else self.chunk_start_ns + self.chunk_duration_ns;
        self.chunk_bytes = 32; // IVF header
        log.info("recording chunk {d:0>3} started", .{self.seq % max_chunks});
    }

    fn closeChunk(self: *SessionRecorder) void {
        if (self.ivf) |*ivf| {
            ivf.finalize(
                @intCast(self.width),
                @intCast(self.height),
                self.fps,
                1,
            ) catch {};
            ivf.deinit();
            self.ivf = null;
        }

        // Write log alongside the chunk
        self.flushLog();
    }

    fn rotateChunk(self: *SessionRecorder, timer: *std.time.Timer) void {
        self.closeChunk();
        self.seq += 1;
        self.pruneOldChunks();
        self.openChunk();
        // Reset chunk_start to current time for the new chunk
        self.chunk_start_ns = timer.read();
    }

    fn flushLog(self: *SessionRecorder) void {
        var name_buf: [16]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d:0>3}.log", .{(if (self.seq == 0) @as(usize, 0) else self.seq) % max_chunks}) catch return;

        const file = self.dir.createFile(name, .{}) catch return;
        defer file.close();

        // Write header
        var hdr_buf: [512]u8 = undefined;
        const elapsed_ms = self.elapsedMs();
        const hdr = std.fmt.bufPrint(&hdr_buf, "=== Zerocast Recording {d:0>3} (v{s}) ===\nCommand: {s}\nResolution: {d}x{d} @{d}fps\nDuration: {d}.{d}s\n\n--- Events ---\n", .{
            self.seq % max_chunks,
            build_options.version,
            self.command,
            self.width, self.height, self.fps,
            elapsed_ms / 1000, (elapsed_ms % 1000) / 100,
        }) catch return;
        file.writeAll(hdr) catch return;
        file.writeAll(self.log_buf.items) catch return;

        // Clear log buffer for next chunk (retain capacity)
        self.log_buf.clearRetainingCapacity();
    }

    fn pruneOldChunks(self: *SessionRecorder) void {
        // Calculate total size of recordings in the directory
        var total: u64 = 0;
        var oldest_idx: usize = 0;
        var chunk_count: usize = 0;
        var sizes: [max_chunks]u64 = [_]u64{0} ** max_chunks;

        for (0..max_chunks) |i| {
            var name_buf: [16]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{d:0>3}.ivf", .{i}) catch continue;
            if (self.dir.statFile(name)) |stat| {
                sizes[i] = @intCast(stat.size);
                total += sizes[i];
                chunk_count += 1;
            } else |_| {}
        }

        // Delete oldest chunks until under budget
        // Start from the chunk after the one we're about to write
        oldest_idx = (self.seq + 1) % max_chunks;
        while (total > self.keep_bytes and chunk_count > 1) {
            var name_buf: [16]u8 = undefined;
            const ivf_name = std.fmt.bufPrint(&name_buf, "{d:0>3}.ivf", .{oldest_idx}) catch break;
            if (sizes[oldest_idx] > 0) {
                total -= sizes[oldest_idx];
                sizes[oldest_idx] = 0;
                chunk_count -= 1;
                self.dir.deleteFile(ivf_name) catch {};
                var log_buf: [16]u8 = undefined;
                const log_name = std.fmt.bufPrint(&log_buf, "{d:0>3}.log", .{oldest_idx}) catch "";
                self.dir.deleteFile(log_name) catch {};
                log.info("pruned old recording chunk {d:0>3}", .{oldest_idx});
            }
            oldest_idx = (oldest_idx + 1) % max_chunks;
        }
    }

    fn elapsedMs(self: *const SessionRecorder) u64 {
        const elapsed_ns = std.time.nanoTimestamp() - self.session_start_ns;
        return @intCast(@max(0, @divTrunc(elapsed_ns, 1_000_000)));
    }

    /// Update resolution (called after encoder reinit).
    pub fn updateResolution(self: *SessionRecorder, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
    }
};
