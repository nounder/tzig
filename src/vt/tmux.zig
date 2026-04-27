// Vendored from ghostty-org/ghostty
//   upstream: src/terminal/tmux.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   import paths flattened (../X stays where appropriate, kept at upstream form)

//! Types and functions related to tmux protocols.

const control = @import("tmux/control.zig");
const layout = @import("tmux/layout.zig");
pub const output = @import("tmux/output.zig");
pub const ControlParser = control.Parser;
pub const ControlNotification = control.Notification;
pub const Layout = layout.Layout;
pub const Viewer = @import("tmux/viewer.zig").Viewer;

test {
    @import("std").testing.refAllDecls(@This());
}
