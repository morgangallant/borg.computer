const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;

const logger = std.log.scoped(.cgroups);

// Returns the path to the cgroup for the given pid.
pub fn current(gpa: std.mem.Allocator, pid: std.posix.pid_t) !?[]const u8 {
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

// Move the given pid into the specified cgroup.
pub fn move_into(cgroup: []const u8, pid: std.posix.pid_t) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}/cgroup.procs", .{cgroup});
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.writer().print("{}", .{pid});
}

// Create a new cgroup. If move is set, the given pid will be moved into the new cgroup.
pub fn create(cgroup: []const u8, child: []const u8, move: ?std.posix.pid_t) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}/{s}", .{ cgroup, child });
    try std.fs.cwd().makePath(path);

    if (move) |pid| {
        const pid_path = try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}/{s}/cgroup.procs", .{ cgroup, child });
        const file = try std.fs.cwd().openFile(pid_path, .{ .mode = .write_only });
        defer file.close();
        try file.writer().print("{}", .{pid});
    }
}

// Uses clone3 to have the kernel create a new process with the correct cgroup rather than
// moving the process to the correct cgroup later on.
pub fn clone_into(cgroup: []const u8) !std.posix.pid_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "/sys/fs/cgroup{s}", .{cgroup});

    // Get a file descriptor that refers to the cgroup directory in the cgroup
    // sysfs to pass to the kernel for clone3.
    const fd: std.os.linux.fd_t = fd: {
        const rc = std.os.linux.open(path, .{
            .PATH = true,
            .DIRECTORY = true,
            .CLOEXEC = true, // Don't want leak this fd to the child process when we clone below
        }, 0);
        switch (std.posix.errno(rc)) {
            .SUCCESS => break :fd @as(std.os.linux.fd_t, @intCast(rc)),
            else => |errno| {
                logger.err("unable to open cgroup dir {s}: {}", .{ path, errno });
                return error.CloneError;
            },
        }
    };
    assert(fd >= 0);
    defer _ = std.os.linux.close(fd);

    const args: extern struct {
        flags: u64,
        pidfd: u64,
        child_tid: u64,
        parent_tid: u64,
        exit_signal: u64,
        stack: u64,
        stack_size: u64,
        tls: u64,
        set_tid: u64,
        set_tid_size: u64,
        cgroup: u64,
    } = .{
        .flags = std.os.linux.CLONE.INTO_CGROUP,
        .pidfd = 0,
        .child_tid = 0,
        .parent_tid = 0,
        .exit_signal = std.os.linux.SIG.CHLD,
        .stack = 0,
        .stack_size = 0,
        .tls = 0,
        .set_tid = 0,
        .set_tid_size = 0,
        .cgroup = @intCast(fd),
    };

    const rc = std.os.linux.syscall2(
        std.os.linux.SYS.clone3,
        @intFromPtr(&args),
        @sizeOf(@TypeOf(args)),
    );
    return switch (std.os.linux.E.init(rc)) {
        .SUCCESS => @as(std.posix.pid_t, @intCast(rc)),
        else => |errno| err: {
            logger.err("unable to clone3: {}", .{errno});
            break :err error.CloneError;
        },
    };
}

test "clone3" {
    // This test doesn't work with the testing allocator,
    // requires the libc allocator.
    const allocator = std.heap.c_allocator;

    const current_pid = std.os.linux.getpid();
    const current_cgroup = (try current(allocator, current_pid)).?;
    defer allocator.free(current_cgroup);

    try create(current_cgroup, "test_clone3", null);
    const new_cgroup_name = try std.fmt.allocPrint(allocator, "{s}/test_clone3", .{current_cgroup});
    defer allocator.free(new_cgroup_name);

    const pid = try clone_into(new_cgroup_name);
    if (pid != 0) {
        return; // Parent process will return instantly.
    }

    // Make sure the current cgroup of the child is what we expect.

    const child_current = std.os.linux.getpid();
    const actual_child_cgroup_name = (try current(allocator, child_current)).?;
    defer allocator.free(actual_child_cgroup_name);

    try testing.expectEqualSlices(u8, new_cgroup_name, actual_child_cgroup_name);
}
