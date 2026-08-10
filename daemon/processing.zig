const std = @import("std");

/// User-selectable processing modes. These values are part of config.json.
pub const Mode = enum {
    /// Preserve finalized STT output and perform no post-STT provider request.
    verbatim,
    /// Apply only deterministic Zig processing and no provider request.
    clean,
    /// Attempt one semantic planner transformation, falling back to raw STT.
    polished,
};

/// Internal routing contract. `legacy_v1` preserves the old formatter path for
/// one migration cycle without exposing it as a new user-selectable mode.
pub const Profile = enum {
    verbatim,
    clean,
    polished,
    /// Compatibility route for legacy llm.enabled=true. It retains the old
    /// formatter behavior and does not opt into future Clean deletions.
    legacy_v1,

    pub fn usesPlanner(self: Profile) bool {
        return self == .polished or self == .legacy_v1;
    }
};

/// Content-free result of applying a processing profile to a transcript.
pub const TransformationOutcome = enum {
    not_requested,
    changed,
    no_change,
    degraded,
    failed,
};

pub const Config = struct {
    // Optional only so an omitted field can be distinguished from an explicit
    // verbatim choice while legacy llm.enabled is accepted for one cycle.
    mode: ?Mode = null,
};

pub fn effective(config: Config, legacy_llm_enabled: bool) Profile {
    if (config.mode) |mode| return switch (mode) {
        .verbatim => .verbatim,
        .clean => .clean,
        .polished => .polished,
    };
    return if (legacy_llm_enabled) .legacy_v1 else .verbatim;
}

test "migration matrix preserves explicit modes and legacy compatibility" {
    try std.testing.expectEqual(Profile.verbatim, effective(.{}, false));
    try std.testing.expectEqual(Profile.legacy_v1, effective(.{}, true));
    try std.testing.expectEqual(Profile.verbatim, effective(.{ .mode = .verbatim }, true));
    try std.testing.expectEqual(Profile.clean, effective(.{ .mode = .clean }, true));
    try std.testing.expectEqual(Profile.polished, effective(.{ .mode = .polished }, false));
}
