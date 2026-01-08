const std = @import("std");
const posix = std.posix;
const std_c = std.c;
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");
const cli = @import("cli.zig");

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

    fn parseOscTitle(self: *Window, data: []const u8) void {
        // Look for OSC 0;title ST or OSC 2;title ST sequences
        // OSC = ESC ] (0x1b 0x5d)
        // ST = ESC \ (0x1b 0x5c) or BEL (0x07)
        var i: usize = 0;
        while (i + 3 < data.len) {
            if (data[i] == 0x1b and data[i + 1] == ']') {
                // Found OSC start
                const cmd_start = i + 2;
                // Check for 0; or 2; (set window title)
                if (cmd_start + 1 < data.len and
                    (data[cmd_start] == '0' or data[cmd_start] == '2') and
                    data[cmd_start + 1] == ';')
                {
                    const title_start = cmd_start + 2;
                    // Find terminator (BEL or ST)
                    var title_end: ?usize = null;
                    var j = title_start;
                    while (j < data.len) {
                        if (data[j] == 0x07) {
                            // BEL terminator
                            title_end = j;
                            break;
                        } else if (j + 1 < data.len and data[j] == 0x1b and data[j + 1] == '\\') {
                            // ST terminator
                            title_end = j;
                            break;
                        }
                        j += 1;
                    }
                    if (title_end) |end| {
                        self.setTitle(data[title_start..end]);
                        i = end;
                        continue;
                    }
                }
            }
            i += 1;
        }
    }

    fn deinit(self: *Window, allocator: std.mem.Allocator) void {
        // Kill child process if running
        if (self.child_pid) |pid| {
            _ = std.c.kill(pid, std.posix.SIG.TERM);
        }
        // Close PTY
        if (self.pty_fd) |fd| {
            posix.close(fd);
        }
        self.terminal.deinit(allocator);
    }

    fn spawnShell(self: *Window) !void {
        // Open PTY
        const master_fd = posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch |err| {
            return err;
        };
        errdefer posix.close(master_fd);

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

        // Fork
        const fork_result = posix.fork();
        const pid = fork_result catch |err| {
            return err;
        };

        if (pid == 0) {
            // Child process
            posix.close(master_fd);

            // Create new session
            _ = std_c.setsid();

            // Open slave
            const slave_fd = posix.open(slave_path, .{ .ACCMODE = .RDWR }, 0) catch {
                posix.exit(1);
            };

            // Set window size on slave too
            _ = ioctl(slave_fd, TIOCSWINSZ, &ws);

            // Dup to stdin/stdout/stderr
            posix.dup2(slave_fd, 0) catch posix.exit(1);
            posix.dup2(slave_fd, 1) catch posix.exit(1);
            posix.dup2(slave_fd, 2) catch posix.exit(1);

            if (slave_fd > 2) posix.close(slave_fd);

            // Exec shell with current environment
            const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
            const argv = [_:null]?[*:0]const u8{shell};

            // Pass through the current environment
            const envp = std.c.environ;
            posix.execvpeZ(shell, &argv, envp) catch posix.exit(1);
            posix.exit(1);
        }

        // Parent
        self.pty_fd = master_fd;
        self.child_pid = pid;
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

    fn writeContent(self: *Window, data: []const u8) !void {
        var stream = self.terminal.vtStream();
        defer stream.deinit();
        try stream.nextSlice(data);
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

    fn deinit(self: *WindowManager) void {
        for (self.floating_windows.items) |*win| {
            win.deinit(self.allocator);
        }
        self.floating_windows.deinit(self.allocator);
        self.main_window.deinit(self.allocator);
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
    allocator: std.mem.Allocator,
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    window_manager: WindowManager,
    floating_window_visible: bool = false,
    original_termios: posix.termios,
    stdout: std.fs.File,
    write_buf: [8192]u8 = undefined,
    term_cols: u16,
    term_rows: u16,

    // Track PTY waiting for terminal query response
    pending_query_pty: ?posix.fd_t = null,

    fn init(allocator: std.mem.Allocator) !TermProxy {
        // Get current window size
        var ws: Winsize = undefined;
        const stdout_fd = std.posix.STDOUT_FILENO;

        const ws_result = ioctl(stdout_fd, TIOCGWINSZ, &ws);
        if (ws_result != 0) {
            ws = .{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
        }

        // Open PTY
        const master_fd = posix.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true }, 0) catch |err| {
            std.debug.print("Failed to open /dev/ptmx: {}\n", .{err});
            return err;
        };
        errdefer posix.close(master_fd);

        // Grant and unlock
        grantpt_wrapper(master_fd);
        unlockpt_wrapper(master_fd);

        const slave_path = ptsname_wrapper(master_fd);

        // Set window size on master
        _ = ioctl(master_fd, TIOCSWINSZ, &ws);

        // Fork
        const fork_result = posix.fork();
        const pid = fork_result catch |err| {
            std.debug.print("Fork failed: {}\n", .{err});
            return err;
        };

        if (pid == 0) {
            // Child process
            posix.close(master_fd);

            // Create new session
            _ = std_c.setsid();

            // Open slave
            const slave_fd = posix.open(slave_path, .{ .ACCMODE = .RDWR }, 0) catch {
                posix.exit(1);
            };

            // Set window size on slave too
            _ = ioctl(slave_fd, TIOCSWINSZ, &ws);

            // Dup to stdin/stdout/stderr
            posix.dup2(slave_fd, 0) catch posix.exit(1);
            posix.dup2(slave_fd, 1) catch posix.exit(1);
            posix.dup2(slave_fd, 2) catch posix.exit(1);

            if (slave_fd > 2) posix.close(slave_fd);

            // Exec shell with current environment
            const shell = std.posix.getenv("SHELL") orelse "/bin/sh";
            const argv = [_:null]?[*:0]const u8{shell};

            // Pass through the current environment
            const envp = std.c.environ;
            posix.execvpeZ(shell, &argv, envp) catch posix.exit(1);
            posix.exit(1);
        }

        // Parent: set terminal to raw mode
        const stdin_fd = std.posix.STDIN_FILENO;
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
        errdefer window_manager.deinit();

        // Create a centered floating window (80% of terminal size)
        const float_width = (ws.ws_col * 80) / 100;
        const float_height = (ws.ws_row * 80) / 100;
        const float_x = (ws.ws_col - float_width) / 2;
        const float_y = (ws.ws_row - float_height) / 2;

        const floating_win = try window_manager.createFloatingWindow(float_x, float_y, float_width, float_height, "Shell");
        floating_win.visible = false; // Start hidden

        // Spawn a shell in the floating window
        try floating_win.spawnShell();

        return TermProxy{
            .allocator = allocator,
            .master_fd = master_fd,
            .child_pid = pid,
            .window_manager = window_manager,
            .original_termios = original_termios,
            .stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO },
            .term_cols = ws.ws_col,
            .term_rows = ws.ws_row,
        };
    }

    fn deinit(self: *TermProxy) void {
        // Restore terminal
        const stdin_fd = std.posix.STDIN_FILENO;
        posix.tcsetattr(stdin_fd, .FLUSH, self.original_termios) catch {};

        posix.close(self.master_fd);
        self.window_manager.deinit();
    }

    fn run(self: *TermProxy) !void {
        const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        var buf: [4096]u8 = undefined;

        // Clear screen and move cursor to top-left so everything starts fresh
        self.stdout.writeAll("\x1b[2J\x1b[H") catch {};

        // Create vtStream for parsing terminal output (main window)
        var main_stream = self.window_manager.main_window.terminal.vtStream();
        defer main_stream.deinit();

        // Get the floating window and create its stream
        var floating_win = self.window_manager.getFloatingWindow(0).?;
        var floating_stream = floating_win.terminal.vtStream();
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
                try main_stream.nextSlice(buf[0..n]);

                if (self.floating_window_visible) {
                    // When floating window visible, we're in alternate screen
                    // Re-render everything from buffer
                    try self.renderAll();
                } else {
                    // Pass through directly - preserves colors, cursor, terminal queries
                    self.stdout.writeAll(buf[0..n]) catch break;
                }
            }

            // Check for floating shell output
            if (pollfds[2].revents & posix.POLL.IN != 0) {
                const n = posix.read(floating_pty_fd, &buf) catch {
                    // Floating shell exited, ignore
                    continue;
                };
                if (n > 0) {
                    // Forward terminal queries to real terminal
                    // Responses will come back on stdin and be routed back
                    if (self.forwardTerminalQueries(buf[0..n])) {
                        self.pending_query_pty = floating_pty_fd;
                    }

                    // Parse OSC title sequences to update window title
                    floating_win.parseOscTitle(buf[0..n]);

                    // Update floating window's terminal state
                    try floating_stream.nextSlice(buf[0..n]);

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
                            _ = posix.write(query_pty, buf[0..n]) catch {};
                            self.pending_query_pty = null;
                            continue;
                        }
                    }
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
                    _ = posix.write(floating_pty_fd, buf[0..n]) catch {};
                } else {
                    // Send input to main shell
                    _ = posix.write(self.master_fd, buf[0..n]) catch break;
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
                try stream.nextSlice(buf[0..n]);
                // Also pass through to real terminal (before we enter alternate)
                self.stdout.writeAll(buf[0..n]) catch break;
            } else {
                break;
            }
        }
    }

    fn enterAlternateScreen(self: *TermProxy) !void {
        var stdout_writer = self.stdout.writer(&self.write_buf);
        try stdout_writer.interface.writeAll("\x1b[?1049h"); // Enter alternate screen
        try stdout_writer.interface.flush();
    }

    fn exitAlternateScreen(self: *TermProxy) !void {
        var stdout_writer = self.stdout.writer(&self.write_buf);
        try stdout_writer.interface.writeAll("\x1b[?1049l"); // Exit alternate screen
        try stdout_writer.interface.flush();

        // Send SIGWINCH to child to force shell/program to redraw
        // This ensures our buffer gets updated with fresh content
        _ = std.c.kill(self.child_pid, std.posix.SIG.WINCH);
    }

    fn renderAll(self: *TermProxy) !void {
        var stdout_writer = self.stdout.writer(&self.write_buf);

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
        var stdout_writer = self.stdout.writer(&self.write_buf);

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

    fn forwardTerminalQueries(self: *TermProxy, data: []const u8) bool {
        // Look for terminal queries in the output and forward them to the real terminal
        // The response will come back on stdin and be routed back to the requesting PTY
        // Returns true if any query was forwarded
        var forwarded = false;
        var i: usize = 0;
        while (i < data.len) {
            if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '[') {
                // Check for Primary DA: ESC [ c or ESC [ 0 c
                if (i + 2 < data.len and data[i + 2] == 'c') {
                    self.stdout.writeAll("\x1b[c") catch {};
                    forwarded = true;
                    i += 3;
                    continue;
                }
                if (i + 3 < data.len and data[i + 2] == '0' and data[i + 3] == 'c') {
                    self.stdout.writeAll("\x1b[0c") catch {};
                    forwarded = true;
                    i += 4;
                    continue;
                }
                // Check for Secondary DA: ESC [ > c or ESC [ > 0 c
                if (i + 3 < data.len and data[i + 2] == '>' and data[i + 3] == 'c') {
                    self.stdout.writeAll("\x1b[>c") catch {};
                    forwarded = true;
                    i += 4;
                    continue;
                }
                if (i + 4 < data.len and data[i + 2] == '>' and data[i + 3] == '0' and data[i + 4] == 'c') {
                    self.stdout.writeAll("\x1b[>0c") catch {};
                    forwarded = true;
                    i += 5;
                    continue;
                }
                // Check for DSR (Device Status Report): ESC [ 5 n or ESC [ 6 n
                if (i + 3 < data.len and data[i + 2] == '5' and data[i + 3] == 'n') {
                    self.stdout.writeAll("\x1b[5n") catch {};
                    forwarded = true;
                    i += 4;
                    continue;
                }
                if (i + 3 < data.len and data[i + 2] == '6' and data[i + 3] == 'n') {
                    self.stdout.writeAll("\x1b[6n") catch {};
                    forwarded = true;
                    i += 4;
                    continue;
                }
            }
            i += 1;
        }
        return forwarded;
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

pub fn main() !u8 {
    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buf);
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // Parse CLI arguments
    const args = std.process.argsAlloc(std.heap.page_allocator) catch {
        stderr.writeAll("error: failed to allocate arguments\n") catch {};
        stderr.flush() catch {};
        return 1;
    };
    defer std.process.argsFree(std.heap.page_allocator, args);

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

    // Run the terminal proxy
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var proxy = TermProxy.init(allocator) catch |err| {
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
