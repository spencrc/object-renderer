const vk = @import("vulkan");
const std = @import("std");
const builtin = @import("builtin");

const Instance = @This();

gpa: std.mem.Allocator,
// vulkan objects
vkb: vk.BaseWrapper,
proxy: vk.InstanceProxy,
debug_messenger: if (builtin.mode == .Debug) vk.DebugUtilsMessengerEXT else void,

pub fn deinit(self: *Instance) void {
    if (builtin.mode == .Debug) self.proxy.destroyDebugUtilsMessengerEXT(self.debug_messenger, null);
    self.proxy.destroyInstance(null);
    // need to destroy wrappers as well to prevent mem leaks
    self.gpa.destroy(self.proxy.wrapper);
}

pub fn init(
    allocator: std.mem.Allocator,
    getInstanceProcAddr: vk.PfnGetInstanceProcAddr,
    backend_extensions: []const [*:0]const u8,
) !Instance {
    var self: Instance = undefined;
    self.gpa = allocator;
    self.vkb = vk.BaseWrapper.load(getInstanceProcAddr);

    if (try checkLayerSupport(&self.vkb, self.gpa) == false) return error.MissingLayer;
    const required_layers = comptime getRequiredLayers();

    var instances_exts: std.ArrayList([*:0]const u8) = .empty;
    defer instances_exts.deinit(self.gpa);
    try instances_exts.appendSlice(self.gpa, comptime getInstanceExtensions());
    try instances_exts.appendSlice(self.gpa, backend_extensions);

    const instance = try self.vkb.createInstance(&.{
        .p_application_info = &.{
            .p_application_name = "Example Vulkan App",
            .application_version = vk.makeApiVersion(1, 0, 0, 0).toU32(),
            .p_engine_name = "No Engine",
            .engine_version = vk.makeApiVersion(1, 0, 0, 0).toU32(),
            .api_version = vk.API_VERSION_1_3.toU32(),
        },
        .enabled_layer_count = @intCast(required_layers.len),
        .pp_enabled_layer_names = required_layers.ptr,
        .enabled_extension_count = @intCast(instances_exts.items.len),
        .pp_enabled_extension_names = instances_exts.items.ptr,
    }, null);

    const vki = try self.gpa.create(vk.InstanceWrapper);
    errdefer self.gpa.destroy(vki);
    vki.* = vk.InstanceWrapper.load(instance, getInstanceProcAddr);
    self.proxy = vk.InstanceProxy.init(instance, vki);
    errdefer self.proxy.destroyInstance(null);

    if (builtin.mode == .Debug) {
        self.debug_messenger = try self.proxy.createDebugUtilsMessengerEXT(&.{
            .message_severity = .{
                .warning_bit_ext = true,
                .error_bit_ext = true,
            },
            .message_type = .{
                .general_bit_ext = true,
                .validation_bit_ext = true,
                .performance_bit_ext = true,
            },
            .pfn_user_callback = &debugUtilsMessengerCallback,
            .p_user_data = null,
        }, null);
    }

    return self;
}

fn checkLayerSupport(vkb: *const vk.BaseWrapper, allocator: std.mem.Allocator) !bool {
    const available_layers = try vkb.enumerateInstanceLayerPropertiesAlloc(allocator);
    defer allocator.free(available_layers);

    const required_layers = comptime getRequiredLayers();

    for (required_layers) |required_layer| {
        for (available_layers) |layer| {
            if (std.mem.eql(u8, std.mem.span(required_layer), std.mem.sliceTo(&layer.layer_name, 0))) {
                break;
            }
        } else {
            return false;
        }
    }
    return true;
}

const empty_names = [_][*:0]const u8{};
const debug_required_layers = [_][*:0]const u8{"VK_LAYER_KHRONOS_validation"}; // will be DCE'd if not in Debug or ReleaseSafe
fn getRequiredLayers() []const [*:0]const u8 {
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => &debug_required_layers,
        else => &empty_names,
    };
}

const debug_instance_exts = [_][*:0]const u8{vk.extensions.ext_debug_utils.name}; // will be DCE'd if not in Debug or ReleaseSafe
fn getInstanceExtensions() []const [*:0]const u8 {
    return switch (builtin.mode) {
        .Debug, .ReleaseSafe => &debug_instance_exts,
        else => &empty_names,
    };
}

fn debugUtilsMessengerCallback(severity: vk.DebugUtilsMessageSeverityFlagsEXT, msg_type: vk.DebugUtilsMessageTypeFlagsEXT, callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, _: ?*anyopaque) callconv(.c) vk.Bool32 {
    const severity_str = if (severity.verbose_bit_ext) "verbose" else if (severity.info_bit_ext) "info" else if (severity.warning_bit_ext) "warning" else if (severity.error_bit_ext) "error" else "unknown";

    const type_str = if (msg_type.general_bit_ext) "general" else if (msg_type.validation_bit_ext) "validation" else if (msg_type.performance_bit_ext) "performance" else if (msg_type.device_address_binding_bit_ext) "device addr" else "unknown";

    const message: [*c]const u8 = if (callback_data) |cb_data| cb_data.p_message else "NO MESSAGE!";
    std.debug.print("[{s}][{s}]. Message:\n  {s}\n", .{ severity_str, type_str, message });

    return .false;
}
