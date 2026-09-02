//! Wraps an allocator to measure allocation work for development adapters.
//!
//! Counts successful allocations, resizes, and remaps. `requested_bytes` accumulates newly acquired
//! bytes, while `live_bytes` and `peak_live_bytes` track ownership held through this wrapper. The
//! wrapper borrows its child allocator and does not deinitialize it.

const std = @import("std");

pub const TrackingAllocator = struct {
    child: std.mem.Allocator,
    allocs: u64 = 0,
    resizes: u64 = 0,
    remaps: u64 = 0,
    requested_bytes: u64 = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn operations(self: TrackingAllocator) u64 {
        return self.allocs + self.resizes + self.remaps;
    }

    fn addLive(self: *TrackingAllocator, amount: usize) void {
        self.live_bytes += amount;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        self.requested_bytes += amount;
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawAlloc(len, alignment, return_address) orelse return null;
        self.allocs += 1;
        self.addLive(len);
        return result;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        if (!self.child.rawResize(memory, alignment, new_len, return_address)) return false;
        self.resizes += 1;
        if (new_len > memory.len) {
            self.addLive(new_len - memory.len);
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        const result = self.child.rawRemap(
            memory,
            alignment,
            new_len,
            return_address,
        ) orelse return null;
        self.remaps += 1;
        if (new_len > memory.len) {
            self.addLive(new_len - memory.len);
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        return result;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(context));
        self.child.rawFree(memory, alignment, return_address);
        self.live_bytes -= memory.len;
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };
};
