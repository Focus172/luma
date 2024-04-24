pub extern fn strcmp(__s1: [*c]const u8, __s2: [*c]const u8) c_int;

const std = @import("std");
const drm = @cImport({
    @cInclude("xf86drmMode.h");
    @cInclude("xf86drm.h");
});
const print = std.debug.print;

const stderr = std.io.getStdErr().writer();
// const stdout = std.io.getStdOut().writer();

pub fn getPropertyValue(drm_fd: c_int, object_id: u32, object_type: u32, prop_name: [*c]const u8) !u64 {
    var props: *drm.drmModeObjectProperties = drm.drmModeObjectGetProperties(drm_fd, object_id, object_type);
    defer drm.drmModeFreeObjectProperties(props);

    var i: u32 = 0;
    while (i < props.*.count_props) : (i += 1) {
        var prop: *drm.drmModePropertyRes = drm.drmModeGetProperty(drm_fd, props.*.props[i]);
        defer drm.drmModeFreeProperty(prop);

        var val: u64 = props.prop_values[i];
        if (strcmp(@as([*c]u8, @ptrCast(@alignCast(&prop.name))), prop_name) == 0) {
            return val;
        }
    } else {
        return error.no_prop;
    }
}

pub fn addProperty(drm_fd: c_int, req: ?*drm.drmModeAtomicReq, object_id: u32, object_type: u32, prop_name: [*c]const u8, value: u64) !void {
    var prop_id: u32 = 0;
    var props: *drm.drmModeObjectProperties = drm.drmModeObjectGetProperties(drm_fd, object_id, object_type);
    {
        var i: u32 = 0;
        while (i < props.count_props) : (i +%= 1) {
            var prop: [*c]drm.drmModePropertyRes = drm.drmModeGetProperty(drm_fd, props.*.props[i]);
            if (strcmp(@as([*c]u8, @ptrCast(@alignCast(&prop.*.name))), prop_name) == @as(c_int, 0)) {
                prop_id = prop.*.prop_id;
                break;
            }
        }
    }

    if (prop_id == @as(u32, @bitCast(@as(c_int, 0)))) {
        return error.no_prop;
        // __assert_fail("prop_id != 0", "04-animatefb.c", @as(c_uint, @bitCast(@as(c_int, 52))), "void add_property(int, drmModeAtomicReq *, uint32_t, uint32_t, const char *, uint64_t)");
    }

    _ = drm.drmModeAtomicAddProperty(req, object_id, prop_id, value);
}

pub fn main() !u8 {
    const drm_fd: std.os.fd_t = try std.os.open("/dev/dri/card0", std.os.O.RDWR | std.os.O.NONBLOCK, 0);
    defer std.os.close(drm_fd);

    if (drm.drmSetClientCap(drm_fd, drm.DRM_CLIENT_CAP_UNIVERSAL_PLANES, 1) != 0) {
        _ = try stderr.write("drmSetClientCap(UNIVERSAL_PLANES) failed");
        return error.set_client_caps;
    }

    if (drm.drmSetClientCap(drm_fd, drm.DRM_CLIENT_CAP_ATOMIC, 1) != 0) {
        _ = try stderr.write("drmSetClientCap(ATOMIC) failed");
        return error.set_client_caps;
    }

    const resources: *drm.drmModeRes = drm.drmModeGetResources(drm_fd);
    defer drm.drmModeFreeResources(resources);

    // Get the first CRTC currently lighted up, error if none
    const crtc: *drm.drmModeCrtc = blk: {
        var i: usize = 0;
        while (i < resources.count_crtcs) : (i += 1) {
            var crtc_id: u32 = resources.crtcs[i];
            const crtc: *drm.drmModeCrtc = drm.drmModeGetCrtc(drm_fd, crtc_id);

            if (crtc.mode_valid != 0) {
                break :blk crtc;
            }
            drm.drmModeFreeCrtc(crtc);
        } else break :blk null;
    } orelse return error.no_crtc;

    defer drm.drmModeFreeCrtc(crtc);

    print("Using CRTC {d}\n", .{crtc.crtc_id});
    print("Using mode {d}x{d} {d}Hz\n", .{ crtc.mode.hdisplay, crtc.mode.vdisplay, crtc.mode.vrefresh });

    const planes: *drm.drmModePlaneRes = drm.drmModeGetPlaneResources(drm_fd);

    // Get the primary plane connected to the CRTC
    const plane: *drm.drmModePlane = blk: {
        var i: u32 = 0;
        while (i < planes.count_planes) : (i +%= 1) {
            var plane_id: u32 = planes.*.planes[i];
            const plane = drm.drmModeGetPlane(drm_fd, plane_id);
            var plane_type: u64 = try getPropertyValue(drm_fd, plane_id, @as(c_uint, 4008636142), "type");
            if ((plane.*.crtc_id == crtc.crtc_id) and (plane_type == @as(u64, @bitCast(@as(c_long, @as(c_int, 1)))))) {
                break :blk plane;
            }
            drm.drmModeFreePlane(plane);
        } else break :blk null;
    } orelse return error.no_plane;
    defer drm.drmModeFreePlane(plane);

    print("Using plane {d}\n", .{plane.plane_id});

    drm.drmModeFreePlaneResources(planes);
    drm.drmModeFreeResources(resources);

    const width: u32 = crtc.mode.hdisplay;
    const height: u32 = crtc.mode.vdisplay;

    var create: drm.drm_mode_create_dumb = .{
        .height = height,
        .width = width,
        .bpp = 32,
        .flags = 0,
        .handle = 0,
        .pitch = 0,
        .size = 0,
    };

    _ = drm.drmIoctl(drm_fd, drm.DRM_IOCTL_MODE_CREATE_DUMB, &create);
    const handle: u32 = create.handle;
    const stride: u32 = create.pitch;
    const size: usize = create.size;

    var handles: [4]u32 = .{ handle, 0, 0, 0 };
    var strides: [4]u32 = .{ stride, 0, 0, 0 };
    var offsets: [4]u32 = .{ 0, 0, 0, 0 };

    var fb_id: u32 = undefined;

    // i have no idea what this means
    const DRM_FORMAT_XRGB8888 = 'X' | 'R' << 8 | '2' << 16 | '4' << 24;
    _ = drm.drmModeAddFB2(drm_fd, width, height, DRM_FORMAT_XRGB8888, &handles, &strides, &offsets, &fb_id, 0);
    print("Allocated FB {d}\n", .{fb_id});

    var map: drm.drm_mode_map_dumb = .{
        .handle = handle,
        .pad = 0,
        .offset = 0,
    };
    _ = drm.drmIoctl(drm_fd, drm.DRM_IOCTL_MODE_MAP_DUMB, &map);

    const data = try std.os.mmap(null, size, // more than one page
        std.os.PROT.READ | std.os.PROT.WRITE, // read & write
        std.os.MAP.SHARED, drm_fd, map.offset);
    defer std.os.munmap(data);

    //                        B, G, R,   X
    var color: [4]u8 = [4]u8{ 0, 0, 255, 255 };

    var inc: u8 = 1;
    var dec: u8 = 2;

    var i: usize = 0;
    while (i < 60 * 5) : (i += 1) {
        color[inc] +%= 15;
        color[dec] -%= 15;
        if (color[dec] == 0) {
            dec = inc;
            inc = (inc + 2) % 3;
        }

        // assign the color to all elemnets in the buffer
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const offset: usize = (y * stride) + (x * 4);
                @memcpy(data[offset .. offset + 4], &color);
            }
        }

        const req: *drm.drmModeAtomicReq = drm.drmModeAtomicAlloc() orelse return error.alloc_failed;
        // defer drm.drmModeAtomicFree(req);

        var plane_id: u32 = plane.plane_id;
        try addProperty(drm_fd, req, plane_id, drm.DRM_MODE_OBJECT_PLANE, "FB_ID", @as(u64, @bitCast(@as(c_ulong, fb_id))));
        try addProperty(drm_fd, req, plane_id, drm.DRM_MODE_OBJECT_PLANE, "SRC_X", @as(u64, @bitCast(@as(c_long, @as(c_int, 0)))));
        try addProperty(drm_fd, req, plane_id, drm.DRM_MODE_OBJECT_PLANE, "SRC_Y", @as(u64, @bitCast(@as(c_long, @as(c_int, 0)))));
        try addProperty(drm_fd, req, plane_id, drm.DRM_MODE_OBJECT_PLANE, "SRC_W", @as(u64, @bitCast(@as(c_long, width << @intCast(16)))));
        try addProperty(drm_fd, req, plane_id, drm.DRM_MODE_OBJECT_PLANE, "SRC_H", @as(u64, @bitCast(@as(c_long, height << @intCast(16)))));
        try addProperty(drm_fd, req, plane_id, drm.DRM_MODE_OBJECT_PLANE, "CRTC_X", @as(u64, @bitCast(@as(c_long, @as(c_int, 0)))));
        try addProperty(drm_fd, req, plane_id, drm.DRM_MODE_OBJECT_PLANE, "CRTC_Y", @as(u64, @bitCast(@as(c_long, @as(c_int, 0)))));
        try addProperty(drm_fd, req, plane_id, drm.DRM_MODE_OBJECT_PLANE, "CRTC_W", @as(u64, @bitCast(@as(c_long, width))));
        try addProperty(drm_fd, req, plane_id, drm.DRM_MODE_OBJECT_PLANE, "CRTC_H", @as(u64, @bitCast(@as(c_long, height))));

        const flags = drm.DRM_MODE_ATOMIC_NONBLOCK;
        const ret = drm.drmModeAtomicCommit(drm_fd, req, flags, null);
        if (ret != 0) {
            _ = try stderr.write("drmModeAtomicCommit failed");
            return error.swap_fb;
        }

        // about 60hz
        std.time.sleep(16666667);
    }
    return 0;
}
