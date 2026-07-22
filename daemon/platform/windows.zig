//! Windows runtime boundary. Native capture, input, clipboard, notification,
//! path, and IPC integrations are intentionally not implemented yet.
const unsupported = @import("unsupported.zig");

pub const Recorder = unsupported.Recorder;
pub const typeText = unsupported.typeText;
pub const copyToClipboard = unsupported.copyToClipboard;
pub const sendNotification = unsupported.sendNotification;
pub const configFile = unsupported.configFile;
pub const keywordsFile = unsupported.keywordsFile;
pub const metricsFile = unsupported.metricsFile;
pub const runtimeRoot = unsupported.runtimeRoot;
pub const effectiveUserId = unsupported.effectiveUserId;
pub const validatePrivateParent = unsupported.validatePrivateParent;
pub const validateSharedTmpParent = unsupported.validateSharedTmpParent;
pub const validatePrivateSocket = unsupported.validatePrivateSocket;
pub const validateSocketKind = unsupported.validateSocketKind;
pub const makeSocketPrivate = unsupported.makeSocketPrivate;
