const std = @import("std");
const posix = std.posix;
const protocol = @import("protocol");
const ipc = @import("ipc");
const drm = @import("drm");

const log = std.log.scoped(.kms);

const max_connectors = 32;

const ConnectorCrtcPair = struct {
    connector_id: u32,
    crtc_id: u64,
};

/// zerocast-kms: Privileged KMS capture helper.
///
/// argv[1] = socketpair fd (as decimal string)
/// argv[2] = card path (e.g. "/dev/dri/card0")
pub fn main() !void {
    const args = std.os.argv;
    if (args.len != 3) {
        log.err("usage: zerocast-kms <socket_fd> <card_path>", .{});
        std.process.exit(1);
    }

    const sock_fd: posix.fd_t = std.fmt.parseInt(posix.fd_t, std.mem.span(args[1]), 10) catch {
        log.err("invalid socket fd: {s}", .{std.mem.span(args[1])});
        std.process.exit(1);
    };

    const card_path = std.mem.span(args[2]);

    const drm_fd = posix.open(card_path, .{ .ACCMODE = .RDONLY }, 0) catch |err| {
        log.err("failed to open {s}: {}", .{ card_path, err });
        std.process.exit(2);
    };
    defer posix.close(drm_fd);

    if (drm.setClientCap(drm_fd, drm.DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) != 0) {
        log.err("drmSetClientCap UNIVERSAL_PLANES failed", .{});
        std.process.exit(2);
    }

    // Atomic is optional — enables correct CRTC-to-connector mapping
    _ = drm.setClientCap(drm_fd, drm.DRM_CLIENT_CAP_ATOMIC, 1);

    log.info("KMS helper ready, card={s}", .{card_path});

    // Main request/response loop
    while (true) {
        var request: protocol.Request = undefined;
        ipc.recvRequest(sock_fd, &request) catch |err| {
            if (err == error.PeerDisconnected) {
                log.info("client disconnected, shutting down", .{});
                break;
            }
            log.err("failed to receive request: {}", .{err});
            continue;
        };

        if (request.version != protocol.protocol_version) {
            log.err("protocol version mismatch: expected {}, got {}", .{ protocol.protocol_version, request.version });
            continue;
        }

        switch (request.type) {
            .get_frame => {
                var response = protocol.Response{};
                getFrame(drm_fd, &response);

                // Collect fds to send via SCM_RIGHTS
                var fds: [protocol.max_planes * protocol.max_dma_bufs_per_plane]i32 = undefined;
                const num_fds = response.collectFds(&fds);

                ipc.sendResponse(sock_fd, &response, fds[0..num_fds]) catch |err| {
                    log.err("failed to send response: {}", .{err});
                };

                // Close fds server-side (client now owns them)
                for (fds[0..num_fds]) |fd| posix.close(fd);
            },
            .shutdown => {
                log.info("shutdown requested", .{});
                break;
            },
        }
    }
}

fn getFrame(drm_fd: posix.fd_t, response: *protocol.Response) void {
    response.* = protocol.Response{};

    // Map connectors → CRTCs
    var c2crtc: [max_connectors]ConnectorCrtcPair = undefined;
    var num_connectors: u32 = 0;
    mapCrtcToConnectors(drm_fd, &c2crtc, &num_connectors);

    const planes_ptr = drm.modeGetPlaneResources(drm_fd) orelse {
        response.setError("failed to get plane resources");
        return;
    };
    defer drm.modeFreePlaneResources(planes_ptr);
    const planes = planes_ptr.*;

    var i: u32 = 0;
    while (i < planes.count_planes and response.num_planes < protocol.max_planes) : (i += 1) {
        const plane_ptr = drm.modeGetPlane(drm_fd, planes.planes[i]) orelse continue;
        defer drm.modeFreePlane(plane_ptr);
        const plane = plane_ptr.*;

        if (plane.fb_id == 0) continue;

        const drmfb_ptr = drm.modeGetFB2(drm_fd, plane.fb_id) orelse continue;
        defer {
            cleanupHandles(drm_fd, drmfb_ptr);
            drm.modeFreeFB2(drmfb_ptr);
        }
        const drmfb = drmfb_ptr.*;

        if (drmfb.handles[0] == 0) continue;

        // Get plane properties (type, position, rotation)
        var props = PlaneProperties{};
        getPlaneProperties(drm_fd, plane.plane_id, &props);

        // Only primary and cursor planes
        if (!props.is_primary and !props.is_cursor) continue;

        // Export DMA-BUF fds
        var fb_fds: [protocol.max_dma_bufs_per_plane]i32 = [_]i32{-1} ** protocol.max_dma_bufs_per_plane;
        var num_fds: u32 = 0;
        for (0..protocol.max_dma_bufs_per_plane) |j| {
            if (drmfb.handles[j] == 0) break;
            var fd: i32 = -1;
            if (drm.primeHandleToFD(drm_fd, drmfb.handles[j], 0, &fd) != 0 or fd == -1) break; // 0 = O_RDONLY
            fb_fds[j] = fd;
            num_fds += 1;
        }

        if (num_fds == 0) continue;

        // Populate response plane
        const idx = response.num_planes;
        var out = &response.planes[idx];

        for (0..num_fds) |j| {
            out.dma_bufs[j].fd = fb_fds[j];
            out.dma_bufs[j].pitch = drmfb.pitches[j];
            out.dma_bufs[j].offset = drmfb.offsets[j];
        }
        out.num_dma_bufs = num_fds;
        out.width = drmfb.width;
        out.height = drmfb.height;
        out.pixel_format = drmfb.pixel_format;
        out.modifier = if (drmfb.flags & drm.DRM_MODE_FB_MODIFIERS != 0) drmfb.modifier else drm.DRM_FORMAT_MOD_INVALID;
        out.connector_id = findConnectorForCrtc(&c2crtc, num_connectors, plane.crtc_id);
        out.is_cursor = props.is_cursor;
        out.rotation = props.rotation;

        if (props.is_cursor) {
            out.x = props.x;
            out.y = props.y;
            out.src_w = 0;
            out.src_h = 0;
        } else {
            out.x = props.src_x;
            out.y = props.src_y;
            out.src_w = props.src_w;
            out.src_h = props.src_h;
        }

        response.num_planes += 1;
    }

    // On error, close all fds and reset
    if (response.num_planes == 0 and response.result == .ok) {
        response.setError("no primary or cursor planes found");
    }
}

const PlaneProperties = struct {
    is_primary: bool = false,
    is_cursor: bool = false,
    x: i32 = 0,
    y: i32 = 0,
    src_x: i32 = 0,
    src_y: i32 = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,
    rotation: protocol.Rotation = .rot_0,
};

fn getPlaneProperties(drm_fd: posix.fd_t, plane_id: u32, out: *PlaneProperties) void {
    const props_ptr = drm.modeObjectGetProperties(drm_fd, plane_id, drm.DRM_MODE_OBJECT_PLANE) orelse return;
    defer drm.modeFreeObjectProperties(props_ptr);
    const props = props_ptr.*;

    var i: u32 = 0;
    while (i < props.count_props) : (i += 1) {
        const prop_ptr = drm.modeGetProperty(drm_fd, props.props[i]) orelse continue;
        defer drm.modeFreeProperty(prop_ptr);
        const prop = prop_ptr.*;

        const prop_type = prop.flags & (drm.DRM_MODE_PROP_LEGACY_TYPE | drm.DRM_MODE_PROP_EXTENDED_TYPE);
        const name = std.mem.span(@as([*:0]const u8, @ptrCast(&prop.name)));
        const value = props.prop_values[i];

        if (prop_type & drm.DRM_MODE_PROP_SIGNED_RANGE != 0) {
            if (std.mem.eql(u8, name, "CRTC_X")) {
                out.x = @intCast(@as(i64, @bitCast(value)));
            } else if (std.mem.eql(u8, name, "CRTC_Y")) {
                out.y = @intCast(@as(i64, @bitCast(value)));
            }
        } else if (prop_type & drm.DRM_MODE_PROP_RANGE != 0) {
            // SRC_* values are fixed-point 16.16
            if (std.mem.eql(u8, name, "SRC_X")) {
                out.src_x = @intCast(value >> 16);
            } else if (std.mem.eql(u8, name, "SRC_Y")) {
                out.src_y = @intCast(value >> 16);
            } else if (std.mem.eql(u8, name, "SRC_W")) {
                out.src_w = @intCast(value >> 16);
            } else if (std.mem.eql(u8, name, "SRC_H")) {
                out.src_h = @intCast(value >> 16);
            }
        } else if (prop_type & drm.DRM_MODE_PROP_ENUM != 0 and std.mem.eql(u8, name, "type")) {
            const enums: [*]const drm.ModePropertyEnum = @ptrCast(@alignCast(prop.enums));
            var j: u32 = 0;
            while (j < @as(u32, @intCast(prop.count_enums))) : (j += 1) {
                if (enums[j].value == value) {
                    const enum_name = std.mem.span(@as([*:0]const u8, @ptrCast(&enums[j].name)));
                    if (std.mem.eql(u8, enum_name, "Primary")) out.is_primary = true;
                    if (std.mem.eql(u8, enum_name, "Cursor")) out.is_cursor = true;
                    break;
                }
            }
        } else if (prop_type & drm.DRM_MODE_PROP_BITMASK != 0 and std.mem.eql(u8, name, "rotation")) {
            var rot: u32 = 0;
            if (value & 2 != 0) rot = (rot + 1) % 4; // 90
            if (value & 4 != 0) rot = (rot + 2) % 4; // 180
            if (value & 8 != 0) rot = (rot + 3) % 4; // 270
            out.rotation = @enumFromInt(rot);
        }
    }
}

fn mapCrtcToConnectors(drm_fd: posix.fd_t, map: *[max_connectors]ConnectorCrtcPair, count: *u32) void {
    count.* = 0;
    const resources_ptr = drm.modeGetResources(drm_fd) orelse return;
    defer drm.modeFreeResources(resources_ptr);
    const resources = resources_ptr.*;

    var i: u32 = 0;
    while (i < @as(u32, @intCast(resources.count_connectors)) and count.* < max_connectors) : (i += 1) {
        const connector_ptr = drm.modeGetConnectorCurrent(drm_fd, resources.connectors[i]) orelse continue;
        defer drm.modeFreeConnector(connector_ptr);
        const connector = connector_ptr.*;

        var crtc_id: u64 = 0;
        connectorGetProperty(drm_fd, &connector, "CRTC_ID", &crtc_id);

        map[count.*] = .{
            .connector_id = connector.connector_id,
            .crtc_id = crtc_id,
        };
        count.* += 1;
    }
}

fn connectorGetProperty(drm_fd: posix.fd_t, connector: *const drm.ModeConnector, name: []const u8, result: *u64) void {
    var i: u32 = 0;
    while (i < @as(u32, @intCast(connector.count_props))) : (i += 1) {
        const prop_ptr = drm.modeGetProperty(drm_fd, connector.props[i]) orelse continue;
        defer drm.modeFreeProperty(prop_ptr);
        const prop = prop_ptr.*;

        const prop_name = std.mem.span(@as([*:0]const u8, @ptrCast(&prop.name)));
        if (std.mem.eql(u8, prop_name, name)) {
            result.* = connector.prop_values[i];
            return;
        }
    }
}

fn findConnectorForCrtc(map: *const [max_connectors]ConnectorCrtcPair, count: u32, crtc_id: u32) u32 {
    for (map[0..count]) |pair| {
        if (pair.crtc_id == crtc_id) return pair.connector_id;
    }
    return 0;
}

fn cleanupHandles(drm_fd: posix.fd_t, drmfb_ptr: anytype) void {
    const fb = drmfb_ptr.*;
    for (0..4) |i| {
        if (fb.handles[i] == 0) continue;

        // Deduplicate — same handle can appear in multiple slots
        var already_closed = false;
        for (0..i) |j| {
            if (fb.handles[i] == fb.handles[j]) {
                already_closed = true;
                break;
            }
        }

        if (!already_closed) {
            _ = drm.closeBufferHandle(drm_fd, fb.handles[i]);
        }
    }
}
