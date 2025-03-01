const std = @import("std");
const testing = std.testing;

pub const cgroup = @import("cgroup.zig");

test {
    testing.refAllDecls(@This());
}

// Cleans up uname strings for use with std.SemanticVersion.
pub fn parse_dirty_semver(dirty_release: []const u8) !std.SemanticVersion {
    const release = blk: {
        var last_valid_char_index: usize = 0;
        var dots_found: u8 = 0;
        for (dirty_release) |c| {
            if (c == '.') dots_found += 1;
            if (dots_found == 3) {
                break;
            }
            if (c == '.' or (c >= '0' and c <= '9')) {
                last_valid_char_index += 1;
                continue;
            }
            break;
        }
        break :blk dirty_release[0..last_valid_char_index];
    };
    return std.SemanticVersion.parse(release);
}

test "parse_dirty_semver" {
    const experiments = [_]struct {
        dirty_release: []const u8,
        expected: std.SemanticVersion,
    }{
        .{
            .dirty_release = "1.2.3",
            .expected = std.SemanticVersion{ .major = 1, .minor = 2, .patch = 3 },
        },
        .{
            .dirty_release = "1001.843.909",
            .expected = std.SemanticVersion{ .major = 1001, .minor = 843, .patch = 909 },
        },
        .{
            .dirty_release = "6.3.8-100.fc37.x86_64",
            .expected = std.SemanticVersion{ .major = 6, .minor = 3, .patch = 8 },
        },
        .{
            .dirty_release = "5.15.90.1-microsoft-standard-WSL2",
            .expected = std.SemanticVersion{ .major = 5, .minor = 15, .patch = 90 },
        },
    };
    for (experiments) |experiment| {
        const version = try parse_dirty_semver(experiment.dirty_release);
        try std.testing.expectEqual(version, experiment.expected);
    }
}
