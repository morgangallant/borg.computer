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
        .{ "cpuset", {} },
        .{ "memory", {} },
        .{ "perf_event", {} },
        .{ "pids", {} },
        .{ "rdma", {} },
        .{ "hugetlb", {} },
        .{ "io", {} },
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

const CreateOptions = struct {
    // If set, the given pid will be moved into the new cgroup.
    move_pid: ?std.posix.pid_t = null,

    // If set, the cgroup will be created as a child of the specified parent cgroup.
    parent: ?[]const u8 = null,
};

// Create a new cgroup. If move is set, the given pid will be moved into the new cgroup.
pub fn create(name: []const u8, options: CreateOptions) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = blk: {
        if (options.parent) |parent| {
            assert(parent.len > 0 and parent[0] == '/');
            break :blk try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}/{s}", .{ parent, name });
        }
        assert(name.len > 0 and name[0] == '/');
        break :blk try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}", .{name});
    };
    try std.fs.cwd().makePath(path);
    if (options.move_pid) |pid| {
        const pid_path = if (options.parent) |parent|
            try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}/{s}/cgroup.procs", .{ parent, name })
        else
            try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}/cgroup.procs", .{name});
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

test "clone_into" {
    // fork'ing (or equiv. clone3) doesn't play nicely with the testing allocator.
    // We need to use the libc allocator instead.
    const allocator = std.heap.c_allocator;

    const cgroup_name = "/test_clone_into";

    // Cleanup from previous test runs
    // TODO is it possible to cleanup after ourselves after we're done?
    // if we defer a cleanup, we get EBUSY since the child is still running
    try delete_if_exists(cgroup_name);

    try create(cgroup_name, .{});

    const pid = try clone_into(cgroup_name);
    if (pid != 0) {
        // We're in the parent process, exit immediately
        return;
    }

    // Make sure the cgroup of the child is what we expect.
    const child_pid = std.os.linux.getpid();
    const child_cgroup = (try current(allocator, child_pid)).?;
    defer allocator.free(child_cgroup);
    try testing.expectEqualStrings(child_cgroup, cgroup_name);
}

// Configures the set of controllers for a cgroup.
// `v` should be a valid format for "cgroup.subtree_control"
// See: https://docs.kernel.org/admin-guide/cgroup-v2.html#controlling-controllers
pub fn configure_controllers(cgroup: []const u8, v: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &buf,
        "/sys/fs/cgroup{s}/cgroup.subtree_control",
        .{cgroup},
    );
    const file = try std.fs.cwd().openFile(path, .{ .mode = .write_only });
    defer file.close();
    try file.writer().writeAll(v);
}

pub fn enabled_controllers(gpa: std.mem.Allocator, cgroup: []const u8) ![]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &buf,
        "/sys/fs/cgroup{s}/cgroup.subtree_control",
        .{cgroup},
    );
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_only });
    defer file.close();

    var reader = std.io.bufferedReader(file.reader());
    const contents = try reader.reader().readAllAlloc(gpa, 1 << 20);
    defer gpa.free(contents);

    const result = std.mem.trimRight(u8, contents, " \r\n");
    return try gpa.dupe(u8, result);
}

// For all controllers that are delegated to the selected cgroup,
// enable them all by writing to the cgroup.subtree_control file.
pub fn enable_all_controllers(gpa: std.mem.Allocator, cgroup: []const u8) !void {
    const raw = try controllers(gpa, cgroup);
    defer gpa.free(raw);

    var builder = std.ArrayList(u8).init(gpa);
    defer builder.deinit();

    var it = std.mem.splitScalar(u8, raw, ' ');
    while (it.next()) |controller| {
        if (controller.len == 0) continue;
        try builder.append('+');
        try builder.appendSlice(controller);
        if (it.rest().len > 0) try builder.append(' ');
    }

    try configure_controllers(cgroup, builder.items);
}

// Delete the cgroup if it exists.
pub fn delete_if_exists(cgroup: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}", .{cgroup});
    std.fs.cwd().deleteDir(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub fn convert_to_threaded_if_needed(gpa: std.mem.Allocator, cgroup: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/sys/fs/cgroup{s}/cgroup.type", .{cgroup});
    const file = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();

    var reader = std.io.bufferedReader(file.reader());
    const contents = try reader.reader().readAllAlloc(gpa, 1 << 20);
    defer gpa.free(contents);

    if (std.mem.startsWith(u8, contents, "domain invalid")) {
        try file.writeAll("threaded");
    }
}

test "configure controllers" {
    const allocator = testing.allocator;

    const cgroup_name = "/test_configure_controllers";

    // Cleanup from previous test runs
    // ... And cleanup after ourselves after we're done
    try delete_if_exists(cgroup_name);
    defer delete_if_exists(cgroup_name) catch |err| {
        std.log.warn("failed to delete cgroup after test: {}", .{err});
    };

    try create(cgroup_name, .{});

    const available_controllers = try controllers(allocator, cgroup_name);
    defer allocator.free(available_controllers);

    const enabled_controllers_before = try enabled_controllers(allocator, cgroup_name);
    defer allocator.free(enabled_controllers_before);
    try testing.expectEqualStrings(enabled_controllers_before, "");

    try enable_all_controllers(allocator, cgroup_name);

    const enabled_controllers_after = try enabled_controllers(allocator, cgroup_name);
    defer allocator.free(enabled_controllers_after);
    try testing.expectEqualStrings(enabled_controllers_after, available_controllers);
}
