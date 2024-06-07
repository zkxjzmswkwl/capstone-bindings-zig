const cs = @cImport({
    @cInclude("capstone/capstone.h");
});

const std = @import("std");

const insn = @import("insn.zig");
const err = @import("error.zig");

const VaArgs = extern struct {
    gp_offset: c_uint = @import("std").mem.zeroes(c_uint),
    fp_offset: c_uint = @import("std").mem.zeroes(c_uint),
    overflow_arg_area: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
    reg_save_area: ?*anyopaque = @import("std").mem.zeroes(?*anyopaque),
};

const Malloc = ?*const fn (usize) callconv(.C) ?*anyopaque;
const Calloc = ?*const fn (usize, usize) callconv(.C) ?*anyopaque;
const Realloc = ?*const fn (?*anyopaque, usize) callconv(.C) ?*anyopaque;
const Free = ?*const fn (?*anyopaque) callconv(.C) void;
const Vsnprintf = ?*const fn ([]u8, usize, [*c]VaArgs) callconv(.C) c_int;

var ALLOCATOR: ?std.mem.Allocator = null;

const PtrLen = usize;
const PtrAddress = usize;
const AllocationTable = std.AutoArrayHashMapUnmanaged(PtrAddress, PtrLen);
var ALLOCATION_TABLE: AllocationTable = .{};

pub fn malloc(size: usize) callconv(.C) ?*anyopaque {
    if (ALLOCATOR) |alloc| {
        const allocated = alloc.alignedAlloc(u8, 16, size) catch return null;
        ALLOCATION_TABLE.put(alloc, @intFromPtr(allocated.ptr), allocated.len) catch @panic("OOM");
        return @ptrCast(allocated.ptr);
    } else {
        @panic("Call `initCapstone` first");
    }
}

pub fn calloc(size: usize, elements: usize) callconv(.C) ?*anyopaque {
    if (ALLOCATOR) |alloc| {
        const allocated = alloc.alloc(u8, elements * size) catch return null;
        ALLOCATION_TABLE.put(alloc, @intFromPtr(allocated.ptr), allocated.len) catch @panic("OOM");
        for (allocated) |*element| {
            element.* = '\x00';
        }
        return @ptrCast(allocated.ptr);
    } else {
        @panic("Call `initCapstone` first");
    }
}

pub fn realloc(ptr: ?*anyopaque, new_size: usize) callconv(.C) ?*anyopaque {
    if (ptr) |p| {
        if (ALLOCATOR) |alloc| {
            const prior = ALLOCATION_TABLE.fetchSwapRemove(@intFromPtr(p)) orelse @panic("Realloc called without element in list");
            const actual: [*]u8 = @ptrFromInt(prior.key);
            const as_fat_ptr: []u8 = actual[0..prior.value];
            const allocated = alloc.realloc(as_fat_ptr, new_size) catch return null;
            ALLOCATION_TABLE.put(alloc, @intFromPtr(allocated.ptr), allocated.len) catch @panic("OOM");
            return @ptrCast(allocated.ptr);
        } else {
            @panic("Call `initCapstone` first.");
        }
    } else {
        return null;
    }
}

pub fn free(ptr: ?*anyopaque) callconv(.C) void {
    if (ALLOCATOR) |alloc| {
        const allocated = ALLOCATION_TABLE.fetchSwapRemove(@intFromPtr(ptr)) orelse @panic("table didn't contain item to be freed");
        const p: [*]u8 = @ptrFromInt(allocated.key);
        const allocated_slice: []u8 = p[0..allocated.value];
        alloc.free(allocated_slice);
    } else {
        @panic("free was called before the allocator exists");
    }
}

pub fn initCapstone(alloc: std.mem.Allocator) err.CapstoneError!void {
    ALLOCATOR = alloc;

    const sys_mem = cs.cs_opt_mem{
        .malloc = &malloc,
        .calloc = &calloc,
        .realloc = &realloc,
        .free = &free,
    };

    const err_return = cs.cs_option(0, cs.CS_OPT_MEM, @intFromPtr(&sys_mem));

    if (err.toError(err_return)) |e| {
        return e;
    }
}
