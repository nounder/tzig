const std = @import("std");
const posix = std.posix;

/// Override default log levels to suppress ghostty-vt stream warnings
pub const std_options: std.Options = .{
    .log_scope_levels = &.{
        .{ .scope = .stream, .level = .err },
    },
};
const std_c = std.c;
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");
const cli = @import("cli.zig");
const VTHandler = @import("vt.zig").VTHandler;

/// Wraps a raw fd in `std.Io.File` and closes it via the Io.
fn closeFd(io: std.Io, fd: posix.fd_t) void {
    var f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    f.close(io);
}

/// Writes all bytes to a raw fd via `std.Io.File`. Errors are silently ignored
/// at call sites that previously discarded `posix.write` results.
fn writeAllFd(io: std.Io, fd: posix.fd_t, bytes: []const u8) !void {
    var f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    try f.writeStreamingAll(io, bytes);
}

/// Context for floating window VT stream.
/// Handles window title changes and forwards device queries to real terminal.
const FloatingWindowContext = struct {
    window: *Window,
    proxy: *TermProxy,

    pub fn onWindowTitle(self: *FloatingWindowContext, title: []const u8) void {
        self.window.setTitle(title);
    }

    pub fn onDeviceQuery(self: *FloatingWindowContext) void {
        // Forward DA query to real terminal, track which PTY to send response to
        self.proxy.stdout.writeStreamingAll(self.proxy.io, "\x1b[c") catch {};
        if (self.window.pty_fd) |fd| {
            self.proxy.pending_query_pty = fd;
        }
    }
};

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

// Platform-specific ioctl constants
const TIOCGWINSZ: c_ulong = if (builtin.os.tag == .macos) 0x40087468 else 0x5413;
const TIOCSWINSZ: c_ulong = if (builtin.os.tag == .macos) 0x80087467 else 0x5414;

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

// Helper to write SGR style escape sequences
fn writeStyle(writer: anytype, style: ghostty_vt.Style) !void {
    // Bold
    if (style.flags.bold) {
        try writer.writeAll("\x1b[1m");
    }
    // Faint
    if (style.flags.faint) {
        try writer.writeAll("\x1b[2m");
    }
    // Italic
    if (style.flags.italic) {
        try writer.writeAll("\x1b[3m");
    }
    // Underline
    if (style.flags.underline != .none) {
        switch (style.flags.underline) {
            .none => {},
            .single => try writer.writeAll("\x1b[4m"),
            .double => try writer.writeAll("\x1b[4:2m"),
            .curly => try writer.writeAll("\x1b[4:3m"),
            .dotted => try writer.writeAll("\x1b[4:4m"),
            .dashed => try writer.writeAll("\x1b[4:5m"),
        }
    }
    // Blink
    if (style.flags.blink) {
        try writer.writeAll("\x1b[5m");
    }
    // Inverse
    if (style.flags.inverse) {
        try writer.writeAll("\x1b[7m");
    }
    // Invisible
    if (style.flags.invisible) {
        try writer.writeAll("\x1b[8m");
    }
    // Strikethrough
    if (style.flags.strikethrough) {
        try writer.writeAll("\x1b[9m");
    }

    // Foreground color
    switch (style.fg_color) {
        .none => {},
        .palette => |idx| {
            if (idx < 8) {
                try writer.print("\x1b[{d}m", .{30 + idx});
            } else if (idx < 16) {
                try writer.print("\x1b[{d}m", .{90 + idx - 8});
            } else {
                try writer.print("\x1b[38;5;{d}m", .{idx});
            }
        },
        .rgb => |rgb| {
            try writer.print("\x1b[38;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
        },
    }

    // Background color
    switch (style.bg_color) {
        .none => {},
        .palette => |idx| {
            if (idx < 8) {
                try writer.print("\x1b[{d}m", .{40 + idx});
            } else if (idx < 16) {
                try writer.print("\x1b[{d}m", .{100 + idx - 8});
            } else {
                try writer.print("\x1b[48;5;{d}m", .{idx});
            }
        },
        .rgb => |rgb| {
            try writer.print("\x1b[48;2;{d};{d};{d}m", .{ rgb.r, rgb.g, rgb.b });
        },
    }
}

const Window = struct {
    // Position & dimensions (in terminal cells, 0-indexed)
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    // Window's own terminal buffer
    terminal: ghostty_vt.Terminal,

    // Optional PTY for running processes in this window
    pty_fd: ?posix.fd_t = null,
    child_pid: ?posix.pid_t = null,

    // Visual options
    has_border: bool,
    default_title: []const u8,

    // Dynamic title from OSC sequences (null = use default_title)
    dynamic_title_buf: [256]u8 = undefined,
    dynamic_title_len: usize = 0,

    // State
    visible: bool = true,

    // Border characters (rounded)
    const border = struct {
        const top_left = "╭";
        const top_right = "╮";
        const bottom_left = "╰";
        const bottom_right = "╯";
        const horizontal = "─";
        const vertical = "│";
    };

    fn init(allocator: std.mem.Allocator, x: u16, y: u16, width: u16, height: u16, has_border: bool, title: []const u8) !Window {
        // Content dimensions (inside border if present)
        const content_cols = if (has_border) width -| 2 else width;
        const content_rows = if (has_border) height -| 2 else height;

        const terminal: ghostty_vt.Terminal = try .init(allocator, .{
            .cols = if (content_cols > 0) content_cols else 1,
            .rows = if (content_rows > 0) content_rows else 1,
        });

        return Window{
            .x = x,
            .y = y,
            .width = width,
            .height = height,
            .terminal = terminal,
            .has_border = has_border,
            .default_title = title,
        };
    }

    fn getTitle(self: *const Window) []const u8 {
        if (self.dynamic_title_len > 0) {
            return self.dynamic_title_buf[0..self.dynamic_title_len];
        }
        return self.default_title;
    }

    fn setTitle(self: *Window, title: []const u8) void {
        const len = @min(title.len, self.dynamic_title_buf.len);
        @memcpy(self.dynamic_title_buf[0..len], title[0..len]);
        self.dynamic_title_len = len;
    }

    fn deinit(self: *Window, io: std.Io, allocator: std.mem.Allocator) void {
        // Kill child process if running
        if (self.child_pid) |pid| {
            _ = std.c.kill(pid, std.posix.SIG.TERM);
        }
        // Close PTY
        if (self.pty_fd) |fd| {
            closeFd(io, fd);
        }
        self.terminal.deinit(allocator);
    }

    fn spawnShell(self: *Window, io: std.Io) !void {
        // Open PTY. `allow_ctty=false` is the default and corresponds to
        // O_NOCTTY at the syscall layer.
        const master_file = try std.Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{ .mode = .read_write });
        const master_fd = master_file.handle;
        errdefer closeFd(io, master_fd);

        // Grant and unlock
        grantpt_wrapper(master_fd);
        unlockpt_wrapper(master_fd);

        const slave_path = ptsname_wrapper(master_fd);

        // Set window size on master
        var ws: Winsize = .{
            .ws_col = self.contentWidth(),
            .ws_row = self.contentHeight(),
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        _ = ioctl(master_fd, TIOCSWINSZ, &ws);

        // Fork. `std.posix.fork` was removed in 0.16; drop to libc.
        const pid_c = std.c.fork();
        if (pid_c < 0) return error.ForkFailed;

        if (pid_c == 0) {
            // Child process. Stick to raw libc here — no Io.File / allocator
            // interaction across fork is the only safe choice.
            _ = std.c.close(master_fd);

            // Create new session
            _ = std_c.setsid();

            // Open slave
            const slave_fd = std.c.open(slave_path.ptr, .{ .ACCMODE = .RDWR });
            if (slave_fd < 0) std.c._exit(1);

            // Set window size on slave too
            _ = ioctl(slave_fd, TIOCSWINSZ, &ws);

            // Dup to stdin/stdout/stderr
            if (std.c.dup2(slave_fd, 0) < 0) std.c._exit(1);
            if (std.c.dup2(slave_fd, 1) < 0) std.c._exit(1);
            if (std.c.dup2(slave_fd, 2) < 0) std.c._exit(1);

            if (slave_fd > 2) _ = std.c.close(slave_fd);

            // Exec shell with current environment. We don't have execvpe in
            // 0.16 stdlib; SHELL is virtually always an absolute path.
            const shell_z: [*:0]const u8 = std.c.getenv("SHELL") orelse "/bin/sh";
            const argv = [_:null]?[*:0]const u8{shell_z};
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            _ = std.c.execve(shell_z, &argv, envp);
            std.c._exit(1);
        }

        // Parent
        self.pty_fd = master_fd;
        self.child_pid = @intCast(pid_c);
    }

    fn contentWidth(self: *const Window) u16 {
        return if (self.has_border) self.width -| 2 else self.width;
    }

    fn contentHeight(self: *const Window) u16 {
        return if (self.has_border) self.height -| 2 else self.height;
    }

    fn render(self: *const Window, writer: anytype) !void {
        if (!self.visible) return;

        if (self.has_border) {
            try self.renderBorder(writer);
        }
        try self.renderContent(writer);
    }

    fn renderBorder(self: *const Window, writer: anytype) !void {
        // Top border with title
        // Position cursor (ANSI is 1-indexed)
        try writer.print("\x1b[{d};{d}H", .{ self.y + 1, self.x + 1 });
        try writer.writeAll(border.top_left);

        // Get the current title (dynamic or default)
        const title = self.getTitle();

        // Calculate title placement (centered)
        const inner_width = self.width -| 2;
        // Account for spaces around title (+2) when calculating available space
        const max_title_len = if (inner_width > 2) inner_width - 2 else 0;
        const title_len: u16 = @intCast(@min(title.len, max_title_len));
        const title_total_width = if (title_len > 0) title_len + 2 else 0; // +2 for spaces
        const remaining_width = inner_width -| title_total_width;
        const padding_before = remaining_width / 2;
        const padding_after = remaining_width -| padding_before;

        // Draw horizontal line with title
        var i: u16 = 0;
        while (i < padding_before) : (i += 1) {
            try writer.writeAll(border.horizontal);
        }
        if (title_len > 0) {
            try writer.writeAll(" ");
            try writer.writeAll(title[0..title_len]);
            try writer.writeAll(" ");
        }
        i = 0;
        while (i < padding_after) : (i += 1) {
            try writer.writeAll(border.horizontal);
        }
        try writer.writeAll(border.top_right);

        // Side borders (left and right edges of each row)
        var row: u16 = 1;
        while (row < self.height -| 1) : (row += 1) {
            // Left border
            try writer.print("\x1b[{d};{d}H", .{ self.y + row + 1, self.x + 1 });
            try writer.writeAll(border.vertical);
            // Right border
            try writer.print("\x1b[{d};{d}H", .{ self.y + row + 1, self.x + self.width });
            try writer.writeAll(border.vertical);
        }

        // Bottom border
        try writer.print("\x1b[{d};{d}H", .{ self.y + self.height, self.x + 1 });
        try writer.writeAll(border.bottom_left);
        i = 0;
        while (i < inner_width) : (i += 1) {
            try writer.writeAll(border.horizontal);
        }
        try writer.writeAll(border.bottom_right);
    }

    fn renderContent(self: *const Window, writer: anytype) !void {
        try self.renderContentWithStyle(writer, false);
    }

    fn renderContentWithStyle(self: *const Window, writer: anytype, with_style: bool) !void {
        const content_x = if (self.has_border) self.x + 1 else self.x;
        const content_y = if (self.has_border) self.y + 1 else self.y;
        const content_w = self.contentWidth();
        const content_h = self.contentHeight();

        const screen = self.terminal.screens.active;
        const pages = &screen.pages;
        // Use .viewport to get what's currently visible, not .screen (which is from top of scrollback)
        const screen_tl = pages.getTopLeft(.viewport);

        var row_it = screen_tl.rowIterator(.right_down, null);
        var row_idx: u16 = 0;

        // Track last style to minimize escape sequences
        var last_style_id: u32 = 0;

        while (row_it.next()) |pin| {
            if (row_idx >= content_h) break;

            // Position cursor for this row
            try writer.print("\x1b[{d};{d}H", .{ content_y + row_idx + 1, content_x + 1 });

            const cells = pin.cells(.all);
            var col: u16 = 0;
            for (cells) |*cell| {
                if (col >= content_w) break;

                // Handle style changes
                if (with_style and cell.style_id != last_style_id) {
                    // Reset and apply new style
                    try writer.writeAll("\x1b[0m");
                    if (cell.style_id != 0) {
                        const style = pin.style(cell);
                        try writeStyle(writer, style);
                    }
                    last_style_id = cell.style_id;
                }

                const cp = cell.codepoint();
                if (cp == 0) {
                    try writer.writeByte(' ');
                } else {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch 1;
                    try writer.writeAll(buf[0..len]);
                }
                col += 1;
            }

            // Reset style at end of row and fill remaining columns
            if (with_style and last_style_id != 0) {
                try writer.writeAll("\x1b[0m");
                last_style_id = 0;
            }
            while (col < content_w) : (col += 1) {
                try writer.writeByte(' ');
            }
            row_idx += 1;
        }

        // Fill remaining rows with spaces
        while (row_idx < content_h) : (row_idx += 1) {
            try writer.print("\x1b[{d};{d}H", .{ content_y + row_idx + 1, content_x + 1 });
            var col: u16 = 0;
            while (col < content_w) : (col += 1) {
                try writer.writeByte(' ');
            }
        }

        // Ensure we end with reset style
        if (with_style) {
            try writer.writeAll("\x1b[0m");
        }
    }

    fn renderWithStyle(self: *const Window, writer: anytype) !void {
        if (!self.visible) return;

        if (self.has_border) {
            try self.renderBorder(writer);
        }
        try self.renderContentWithStyle(writer, true);
    }
};

const WindowManager = struct {
    allocator: std.mem.Allocator,

    // Main window (full terminal, no border)
    main_window: Window,

    // Floating windows (rendered on top)
    floating_windows: std.ArrayList(Window) = .empty,

    // Terminal dimensions
    term_cols: u16,
    term_rows: u16,

    fn init(allocator: std.mem.Allocator, cols: u16, rows: u16) !WindowManager {
        const main_window = try Window.init(allocator, 0, 0, cols, rows, false, "");

        return WindowManager{
            .allocator = allocator,
            .main_window = main_window,
            .term_cols = cols,
            .term_rows = rows,
        };
    }

    fn deinit(self: *WindowManager, io: std.Io) void {
        for (self.floating_windows.items) |*win| {
            win.deinit(io, self.allocator);
        }
        self.floating_windows.deinit(self.allocator);
        self.main_window.deinit(io, self.allocator);
    }

    fn createFloatingWindow(self: *WindowManager, x: u16, y: u16, width: u16, height: u16, title: []const u8) !*Window {
        const window = try Window.init(self.allocator, x, y, width, height, true, title);
        try self.floating_windows.append(self.allocator, window);
        return &self.floating_windows.items[self.floating_windows.items.len - 1];
    }

    fn render(self: *WindowManager, writer: anytype) !void {
        // First render main window
        try self.main_window.render(writer);

        // Then render floating windows on top
        for (self.floating_windows.items) |*win| {
            try win.render(writer);
        }
    }

    fn getFloatingWindow(self: *WindowManager, index: usize) ?*Window {
        if (index < self.floating_windows.items.len) {
            return &self.floating_windows.items[index];
        }
        return null;
    }
};

const TermProxy = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    window_manager: WindowManager,
    floating_window_visible: bool = false,
    original_termios: posix.termios,
    stdout: std.Io.File,
    write_buf: [8192]u8 = undefined,
    term_cols: u16,
    term_rows: u16,

    // Track PTY waiting for terminal query response
    pending_query_pty: ?posix.fd_t = null,

    // Scrollback mode state
    waiting_for_prefix_key: bool = false, // Waiting for second key after Ctrl+b
    in_scrollback_mode: bool = false, // Currently viewing scrollback

    fn init(io: std.Io, allocator: std.mem.Allocator) !TermProxy {
        // Get current window size
        var ws: Winsize = undefined;
        const stdout_fd = std.Io.File.stdout().handle;

        const ws_result = ioctl(stdout_fd, TIOCGWINSZ, &ws);
        if (ws_result != 0) {
            ws = .{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
        }

        // Open PTY. Default `allow_ctty = false` corresponds to O_NOCTTY.
        const master_file = std.Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{ .mode = .read_write }) catch |err| {
            std.debug.print("Failed to open /dev/ptmx: {}\n", .{err});
            return err;
        };
        const master_fd = master_file.handle;
        errdefer closeFd(io, master_fd);

        // Grant and unlock
        grantpt_wrapper(master_fd);
        unlockpt_wrapper(master_fd);

        const slave_path = ptsname_wrapper(master_fd);

        // Set window size on master
        _ = ioctl(master_fd, TIOCSWINSZ, &ws);

        // Fork. `std.posix.fork` was removed in 0.16; drop to libc.
        const pid_c = std.c.fork();
        if (pid_c < 0) return error.ForkFailed;

        if (pid_c == 0) {
            // Child process. Stick to raw libc here — fork-safety.
            _ = std.c.close(master_fd);

            // Create new session
            _ = std_c.setsid();

            // Open slave
            const slave_fd = std.c.open(slave_path.ptr, .{ .ACCMODE = .RDWR });
            if (slave_fd < 0) std.c._exit(1);

            // Set window size on slave too
            _ = ioctl(slave_fd, TIOCSWINSZ, &ws);

            // Dup to stdin/stdout/stderr
            if (std.c.dup2(slave_fd, 0) < 0) std.c._exit(1);
            if (std.c.dup2(slave_fd, 1) < 0) std.c._exit(1);
            if (std.c.dup2(slave_fd, 2) < 0) std.c._exit(1);

            if (slave_fd > 2) _ = std.c.close(slave_fd);

            // Exec shell with current environment
            const shell_z: [*:0]const u8 = std.c.getenv("SHELL") orelse "/bin/sh";
            const argv = [_:null]?[*:0]const u8{shell_z};
            const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
            _ = std.c.execve(shell_z, &argv, envp);
            std.c._exit(1);
        }

        // Parent: set terminal to raw mode
        const stdin_fd = std.Io.File.stdin().handle;
        const original_termios = try posix.tcgetattr(stdin_fd);
        var raw = original_termios;

        // Make raw
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        try posix.tcsetattr(stdin_fd, .FLUSH, raw);

        // Initialize window manager
        var window_manager = try WindowManager.init(allocator, ws.ws_col, ws.ws_row);
        errdefer window_manager.deinit(io);

        // Create a centered floating window (80% of terminal size)
        const float_width = (ws.ws_col * 80) / 100;
        const float_height = (ws.ws_row * 80) / 100;
        const float_x = (ws.ws_col - float_width) / 2;
        const float_y = (ws.ws_row - float_height) / 2;

        const floating_win = try window_manager.createFloatingWindow(float_x, float_y, float_width, float_height, "Shell");
        floating_win.visible = false; // Start hidden

        // Spawn a shell in the floating window
        try floating_win.spawnShell(io);

        return TermProxy{
            .io = io,
            .allocator = allocator,
            .master_fd = master_fd,
            .child_pid = @intCast(pid_c),
            .window_manager = window_manager,
            .original_termios = original_termios,
            .stdout = std.Io.File.stdout(),
            .term_cols = ws.ws_col,
            .term_rows = ws.ws_row,
        };
    }

    fn deinit(self: *TermProxy) void {
        // Restore terminal
        const stdin_fd = std.Io.File.stdin().handle;
        posix.tcsetattr(stdin_fd, .FLUSH, self.original_termios) catch {};

        closeFd(self.io, self.master_fd);
        self.window_manager.deinit(self.io);
    }

    fn run(self: *TermProxy) !void {
        const stdin = std.Io.File.stdin();
        var buf: [4096]u8 = undefined;

        // Clear screen and move cursor to top-left so everything starts fresh
        self.stdout.writeStreamingAll(self.io, "\x1b[2J\x1b[H") catch {};

        // Create vtStream for parsing terminal output (main window)
        // Main window uses simple ReadonlyStream - queries passthrough to real terminal
        var main_stream = self.window_manager.main_window.terminal.vtStream();
        defer main_stream.deinit();

        // Get the floating window and create its stream with our extended handler
        // This handler intercepts title changes and device queries while delegating
        // all terminal state modifications to ReadonlyHandler
        var floating_win = self.window_manager.getFloatingWindow(0).?;
        var floating_ctx = FloatingWindowContext{
            .window = floating_win,
            .proxy = self,
        };
        const FloatingHandler = VTHandler(FloatingWindowContext);
        const FloatingStream = ghostty_vt.Stream(FloatingHandler);
        var floating_stream: FloatingStream = .initAlloc(
            self.allocator,
            FloatingHandler.init(&floating_win.terminal, &floating_ctx),
        );
        defer floating_stream.deinit();

        const floating_pty_fd = floating_win.pty_fd.?;

        var pollfds = [_]posix.pollfd{
            .{ .fd = stdin.handle, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.master_fd, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = floating_pty_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        while (true) {
            const poll_result = posix.poll(&pollfds, -1) catch break;
            if (poll_result == 0) continue;

            // Check for main shell output
            if (pollfds[1].revents & posix.POLL.IN != 0) {
                const n = posix.read(self.master_fd, &buf) catch break;
                if (n == 0) break;

                // Update main window's terminal state
                main_stream.nextSlice(buf[0..n]);

                if (self.floating_window_visible) {
                    // When floating window visible, we're in alternate screen
                    // Re-render everything from buffer
                    try self.renderAll();
                } else {
                    // Pass through directly - preserves colors, cursor, terminal queries
                    self.stdout.writeStreamingAll(self.io, buf[0..n]) catch break;
                }
            }

            // Check for floating shell output
            if (pollfds[2].revents & posix.POLL.IN != 0) {
                const n = posix.read(floating_pty_fd, &buf) catch {
                    // Floating shell exited, ignore
                    continue;
                };
                if (n > 0) {
                    // Update floating window's terminal state
                    // VTHandler automatically handles:
                    // - Title changes (window_title action -> onWindowTitle)
                    // - Device queries (device_attributes action -> onDeviceQuery)
                    floating_stream.nextSlice(buf[0..n]);

                    // Re-render if visible
                    if (self.floating_window_visible) {
                        try self.renderAll();
                    }
                }
            }

            // Check for user input
            if (pollfds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(stdin.handle, &buf) catch break;
                if (n == 0) break;

                // Check if this is a terminal response (for forwarded queries)
                // Terminal responses start with ESC [ and end with specific chars
                // DA response: ESC [ ? ... c
                // DSR response: ESC [ ... n or ESC [ ... R
                if (self.pending_query_pty) |query_pty| {
                    if (n >= 3 and buf[0] == 0x1b and buf[1] == '[') {
                        const last = buf[n - 1];
                        if (last == 'c' or last == 'n' or last == 'R') {
                            // This is a terminal response, send to the PTY that requested it
                            writeAllFd(self.io, query_pty, buf[0..n]) catch {};
                            self.pending_query_pty = null;
                            continue;
                        }
                    }
                }

                // Handle scrollback mode input
                if (self.in_scrollback_mode) {
                    if (try self.handleScrollbackInput(buf[0..n])) {
                        continue;
                    }
                }

                // Check for Ctrl+b prefix (0x02)
                if (n == 1 and buf[0] == 0x02) {
                    self.waiting_for_prefix_key = true;
                    continue;
                }

                // Check for second key after Ctrl+b
                if (self.waiting_for_prefix_key) {
                    self.waiting_for_prefix_key = false;
                    if (n == 1 and buf[0] == '[') {
                        // Ctrl+b [ - Enter scrollback mode
                        if (!self.in_scrollback_mode and !self.floating_window_visible) {
                            try self.enterScrollbackMode();
                        }
                        continue;
                    }
                    // Not '[', send the Ctrl+b and the key to the shell
                    writeAllFd(self.io, self.master_fd, &[_]u8{0x02}) catch break;
                    // Fall through to send the current key
                }

                // Check for our hotkey (Ctrl+])
                // 0x1d = standard encoding
                // \x1b[93;5u = Kitty keyboard protocol encoding
                const is_hotkey = (n == 1 and buf[0] == 0x1d) or
                    (n == 7 and std.mem.eql(u8, buf[0..7], "\x1b[93;5u"));

                if (is_hotkey) {
                    // Toggle floating window visibility
                    floating_win.visible = !floating_win.visible;
                    self.floating_window_visible = floating_win.visible;

                    if (self.floating_window_visible) {
                        // Drain any pending PTY output before opening overlay
                        try self.drainPtyOutput(&main_stream);
                        // Enter alternate screen and render everything
                        try self.enterAlternateScreen();
                        try self.renderAll();
                    } else {
                        // Render current state, then exit alternate screen
                        try self.renderMainWindowOnly();
                        try self.exitAlternateScreen();
                    }
                    continue;
                }

                // Route input based on which window is focused
                if (self.floating_window_visible) {
                    // Send input to floating shell
                    writeAllFd(self.io, floating_pty_fd, buf[0..n]) catch {};
                } else {
                    // Send input to main shell
                    writeAllFd(self.io, self.master_fd, buf[0..n]) catch break;
                }
            }

            // Check for main shell hangup
            if (pollfds[1].revents & posix.POLL.HUP != 0) break;

            // Check for floating shell hangup (don't exit, just note it)
            if (pollfds[2].revents & posix.POLL.HUP != 0) {
                // Floating shell exited - could respawn or just ignore
                // For now, disable polling on it by setting fd to -1
                pollfds[2].fd = -1;
            }
        }
    }

    fn drainPtyOutput(self: *TermProxy, stream: anytype) !void {
        var buf: [4096]u8 = undefined;
        var drain_pollfds = [_]posix.pollfd{
            .{ .fd = self.master_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        // Drain pending output with very short timeout (1ms) and max iterations
        // This catches any buffered output without blocking on continuous streams
        var iterations: usize = 0;
        const max_iterations = 5;

        while (iterations < max_iterations) : (iterations += 1) {
            const poll_result = posix.poll(&drain_pollfds, 1) catch break;
            if (poll_result == 0) break; // Timeout, no more pending data

            if (drain_pollfds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(self.master_fd, &buf) catch break;
                if (n == 0) break;
                // Update buffer
                stream.nextSlice(buf[0..n]);
                // Also pass through to real terminal (before we enter alternate)
                self.stdout.writeStreamingAll(self.io, buf[0..n]) catch break;
            } else {
                break;
            }
        }
    }

    fn enterAlternateScreen(self: *TermProxy) !void {
        var stdout_writer = self.stdout.writer(self.io, &self.write_buf);
        try stdout_writer.interface.writeAll("\x1b[?1049h"); // Enter alternate screen
        try stdout_writer.interface.flush();
    }

    fn exitAlternateScreen(self: *TermProxy) !void {
        var stdout_writer = self.stdout.writer(self.io, &self.write_buf);
        try stdout_writer.interface.writeAll("\x1b[?1049l"); // Exit alternate screen
        try stdout_writer.interface.flush();

        // Send SIGWINCH to child to force shell/program to redraw
        // This ensures our buffer gets updated with fresh content
        _ = std.c.kill(self.child_pid, std.posix.SIG.WINCH);
    }

    fn renderAll(self: *TermProxy) !void {
        var stdout_writer = self.stdout.writer(self.io, &self.write_buf);

        // Hide cursor during rendering
        try stdout_writer.interface.writeAll("\x1b[?25l");
        // Clear screen and home cursor
        try stdout_writer.interface.writeAll("\x1b[H\x1b[2J");

        // Render main window with colors from buffer
        try self.window_manager.main_window.renderWithStyle(&stdout_writer.interface);

        // Render floating windows on top (with colors)
        for (self.window_manager.floating_windows.items) |*win| {
            try win.renderWithStyle(&stdout_writer.interface);
        }

        // Position cursor at the focused window's cursor position
        if (self.floating_window_visible) {
            if (self.window_manager.getFloatingWindow(0)) |win| {
                const screen = win.terminal.screens.active;
                const cursor_x = screen.cursor.x;
                const cursor_y = screen.cursor.y;
                // Calculate absolute position (window position + border + cursor offset)
                const abs_x = win.x + (if (win.has_border) @as(u16, 1) else 0) + cursor_x + 1; // +1 for ANSI 1-indexed
                const abs_y = win.y + (if (win.has_border) @as(u16, 1) else 0) + cursor_y + 1;
                try stdout_writer.interface.print("\x1b[{d};{d}H", .{ abs_y, abs_x });
            }
        }

        // Show cursor
        try stdout_writer.interface.writeAll("\x1b[?25h");
        try stdout_writer.interface.flush();
    }

    fn renderMainWindowOnly(self: *TermProxy) !void {
        var stdout_writer = self.stdout.writer(self.io, &self.write_buf);

        // Hide cursor during rendering
        try stdout_writer.interface.writeAll("\x1b[?25l");
        // Clear screen and home cursor
        try stdout_writer.interface.writeAll("\x1b[H\x1b[2J");

        // Render main window with colors from buffer
        try self.window_manager.main_window.renderWithStyle(&stdout_writer.interface);

        // Show cursor
        try stdout_writer.interface.writeAll("\x1b[?25h");
        try stdout_writer.interface.flush();
    }

    fn enterScrollbackMode(self: *TermProxy) !void {
        self.in_scrollback_mode = true;

        // Scroll viewport to top of scrollback
        const terminal = &self.window_manager.main_window.terminal;
        terminal.scrollViewport(.top);

        // Enter alternate screen and render
        try self.enterAlternateScreen();
        try self.renderScrollback();
    }

    fn exitScrollbackMode(self: *TermProxy) !void {
        self.in_scrollback_mode = false;

        // Scroll viewport back to bottom (active area)
        const terminal = &self.window_manager.main_window.terminal;
        terminal.scrollViewport(.bottom);

        // Exit alternate screen - shell will redraw
        try self.exitAlternateScreen();
    }

    fn handleScrollbackInput(self: *TermProxy, input: []const u8) !bool {
        if (input.len == 0) return false;

        const terminal = &self.window_manager.main_window.terminal;

        // Single character commands
        if (input.len == 1) {
            switch (input[0]) {
                'q', 0x1b => { // q or Escape - exit scrollback
                    try self.exitScrollbackMode();
                    return true;
                },
                'j' => { // Scroll down one line
                    terminal.scrollViewport(.{ .delta = 1 });
                    try self.renderScrollback();
                    return true;
                },
                'k' => { // Scroll up one line
                    terminal.scrollViewport(.{ .delta = -1 });
                    try self.renderScrollback();
                    return true;
                },
                'g' => { // Go to top
                    terminal.scrollViewport(.top);
                    try self.renderScrollback();
                    return true;
                },
                'G' => { // Go to bottom
                    terminal.scrollViewport(.bottom);
                    try self.renderScrollback();
                    return true;
                },
                0x04 => { // Ctrl+d - half page down
                    const half_page: isize = @intCast(self.term_rows / 2);
                    terminal.scrollViewport(.{ .delta = half_page });
                    try self.renderScrollback();
                    return true;
                },
                0x15 => { // Ctrl+u - half page up
                    const half_page: isize = @intCast(self.term_rows / 2);
                    terminal.scrollViewport(.{ .delta = -half_page });
                    try self.renderScrollback();
                    return true;
                },
                else => return true, // Consume but ignore other single chars
            }
        }

        // Consume all input in scrollback mode
        return true;
    }

    fn renderScrollback(self: *TermProxy) !void {
        var stdout_writer = self.stdout.writer(self.io, &self.write_buf);

        // Hide cursor during rendering
        try stdout_writer.interface.writeAll("\x1b[?25l");
        // Clear screen and home cursor
        try stdout_writer.interface.writeAll("\x1b[H\x1b[2J");

        // Render the viewport content from the terminal
        try self.window_manager.main_window.renderWithStyle(&stdout_writer.interface);

        // Draw status line at bottom showing position
        const screen = self.window_manager.main_window.terminal.screens.active;
        const at_bottom = screen.viewportIsBottom();

        try stdout_writer.interface.print("\x1b[{d};1H", .{self.term_rows}); // Move to last row
        try stdout_writer.interface.writeAll("\x1b[7m"); // Reverse video
        if (at_bottom) {
            try stdout_writer.interface.writeAll(" [scrollback: BOTTOM] q=exit j/k=scroll Ctrl+u/d=page g/G=top/bottom ");
        } else {
            try stdout_writer.interface.writeAll(" [scrollback] q=exit j/k=scroll Ctrl+u/d=page g/G=top/bottom ");
        }
        try stdout_writer.interface.writeAll("\x1b[0m"); // Reset

        // Keep cursor hidden in scrollback mode
        try stdout_writer.interface.flush();
    }
};

// PTY helper functions
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;

fn grantpt_wrapper(fd: posix.fd_t) void {
    _ = grantpt(fd);
}

fn unlockpt_wrapper(fd: posix.fd_t) void {
    _ = unlockpt(fd);
}

fn ptsname_wrapper(fd: posix.fd_t) [:0]const u8 {
    const ptr = ptsname(fd) orelse "/dev/pts/0";
    return std.mem.span(ptr);
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // Parse CLI arguments. The arena lives until the end of main, so we
    // can hand its slices straight to cli.parse.
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch {
        stderr.writeAll("error: failed to allocate arguments\n") catch {};
        stderr.flush() catch {};
        return 1;
    };

    const action = cli.parse(args[1..]) catch {
        stderr.writeAll("error: invalid argument\n") catch {};
        stderr.writeAll("Try 'tzig --help' for more information.\n") catch {};
        stderr.flush() catch {};
        return 1;
    };

    switch (action) {
        .version => {
            cli.printVersion(stdout) catch return 1;
            stdout.flush() catch {};
            return 0;
        },
        .help => {
            cli.printHelp(stdout) catch return 1;
            stdout.flush() catch {};
            return 0;
        },
        .run => {},
    }

    // Run the terminal proxy. tzig: prefer the gpa from init.gpa where
    // possible; we still use a per-process DebugAllocator here so our leak
    // checks stay tight in debug builds.
    _ = init.gpa;
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var proxy = TermProxy.init(io, allocator) catch |err| {
        stderr.print("error: failed to initialize terminal: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        return 1;
    };
    defer proxy.deinit();

    proxy.run() catch |err| {
        stderr.print("error: {}\n", .{err}) catch {};
        stderr.flush() catch {};
        return 1;
    };

    return 0;
}
