const std = @import("std");
const wlr = @cImport({
    @cDefine("_POSIX_C_SOURCE", "200112L");
    @cDefine("WLR_USE_UNSTABLE", {});
    @cInclude("linux/input-event-codes.h");
    @cInclude("unistd.h");
    @cInclude("wayland-server-core.h");
    @cInclude("wlr/backend.h");
    @cInclude("wlr/backend/libinput.h");
    @cInclude("wlr/render/allocator.h");
    @cInclude("wlr/render/wlr_renderer.h");
    @cInclude("wlr/types/wlr_cursor.h");
    @cInclude("wlr/types/wlr_compositor.h");
    @cInclude("wlr/types/wlr_data_control_v1.h");
    @cInclude("wlr/types/wlr_data_device.h");
    @cInclude("wlr/types/wlr_export_dmabuf_v1.h");
    @cInclude("wlr/types/wlr_gamma_control_v1.h");
    @cInclude("wlr/types/wlr_idle.h");
    @cInclude("wlr/types/wlr_input_device.h");
    @cInclude("wlr/types/wlr_input_inhibitor.h");
    @cInclude("wlr/types/wlr_keyboard.h");
    @cInclude("wlr/types/wlr_layer_shell_v1.h");
    @cInclude("wlr/types/wlr_matrix.h");
    @cInclude("wlr/types/wlr_output.h");
    @cInclude("wlr/types/wlr_output_damage.h");
    @cInclude("wlr/types/wlr_output_layout.h");
    @cInclude("wlr/types/wlr_output_management_v1.h");
    @cInclude("wlr/types/wlr_pointer.h");
    @cInclude("wlr/types/wlr_presentation_time.h");
    @cInclude("wlr/types/wlr_primary_selection.h");
    @cInclude("wlr/types/wlr_primary_selection_v1.h");
    @cInclude("wlr/types/wlr_seat.h");
    @cInclude("wlr/types/wlr_server_decoration.h");
    @cInclude("wlr/types/wlr_screencopy_v1.h");
    @cInclude("wlr/types/wlr_viewporter.h");
    @cInclude("wlr/types/wlr_xcursor_manager.h");
    @cInclude("wlr/types/wlr_xdg_shell.h");
    @cInclude("wlr/types/wlr_xdg_decoration_v1.h");
    @cInclude("wlr/types/wlr_xdg_output_v1.h");
    @cInclude("wlr/util/log.h");
    @cInclude("wlr/util/region.h");
    @cInclude("wlr/xwayland.h");
    @cInclude("X11/Xlib.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

pub fn main() !void {
    std.log.info("Starting Byway", .{});

    var server: Server = undefined;
    try server.init();
    defer server.deinit();
    try server.start();

    std.log.info("Exiting Byway", .{});
}

const Surface = struct {
    fn create(server: *Server, typed_surface: anytype, ancestor: ?*Surface) !?*Surface {
        if (@TypeOf(typed_surface) == *wlr.wlr_xdg_surface and
            typed_surface.role == wlr.WLR_XDG_SURFACE_ROLE_POPUP and
            ancestor == null)
        {
            return null;
        }

        var surface = try alloc.create(Surface);
        try surface.init(typed_surface, server, ancestor);

        return surface;
    }

    fn init(
        self: *Surface,
        typed_surface: anytype,
        server: *Server,
        ancestor: ?*Surface,
    ) !void {
        self.server = server;
        self.wlr_surface = null;
        self.mapped = false;
        self.list = null;
        self.node.data = self;
        self.is_requested_fullscreen = false;
        self.has_border = false;
        self.ancestor = ancestor;
        self.output_box = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        self.workspace = 0;
        self.is_actual_fullscreen = false;
        self.borders = .{
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
            .{ .x = 0, .y = 0, .width = 0, .height = 0 },
        };

        Signal.connect(void, self, "map", Surface.onMap, &typed_surface.events.map);
        Signal.connect(void, self, "unmap", Surface.onUnmap, &typed_surface.events.unmap);
        Signal.connect(void, self, "destroy", Surface.onDestroy, &typed_surface.events.destroy);

        switch (@TypeOf(typed_surface)) {
            *wlr.wlr_xdg_surface => {
                self.typed_surface = SurfaceType{ .xdg = typed_surface };
                Signal.connect(
                    *wlr.wlr_xdg_popup,
                    self,
                    "popup",
                    Surface.onNewPopup,
                    &typed_surface.events.new_popup,
                );

                switch (typed_surface.role) {
                    wlr.WLR_XDG_SURFACE_ROLE_TOPLEVEL => {
                        wlr.wlr_xdg_surface_ping(typed_surface);
                        self.list = &server.toplevels;
                        self.has_border = true;

                        Signal.connect(
                            void,
                            self,
                            "request_fullscreen",
                            Surface.onRequestFullscreen,
                            &@ptrCast(
                                *wlr.wlr_xdg_toplevel,
                                @field(typed_surface, wlr_xdg_surface_union).toplevel,
                            ).events.request_fullscreen,
                        );
                    },
                    else => {},
                }
            },
            *wlr.wlr_xwayland_surface => {
                self.typed_surface = SurfaceType{ .xwayland = typed_surface };
                if (typed_surface.override_redirect) {
                    self.list = &server.unmanaged_toplevels;
                } else {
                    self.has_border = true;
                    self.list = &server.toplevels;
                }
                Signal.connect(
                    void,
                    self,
                    "request_fullscreen",
                    Surface.onRequestFullscreen,
                    &typed_surface.events.request_fullscreen,
                );
                Signal.connect(
                    void,
                    self,
                    "activate",
                    Surface.onActivate,
                    &typed_surface.events.request_activate,
                );
                Signal.connect(
                    *wlr.wlr_xwayland_surface_configure_event,
                    self,
                    "configure",
                    Surface.onConfigure,
                    &typed_surface.events.request_configure,
                );
            },
            *wlr.wlr_layer_surface_v1 => {
                self.typed_surface = SurfaceType{ .layer = typed_surface };
                Signal.connect(
                    *wlr.wlr_xdg_popup,
                    self,
                    "popup",
                    Surface.onNewPopup,
                    &typed_surface.events.new_popup,
                );
                if (server.outputAtCursor()) |output| {
                    if (typed_surface.output == null) {
                        typed_surface.output = output.wlr_output;
                    }
                }
                if (Output.fromWlrOutput(typed_surface.output)) |output| {
                    self.layer = typed_surface.pending.layer;
                    output.layers[self.layer].prepend(&self.node);
                    output.arrangeLayers();
                }
            },
            *wlr.wlr_subsurface => {
                self.typed_surface = SurfaceType{ .subsurface = typed_surface };
            },
            *wlr.wlr_drag_icon => {
                self.typed_surface = SurfaceType{ .drag_icon = typed_surface };
            },
            else => {
                std.log.err("unknown surface {s} {d}", .{ @TypeOf(typed_surface), typed_surface });
            },
        }
    }

    fn onCommit(self: *Surface, _: void) !void {
        switch (self.typed_surface) {
            .xdg => |xdg| {
                if (self.pending_serial > 0 and xdg.current.configure_serial >= self.pending_serial) {
                    self.pending_serial = 0;
                    self.server.damageAllOutputs();
                }
            },
            .layer => |layer_surface| {
                if (Output.fromWlrOutput(layer_surface.output)) |output| {
                    if (layer_surface.current.committed != 0 or
                        self.mapped != layer_surface.mapped)
                    {
                        self.mapped = layer_surface.mapped;
                        if (self.layer != layer_surface.current.layer) {
                            output.layers[self.layer].remove(&self.node);
                            output.layers[layer_surface.current.layer].prepend(
                                &self.node,
                            );
                            self.layer = layer_surface.current.layer;
                        }
                        output.arrangeLayers();
                    }
                }
            },
            else => {},
        }

        self.updateBorders();
        self.damage(if (self.server.config.damage_tracking == .full) false else true);
    }

    fn shouldFocus(self: *Surface) bool {
        return switch (self.typed_surface) {
            .xwayland => |xwayland| !xwayland.override_redirect or
                wlr.wlr_xwayland_or_surface_wants_focus(xwayland),
            .layer => self.layer != wlr.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND and
                self.layer != wlr.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
            else => true,
        };
    }

    fn onMap(self: *Surface, _: void) !void {
        self.mapped = true;
        self.initWlrSurface();

        if (self.has_border) self.place();
        switch (self.typed_surface) {
            .xwayland => |xwayland| {
                self.output_box.x = xwayland.x;
                self.output_box.y = xwayland.y;
            },
            else => {},
        }
        if (self.list) |list| list.prepend(&self.node);
        self.setKeyboardFocus();
        self.updateOutputs();
        self.server.damageAllOutputs();
    }

    fn onUnmap(self: *Surface, _: void) !void {
        if (!self.mapped) return;
        self.mapped = false;
        wlr.wl_list_remove(&self.commit.link);
        switch (self.typed_surface) {
            .xdg, .subsurface => {
                wlr.wl_list_remove(&self.subsurface.link);
            },
            else => {},
        }
        self.server.damageAllOutputs();

        self.wlr_surface = null;

        if (self.list) |list| {
            list.remove(&self.node);
        }
        self.server.processCursorMotion(0);
    }

    fn onDestroy(self: *Surface, _: void) !void {
        wlr.wl_list_remove(&self.map.link);
        wlr.wl_list_remove(&self.unmap.link);
        if (self.mapped) {
            self.server.damageAllOutputs();
        }
        wlr.wl_list_remove(&self.destroy.link);

        if (self.list) |_| {
            wlr.wl_list_remove(&self.request_fullscreen.link);
            switch (self.typed_surface) {
                .xwayland => |xwayland| {
                    if (!xwayland.override_redirect) {
                        wlr.wl_list_remove(&self.activate.link);
                        wlr.wl_list_remove(&self.configure.link);
                    }
                },
                else => {},
            }
        }

        switch (self.typed_surface) {
            .layer => |layer_surface| {
                if (Output.fromWlrOutput(layer_surface.output)) |output| {
                    output.arrangeLayers();
                    output.layers[self.layer].remove(&self.node);
                    layer_surface.output = null;
                }
            },
            else => {},
        }

        alloc.destroy(self);
    }

    fn onActivate(self: *Surface, _: void) !void {
        switch (self.typed_surface) {
            .xwayland => |xwayland| {
                wlr.wlr_xwayland_surface_activate(xwayland, true);
            },
            else => {
                std.log.err("unexpected activate", .{});
            },
        }
        self.server.damageAllOutputs();
    }

    fn onConfigure(
        self: *Surface,
        event: *wlr.wlr_xwayland_surface_configure_event,
    ) !void {
        switch (self.typed_surface) {
            .xwayland => |xwayland| {
                self.updateBorders();
                wlr.wlr_xwayland_surface_configure(
                    xwayland,
                    event.x,
                    event.y,
                    event.width,
                    event.height,
                );
            },
            else => {
                std.log.err("unexpected configure", .{});
            },
        }
        self.server.damageAllOutputs();
    }

    fn onNewPopup(self: *Surface, wlr_popup: *wlr.wlr_xdg_popup) !void {
        _ = try Surface.create(
            self.server,
            @ptrCast(*wlr.wlr_xdg_surface, wlr_popup.base),
            if (self.has_border) self else if (self.ancestor) |ancestor| ancestor else self,
        );
    }

    fn onNewSubsurface(self: *Surface, wlr_subsurface: *wlr.wlr_subsurface) !void {
        _ = try Surface.create(self.server, wlr_subsurface, if (self.has_border) self else self.ancestor);
    }

    fn onRequestFullscreen(self: *Surface, _: void) !void {
        self.is_requested_fullscreen = !self.is_requested_fullscreen;

        switch (self.typed_surface) {
            .xdg => |xdg| {
                _ = wlr.wlr_xdg_toplevel_set_fullscreen(xdg, self.is_requested_fullscreen);
            },
            .xwayland => |xwayland| {
                wlr.wlr_xwayland_surface_set_fullscreen(xwayland, self.is_requested_fullscreen);
            },
            else => {},
        }
    }

    fn initWlrSurface(self: *Surface) void {
        if (self.wlr_surface != null) return;

        self.wlr_surface = switch (self.typed_surface) {
            .xdg => |xdg| xdg.surface,
            .xwayland => |xwayland| xwayland.surface,
            .layer => |layer_surface| layer_surface.surface,
            .subsurface => |subsurface| subsurface.surface,
            .drag_icon => |drag_icon| drag_icon.surface,
        };

        if (self.wlr_surface) |wlr_surface| {
            wlr_surface.data = self;
            Signal.connect(
                *wlr.wlr_subsurface,
                self,
                "subsurface",
                Surface.onNewSubsurface,
                &wlr_surface.events.new_subsurface,
            );
            Signal.connect(
                void,
                self,
                "commit",
                Surface.onCommit,
                &wlr_surface.events.commit,
            );

            for ([2]*wlr.wl_list{
                &wlr_surface.current.subsurfaces_below,
                &wlr_surface.current.subsurfaces_above,
            }) |subsurfaces| {
                var iter: *wlr.wl_list = subsurfaces.next;
                while (iter != subsurfaces) : (iter = iter.next) {
                    self.onNewSubsurface(@fieldParentPtr(
                        wlr.wlr_subsurface,
                        "current",
                        @fieldParentPtr(wlr.wlr_subsurface_parent_state, "link", iter),
                    )) catch unreachable;
                }
            }
        }
    }

    fn unconstrainPopup(self: *Surface) void {
        switch (self.typed_surface) {
            .xdg => |xdg| {
                if (xdg.role == wlr.WLR_XDG_SURFACE_ROLE_POPUP) {
                    if (self.getCenterOutput()) |output| {
                        var box: wlr.wlr_box = undefined;
                        output.getBox(&box);
                        wlr.wlr_xdg_popup_unconstrain_from_box(
                            @ptrCast(*wlr.wlr_xdg_popup, @field(xdg, wlr_xdg_surface_union).popup),
                            &box,
                        );
                    }
                }
            },
            else => {},
        }
    }
    fn toFront(self: *Surface) void {
        switch (self.typed_surface) {
            .xwayland => |xwayland| {
                wlr.wlr_xwayland_surface_restack(xwayland, null, wlr.XCB_STACK_MODE_ABOVE);
            },
            else => {},
        }
    }

    fn toBack(self: *Surface) void {
        switch (self.typed_surface) {
            .xwayland => |xwayland| {
                wlr.wlr_xwayland_surface_restack(xwayland, null, wlr.XCB_STACK_MODE_BELOW);
            },
            else => {},
        }
    }

    fn setKeyboardFocus(self: *Surface) void {
        if (self.wlr_surface) |wlr_surface| {
            if (self.shouldFocus()) self.server.setKeyboardFocus(wlr_surface);
        }
    }

    fn setGeometry(self: *Surface, box: wlr.wlr_box) void {
        self.output_box = box;

        switch (self.typed_surface) {
            .xdg => |xdg| {
                var xdg_box: wlr.wlr_box = undefined;
                wlr.wlr_xdg_surface_get_geometry(xdg, &xdg_box);
                self.output_box.x -= xdg_box.x;
                self.output_box.y -= xdg_box.y;
                self.pending_serial = wlr.wlr_xdg_toplevel_set_size(
                    xdg,
                    @intCast(u32, box.width),
                    @intCast(u32, box.height),
                );
            },
            .xwayland => |xwayland| {
                if (self.getCenterOutput()) |output| {
                    wlr.wlr_xwayland_surface_configure(
                        xwayland,
                        @intCast(i16, output.total_box.x + self.output_box.x),
                        @intCast(i16, output.total_box.y + self.output_box.y),
                        @intCast(u16, box.width),
                        @intCast(u16, box.height),
                    );
                }
            },
            else => {},
        }

        self.updateOutputs();
        self.updateBorders();
        self.server.damageAllOutputs();
    }

    fn getGeometry(self: *Surface, box: *wlr.wlr_box) void {
        box.x = 0;
        box.y = 0;
        switch (self.typed_surface) {
            .xdg => |xdg| {
                wlr.wlr_xdg_surface_get_geometry(xdg, box);
            },
            .xwayland => |xwayland| {
                box.width = xwayland.width;
                box.height = xwayland.height;
            },
            .layer => {
                box.width = self.output_box.width;
                box.height = self.output_box.height;
            },
            else => {},
        }
        box.x += self.output_box.x;
        box.y += self.output_box.y;
    }

    fn isXdgPopup(wlr_surface: *wlr.wlr_surface) bool {
        return std.mem.eql(u8, "xdg_popup", std.mem.span(
            @ptrCast(*const wlr.wlr_surface_role, wlr_surface.role).name,
        ));
    }

    fn adjustBoundsFromPopup(xdg_popup: *wlr.wlr_xdg_popup, parent_box: *wlr.wlr_box) void {
        parent_box.x += xdg_popup.geometry.x;
        parent_box.y += xdg_popup.geometry.y;

        if (@ptrCast(?*wlr.wlr_surface, xdg_popup.parent)) |parent| {
            if (Surface.isXdgPopup(parent)) {
                adjustBoundsFromPopup(
                    @field(@ptrCast(
                        *wlr.wlr_xdg_surface,
                        wlr.wlr_xdg_surface_from_wlr_surface(parent),
                    ), wlr_xdg_surface_union).popup,
                    parent_box,
                );
            }
        }
    }

    fn getParentBox(self: *Surface, box: *wlr.wlr_box) void {
        if (self.ancestor) |ancestor| {
            ancestor.getGeometry(box);
        } else {
            self.getGeometry(box);
        }

        switch (self.typed_surface) {
            .xdg => |xdg| {
                if (xdg.role == wlr.WLR_XDG_SURFACE_ROLE_POPUP) {
                    adjustBoundsFromPopup(
                        @field(xdg, wlr_xdg_surface_union).popup,
                        box,
                    );
                }
            },
            .subsurface => |subsurface| {
                var parent: *wlr.wlr_surface = subsurface.parent;
                if (Surface.isXdgPopup(parent)) {
                    adjustBoundsFromPopup(
                        @field(@ptrCast(
                            *wlr.wlr_xdg_surface,
                            wlr.wlr_xdg_surface_from_wlr_surface(parent),
                        ), wlr_xdg_surface_union).popup,
                        box,
                    );
                }
            },
            else => {},
        }
    }

    fn getLayoutBox(self: *Surface, box: *wlr.wlr_box) void {
        if (self.wlr_surface) |wlr_surface| {
            var parent_box: wlr.wlr_box = undefined;
            self.getParentBox(&parent_box);
            box.width = wlr_surface.current.width;
            box.height = wlr_surface.current.height;
            box.x = parent_box.x + wlr_surface.sx;
            box.y = parent_box.y + wlr_surface.sy;
        }
    }

    const UpdateOutput = struct {
        wlr_output: *wlr.wlr_output,
        enter: bool,
    };

    fn updateOutputIter(
        surf: [*c]wlr.wlr_surface,
        _: i32,
        _: i32,
        data: ?*anyopaque,
    ) callconv(.C) void {
        const uo = @ptrCast(*UpdateOutput, @alignCast(@alignOf(*UpdateOutput), data));
        const wlr_surface = @ptrCast(*wlr.wlr_surface, surf);

        if (uo.enter) {
            wlr.wlr_surface_send_enter(wlr_surface, uo.wlr_output);
            if (Surface.fromWlrSurface(wlr_surface)) |s| s.unconstrainPopup();
        } else {
            wlr.wlr_surface_send_leave(wlr_surface, uo.wlr_output);
        }
    }

    fn updateOutputs(self: *Surface) void {
        var box: wlr.wlr_box = undefined;
        self.getLayoutBox(&box);
        var iter = self.server.outputs.first;
        while (iter) |node| : (iter = node.next) {
            var output_box: wlr.wlr_box = undefined;
            node.data.getBox(&output_box);
            var intersection: wlr.wlr_box = undefined;
            var uo = UpdateOutput{
                .wlr_output = node.data.wlr_output,
                .enter = wlr.wlr_box_intersection(&intersection, &output_box, &box),
            };
            self.forEachSurface(updateOutputIter, &uo, false);
            self.forEachSurface(updateOutputIter, &uo, true);
        }
    }

    fn damage(self: *Surface, whole: bool) void {
        if (self.server.config.damage_tracking == .minimal) {
            self.server.damageAllOutputs();
            return;
        }

        var box: wlr.wlr_box = undefined;
        self.getLayoutBox(&box);
        var iter = self.server.outputs.first;
        while (iter) |node| : (iter = node.next) {
            const layout = node.data.getLayout();
            var intersection: wlr.wlr_box = undefined;
            var output_box: wlr.wlr_box = undefined;
            node.data.getBox(&output_box);

            if (wlr.wlr_box_intersection(&intersection, &output_box, &box)) {
                var ddata = DamageData{
                    .output = node.data,
                    .whole = whole,
                    .box = wlr.wlr_box{
                        .width = box.width,
                        .height = box.height,
                        .x = box.x - layout.x,
                        .y = box.y - layout.y,
                    },
                };

                self.forEachSurface(damageIter, &ddata, false);
            }
        }
    }

    const DamageData = struct {
        output: *Output,
        box: wlr.wlr_box,
        whole: bool,
    };

    fn damageIter(
        surf: [*c]wlr.wlr_surface,
        sx: i32,
        sy: i32,
        data: ?*anyopaque,
    ) callconv(.C) void {
        const ddata = @ptrCast(*DamageData, @alignCast(@alignOf(*DamageData), data));
        const wlr_surface = @ptrCast(*wlr.wlr_surface, surf);
        var box = ddata.box;
        box.x += sx;
        box.y += sy;
        scaleBox(&box, ddata.output.wlr_output.scale);

        if (wlr.pixman_region32_not_empty(&wlr_surface.buffer_damage) != 0) {
            var pixman_damage: wlr.pixman_region32_t = undefined;
            wlr.pixman_region32_init(&pixman_damage);
            wlr.wlr_surface_get_effective_damage(wlr_surface, &pixman_damage);
            wlr.wlr_region_scale(&pixman_damage, &pixman_damage, ddata.output.wlr_output.scale);
            if (@floatToInt(i32, @ceil(ddata.output.wlr_output.scale)) > wlr_surface.current.scale) {
                wlr.wlr_region_expand(
                    &pixman_damage,
                    &pixman_damage,
                    @floatToInt(i32, @ceil(ddata.output.wlr_output.scale)) - wlr_surface.current.scale,
                );
            }
            wlr.pixman_region32_translate(&pixman_damage, box.x, box.y);
            wlr.wlr_output_damage_add(ddata.output.damage, &pixman_damage);
            wlr.pixman_region32_fini(&pixman_damage);
        }

        if (ddata.whole) {
            wlr.wlr_output_damage_add_box(ddata.output.damage, &box);
        }

        if (wlr.wl_list_empty(&wlr_surface.current.frame_callback_list) == 0) {
            wlr.wlr_output_schedule_frame(ddata.output.wlr_output);
        }
    }
    fn forEachSurface(
        self: *Surface,
        cb: fn ([*c]wlr.wlr_surface, i32, i32, ?*anyopaque) callconv(.C) void,
        data: *anyopaque,
        popups: bool,
    ) void {
        switch (self.typed_surface) {
            .xdg => |xdg| {
                if (!popups) {
                    wlr.wlr_xdg_surface_for_each_surface(xdg, cb, data);
                } else {
                    wlr.wlr_xdg_surface_for_each_popup_surface(xdg, cb, data);
                }
            },
            .layer => |layer_surface| {
                if (!popups) {
                    wlr.wlr_layer_surface_v1_for_each_surface(layer_surface, cb, data);
                } else {
                    wlr.wlr_layer_surface_v1_for_each_popup_surface(layer_surface, cb, data);
                }
            },
            else => {
                wlr.wlr_surface_for_each_surface(self.wlr_surface, cb, data);
            },
        }
    }

    fn surfaceAt(self: *Surface, x: f64, y: f64, sx: *f64, sy: *f64) ?*wlr.wlr_surface {
        const vx = x - @intToFloat(f64, self.output_box.x);
        const vy = y - @intToFloat(f64, self.output_box.y);

        switch (self.typed_surface) {
            .xdg => |xdg| {
                return wlr.wlr_xdg_surface_surface_at(xdg, vx, vy, sx, sy);
            },
            .xwayland => |xwayland| {
                if (wlr.wlr_box_contains_point(&wlr.wlr_box{
                    .x = self.output_box.x,
                    .y = self.output_box.y,
                    .width = xwayland.width,
                    .height = xwayland.height,
                }, x, y)) {
                    return wlr.wlr_surface_surface_at(self.wlr_surface, vx, vy, sx, sy);
                }
            },
            .layer => |layer_surface| {
                if (layer_surface.mapped) {
                    return wlr.wlr_layer_surface_v1_surface_at(layer_surface, vx, vy, sx, sy);
                }
            },
            else => {},
        }

        return null;
    }

    fn updateBorders(self: *Surface) void {
        if (!self.has_border) return;

        var box: wlr.wlr_box = undefined;
        self.getGeometry(&box);
        box.x -= self.output_box.x;
        box.y -= self.output_box.y;
        var border_left: i32 = box.x - self.server.config.active_border_width;
        var border_top: i32 = box.y - self.server.config.active_border_width;
        self.borders = .{
            .{ // top
                .x = border_left,
                .y = border_top,
                .width = box.width + 2 * self.server.config.active_border_width,
                .height = self.server.config.active_border_width,
            },
            .{ // left
                .x = border_left,
                .y = border_top + self.server.config.active_border_width,
                .width = self.server.config.active_border_width,
                .height = box.height,
            },
            .{ // right
                .x = border_left + box.width + self.server.config.active_border_width,
                .y = border_top + self.server.config.active_border_width,
                .width = self.server.config.active_border_width,
                .height = box.height,
            },
            .{ // bottom
                .x = border_left,
                .y = border_top + box.height + self.server.config.active_border_width,
                .width = box.width + 2 * self.server.config.active_border_width,
                .height = self.server.config.active_border_width,
            },
        };
        self.damageBorders();
    }

    fn damageBorders(self: *Surface) void {
        if (self.has_border) {
            var iter = self.server.outputs.first;
            var parent_box: wlr.wlr_box = undefined;
            self.getParentBox(&parent_box);
            while (iter) |node| : (iter = node.next) {
                const layout = @ptrCast(
                    *wlr.wlr_output_layout_output,
                    wlr.wlr_output_layout_get(
                        self.server.wlr_output_layout,
                        node.data.wlr_output,
                    ),
                );

                for (self.borders) |border| {
                    var box = border;
                    box.x -= layout.x - parent_box.x;
                    box.y -= layout.y - parent_box.y;
                    scaleBox(&box, node.data.wlr_output.scale);
                    wlr.wlr_output_damage_add_box(node.data.damage, &box);
                }
            }
        }
    }

    fn getAppId(self: *Surface) [*:0]const u8 {
        return switch (self.typed_surface) {
            .xdg => |xdg| @ptrCast(
                *wlr.wlr_xdg_toplevel,
                @field(xdg, wlr_xdg_surface_union).toplevel,
            ).app_id,
            .xwayland => |xwayland| xwayland.class,
            else => "",
        };
    }

    fn getCenterOutput(self: *Surface) ?*Output {
        return self.server.outputAt(
            @intToFloat(f64, self.output_box.x + @divFloor(self.output_box.width, 2)),
            @intToFloat(f64, self.output_box.y + @divFloor(self.output_box.height, 2)),
        );
    }

    fn fromWlrSurface(wlr_surface: ?*wlr.wlr_surface) ?*Surface {
        if (wlr_surface) |surface| {
            return @ptrCast(?*Surface, @alignCast(@alignOf(?*Surface), surface.data));
        }

        return null;
    }

    fn getToplevel(self: *Surface) ?*Surface {
        if (self.has_border) {
            return self;
        } else if (self.ancestor) |ancestor| {
            return ancestor.getToplevel();
        } else {
            return null;
        }
    }

    fn move(
        self: *Surface,
        dir: Config.Direction,
        pixels: u32,
        comptime abscissa: []const u8,
        comptime ordinate: []const u8,
    ) void {
        if (self.getCenterOutput()) |output| {
            var box: wlr.wlr_box = undefined;
            self.getGeometry(&box);
            const factor = @floatToInt(
                i32,
                @intToFloat(f64, pixels) / output.wlr_output.scale,
            );
            const delta_abscissa: i32 = switch (dir) {
                .left => -1,
                .right => 1,
                else => 0,
            };
            const delta_ordinate: i32 = switch (dir) {
                .up => -1,
                .down => 1,
                else => 0,
            };
            @field(box, abscissa) += factor * delta_abscissa;
            @field(box, ordinate) += factor * delta_ordinate;
            self.setGeometry(box);
        }
    }

    fn toggleFullscreen(self: *Surface) void {
        if (self.is_actual_fullscreen) {
            self.is_actual_fullscreen = false;
            self.setGeometry(self.pre_fullscreen_position);
        } else {
            if (self.getCenterOutput()) |output| {
                self.is_actual_fullscreen = true;
                self.getGeometry(&self.pre_fullscreen_position);
                self.setGeometry(output.total_box);
            }
        }
    }

    fn place(self: *Surface) void {
        if (self.server.outputAtCursor()) |output| {
            self.workspace = output.active_workspace;
        }

        var parent_box = wlr.wlr_box{ .x = 0, .y = 0, .width = 0, .height = 0 };
        var box: wlr.wlr_box = undefined;
        self.getGeometry(&box);

        switch (self.typed_surface) {
            .xdg => |xdg| {
                if (xdg.role == wlr.WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
                    if (@ptrCast(?*wlr.wlr_xdg_surface, @ptrCast(
                        *wlr.wlr_xdg_toplevel,
                        @field(xdg, wlr_xdg_surface_union).toplevel,
                    ).parent)) |parent_xdg| {
                        if (Surface.fromWlrSurface(parent_xdg.surface)) |parent| {
                            parent.getGeometry(&parent_box);
                        }
                    }
                }
            },
            else => {},
        }

        if (parent_box.width == 0) {
            if (self.server.outputAtCursor()) |output| {
                output.getBox(&parent_box);
            }
        }

        box.x = parent_box.x + @divFloor(parent_box.width, 2) - @divFloor(box.width, 2);
        box.y = parent_box.y + @divFloor(parent_box.height, 2) - @divFloor(box.height, 2);
        self.setGeometry(box);
    }

    fn initDamageRender(
        box: wlr.wlr_box,
        region: *wlr.pixman_region32_t,
        output_damage: *wlr.pixman_region32_t,
    ) ?[]wlr.pixman_box32_t {
        wlr.pixman_region32_init(region);
        _ = wlr.pixman_region32_union_rect(
            region,
            region,
            box.x,
            box.y,
            @intCast(u32, box.width),
            @intCast(u32, box.height),
        );
        _ = wlr.pixman_region32_intersect(region, region, output_damage);
        if (wlr.pixman_region32_not_empty(region) != 0) {
            var num_rects: i32 = undefined;
            var rects: [*c]wlr.pixman_box32_t = wlr.pixman_region32_rectangles(region, &num_rects);
            return rects[0..@intCast(usize, num_rects)];
        }

        return null;
    }

    fn scaleLength(length: i32, offset: i32, scale: f64) i32 {
        return @floatToInt(i32, @round(@intToFloat(f64, offset + length) * scale) -
            @round(@intToFloat(f64, offset) * scale));
    }

    fn scaleBox(box: *wlr.wlr_box, scale: f64) void {
        box.x = @floatToInt(i32, @round(@intToFloat(f64, box.x) * scale));
        box.y = @floatToInt(i32, @round(@intToFloat(f64, box.y) * scale));
        box.width = scaleLength(box.width, box.x, scale);
        box.height = scaleLength(box.height, box.x, scale);
    }

    fn renderFirstFullscreen(surfaces: std.TailQueue(*Surface), rdata: *RenderData) bool {
        var iter = surfaces.last;
        return while (iter) |node| : (iter = node.prev) {
            if (node.data.is_actual_fullscreen) {
                node.data.triggerRender(rdata, false);
                break true;
            }
        } else false;
    }

    fn renderList(
        surfaces: std.TailQueue(*Surface),
        rdata: *RenderData,
        popups: bool,
    ) void {
        rdata.spread.set(surfaces, rdata.output);
        var iter = surfaces.last;
        rdata.spread.index = 0;
        while (iter) |node| : (iter = node.prev) {
            if (!node.data.isVisibleOn(rdata.output)) continue;
            node.data.triggerRender(rdata, popups);
            if (rdata.output.spread_view) rdata.spread.index += 1;
        }
    }

    fn isVisible(self: *Surface) bool {
        var iter = self.server.outputs.first;
        return while (iter) |node| : (iter = node.next) {
            if (self.isVisibleOn(node.data)) break true;
        } else false;
    }

    fn isVisibleOn(self: *Surface, output: *Output) bool {
        if (self.workspace != 0 and self.workspace != output.active_workspace) return false;
        var box: wlr.wlr_box = undefined;
        self.getGeometry(&box);
        return wlr.wlr_output_layout_intersects(
            output.server.wlr_output_layout,
            output.wlr_output,
            &box,
        );
    }

    fn triggerRender(self: *Surface, rdata: *RenderData, popups: bool) void {
        switch (self.typed_surface) {
            .xdg, .xwayland => {
                if (rdata.output.spread_view) {
                    const col = @intCast(i32, @rem(rdata.spread.index, rdata.spread.cols));
                    const row = @intCast(i32, @divFloor(rdata.spread.index, rdata.spread.cols));
                    rdata.x = col * rdata.spread.width + rdata.spread.margin_x + rdata.spread.layout.x;
                    rdata.y = row * rdata.spread.height + rdata.spread.margin_y + rdata.spread.layout.y;
                    rdata.spread.scale = @minimum(
                        @intToFloat(f32, rdata.spread.width - 2 * rdata.spread.margin_x) / @intToFloat(f32, self.output_box.width),
                        @intToFloat(f32, rdata.spread.height - 2 * rdata.spread.margin_y) / @intToFloat(f32, self.output_box.height),
                    );
                } else {
                    rdata.x = self.output_box.x;
                    rdata.y = self.output_box.y;
                }
            },
            .drag_icon => |drag_icon| {
                if (!drag_icon.mapped or rdata.output != self.server.outputAtCursor()) return;

                rdata.x = @floatToInt(i32, self.server.cursor.x);
                rdata.y = @floatToInt(i32, self.server.cursor.y);
            },
            else => {
                rdata.x = self.output_box.x;
                rdata.y = self.output_box.y;
            },
        }
        self.forEachSurface(renderIter, rdata, popups);
    }

    fn renderIter(
        surf: [*c]wlr.wlr_surface,
        sx: i32,
        sy: i32,
        data: ?*anyopaque,
    ) callconv(.C) void {
        if (Surface.fromWlrSurface(@ptrCast(*wlr.wlr_surface, surf))) |surface| {
            surface.render(@ptrCast(*RenderData, @alignCast(@alignOf(*RenderData), data)), sx, sy);
        } else {
            std.log.err("Could not find surface to render: {s}", .{@ptrCast(*const wlr.wlr_surface_role, @ptrCast(*wlr.wlr_surface, surf).role).name});
        }
    }

    fn render(self: *Surface, rdata: *RenderData, sx: i32, sy: i32) void {
        if (self.wlr_surface) |wlr_surface| {
            if (wlr.wlr_surface_get_texture(wlr_surface)) |texture| {
                var oxf: f64 = 0;
                var oyf: f64 = 0;
                wlr.wlr_output_layout_output_coords(
                    rdata.output.server.wlr_output_layout,
                    rdata.output.wlr_output,
                    &oxf,
                    &oyf,
                );

                oxf += @intToFloat(f64, rdata.x + sx);
                oyf += @intToFloat(f64, rdata.y + sy);
                const ox = @floatToInt(i32, oxf);
                const oy = @floatToInt(i32, oyf);

                var region: wlr.pixman_region32_t = undefined;

                if (self.has_border and !rdata.output.spread_view) {
                    const color = if (self == rdata.output.server.grabbed_toplevel)
                        &rdata.output.server.config.grabbed_color
                    else if (wlr_surface == rdata.output.server.seat.keyboard_state.focused_surface)
                        &rdata.output.server.config.focused_color
                    else
                        &rdata.output.server.config.border_color;
                    for (self.borders) |border| {
                        var b = border;
                        b.x += ox;
                        b.y += oy;
                        scaleBox(&b, rdata.output.wlr_output.scale);
                        if (initDamageRender(b, &region, rdata.damage)) |rects| {
                            for (rects) |rect| {
                                scissor(rdata.output.wlr_output, rect);
                                wlr.wlr_render_rect(
                                    rdata.output.wlr_output.renderer,
                                    &b,
                                    color,
                                    &rdata.output.wlr_output.transform_matrix,
                                );
                            }
                        }
                        wlr.pixman_region32_fini(&region);
                    }
                }

                var box = wlr.wlr_box{
                    .x = ox,
                    .y = oy,
                    .width = @floatToInt(i32, @intToFloat(f32, wlr_surface.current.width) * rdata.spread.scale),
                    .height = @floatToInt(i32, @intToFloat(f32, wlr_surface.current.height) * rdata.spread.scale),
                };
                scaleBox(&box, rdata.output.wlr_output.scale);
                var matrix: [9]f32 = undefined;
                const transform = wlr.wlr_output_transform_invert(wlr_surface.current.transform);
                wlr.wlr_matrix_project_box(&matrix, &box, transform, 0, &rdata.output.wlr_output.transform_matrix);

                if (initDamageRender(box, &region, rdata.damage)) |rects| {
                    for (rects) |rect| {
                        scissor(rdata.output.wlr_output, rect);
                        _ = wlr.wlr_render_texture_with_matrix(rdata.output.wlr_output.renderer, texture, &matrix, 1);
                    }
                }
                wlr.pixman_region32_fini(&region);
                wlr.wlr_surface_send_frame_done(wlr_surface, &rdata.when);
                wlr.wlr_presentation_surface_sampled_on_output(
                    rdata.output.server.presentation,
                    wlr_surface,
                    rdata.output.wlr_output,
                );
            }
        }
    }

    fn setActivated(self: *Surface, activated: bool) bool {
        switch (self.typed_surface) {
            .xdg => |xdg| {
                if (xdg.role == wlr.WLR_XDG_SURFACE_ROLE_TOPLEVEL) {
                    _ = wlr.wlr_xdg_toplevel_set_activated(xdg, activated);
                    return true;
                }
            },
            .xwayland => |xwayland| {
                wlr.wlr_xwayland_surface_activate(xwayland, activated);
                if (activated) {
                    wlr.wlr_xwayland_surface_restack(xwayland, null, wlr.XCB_STACK_MODE_ABOVE);
                }
                return true;
            },
            .layer => return true,
            else => {},
        }
        return false;
    }

    const SurfaceType = enum { xdg, xwayland, layer, subsurface, drag_icon };

    node: std.TailQueue(*Surface).Node,
    list: ?*std.TailQueue(*Surface),
    server: *Server,
    ancestor: ?*Surface,
    typed_surface: union(SurfaceType) {
        xdg: *wlr.wlr_xdg_surface,
        xwayland: *wlr.wlr_xwayland_surface,
        layer: *wlr.wlr_layer_surface_v1,
        subsurface: *wlr.wlr_subsurface,
        drag_icon: *wlr.wlr_drag_icon,
    },
    wlr_surface: ?*wlr.wlr_surface,
    mapped: bool,
    layer: wlr.zwlr_layer_shell_v1_layer,
    output_box: wlr.wlr_box,
    activate: wlr.wl_listener,
    configure: wlr.wl_listener,
    popup: wlr.wl_listener,
    subsurface: wlr.wl_listener,
    map: wlr.wl_listener,
    unmap: wlr.wl_listener,
    commit: wlr.wl_listener,
    destroy: wlr.wl_listener,
    request_fullscreen: wlr.wl_listener,
    is_requested_fullscreen: bool,
    has_border: bool,
    borders: [4]wlr.wlr_box,
    is_actual_fullscreen: bool,
    pre_fullscreen_position: wlr.wlr_box,
    workspace: u32,
    pending_serial: u32,
};

const Keyboard = struct {
    fn create(server: *Server, device: *wlr.wlr_input_device) !?*Keyboard {
        var keyboard = try alloc.create(Keyboard);
        keyboard.init(server, device);

        return keyboard;
    }
    fn init(self: *Keyboard, server: *Server, device: *wlr.wlr_input_device) void {
        self.node.data = self;
        self.server = server;
        self.device = device;
        self.wlr_keyboard = @field(device, wlr_input_device_union).keyboard;
        self.captured_modifiers = 0;

        self.server.keyboards.append(&self.node);
        var context = wlr.xkb_context_new(wlr.XKB_CONTEXT_NO_FLAGS);
        var keymap = wlr.xkb_keymap_new_from_names(
            context,
            null,
            wlr.XKB_KEYMAP_COMPILE_NO_FLAGS,
        );

        _ = wlr.wlr_keyboard_set_keymap(self.wlr_keyboard, keymap);
        wlr.xkb_keymap_unref(keymap);
        wlr.xkb_context_unref(context);
        wlr.wlr_keyboard_set_repeat_info(self.wlr_keyboard, 25, 600);

        Signal.connect(
            void,
            self,
            "modifiers",
            Keyboard.onModifiers,
            &self.wlr_keyboard.events.modifiers,
        );
        Signal.connect(
            *wlr.wlr_event_keyboard_key,
            self,
            "key",
            Keyboard.onKey,
            &self.wlr_keyboard.events.key,
        );

        wlr.wlr_seat_set_keyboard(server.seat, device);
    }

    fn onModifiers(self: *Keyboard, _: void) !void {
        wlr.wlr_seat_set_keyboard(self.server.seat, self.device);
        wlr.wlr_seat_keyboard_notify_modifiers(self.server.seat, &self.wlr_keyboard.modifiers);

        if (self.wlr_keyboard.modifiers.depressed == 0 and self.captured_modifiers != 0) {
            self.captured_modifiers = 0;
            self.server.reportHotkeyModifierState(false);
        }
    }

    fn onKey(self: *Keyboard, event: *wlr.wlr_event_keyboard_key) !void {
        wlr.wlr_idle_notify_activity(self.server.idle, self.server.seat);

        var handled = false;
        const keycode: u32 = event.keycode + 8;
        var syms: [*c]wlr.xkb_keysym_t = undefined;
        const nsyms = wlr.xkb_state_key_get_syms(self.wlr_keyboard.xkb_state, keycode, &syms);
        if (nsyms > 0) {
            const modifiers: u32 = wlr.wlr_keyboard_get_modifiers(self.wlr_keyboard);
            if (event.state == wlr.WL_KEYBOARD_KEY_STATE_PRESSED) {
                if (self.server.outputAtCursor()) |output| {
                    if (output.spread_view and modifiers == 0 and syms[0] == wlr.XKB_KEY_Escape) {
                        output.toggleSpreadView();
                        return;
                    }
                }
                if (self.server.input_inhibit_mgr.active_inhibitor == null) {
                    for (syms[0..@intCast(usize, nsyms)]) |symbol| {
                        handled = self.handleKeybinding(modifiers, symbol) or handled;
                        if (handled) break;
                    }
                }
            }
        }
        if (!handled) {
            wlr.wlr_seat_set_keyboard(self.server.seat, self.device);
            wlr.wlr_seat_keyboard_notify_key(
                self.server.seat,
                event.time_msec,
                event.keycode,
                event.state,
            );
        }
    }

    fn handleKeybinding(self: *Keyboard, modifiers: u32, symbol: wlr.xkb_keysym_t) bool {
        for (self.server.config.hotkeys) |hotkey| {
            if (hotkey.modifiers == modifiers and hotkey.key == symbol) {
                if (modifiers != 0) {
                    self.captured_modifiers = modifiers;
                    self.server.reportHotkeyModifierState(true);
                }

                hotkey.cb(self.server, hotkey.arg);
                return true;
            }
        }

        return false;
    }

    node: std.TailQueue(*Keyboard).Node,
    server: *Server,
    device: *wlr.wlr_input_device,
    wlr_keyboard: *wlr.wlr_keyboard,
    modifiers: wlr.wl_listener,
    key: wlr.wl_listener,
    captured_modifiers: u32,
};

const SpreadParams = struct {
    fn set(self: *SpreadParams, surfaces: std.TailQueue(*Surface), output: *Output) void {
        self.scale = 1;
        if (!output.spread_view) return;
        var visible_count: f32 = 0;
        var iter = surfaces.last;
        while (iter) |node| : (iter = node.prev) {
            if (node.data.isVisibleOn(output)) visible_count += 1;
        }
        if (visible_count == 0) return;
        self.layout = output.getLayout();
        self.rows = @floatToInt(u32, @sqrt(visible_count));
        self.cols = @floatToInt(u32, @ceil(visible_count / @intToFloat(f64, self.rows)));
        var output_box: wlr.wlr_box = undefined;
        output.getBox(&output_box);
        const margin_ratio = 20;
        self.margin_x = @divFloor(output_box.width, margin_ratio);
        self.margin_y = @divFloor(output_box.height, margin_ratio);
        self.width = @divFloor(output_box.width, @intCast(i32, self.cols));
        self.height = @divFloor(output_box.height, @intCast(i32, self.rows));
    }

    cols: u32,
    rows: u32,
    index: u32,
    scale: f32,
    layout: *wlr.wlr_output_layout_output,
    margin_x: i32,
    margin_y: i32,
    width: i32,
    height: i32,
};
const RenderData = struct {
    output: *Output,
    x: i32 = -1,
    y: i32 = -1,
    when: wlr.timespec,
    damage: *wlr.pixman_region32_t,
    spread: SpreadParams = undefined,
};

fn scissor(wlr_output: *wlr.wlr_output, rect: wlr.pixman_box32_t) void {
    var box = wlr.wlr_box{
        .x = rect.x1,
        .y = rect.y1,
        .width = rect.x2 - rect.x1,
        .height = rect.y2 - rect.y1,
    };

    var ow: i32 = undefined;
    var oh: i32 = undefined;
    wlr.wlr_output_transformed_resolution(wlr_output, &ow, &oh);
    var transform = wlr.wlr_output_transform_invert(wlr_output.transform);
    wlr.wlr_box_transform(&box, &box, transform, ow, oh);
    wlr.wlr_renderer_scissor(wlr_output.renderer, &box);
}

const Output = struct {
    fn create(server: *Server, wlr_output: *wlr.wlr_output) !?*Output {
        var output = try alloc.create(Output);
        output.init(server, wlr_output);

        return output;
    }
    fn init(self: *Output, server: *Server, wlr_output: *wlr.wlr_output) void {
        _ = wlr.wlr_output_init_render(wlr_output, server.wlr_allocator, server.wlr_renderer);
        if (wlr.wl_list_empty(&wlr_output.modes) == 0) {
            const mode = wlr.wlr_output_preferred_mode(wlr_output);
            wlr.wlr_output_set_mode(wlr_output, mode);
            wlr.wlr_output_enable_adaptive_sync(wlr_output, true);
            wlr.wlr_output_enable(wlr_output, true);
            if (!wlr.wlr_output_commit(wlr_output)) {
                alloc.destroy(self);
                return;
            }
        }

        self.node.data = self;
        self.active_workspace = 1;
        self.wlr_output = wlr_output;
        self.server = server;
        self.wlr_output.data = self;
        self.damage = wlr.wlr_output_damage_create(wlr_output);
        for (LAYERS_TOP_TO_BOTTOM) |layerIndex| {
            self.layers[layerIndex] = std.TailQueue(*Surface){};
        }
        self.server.outputs.append(&self.node);
        self.spread_view = false;
        wlr.wlr_output_layout_add_auto(self.server.wlr_output_layout, self.wlr_output);

        Signal.connect(
            void,
            self,
            "frame",
            Output.onFrame,
            &self.damage.events.frame,
        );
        Signal.connect(
            void,
            self,
            "destroy",
            Output.onDestroy,
            &wlr_output.events.destroy,
        );
    }

    fn fromWlrOutput(wlr_output: ?*wlr.wlr_output) ?*Output {
        if (wlr_output) |output| {
            return @ptrCast(?*Output, @alignCast(@alignOf(?*Output), output.data));
        }

        return null;
    }

    fn damageAll(self: *Output) void {
        wlr.wlr_output_damage_add_whole(self.damage);
    }

    fn onFrame(self: *Output, _: void) !void {
        var now: wlr.timespec = undefined;
        _ = wlr.clock_gettime(wlr.CLOCK_MONOTONIC, &now);

        var damage: wlr.pixman_region32_t = undefined;
        wlr.pixman_region32_init(&damage);
        var needs_frame: bool = false;

        if (!wlr.wlr_output_damage_attach_render(self.damage, &needs_frame, &damage)) {
            return;
        }

        if (needs_frame) {
            wlr.wlr_renderer_begin(
                self.wlr_output.renderer,
                @intCast(u32, self.wlr_output.width),
                @intCast(u32, self.wlr_output.height),
            );

            if (wlr.pixman_region32_not_empty(&damage) != 0) {
                var rdata: RenderData = .{ .output = self, .damage = &damage, .when = now };
                rdata.spread.scale = 1;

                var nrects: i32 = undefined;
                for (wlr.pixman_region32_rectangles(&damage, &nrects)[0..@intCast(usize, nrects)]) |rect| {
                    scissor(self.wlr_output, rect);
                    wlr.wlr_renderer_clear(self.wlr_output.renderer, &self.server.config.background_color);
                }

                if (!Surface.renderFirstFullscreen(self.server.toplevels, &rdata)) {
                    Surface.renderList(self.layers[wlr.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND], &rdata, false);
                    Surface.renderList(self.layers[wlr.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM], &rdata, false);
                    if (self.server.show_toplevels) Surface.renderList(self.server.toplevels, &rdata, false);
                    if (self.server.show_toplevels) Surface.renderList(self.server.unmanaged_toplevels, &rdata, false);
                    Surface.renderList(self.layers[wlr.ZWLR_LAYER_SHELL_V1_LAYER_TOP], &rdata, false);
                    Surface.renderList(self.layers[wlr.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY], &rdata, false);
                }
                if (self.server.grabbed_toplevel) |grabbed| grabbed.triggerRender(&rdata, false);
                if (self.server.drag_icon) |drag_icon| drag_icon.triggerRender(&rdata, false);
                Surface.renderList(self.layers[wlr.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND], &rdata, true);
                Surface.renderList(self.layers[wlr.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM], &rdata, true);
                Surface.renderList(self.layers[wlr.ZWLR_LAYER_SHELL_V1_LAYER_TOP], &rdata, true);
                Surface.renderList(self.layers[wlr.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY], &rdata, true);
            }
            wlr.wlr_renderer_scissor(self.wlr_output.renderer, null);
            wlr.wlr_output_render_software_cursors(self.wlr_output, null);
            wlr.wlr_renderer_end(self.wlr_output.renderer);
            wlr.wlr_output_set_damage(self.wlr_output, &self.damage.current);
            _ = wlr.wlr_output_commit(self.wlr_output);
        } else {
            wlr.wlr_output_rollback(self.wlr_output);
        }

        wlr.pixman_region32_fini(&damage);
    }

    fn onDestroy(self: *Output, _: void) !void {
        wlr.wl_list_remove(&self.frame.link);
        wlr.wl_list_remove(&self.destroy.link);
        self.server.outputs.remove(&self.node);
        wlr.wlr_output_layout_remove(self.server.wlr_output_layout, self.wlr_output);

        // TODO: move toplevels to remaining output
        alloc.destroy(self);
    }

    fn onLayoutChanged(self: *Output, config: *wlr.wlr_output_configuration_v1) void {
        var head: *wlr.wlr_output_configuration_head_v1 = wlr.wlr_output_configuration_head_v1_create(config, self.wlr_output);
        self.total_box = wlr.wlr_output_layout_get_box(
            self.server.wlr_output_layout,
            self.wlr_output,
        ).*;
        self.usable_box = self.total_box;
        head.state.enabled = self.wlr_output.enabled;
        head.state.mode = self.wlr_output.current_mode;
        head.state.x = self.total_box.x;
        head.state.y = self.total_box.y;
        self.arrangeLayers();
    }

    fn arrangeLayer(
        self: *Output,
        layer_surfaces: std.TailQueue(*Surface),
        usable_area: *wlr.wlr_box,
        exclusive: bool,
    ) void {
        const both_horiz: u32 = LAYER_ANCHOR_LEFT | LAYER_ANCHOR_RIGHT;
        const both_vert: u32 = LAYER_ANCHOR_TOP | LAYER_ANCHOR_BOTTOM;

        var iter = layer_surfaces.first;
        while (iter) |node| : (iter = node.next) {
            var surface = node.data;
            var state: *wlr.wlr_layer_surface_v1_state = &surface.typed_surface.layer.current;
            if (exclusive != (state.exclusive_zone > 0)) {
                continue;
            }

            var new_x: i32 = undefined;
            var new_y: i32 = undefined;
            var new_width = @intCast(i32, state.desired_width);
            var new_height = @intCast(i32, state.desired_height);
            var bounds: wlr.wlr_box = if (state.exclusive_zone == -1) self.total_box else usable_area.*;

            // Horizontal axis
            if (((state.anchor & both_horiz) != 0) and new_width == 0) {
                new_x = bounds.x;
                new_width = bounds.width;
            } else if ((state.anchor & LAYER_ANCHOR_LEFT) != 0) {
                new_x = bounds.x;
            } else if ((state.anchor & LAYER_ANCHOR_RIGHT) != 0) {
                new_x = bounds.x + bounds.width - new_width;
            } else {
                new_x = bounds.x + @divFloor(bounds.width, 2) - @divFloor(new_width, 2);
            }
            // Vertical axis
            if (((state.anchor & both_vert) != 0) and new_height == 0) {
                new_y = bounds.y;
                new_height = bounds.height;
            } else if ((state.anchor & LAYER_ANCHOR_TOP) != 0) {
                new_y = bounds.y;
            } else if ((state.anchor & LAYER_ANCHOR_BOTTOM) != 0) {
                new_y = bounds.y + bounds.height - new_height;
            } else {
                new_y = bounds.y + @divFloor(bounds.height, 2) - @divFloor(new_height, 2);
            }
            // Margin
            if ((state.anchor & both_horiz) == both_horiz) {
                new_x += state.margin.left;
                new_width -= state.margin.left + state.margin.right;
            } else if ((state.anchor & LAYER_ANCHOR_LEFT) != 0) {
                new_x += state.margin.left;
            } else if ((state.anchor & LAYER_ANCHOR_RIGHT) != 0) {
                new_x -= state.margin.right;
            }
            if ((state.anchor & both_vert) == both_vert) {
                new_y += state.margin.top;
                new_height -= state.margin.top + state.margin.bottom;
            } else if ((state.anchor & LAYER_ANCHOR_TOP) != 0) {
                new_y += state.margin.top;
            } else if ((state.anchor & LAYER_ANCHOR_BOTTOM) != 0) {
                new_y -= state.margin.bottom;
            }
            if (new_width < 0 or new_height < 0) {
                wlr.wlr_layer_surface_v1_destroy(surface.typed_surface.layer);
                continue;
            }

            surface.output_box = wlr.wlr_box{
                .x = @intCast(i32, new_x),
                .y = @intCast(i32, new_y),
                .width = @intCast(i32, new_width),
                .height = @intCast(i32, new_height),
            };

            if (state.exclusive_zone > 0)
                handleLayerExclusives(
                    usable_area,
                    state.anchor,
                    state.exclusive_zone,
                    state.margin.top,
                    state.margin.right,
                    state.margin.bottom,
                    state.margin.left,
                );
            _ = wlr.wlr_layer_surface_v1_configure(
                surface.typed_surface.layer,
                @intCast(u32, new_width),
                @intCast(u32, new_height),
            );
        }
    }

    fn arrangeLayers(self: *Output) void {
        var updated_usable_box = self.total_box;

        for (LAYERS_TOP_TO_BOTTOM) |layer| {
            self.arrangeLayer(self.layers[layer], &updated_usable_box, true);
        }

        if (!std.meta.eql(updated_usable_box, self.usable_box)) {
            self.usable_box = updated_usable_box;
            // TODO: move toplevels to avoid?
        }

        for (LAYERS_TOP_TO_BOTTOM) |layer| {
            self.arrangeLayer(self.layers[layer], &updated_usable_box, false);
        }
        self.damageAll();
    }

    fn layerSurfaceAt(
        self: *Output,
        layer: wlr.zwlr_layer_shell_v1_layer,
        x: f64,
        y: f64,
        sx: *f64,
        sy: *f64,
    ) ?*wlr.wlr_surface {
        var iter = self.layers[layer].last;
        return while (iter) |node| : (iter = node.prev) {
            if (node.data.surfaceAt(x, y, sx, sy)) |wlr_surface| {
                break wlr_surface;
            }
        } else null;
    }

    fn handleLayerExclusives(
        usable_area: *wlr.wlr_box,
        anchor: u32,
        exclusive: i32,
        margin_top: i32,
        margin_right: i32,
        margin_bottom: i32,
        margin_left: i32,
    ) void {
        const Edge = struct {
            singular_anchor: u32,
            anchor_triplet: u32,
            positive_axis: ?*i32,
            negative_axis: ?*i32,
            margin: i32,
        };

        const edges: [4]Edge = .{
            .{ // Top
                .singular_anchor = LAYER_ANCHOR_TOP,
                .anchor_triplet = LAYER_ANCHOR_LEFT | LAYER_ANCHOR_RIGHT | LAYER_ANCHOR_TOP,
                .positive_axis = &usable_area.y,
                .negative_axis = &usable_area.height,
                .margin = margin_top,
            },
            .{ // Bottom
                .singular_anchor = LAYER_ANCHOR_BOTTOM,
                .anchor_triplet = LAYER_ANCHOR_LEFT | LAYER_ANCHOR_RIGHT | LAYER_ANCHOR_BOTTOM,
                .positive_axis = null,
                .negative_axis = &usable_area.height,
                .margin = margin_bottom,
            },
            .{ // Left
                .singular_anchor = LAYER_ANCHOR_LEFT,
                .anchor_triplet = LAYER_ANCHOR_LEFT | LAYER_ANCHOR_TOP | LAYER_ANCHOR_BOTTOM,
                .positive_axis = &usable_area.x,
                .negative_axis = &usable_area.width,
                .margin = margin_left,
            },
            .{ // Right
                .singular_anchor = LAYER_ANCHOR_RIGHT,
                .anchor_triplet = LAYER_ANCHOR_RIGHT | LAYER_ANCHOR_TOP | LAYER_ANCHOR_BOTTOM,
                .positive_axis = null,
                .negative_axis = &usable_area.width,
                .margin = margin_right,
            },
        };

        for (edges) |*edge| {
            if ((anchor == edge.singular_anchor or anchor == edge.anchor_triplet) and
                exclusive + @intCast(i32, edge.margin) > 0)
            {
                if (edge.positive_axis) |*positive_axis| {
                    positive_axis.*.* += exclusive + @intCast(i32, edge.margin);
                }
                if (edge.negative_axis) |*negative_axis| {
                    negative_axis.*.* -= exclusive + @intCast(i32, edge.margin);
                }
                break;
            }
        }
    }

    fn getLayout(self: *Output) *wlr.wlr_output_layout_output {
        return @ptrCast(
            *wlr.wlr_output_layout_output,
            wlr.wlr_output_layout_get(self.server.wlr_output_layout, self.wlr_output),
        );
    }

    fn getBox(self: *Output, box: *wlr.wlr_box) void {
        const layout = self.getLayout();
        box.x = layout.x;
        box.y = layout.y;
        wlr.wlr_output_effective_resolution(
            self.wlr_output,
            &box.width,
            &box.height,
        );
    }

    fn toggleSpreadView(self: *Output) void {
        self.spread_view = !self.spread_view;
        self.damageAll();
    }

    const LAYERS_TOP_TO_BOTTOM: [LAYER_COUNT]usize = .{
        wlr.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
        wlr.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
        wlr.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
        wlr.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
    };
    const LAYER_COUNT = 4;

    const LAYER_ANCHOR_TOP = wlr.ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP;
    const LAYER_ANCHOR_LEFT = wlr.ZWLR_LAYER_SURFACE_V1_ANCHOR_LEFT;
    const LAYER_ANCHOR_BOTTOM = wlr.ZWLR_LAYER_SURFACE_V1_ANCHOR_BOTTOM;
    const LAYER_ANCHOR_RIGHT = wlr.ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT;

    node: std.TailQueue(*Output).Node,
    server: *Server,
    wlr_output: *wlr.wlr_output,
    frame: wlr.wl_listener,
    destroy: wlr.wl_listener,
    total_box: wlr.wlr_box,
    usable_box: wlr.wlr_box,
    layers: [LAYER_COUNT]std.TailQueue(*Surface),
    active_workspace: u32,
    damage: *wlr.wlr_output_damage,
    spread_view: bool,
};

const Server = struct {
    fn init(self: *Server) !void {
        self.config.init();
        self.drag_icon = null;
        self.grabbed_toplevel = null;
        self.modifier_pressed = false;
        self.show_toplevels = true;
        wlr.wlr_log_init(wlr.WLR_DEBUG, null);
        self.wl_display = wlr.wl_display_create() orelse
            return error.CannotCreateDisplay;
        self.wlr_backend = wlr.wlr_backend_autocreate(self.wl_display) orelse
            return error.CannotCreateBackend;
        self.wlr_renderer = wlr.wlr_renderer_autocreate(self.wlr_backend) orelse
            return error.CannotGetRenderer;
        _ = wlr.wlr_renderer_init_wl_display(self.wlr_renderer, self.wl_display);
        self.wlr_allocator = wlr.wlr_allocator_autocreate(self.wlr_backend, self.wlr_renderer);
        var compositor: *wlr.wlr_compositor = wlr.wlr_compositor_create(
            self.wl_display,
            self.wlr_renderer,
        ) orelse
            return error.CannotCreateCompositor;

        _ = wlr.wlr_data_device_manager_create(self.wl_display);
        _ = wlr.wlr_primary_selection_v1_device_manager_create(self.wl_display);
        _ = wlr.wlr_export_dmabuf_manager_v1_create(self.wl_display);
        _ = wlr.wlr_screencopy_manager_v1_create(self.wl_display);
        _ = wlr.wlr_data_control_manager_v1_create(self.wl_display);
        _ = wlr.wlr_gamma_control_manager_v1_create(self.wl_display);
        _ = wlr.wlr_viewporter_create(self.wl_display);
        self.wlr_output_layout = wlr.wlr_output_layout_create() orelse
            return error.CannotCreateOutputLayout;
        self.outputs = std.TailQueue(*Output){};
        Signal.connect(
            void,
            self,
            "output_changed",
            Server.onOutputLayoutChanged,
            &self.wlr_output_layout.events.change,
        );
        _ = wlr.wlr_xdg_output_manager_v1_create(self.wl_display, self.wlr_output_layout);
        Signal.connect(
            *wlr.wlr_output,
            self,
            "new_output",
            Server.onNewOutput,
            &self.wlr_backend.events.new_output,
        );
        self.toplevels = std.TailQueue(*Surface){};
        self.unmanaged_toplevels = std.TailQueue(*Surface){};
        self.xdg_shell = wlr.wlr_xdg_shell_create(self.wl_display);
        Signal.connect(
            *wlr.wlr_xdg_surface,
            self,
            "new_xdg_surface",
            Server.onNewXdgSurface,
            &self.xdg_shell.events.new_surface,
        );
        self.layer_shell = wlr.wlr_layer_shell_v1_create(self.wl_display);
        Signal.connect(
            *wlr.wlr_layer_surface_v1,
            self,
            "new_layer_surface",
            Server.onNewLayerSurface,
            &self.layer_shell.events.new_surface,
        );
        self.cursor_mode = .passthrough;
        self.cursor = wlr.wlr_cursor_create();
        wlr.wlr_cursor_attach_output_layout(self.cursor, self.wlr_output_layout);
        self.cursor_mgr = wlr.wlr_xcursor_manager_create(null, 24);
        _ = wlr.wlr_xcursor_manager_load(self.cursor_mgr, 1);
        Signal.connect(
            *wlr.wlr_event_pointer_motion,
            self,
            "cursor_motion",
            Server.onCursorMotion,
            &self.cursor.events.motion,
        );
        Signal.connect(
            *wlr.wlr_event_pointer_motion_absolute,
            self,
            "cursor_motion_absolute",
            Server.onCursorMotionAbsolute,
            &self.cursor.events.motion_absolute,
        );
        Signal.connect(
            *wlr.wlr_event_pointer_button,
            self,
            "cursor_button",
            Server.onCursorButton,
            &self.cursor.events.button,
        );
        Signal.connect(
            *wlr.wlr_event_pointer_axis,
            self,
            "cursor_axis",
            Server.onCursorAxis,
            &self.cursor.events.axis,
        );
        Signal.connect(
            void,
            self,
            "cursor_frame",
            Server.onCursorFrame,
            &self.cursor.events.frame,
        );
        self.keyboards = std.TailQueue(*Keyboard){};
        Signal.connect(
            *wlr.wlr_input_device,
            self,
            "new_input",
            Server.onNewInputDevice,
            &self.wlr_backend.events.new_input,
        );
        self.seat = wlr.wlr_seat_create(self.wl_display, "seat0");
        Signal.connect(
            *wlr.wlr_seat_pointer_request_set_cursor_event,
            self,
            "request_cursor",
            Server.onRequestSetCursor,
            &self.seat.events.request_set_cursor,
        );
        Signal.connect(
            *wlr.wlr_seat_request_set_selection_event,
            self,
            "request_set_selection",
            Server.onRequestSetSelection,
            &self.seat.events.request_set_selection,
        );
        Signal.connect(
            *wlr.wlr_seat_request_set_primary_selection_event,
            self,
            "request_set_primary_selection",
            Server.onRequestSetPrimarySelection,
            &self.seat.events.request_set_primary_selection,
        );
        Signal.connect(
            *wlr.wlr_seat_request_start_drag_event,
            self,
            "request_start_drag",
            Server.onRequestStartDrag,
            &self.seat.events.request_start_drag,
        );
        Signal.connect(
            *wlr.wlr_drag,
            self,
            "start_drag",
            Server.onStartDrag,
            &self.seat.events.start_drag,
        );
        wlr.wlr_server_decoration_manager_set_default_mode(
            wlr.wlr_server_decoration_manager_create(self.wl_display),
            wlr.WLR_SERVER_DECORATION_MANAGER_MODE_SERVER,
        );
        _ = wlr.wlr_xdg_decoration_manager_v1_create(self.wl_display);
        self.input_inhibit_mgr = wlr.wlr_input_inhibit_manager_create(self.wl_display);
        self.idle = wlr.wlr_idle_create(self.wl_display);
        self.output_manager = wlr.wlr_output_manager_v1_create(self.wl_display);
        Signal.connect(
            *wlr.wlr_output_configuration_v1,
            self,
            "output_manager_apply",
            Server.onOutputManagerApply,
            &self.output_manager.events.apply,
        );
        Signal.connect(
            *wlr.wlr_output_configuration_v1,
            self,
            "output_manager_test",
            Server.onOutputManagerTest,
            &self.output_manager.events.@"test",
        );
        self.presentation = wlr.wlr_presentation_create(self.wl_display, self.wlr_backend);
        self.xwayland = wlr.wlr_xwayland_create(self.wl_display, compositor, true);
        if (self.xwayland) |xwayland| {
            Signal.connect(
                void,
                self,
                "xwayland_ready",
                Server.onXwaylandReady,
                &xwayland.events.ready,
            );
            Signal.connect(
                *wlr.wlr_xwayland_surface,
                self,
                "new_xwayland_surface",
                Server.onNewXwaylandSurface,
                &xwayland.events.new_surface,
            );
            if (wlr.setenv("DISPLAY", xwayland.display_name, 1) == -1) {
                std.log.err("Failed to set DISPLAY env var for xwayland", .{});
            }
        } else {
            std.log.err("Failed to setup XWayland X server, continuing without it", .{});
        }
    }

    fn deinit(self: *Server) void {
        std.log.info("Shutting down Byway", .{});

        if (self.xwayland) |xwayland| {
            wlr.wlr_xwayland_destroy(xwayland);
        }
        wlr.wl_display_destroy_clients(self.wl_display);
        wlr.wl_display_destroy(self.wl_display);
        wlr.wlr_xcursor_manager_destroy(self.cursor_mgr);
        wlr.wlr_cursor_destroy(self.cursor);
        wlr.wlr_output_layout_destroy(self.wlr_output_layout);
    }

    fn start(self: *Server) !void {
        const socket = wlr.wl_display_add_socket_auto(self.wl_display) orelse return error.CannotAddSocket;

        if (!wlr.wlr_backend_start(self.wlr_backend)) {
            return error.CannotStartBackend;
        }

        if (wlr.setenv("WAYLAND_DISPLAY", socket, 1) == -1) {
            return error.CannotSetWaylandDisplayVar;
        }

        std.log.info("Running Byway on WAYLAND_DISPLAY={s}", .{socket});
        for (self.config.autostart.items) |cmd| {
            std.log.info("cmd {s}", .{cmd});
            self.actionCmd(cmd);
        }

        wlr.wl_display_run(self.wl_display);
    }

    fn onOutputLayoutChanged(self: *Server, _: void) !void {
        var config = wlr.wlr_output_configuration_v1_create();

        var iter = self.outputs.first;
        while (iter) |node| : (iter = node.next) {
            node.data.onLayoutChanged(config);
        }

        wlr.wlr_output_manager_v1_set_configuration(self.output_manager, config);
    }

    fn onNewOutput(self: *Server, wlr_output: *wlr.wlr_output) !void {
        _ = try Output.create(self, wlr_output);
    }

    fn onNewXdgSurface(self: *Server, xdg_surface: *wlr.wlr_xdg_surface) !void {
        _ = try Surface.create(self, xdg_surface, null);
    }

    fn onNewXwaylandSurface(self: *Server, xwayland_surface: *wlr.wlr_xwayland_surface) !void {
        _ = try Surface.create(self, xwayland_surface, null);
    }

    fn onNewLayerSurface(self: *Server, wlr_layer_surface: *wlr.wlr_layer_surface_v1) !void {
        _ = try Surface.create(self, wlr_layer_surface, null);
    }

    fn onCursorMotion(self: *Server, event: *wlr.wlr_event_pointer_motion) !void {
        wlr.wlr_cursor_move(self.cursor, event.device, event.delta_x, event.delta_y);
        self.processCursorMotion(event.time_msec);
    }

    fn onCursorMotionAbsolute(self: *Server, event: *wlr.wlr_event_pointer_motion_absolute) !void {
        wlr.wlr_cursor_warp_absolute(self.cursor, event.device, event.x, event.y);
        self.processCursorMotion(event.time_msec);
    }

    fn onCursorButton(self: *Server, event: *wlr.wlr_event_pointer_button) !void {
        wlr.wlr_idle_notify_activity(self.idle, self.seat);

        if (self.outputAtCursor()) |output| {
            if (output.spread_view) {
                var spread: SpreadParams = undefined;
                spread.set(self.toplevels, output);
                if (spread.cols == 0) return;
                const layout = output.getLayout();
                const col = @divTrunc(@floatToInt(i32, self.cursor.x) - layout.x, spread.width);
                const row = @divTrunc(@floatToInt(i32, self.cursor.y) - layout.y, spread.height);
                var index = row * @intCast(i32, spread.cols) + col;
                var iter = self.toplevels.last;
                while (iter) |node| : ({
                    iter = node.prev;
                    index -= 1;
                }) {
                    if (index == 0) {
                        self.toplevelToFront(node.data);
                        break;
                    }
                }
                output.toggleSpreadView();
                return;
            }
        }
        self.processCursorMotion(event.time_msec);

        var handled = false;

        if (event.state == wlr.WLR_BUTTON_RELEASED) {
            if (self.cursor_mode != .passthrough) {
                self.cursor_mode = .passthrough;
                handled = true;
                self.grabbed_toplevel = null;
            }
        } else {
            const keyboard = wlr.wlr_seat_get_keyboard(self.seat);
            const modifiers = wlr.wlr_keyboard_get_modifiers(keyboard);
            if (modifiers == self.config.mouse_move_modifiers and
                event.button == self.config.mouse_move_button)
            {
                self.actionMove();
                handled = true;
            } else if (modifiers == self.config.mouse_grow_modifiers and
                event.button == self.config.mouse_grow_button)
            {
                self.actionResize();
                handled = true;
            }
        }

        if (!handled) {
            _ = wlr.wlr_seat_pointer_notify_button(
                self.seat,
                event.time_msec,
                event.button,
                event.state,
            );
        }
    }

    fn onCursorAxis(self: *Server, event: *wlr.wlr_event_pointer_axis) !void {
        wlr.wlr_idle_notify_activity(self.idle, self.seat);
        self.processCursorMotion(event.time_msec);
        wlr.wlr_seat_pointer_notify_axis(
            self.seat,
            event.time_msec,
            event.orientation,
            event.delta,
            event.delta_discrete,
            event.source,
        );
    }

    fn onCursorFrame(self: *Server, _: void) !void {
        wlr.wlr_seat_pointer_notify_frame(self.seat);
    }

    fn setKeyboardFocus(self: *Server, wlr_surface: *wlr.wlr_surface) void {
        if (Surface.fromWlrSurface(wlr_surface)) |next_surface| {
            if (!next_surface.shouldFocus()) {
                return;
            }

            if (self.seat.keyboard_state.focused_surface) |prev_wlr_surface| {
                if (prev_wlr_surface == wlr_surface) {
                    return;
                }

                if (Surface.fromWlrSurface(prev_wlr_surface)) |prev_surface| {
                    _ = prev_surface.setActivated(false);
                    if (prev_surface != next_surface) {
                        prev_surface.damageBorders();
                    }
                }
            }

            if (next_surface.setActivated(true)) {
                const wlr_keyboard: *wlr.wlr_keyboard = wlr.wlr_seat_get_keyboard(self.seat);
                wlr.wlr_seat_keyboard_notify_enter(
                    self.seat,
                    wlr_surface,
                    &wlr_keyboard.keycodes,
                    wlr_keyboard.num_keycodes,
                    &wlr_keyboard.modifiers,
                );
            }

            next_surface.damageBorders();
        }
    }

    fn onNewInputDevice(self: *Server, device: *wlr.wlr_input_device) !void {
        switch (device.type) {
            wlr.WLR_INPUT_DEVICE_KEYBOARD => {
                _ = try Keyboard.create(self, device);
            },
            wlr.WLR_INPUT_DEVICE_POINTER => {
                if (wlr.wlr_input_device_is_libinput(device)) {
                    var libinput_device = wlr.wlr_libinput_get_device_handle(device);

                    if (self.config.tap_to_click and wlr.libinput_device_config_tap_get_finger_count(libinput_device) != 0) {
                        _ = wlr.libinput_device_config_tap_set_enabled(
                            libinput_device,
                            wlr.LIBINPUT_CONFIG_TAP_ENABLED,
                        );
                    }
                    if (wlr.libinput_device_config_scroll_has_natural_scroll(libinput_device) != 0) {
                        _ = wlr.libinput_device_config_scroll_set_natural_scroll_enabled(
                            libinput_device,
                            if (self.config.natural_scrolling) 1 else 0,
                        );
                    }
                }
                wlr.wlr_cursor_attach_input_device(self.cursor, device);
            },
            else => {},
        }

        var capabilities: u32 = wlr.WL_SEAT_CAPABILITY_POINTER;
        if (self.keyboards.first != null) capabilities |= wlr.WL_SEAT_CAPABILITY_KEYBOARD;
        wlr.wlr_seat_set_capabilities(self.seat, capabilities);
    }

    fn onRequestSetCursor(self: *Server, event: *wlr.wlr_seat_pointer_request_set_cursor_event) !void {
        if (self.seat.pointer_state.focused_client == event.seat_client) {
            wlr.wlr_cursor_set_surface(self.cursor, event.surface, event.hotspot_x, event.hotspot_y);
        }
    }

    fn onRequestSetSelection(self: *Server, event: *wlr.wlr_seat_request_set_selection_event) !void {
        wlr.wlr_seat_set_selection(self.seat, event.source, event.serial);
    }

    fn onRequestSetPrimarySelection(
        self: *Server,
        event: *wlr.wlr_seat_request_set_primary_selection_event,
    ) !void {
        wlr.wlr_seat_set_primary_selection(self.seat, event.source, event.serial);
    }

    fn onRequestStartDrag(self: *Server, event: *wlr.wlr_seat_request_start_drag_event) !void {
        if (wlr.wlr_seat_validate_pointer_grab_serial(self.seat, event.origin, event.serial)) {
            wlr.wlr_seat_start_pointer_drag(self.seat, event.drag, event.serial);
        } else {
            wlr.wlr_data_source_destroy(@ptrCast(*wlr.wlr_drag, event.drag).source);
        }
    }

    fn onStartDrag(self: *Server, wlr_drag: *wlr.wlr_drag) !void {
        self.drag_icon = try Surface.create(self, @ptrCast(*wlr.wlr_drag_icon, wlr_drag.icon), null);
        Signal.connect(
            void,
            self,
            "destroy_drag",
            Server.onDestroyDrag,
            &wlr_drag.events.destroy,
        );
    }

    fn onDestroyDrag(self: *Server, _: void) !void {
        self.drag_icon = null;
    }

    fn onOutputManagerApply(self: *Server, config: *wlr.wlr_output_configuration_v1) !void {
        self.outputManagerApply(config, false);
    }

    fn onOutputManagerTest(self: *Server, config: *wlr.wlr_output_configuration_v1) !void {
        self.outputManagerApply(config, true);
    }

    fn outputManagerApply(
        self: *Server,
        config: *wlr.wlr_output_configuration_v1,
        is_test: bool,
    ) void {
        var test_passed = true;

        var iter: *wlr.wl_list = config.heads.next;
        while (iter != &config.heads) : (iter = iter.next) {
            const head = @fieldParentPtr(wlr.wlr_output_configuration_head_v1, "link", iter);
            wlr.wlr_output_enable(head.state.output, head.state.enabled);
            if (head.state.enabled) {
                if (head.state.mode) |mode| {
                    wlr.wlr_output_set_mode(head.state.output, mode);
                } else {
                    wlr.wlr_output_set_custom_mode(
                        head.state.output,
                        head.state.custom_mode.width,
                        head.state.custom_mode.height,
                        head.state.custom_mode.refresh,
                    );
                }
                wlr.wlr_output_layout_move(
                    self.wlr_output_layout,
                    head.state.output,
                    head.state.x,
                    head.state.y,
                );
                wlr.wlr_output_set_transform(head.state.output, head.state.transform);
                wlr.wlr_output_set_scale(head.state.output, head.state.scale);
            }

            test_passed = wlr.wlr_output_test(head.state.output);
            if (!test_passed) {
                break;
            }
        }
        if (test_passed) {
            iter = config.heads.next;
            while (iter != &config.heads) : (iter = iter.next) {
                const head = @fieldParentPtr(wlr.wlr_output_configuration_head_v1, "link", iter);
                if (is_test) {
                    wlr.wlr_output_rollback(head.state.output);
                } else {
                    _ = wlr.wlr_output_commit(head.state.output);
                }
            }
            wlr.wlr_output_configuration_v1_send_succeeded(config);
        } else {
            wlr.wlr_output_configuration_v1_send_failed(config);
        }
        wlr.wlr_output_configuration_v1_destroy(config);
        self.configureCursor();
    }

    fn onXwaylandReady(self: *Server, _: void) !void {
        if (self.xwayland) |xwayland| {
            var xc = wlr.xcb_connect(xwayland.display_name, null);
            const xc_err = wlr.xcb_connection_has_error(xc);
            if (xc_err != 0) {
                std.log.err("xcb_connect failed with code {d}", .{xc_err});
                return;
            }

            wlr.wlr_xwayland_set_seat(xwayland, self.seat);

            if (wlr.wlr_xcursor_manager_get_xcursor(self.cursor_mgr, "left_ptr", 1)) |xcursor| {
                const img = @ptrCast(
                    *wlr.wlr_xcursor_image,
                    @ptrCast(*wlr.wlr_xcursor, xcursor).images[0],
                );
                wlr.wlr_xwayland_set_cursor(
                    xwayland,
                    img.buffer,
                    img.width * 4,
                    img.width,
                    img.height,
                    @intCast(i32, img.hotspot_x),
                    @intCast(i32, img.hotspot_y),
                );
            }
            wlr.xcb_disconnect(xc);
        }
    }

    fn processCursorMove(self: *Server) void {
        if (self.grabbed_toplevel) |toplevel| {
            var box: wlr.wlr_box = undefined;
            toplevel.getGeometry(&box);
            box.x = @floatToInt(i32, self.cursor.x) - self.grab_x;
            box.y = @floatToInt(i32, self.cursor.y) - self.grab_y;
            toplevel.setGeometry(box);
        }
    }

    fn processCursorResize(self: *Server) void {
        if (self.grabbed_toplevel) |toplevel| {
            var border_x = @floatToInt(i32, self.cursor.x) - self.grab_x;
            var border_y = @floatToInt(i32, self.cursor.y) - self.grab_y;
            var new_position: wlr.wlr_box = undefined;
            new_position.x = self.grab_geobox.x;
            var new_right = self.grab_geobox.x + self.grab_geobox.width;
            new_position.y = self.grab_geobox.y;
            var new_bottom = self.grab_geobox.y + self.grab_geobox.height;

            if (self.resize_edges & wlr.WLR_EDGE_TOP != 0) {
                new_position.y = border_y;
                if (new_position.y >= new_bottom) {
                    new_position.y = new_bottom - 1;
                }
            } else if (self.resize_edges & wlr.WLR_EDGE_BOTTOM != 0) {
                new_bottom = border_y;
                if (new_bottom <= new_position.y) {
                    new_bottom = new_position.y + 1;
                }
            }
            if (self.resize_edges & wlr.WLR_EDGE_LEFT != 0) {
                new_position.x = border_x;
                if (new_position.x >= new_right) {
                    new_position.x = new_right - 1;
                }
            } else if (self.resize_edges & wlr.WLR_EDGE_RIGHT != 0) {
                new_right = border_x;
                if (new_right <= new_position.x) {
                    new_right = new_position.x + 1;
                }
            }

            new_position.width = new_right - new_position.x;
            new_position.height = new_bottom - new_position.y;
            toplevel.setGeometry(new_position);
        }
    }

    fn outputAt(self: *Server, x: f64, y: f64) ?*Output {
        return Output.fromWlrOutput(wlr.wlr_output_layout_output_at(self.wlr_output_layout, x, y));
    }

    fn outputAtCursor(self: *Server) ?*Output {
        return self.outputAt(self.cursor.x, self.cursor.y);
    }

    fn processCursorMotion(self: *Server, time: u32) void {
        wlr.wlr_idle_notify_activity(self.idle, self.seat);

        if (self.cursor_mode == .move) {
            self.processCursorMove();
            return;
        } else if (self.cursor_mode == .resize) {
            self.processCursorResize();
            return;
        }

        if (self.outputAtCursor()) |output| {
            if (output.spread_view) return;

            var sx: f64 = undefined;
            var sy: f64 = undefined;
            var wlr_surface: ?*wlr.wlr_surface = null;

            wlr_surface = output.layerSurfaceAt(
                wlr.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
                self.cursor.x,
                self.cursor.y,
                &sx,
                &sy,
            );

            if (wlr_surface == null) {
                wlr_surface = output.layerSurfaceAt(
                    wlr.ZWLR_LAYER_SHELL_V1_LAYER_TOP,
                    self.cursor.x,
                    self.cursor.y,
                    &sx,
                    &sy,
                );
            }

            if (wlr_surface == null) {
                wlr_surface = self.toplevelAt(self.cursor.x, self.cursor.y, &sx, &sy);
            }

            if (wlr_surface == null) {
                wlr_surface = output.layerSurfaceAt(
                    wlr.ZWLR_LAYER_SHELL_V1_LAYER_BOTTOM,
                    self.cursor.x,
                    self.cursor.y,
                    &sx,
                    &sy,
                );
            }

            if (wlr_surface == null) {
                wlr_surface = output.layerSurfaceAt(
                    wlr.ZWLR_LAYER_SHELL_V1_LAYER_BACKGROUND,
                    self.cursor.x,
                    self.cursor.y,
                    &sx,
                    &sy,
                );
            }

            if (wlr_surface) |surface_under_cursor| {
                self.setKeyboardFocus(surface_under_cursor);
                wlr.wlr_seat_pointer_notify_enter(self.seat, surface_under_cursor, sx, sy);
                wlr.wlr_seat_pointer_notify_motion(self.seat, time, sx, sy);
            } else {
                wlr.wlr_seat_pointer_clear_focus(self.seat);
                wlr.wlr_xcursor_manager_set_cursor_image(self.cursor_mgr, "left_ptr", self.cursor);
                var focused_surface = Surface.fromWlrSurface(self.seat.keyboard_state.focused_surface);
                if (focused_surface == null or !focused_surface.?.mapped) {
                    var iter = self.toplevels.first;
                    while (iter) |node| : (iter = node.next) {
                        if (node.data.workspace == output.active_workspace) {
                            node.data.setKeyboardFocus();
                            break;
                        }
                    }
                }
            }
        }
    }

    fn toplevelAt(
        self: *Server,
        x: f64,
        y: f64,
        sx: *f64,
        sy: *f64,
    ) ?*wlr.wlr_surface {
        if (self.outputAt(x, y)) |output| {
            for ([2]std.TailQueue(*Surface){
                self.unmanaged_toplevels,
                self.toplevels,
            }) |list| {
                var iter = list.first;
                while (iter) |node| : (iter = node.next) {
                    var toplevel = node.data;
                    if (toplevel.workspace != output.active_workspace) {
                        continue;
                    }
                    if (toplevel.surfaceAt(x, y, sx, sy)) |wlr_surface| {
                        return wlr_surface;
                    }
                }
            }
        }
        return null;
    }

    fn actionMove(self: *Server) void {
        self.grabToplevelForResizeMove(.move);
    }

    fn actionResize(self: *Server) void {
        self.grabToplevelForResizeMove(.resize);

        if (self.grabbed_toplevel) |toplevel| {
            toplevel.getGeometry(&self.grab_geobox);

            self.resize_edges = 0;

            var cursor_x = @floatToInt(i32, self.cursor.x);
            var cursor_y = @floatToInt(i32, self.cursor.y);
            if (cursor_x < self.grab_geobox.x + @divFloor(self.grab_geobox.width, 2)) {
                self.resize_edges |= wlr.WLR_EDGE_LEFT;
            } else {
                self.resize_edges |= wlr.WLR_EDGE_RIGHT;
            }
            if (cursor_y < self.grab_geobox.y + @divFloor(self.grab_geobox.height, 2)) {
                self.resize_edges |= wlr.WLR_EDGE_TOP;
            } else {
                self.resize_edges |= wlr.WLR_EDGE_BOTTOM;
            }

            var border_x = self.grab_geobox.x + (if ((self.resize_edges & wlr.WLR_EDGE_RIGHT) == 0) 0 else self.grab_geobox.width);
            var border_y = self.grab_geobox.y + (if ((self.resize_edges & wlr.WLR_EDGE_BOTTOM) == 0) 0 else self.grab_geobox.height);
            self.grab_x = cursor_x - border_x;
            self.grab_y = cursor_y - border_y;
        }
    }

    fn actionCmd(_: *Server, cmd: []const u8) void {
        const childProc = std.ChildProcess.init(&.{ "/bin/sh", "-c", cmd }, alloc) catch |err| {
            std.log.err("command failed: {s} {s}", .{ cmd, err });
            return;
        };
        childProc.spawn() catch |err| {
            std.log.err("command failed: {s} {s}", .{ cmd, err });
            return;
        };
    }

    fn grabToplevelForResizeMove(self: *Server, cursor_mode: CursorMode) void {
        if (self.getFocusedToplevel()) |toplevel| {
            if (!toplevel.is_actual_fullscreen) {
                var box: wlr.wlr_box = undefined;
                toplevel.getGeometry(&box);
                self.grabbed_toplevel = toplevel;
                self.cursor_mode = cursor_mode;
                self.grab_x = @floatToInt(i32, self.cursor.x) - box.x;
                self.grab_y = @floatToInt(i32, self.cursor.y) - box.y;
            }
        }
    }

    fn getFocusedToplevel(self: *Server) ?*Surface {
        if (Surface.fromWlrSurface(self.seat.keyboard_state.focused_surface)) |surface| {
            return surface.getToplevel();
        }
        return null;
    }

    fn toplevelToFront(self: *Server, surface: *Surface) void {
        surface.setKeyboardFocus();
        self.toplevels.remove(&surface.node);
        self.toplevels.prepend(&surface.node);
        surface.toFront();
        self.damageAllOutputs();
    }

    fn actionToplevelToFront(self: *Server, _: []const u8) void {
        if (self.getFocusedToplevel()) |toplevel| {
            self.toplevelToFront(toplevel);
        }
    }

    fn actionToplevelToBack(self: *Server, _: []const u8) void {
        if (self.getFocusedToplevel()) |toplevel| {
            self.toplevels.remove(&toplevel.node);
            self.toplevels.append(&toplevel.node);
            toplevel.toBack();
            self.damageAllOutputs();
        }
    }

    fn actionToplevelToWorkspace(self: *Server, arg: []const u8) void {
        if (self.getFocusedToplevel()) |toplevel| {
            const workspace = std.fmt.parseUnsigned(u32, arg, 10) catch return;
            toplevel.workspace = workspace;
            self.processCursorMotion(0);
            self.damageAllOutputs();
        }
    }

    fn actionSwitchToWorkspace(self: *Server, arg: []const u8) void {
        if (self.outputAtCursor()) |output| {
            const workspace = std.fmt.parseUnsigned(u32, arg, 10) catch return;
            output.active_workspace = workspace;
            self.processCursorMotion(0);
            output.damageAll();
        }
    }

    fn actionToggleSpreadView(self: *Server, _: []const u8) void {
        if (self.outputAtCursor()) |output| output.toggleSpreadView();
    }

    fn actionToggleHideToplevels(self: *Server, _: []const u8) void {
        self.show_toplevels = !self.show_toplevels;
        self.damageAllOutputs();
    }

    fn actionQuit(self: *Server, _: []const u8) void {
        wlr.wl_display_terminate(self.wl_display);
    }

    fn actionChvt(self: *Server, arg: []const u8) void {
        const vt = std.fmt.parseUnsigned(u32, arg, 10) catch return;
        _ = wlr.wlr_session_change_vt(wlr.wlr_backend_get_session(self.wlr_backend), vt);
    }

    fn nextIterCirc(list: std.TailQueue(*Surface), node: *std.TailQueue(*Surface).Node, forward: bool) ?*std.TailQueue(*Surface).Node {
        var iter = if (forward) node.next else node.prev;

        if (iter) |i| return i;

        return if (forward) list.first else list.last;
    }

    fn grabNextToplevel(self: *Server, forward: bool, app_id_comp: bool) void {
        if (if (self.grabbed_toplevel != null)
            self.grabbed_toplevel
        else
            self.getFocusedToplevel()) |start_toplevel|
        {
            var start_node = &start_toplevel.node;
            var iter = Server.nextIterCirc(self.toplevels, start_node, forward);
            while (iter) |node| : (iter = Server.nextIterCirc(self.toplevels, node, forward)) {
                if (node == start_node) {
                    break;
                }

                if (!node.data.isVisible()) continue;

                if (std.mem.eql(
                    u8,
                    std.mem.span(node.data.getAppId()),
                    std.mem.span(start_node.data.getAppId()),
                ) != app_id_comp) {
                    continue;
                }

                self.grabbed_toplevel = node.data;
                self.damageAllOutputs();
                break;
            }
        }
    }

    fn actionCycleToplevels(self: *Server, arg: []const u8) void {
        var forward = std.fmt.parseInt(i32, arg, 10) catch return;
        self.grabNextToplevel(forward > 0, true);
    }

    fn actionCycleGroups(self: *Server, arg: []const u8) void {
        var forward = std.fmt.parseInt(i32, arg, 10) catch return;
        self.grabNextToplevel(forward > 0, false);
    }

    fn reportHotkeyModifierState(self: *Server, pressed: bool) void {
        self.modifier_pressed = pressed;
        if (!pressed and self.cursor_mode == .passthrough) {
            if (self.grabbed_toplevel) |grabbed_toplevel| {
                self.grabbed_toplevel = null;
                self.toplevelToFront(grabbed_toplevel);
            }
        }
    }

    fn keyboardAdjustToplevel(
        self: *Server,
        arg: []const u8,
        comptime abscissa: []const u8,
        comptime ordinate: []const u8,
    ) void {
        if (self.getFocusedToplevel()) |toplevel| {
            if (std.meta.stringToEnum(Config.Direction, arg)) |dir| {
                toplevel.move(dir, self.config.move_pixels, abscissa, ordinate);
            }
        }
    }
    fn actionMoveKeyboard(self: *Server, arg: []const u8) void {
        self.keyboardAdjustToplevel(arg, "x", "y");
    }

    fn actionGrowKeyboard(self: *Server, arg: []const u8) void {
        self.keyboardAdjustToplevel(arg, "width", "height");
    }

    fn actionToggleFullscreen(self: *Server, _: []const u8) void {
        if (self.getFocusedToplevel()) |toplevel| {
            self.toplevelToFront(toplevel);
            toplevel.toggleFullscreen();
        }
    }

    fn actionReloadConfig(self: *Server, _: []const u8) void {
        self.config.reload();
    }

    fn damageAllOutputs(self: *Server) void {
        var iter = self.outputs.first;
        while (iter) |node| : (iter = node.next) {
            node.data.damageAll();
        }
    }

    fn configureCursor(self: *Server) void {
        var iter = self.outputs.first;
        while (iter) |node| : (iter = node.next) {
            _ = wlr.wlr_xcursor_manager_load(self.cursor_mgr, node.data.wlr_output.scale);
        }
    }

    config: Config,
    wl_display: *wlr.wl_display,
    wlr_backend: *wlr.wlr_backend,
    wlr_renderer: *wlr.wlr_renderer,
    wlr_allocator: *wlr.wlr_allocator,

    toplevels: std.TailQueue(*Surface),
    unmanaged_toplevels: std.TailQueue(*Surface),
    show_toplevels: bool,

    wlr_output_layout: *wlr.wlr_output_layout,
    outputs: std.TailQueue(*Output),
    output_changed: wlr.wl_listener,
    new_output: wlr.wl_listener,
    output_manager: *wlr.wlr_output_manager_v1,
    output_manager_test: wlr.wl_listener,
    output_manager_apply: wlr.wl_listener,

    xdg_shell: *wlr.wlr_xdg_shell,
    new_xdg_surface: wlr.wl_listener,
    layer_shell: *wlr.wlr_layer_shell_v1,
    new_layer_surface: wlr.wl_listener,

    cursor: *wlr.wlr_cursor,
    cursor_mgr: *wlr.wlr_xcursor_manager,
    cursor_motion: wlr.wl_listener,
    cursor_motion_absolute: wlr.wl_listener,
    cursor_button: wlr.wl_listener,
    cursor_axis: wlr.wl_listener,
    cursor_frame: wlr.wl_listener,

    seat: *wlr.wlr_seat,
    new_input: wlr.wl_listener,
    request_cursor: wlr.wl_listener,
    request_set_selection: wlr.wl_listener,
    request_set_primary_selection: wlr.wl_listener,
    request_start_drag: wlr.wl_listener,
    start_drag: wlr.wl_listener,
    destroy_drag: wlr.wl_listener,
    drag_icon: ?*Surface,

    keyboards: std.TailQueue(*Keyboard),
    cursor_mode: CursorMode,
    grabbed_toplevel: ?*Surface,
    grab_geobox: wlr.wlr_box,
    grab_x: i32,
    grab_y: i32,
    resize_edges: u32,
    modifier_pressed: bool,

    input_inhibit_mgr: *wlr.wlr_input_inhibit_manager,
    idle: *wlr.wlr_idle,

    presentation: *wlr.wlr_presentation,
    new_xwayland_surface: wlr.wl_listener,
    xwayland_ready: wlr.wl_listener,
    xwayland: ?*wlr.wlr_xwayland,

    const CursorMode = enum {
        passthrough,
        move,
        resize,
    };
};

const Config = struct {
    const Action = enum {
        command,
        toplevel_to_front,
        toplevel_to_back,
        cycle_groups,
        cycle_toplevels,
        move_toplevel,
        grow_toplevel,
        toggle_fullscreen,
        toggle_spread_view,
        toggle_hide_toplevels,
        switch_to_workspace,
        toplevel_to_workspace,
        quit,
        chvt,
        reload_config,
    };

    const Direction = enum {
        up,
        down,
        left,
        right,
    };

    const DamageTrackingLevel = enum {
        minimal,
        partial,
        full,
    };

    const KeyModifier = enum(u32) {
        shift = wlr.WLR_MODIFIER_SHIFT,
        caps = wlr.WLR_MODIFIER_CAPS,
        ctrl = wlr.WLR_MODIFIER_CTRL,
        alt = wlr.WLR_MODIFIER_ALT,
        mod2 = wlr.WLR_MODIFIER_MOD2,
        mod3 = wlr.WLR_MODIFIER_MOD3,
        logo = wlr.WLR_MODIFIER_LOGO,
        mod5 = wlr.WLR_MODIFIER_MOD5,
    };

    const MouseButton = enum(u32) {
        left = wlr.BTN_LEFT,
        right = wlr.BTN_RIGHT,
        middle = wlr.BTN_MIDDLE,
    };

    const Unparsed = struct {
        tap_to_click: ?bool = null,
        natural_scrolling: ?bool = null,
        background_color: ?[4]f32 = null,
        border_color: ?[4]f32 = null,
        focused_color: ?[4]f32 = null,
        grabbed_color: ?[4]f32 = null,
        active_border_width: ?i32 = null,
        hotkeys: ?[]struct {
            modifiers: []KeyModifier,
            key: []u8,
            action: Action,
            arg: []u8,
        } = null,
        mouse_move_modifiers: ?[]KeyModifier = null,
        mouse_move_button: ?MouseButton = null,
        mouse_grow_modifiers: ?[]KeyModifier = null,
        mouse_grow_button: ?MouseButton = null,
        autostart: ?[][]u8 = null,
        move_pixels: ?u32 = null,
        grow_pixels: ?u32 = null,
        damage_tracking: ?DamageTrackingLevel = null,
    };

    fn loadDefault(self: *Config) void {
        const default =
            \\ {
            \\     "tap_to_click": true,
            \\     "natural_scrolling": true,
            \\     "background_color": [0.3, 0.3, 0.3, 1.0],
            \\     "border_color": [0.5, 0.5, 0.5, 1.0],
            \\     "focused_color": [0.28, 0.78, 1.0, 1.0],
            \\     "grabbed_color": [1.0, 0.6, 0.7, 1.0],
            \\     "active_border_width": 3,
            \\     "autostart": [],
            \\     "move_pixels": 10,
            \\     "grow_pixels": 10,
            \\     "damage_tracking": "minimal",
            \\     "mouse_move_modifiers": ["logo"],
            \\     "mouse_move_button": "left",
            \\     "mouse_grow_modifiers": ["logo", "shift"],
            \\     "mouse_grow_button": "left",
            \\     "hotkeys": [
            \\         {
            \\             "modifiers": ["logo"],
            \\             "key": "t",
            \\             "action": "command",
            \\             "arg": "$TERM"
            \\         },
            \\         {
            \\             "modifiers": ["ctrl", "alt"],
            \\             "key": "BackSpace",
            \\             "action": "quit",
            \\             "arg": ""
            \\         }
            \\     ]
            \\ }
        ;
        load(self, default);
    }

    fn loadFromFile(self: *Config) void {
        var path: ?[]const u8 = std.os.getenv("XDG_CONFIG_HOME");
        if (path == null) {
            path = std.mem.concat(
                alloc,
                u8,
                &[2][]const u8{ std.os.getenv("HOME").?, "/.config" },
            ) catch |err| {
                std.log.err("Could not read config: {s}", .{err});
                return;
            };
        }

        if (path) |cfgdir| {
            defer alloc.free(cfgdir);
            const cfgpath = std.mem.concat(alloc, u8, &.{ cfgdir, "/byway" }) catch |err| {
                std.log.err("Could not read config: {s}", .{err});
                return;
            };
            defer alloc.free(cfgpath);
            var byway_config_dir = std.fs.cwd().openDir(cfgpath, .{}) catch |err| {
                std.log.err("Could not read config: {s}", .{err});
                return;
            };
            defer byway_config_dir.close();
            const contents = byway_config_dir.readFileAlloc(
                alloc,
                "config.json",
                256000,
            ) catch |err| {
                std.log.err("Could not read config: {s}", .{err});
                return;
            };
            defer alloc.free(contents);

            load(self, contents);
        }
    }

    fn load(self: *Config, update: []const u8) void {
        var stream = std.json.TokenStream.init(update);
        @setEvalBranchQuota(10000);
        const parsed = std.json.parse(Unparsed, &stream, .{
            .ignore_unknown_fields = true,
            .allocator = alloc,
        }) catch |err| {
            std.log.err("Could not parse config: {s}", .{err});
            return;
        };
        defer std.json.parseFree(Unparsed, parsed, .{
            .allocator = alloc,
        });

        if (parsed.mouse_grow_button) |mgb| self.mouse_grow_button = @enumToInt(mgb);
        if (parsed.mouse_grow_modifiers) |mgm| {
            self.mouse_grow_modifiers = 0;
            for (mgm) |mod| {
                self.mouse_grow_modifiers |= @enumToInt(mod);
            }
        }
        if (parsed.mouse_move_button) |mmb| self.mouse_move_button = @enumToInt(mmb);
        if (parsed.mouse_move_modifiers) |mmm| {
            self.mouse_move_modifiers = 0;
            for (mmm) |mod| {
                self.mouse_move_modifiers |= @enumToInt(mod);
            }
        }

        if (parsed.tap_to_click) |val| self.tap_to_click = val;
        if (parsed.natural_scrolling) |val| self.natural_scrolling = val;
        if (parsed.background_color) |val| self.background_color = val;
        if (parsed.border_color) |val| self.border_color = val;
        if (parsed.focused_color) |val| self.focused_color = val;
        if (parsed.grabbed_color) |val| self.grabbed_color = val;
        if (parsed.active_border_width) |val| self.active_border_width = val;
        if (parsed.move_pixels) |val| self.move_pixels = val;
        if (parsed.grow_pixels) |val| self.grow_pixels = val;
        if (parsed.damage_tracking) |val| self.damage_tracking = val;

        if (parsed.autostart) |autostart| {
            self.autostart.clearAndFree();
            for (autostart) |cmdcfg| {
                var cmd = alloc.alloc(u8, cmdcfg.len) catch return;
                std.mem.copy(u8, cmd, cmdcfg);
                self.autostart.append(cmd) catch return;
            }
        }
        if (parsed.hotkeys) |hotkeys| {
            self.hotkeys = alloc.alloc(Hotkey, hotkeys.len) catch unreachable;
            for (hotkeys) |hotkeyConfig, idx| {
                self.hotkeys[idx].arg = alloc.alloc(u8, hotkeyConfig.arg.len) catch return;
                std.mem.copy(u8, self.hotkeys[idx].arg, hotkeyConfig.arg);

                self.hotkeys[idx].modifiers = 0;
                for (hotkeyConfig.modifiers) |mod| {
                    self.hotkeys[idx].modifiers |= @enumToInt(mod);
                }
                var configKey = std.cstr.addNullByte(alloc, hotkeyConfig.key) catch return;
                defer alloc.free(configKey);
                self.hotkeys[idx].key = wlr.xkb_keysym_from_name(configKey, wlr.XKB_KEYSYM_NO_FLAGS);
                self.hotkeys[idx].cb = switch (hotkeyConfig.action) {
                    .command => Server.actionCmd,
                    .toplevel_to_front => Server.actionToplevelToFront,
                    .toplevel_to_back => Server.actionToplevelToBack,
                    .cycle_groups => Server.actionCycleGroups,
                    .cycle_toplevels => Server.actionCycleToplevels,
                    .move_toplevel => Server.actionMoveKeyboard,
                    .grow_toplevel => Server.actionGrowKeyboard,
                    .toggle_fullscreen => Server.actionToggleFullscreen,
                    .switch_to_workspace => Server.actionSwitchToWorkspace,
                    .toplevel_to_workspace => Server.actionToplevelToWorkspace,
                    .toggle_spread_view => Server.actionToggleSpreadView,
                    .toggle_hide_toplevels => Server.actionToggleHideToplevels,
                    .quit => Server.actionQuit,
                    .chvt => Server.actionChvt,
                    .reload_config => Server.actionReloadConfig,
                };
            }
        }
    }

    const Hotkey = struct {
        modifiers: u32,
        key: u32,
        cb: fn (*Server, []const u8) void,
        arg: []u8,
    };

    tap_to_click: bool,
    natural_scrolling: bool,
    background_color: [4]f32,
    border_color: [4]f32,
    focused_color: [4]f32,
    grabbed_color: [4]f32,
    active_border_width: i32,
    hotkeys: []Hotkey,
    mouse_move_modifiers: u32,
    mouse_move_button: u32,
    mouse_grow_modifiers: u32,
    mouse_grow_button: u32,
    autostart: std.ArrayList([]u8),
    move_pixels: u32,
    grow_pixels: u32,
    damage_tracking: DamageTrackingLevel,

    fn init(self: *Config) void {
        self.autostart = std.ArrayList([]u8).init(alloc);
        self.loadDefault();
        self.reload();
    }

    fn reload(self: *Config) void {
        self.loadFromFile();
    }
};

const Signal = struct {
    fn connect(
        comptime PayloadType: type,
        container: anytype,
        comptime listenerField: []const u8,
        comptime cb: fn (container: @TypeOf(container), data: PayloadType) anyerror!void,
        signal: *wlr.wl_signal,
    ) void {
        var listener = &@field(container, listenerField);
        listener.notify = Listener(PayloadType, @TypeOf(container.*), listenerField, cb).onSignal;
        wlr.wl_signal_add(signal, listener);
    }

    fn Listener(
        comptime PayloadType: type,
        comptime ContainerType: type,
        comptime listenerField: []const u8,
        comptime cb: fn (container: *ContainerType, data: PayloadType) anyerror!void,
    ) type {
        return struct {
            fn onSignal(cbListener: [*c]wlr.wl_listener, data: ?*anyopaque) callconv(.C) void {
                cb(
                    @fieldParentPtr(ContainerType, listenerField, cbListener),
                    if (PayloadType == void) {} else @ptrCast(
                        PayloadType,
                        @alignCast(@alignOf(PayloadType), data),
                    ),
                ) catch |err| {
                    std.log.err("Error from callback {d}", .{err});
                };
            }
        };
    }
};

const wlr_xdg_surface_union = @typeInfo(wlr.wlr_xdg_surface).Struct.fields[5].name;
const wlr_input_device_union = @typeInfo(wlr.wlr_input_device).Struct.fields[8].name;

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var alloc = gpa.allocator();
