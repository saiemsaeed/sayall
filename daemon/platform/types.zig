pub const RuntimeRoot = struct {
    path: []const u8,
    parent_security: ParentSecurity,
};

pub const ParentSecurity = enum {
    private,
    shared_sticky_tmp,
};

pub const Recording = struct {
    /// Owned by the caller.
    path: []u8,
};
