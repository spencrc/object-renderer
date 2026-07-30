const std = @import("std");
const engine = @import("engine.zig");

pub fn main(init: std.process.Init) !void {
    var e = try engine.init(init.gpa);
    defer e.deinit();
}
