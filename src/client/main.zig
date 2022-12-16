const std = @import("std");
const window = @import("window");
const gl = @import("gl");
const ls = @import("ls");
const nm = @import("nm");
const util = @import("util");
const zlua = @import("ziglua");

const Allocator = std.mem.Allocator;

const Vec3 = nm.Vec3;
const vec3 = nm.vec3;

const munleko = @import("munleko");

const Engine = munleko.Engine;
const Session = munleko.Session;
const World = munleko.World;

const Mutex = std.Thread.Mutex;

const Window = window.Window;

pub const rendering = @import("rendering.zig");


fn printSubZones(a: [3]i32, b: [3]i32, r: u32) void {
    var ranges: [3]nm.Range3i = undefined;
    const a_vec = nm.vec3i(a);
    const b_vec = nm.vec3i(b);
    std.log.info("subtract zone {d: >2} from {d: >2} (radius {d: >2}):", .{b_vec, a_vec, r});
    for (World.ObserverZone.subtractZones(a_vec, b_vec, r, &ranges)) |range| {
        std.log.info("range from {d: >2} to {d: >2}", .{range.min, range.max});
    }
}

pub fn main() !void {

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ =  gpa.deinit();


    const allocator = gpa.allocator();
    // printSubZones(.{0, 0, 0}, .{0, 0, 0}, 4);
    // printSubZones(.{0, 0, 0}, .{2, 0, 0}, 4);
    // printSubZones(.{0, 0, 0}, .{-2, 0, 0}, 4);
    // printSubZones(.{0, 0, 0}, .{0, 2, 0}, 4);
    // printSubZones(.{0, 0, 0}, .{0, -2, 0}, 4);
    // printSubZones(.{0, 0, 0}, .{0, 0, 2}, 4);
    // printSubZones(.{0, 0, 0}, .{0, 0, -2}, 4);
    // printSubZones(.{0, 0, 0}, .{0, 1, 2}, 4);
    // printSubZones(.{0, 0, 0}, .{0, 1, -2}, 4);
    // printSubZones(.{0, 0, 0}, .{0, -1, 2}, 4);
    // printSubZones(.{0, 0, 0}, .{0, -1, -2}, 4);
    // printSubZones(.{0, 0, 0}, .{8, 8, 8}, 4);

    try window.init();
    defer window.deinit();


    var client: Client = undefined;
    try client.init(allocator);
    defer client.deinit();

    try client.run();

}

const FlyCam = @import("FlyCam.zig");


pub const Client = struct {

    window: Window,
    engine: Engine,

    pub fn init(self: *Client, allocator: Allocator) !void {
        self.window = Window.init(allocator);
        self.engine = try Engine.init(allocator);
    }

    pub fn deinit(self: *Client) void {
        self.window.deinit();
        self.engine.deinit();
    }


    pub fn run(self: *Client) !void {

        try self.window.create(.{});
        defer self.window.destroy();
        self.window.makeContextCurrent();
        self.window.setVsync(.disabled);

        try gl.init(window.getGlProcAddress);
        gl.viewport(self.window.size);
        gl.enable(.depth_test);
        gl.setDepthFunction(.less);
        gl.enable(.cull_face);

        var session = try self.engine.createSession();
        defer session.destroy();

        var cam = FlyCam.init(self.window);
        cam.move_speed = 64;

        const cam_obs = try session.world.observers.create(cam.position.cast(i32));
        defer session.world.observers.delete(cam_obs) catch {};

        var session_context = SessionContext {
            .client = self,
        };

        try session.start(&session_context, .{
            .on_tick = SessionContext.onTick,
            .on_world_update = SessionContext.onWorldUpdate,
        });


        self.window.setMouseMode(.disabled);


        const dbg = try rendering.Debug.init();
        defer dbg.deinit();

        dbg.setLight(vec3(.{1, 3, 2}).norm() orelse unreachable);

        gl.clearColor(.{0, 0, 0, 1});
        gl.clearDepth(.float, 1);

        dbg.start();

        var fps_counter = try util.FpsCounter.start(1);

        while (self.window.nextFrame()) {
            for(self.window.events.get(.framebuffer_size)) |size| {
                gl.viewport(size);
            }
            if (self.window.buttonPressed(.grave)) {
                switch (self.window.mouse_mode) {
                    .disabled => self.window.setMouseMode(.visible),
                    else => self.window.setMouseMode(.disabled),
                }
            }

            cam.update(self.window);
            session.world.observers.setPosition(cam_obs, cam.position.cast(i32));
            dbg.setView(cam.viewMatrix());

            gl.clear(.color_depth);
            dbg.setProj(
                nm.transform.createPerspective(
                    90.0 * std.math.pi / 180.0,
                    @intToFloat(f32, self.window.size[0]) / @intToFloat(f32, self.window.size[1]),
                    0.001, 1000,
                )
            );

            const grid_size = 8;
            var pos = Vec3.zero;
            while (pos.v[0] < grid_size) : ( pos.v[0] += 1) {
                pos.v[1] = 0;
                while (pos.v[1] < grid_size) : ( pos.v[1] += 1) {
                    pos.v[2] = 0;
                    while (pos.v[2] < grid_size) : ( pos.v[2] += 1) {
                        dbg.drawCube(pos.mulScalar(World.chunk_width).addScalar(World.chunk_width / 2), 1, vec3(.{0.8, 1, 1}));
                    }
                }
            }

            // dbg.drawCube(Vec3.zero, 1, vec3(.{0.8, 1, 1}));
            if (fps_counter.frame()) |frames| {
                _ = frames;
                // std.log.info("fps: {d}", .{frames});
            }
        }
    }


    const SessionContext = struct {
        client: *Client,

        fn onTick(self: *SessionContext, session: *Session) !void {
            _ = self;
            _ = session;
            // if (session.tick_count % 100 == 0) {
            //     std.log.debug("tick {d}", .{ session.tick_count });
            // }
        }

        fn onWorldUpdate(self: *SessionContext, world: *World) !void {
            _ = self;
            const chunks = &world.chunks;
            const graph = &world.graph;
            for (chunks.load_state_events.get(.active)) |chunk| {
                const position = graph.positions.get(chunk);
                std.log.info("loaded {} at {d: >4}", .{chunk, position});
            }
            for (chunks.load_state_events.get(.unloading)) |chunk| {
                const position = graph.positions.get(chunk);
                std.log.info("unloaded {} at {d: >4}", .{chunk, position});
            }
        }
    };


};