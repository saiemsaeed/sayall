pub const ShortcutState = struct {
    enabled: bool,
    shortcut: []const u8,
    persisted: bool,
    external: bool = false,
};

pub const ShortcutActivation = enum {
    reloaded,
    deferred,
};

pub const ShortcutConflict = struct {
    path: []const u8,
    line: usize,
    binding: []const u8,
    equivalent: bool,
};

pub const ShortcutUnresolved = struct {
    path: []const u8,
    line: usize,
    expression: []const u8,
};

pub const ShortcutRollbackFailure = enum {
    concurrent_modification,
    io_failure,
};

pub const ShortcutApplyResult = union(enum) {
    applied: struct {
        state: ShortcutState,
        changed: bool,
        activation: ShortcutActivation,
    },
    external: ShortcutState,
    external_owned: ShortcutState,
    conflict: ShortcutConflict,
    unresolved: ShortcutUnresolved,
    unsupported: []const u8,
    unsafe_root: []const u8,
    concurrent_modification: []const u8,
    reload_failed: []const u8,
    rollback_failed: ShortcutRollbackFailure,
};

pub const ShortcutRequest = union(enum) {
    show,
    set: []const u8,
    reset,
    disable,
};

pub const ShortcutResult = union(enum) {
    state: ShortcutState,
    applied: ShortcutApplyResult,
    invalid: []const u8,
};

pub const RestartResult = union(enum) {
    restarted,
    spawn_failed: anyerror,
    wait_failed: anyerror,
    failed,
};

pub const SetupResult = struct {
    shortcut_ok: bool,
    services_ok: bool,
};

pub const UpdatePlan = struct {
    installed: []const u8,
    update_target: []const u8,
    legacy_migration: bool,
};

pub const UpdatePreparation = union(enum) {
    ready: UpdatePlan,
    package_missing,
    yay_missing,
};

pub const UpdateResult = union(enum) {
    package_failed,
    services_failed,
    shortcut: ShortcutApplyResult,
};

pub const DiagnosticStatus = enum {
    ok,
    warn,
    fail,
};

pub const Diagnostic = struct {
    status: DiagnosticStatus,
    label: []const u8,
    detail: []const u8,
};

pub const Diagnostics = struct {
    commands: [4]Diagnostic,
    notification: ?Diagnostic,
    services: [2]Diagnostic,
};
