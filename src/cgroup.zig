const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

// Returns the path to the cgroup for the given pid.
pub fn current(gpa: std.mem.Allocator, pid: std.os.linux.pid_t) !?[]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/proc/{d}/cgroup", .{pid});
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var reader = std.io.bufferedReader(file.reader());
    const contents = try reader.reader().readAllAlloc(gpa, 1 << 20);
    defer gpa.free(contents);

    // On my machine, the cgroup path looks like:
    // mg@opti:~$ cat /proc/176425/cgroup
    // 0::/user.slice/user-1000.slice/session-1614.scope
    //
    // Specifically, we're looking to return that last bit.

    const idx = std.mem.lastIndexOfScalar(u8, contents, ':') orelse return null;
    const result = std.mem.trimRight(u8, contents[idx + 1 ..], " \r\n");
    return try gpa.dupe(u8, result);
}

test "current pid" {
    const allocator = testing.allocator;

    const pid = std.os.linux.getpid();

    const current_path = (try current(allocator, pid)).?;
    defer allocator.free(current_path);
    try testing.expect(current_path.len > 0);
    try testing.expect(std.fs.path.isAbsolute(current_path));
}

// Returns a space-seperated list of active controllers for the given cgroup.
pub fn controllers(gpa: std.mem.Allocator, cgroup: []const u8) ![]const u8 {
    assert(std.fs.path.isAbsolute(cgroup));

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &buf,
        "/sys/fs/cgroup{s}/cgroup.controllers",
        .{cgroup},
    );
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var reader = std.io.bufferedReader(file.reader());
    const contents = try reader.reader().readAllAlloc(gpa, 1 << 20);
    defer gpa.free(contents);

    const result = std.mem.trimRight(u8, contents, " \r\n");
    return try gpa.dupe(u8, result);
}

test "controllers" {
    const allocator = testing.allocator;

    const pid = std.os.linux.getpid();

    const current_cgroup = (try current(allocator, pid)).?;
    defer allocator.free(current_cgroup);

    const current_controllers = try controllers(allocator, current_cgroup);
    defer allocator.free(current_controllers);

    const valid_controllers = std.StaticStringMap(void).initComptime(.{
        .{ "cpu", {} },
        .{ "cpuacct", {} },
        .{ "cpuset", {} },
        .{ "devices", {} },
        .{ "freezer", {} },
        .{ "memory", {} },
        .{ "net_cls", {} },
        .{ "net_prio", {} },
        .{ "perf_event", {} },
        .{ "pids", {} },
        .{ "rdma", {} },
        .{ "blkio", {} },
        .{ "hugetlb", {} },
    });

    var iterator = std.mem.tokenizeAny(u8, current_controllers, " ");
    var num_controllers: usize = 0;
    while (iterator.next()) |controller| {
        try testing.expect(valid_controllers.get(controller) != null);
        num_controllers += 1;
    }

    // On most systems, there should be a few controllers set even for
    // base cgroups, i.e. the one running bash etc.
    try testing.expect(num_controllers > 0);
}
