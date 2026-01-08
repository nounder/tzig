const std = @import("std");
const posix = std.posix;
const std_c = std.c;
const builtin = @import("builtin");
const ghostty_vt = @import("ghostty-vt");

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

const Overlay = struct {
    active: bool = false,
    scroll_offset: usize = 0,

    fn toggle(self: *Overlay) void {
        self.active = !self.active;
        self.scroll_offset = 0;
    }

    fn render(self: *Overlay, writer: anytype, terminal: *ghostty_vt.Terminal) !void {
        // Enter alternate screen for overlay
        try writer.writeAll("\x1b[?1049h");
        try writer.writeAll("\x1b[H\x1b[2J"); // clear

        const screen = terminal.screens.active;
        const pages = &screen.pages;

        // Draw header
        try writer.writeAll("\x1b[7m"); // reverse video
        try writer.writeAll(" SCROLLBACK | j/k scroll | q quit ");
        try writer.writeAll("\x1b[0m\r\n");

        // Draw scrollback content
        const max_lines = terminal.rows -| 2;
        if (max_lines == 0) return;

        // Get bottom of history (row just before active region)
        const active_top = pages.getTopLeft(.active);
        const history_br = active_top.up(1) orelse {
            try writer.writeAll("\r\n  (no scrollback history yet)\r\n");
            return;
        };

        // Get top of history
        const history_tl = pages.getTopLeft(.history);

        // Apply scroll offset - start from bottom of history and go up
        var view_bottom = history_br;
        var offset_remaining = self.scroll_offset;
        while (offset_remaining > 0) {
            if (view_bottom.up(1)) |p| {
                view_bottom = p;
                offset_remaining -= 1;
            } else {
                break; // Can't scroll any further up
            }
        }

        // Calculate starting position for display (go up max_lines-1 from view_bottom)
        var view_top = view_bottom;
        var lines_available: usize = 1; // view_bottom itself counts as 1
        var i: usize = 0;
        while (i < max_lines - 1) : (i += 1) {
            if (view_top.up(1)) |p| {
                view_top = p;
                lines_available += 1;
            } else {
                break; // Hit top of history
            }
        }

        // Use rowIterator to iterate from view_top down to view_bottom
        var row_it = view_top.rowIterator(.right_down, view_bottom);
        var lines_shown: usize = 0;

        while (row_it.next()) |pin| {
            if (lines_shown >= max_lines) break;

            const cells = pin.cells(.all);
            for (cells) |cell| {
                const cp = cell.codepoint();
                if (cp == 0) {
                    try writer.writeByte(' ');
                } else {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch 1;
                    try writer.writeAll(buf[0..len]);
                }
            }
            try writer.writeAll("\r\n");
            lines_shown += 1;
        }

        // Unused but kept for potential future use
        _ = history_tl;
    }

    fn hide(writer: anytype) !void {
        // Leave alternate screen
        try writer.writeAll("\x1b[?1049l");
    }
};

const TermProxy = struct {
    master_fd: posix.fd_t,
    child_pid: posix.pid_t,
    terminal: ghostty_vt.Terminal,
    overlay: Overlay,
    original_termios: posix.termios,
    stdout: std.fs.File,
    write_buf: [8192]u8 = undefined,

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

        // Initialize ghostty terminal
        const terminal: ghostty_vt.Terminal = try .init(allocator, .{
            .cols = ws.ws_col,
            .rows = ws.ws_row,
        });
        errdefer terminal.deinit(allocator);

        return TermProxy{
            .master_fd = master_fd,
            .child_pid = pid,
            .terminal = terminal,
            .overlay = Overlay{},
            .original_termios = original_termios,
            .stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO },
        };
    }

    fn deinit(self: *TermProxy, allocator: std.mem.Allocator) void {
        // Restore terminal
        const stdin_fd = std.posix.STDIN_FILENO;
        posix.tcsetattr(stdin_fd, .FLUSH, self.original_termios) catch {};

        posix.close(self.master_fd);
        self.terminal.deinit(allocator);
    }

    fn run(self: *TermProxy) !void {
        const stdin = std.fs.File{ .handle = std.posix.STDIN_FILENO };
        var buf: [4096]u8 = undefined;

        // Create vtStream for parsing terminal output
        var stream = self.terminal.vtStream();
        defer stream.deinit();

        var pollfds = [_]posix.pollfd{
            .{ .fd = stdin.handle, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = self.master_fd, .events = posix.POLL.IN, .revents = 0 },
        };

        while (true) {
            const poll_result = posix.poll(&pollfds, -1) catch break;
            if (poll_result == 0) continue;

            // Check for child output
            if (pollfds[1].revents & posix.POLL.IN != 0) {
                const n = posix.read(self.master_fd, &buf) catch break;
                if (n == 0) break;

                // Update terminal state using ghostty-vt stream
                try stream.nextSlice(buf[0..n]);

                // Forward to terminal (if overlay not active)
                if (!self.overlay.active) {
                    self.stdout.writeAll(buf[0..n]) catch break;
                }
            }

            // Check for user input
            if (pollfds[0].revents & posix.POLL.IN != 0) {
                const n = posix.read(stdin.handle, &buf) catch break;
                if (n == 0) break;

                // Check for our hotkey - multiple options:
                // Ctrl+] standard: 0x1d
                // Ctrl+] kitty protocol: ESC [ 93 ; 5 u
                // F12: ESC [ 24 ~ or ESC O P (varies by terminal)
                const is_hotkey = (n == 1 and buf[0] == 0x1d) or
                    (n >= 6 and std.mem.startsWith(u8, buf[0..n], "\x1b[93;5u")) or
                    (n >= 4 and std.mem.startsWith(u8, buf[0..n], "\x1b[24~")) or // F12
                    (n >= 5 and std.mem.startsWith(u8, buf[0..n], "\x1bOP")); // F1
                if (is_hotkey) {
                    self.overlay.toggle();
                    var stdout_writer = self.stdout.writer(&self.write_buf);
                    if (self.overlay.active) {
                        try self.overlay.render(&stdout_writer.interface, &self.terminal);
                    } else {
                        try Overlay.hide(&stdout_writer.interface);
                        // Reset attributes - alternate screen restore handles the rest
                        try stdout_writer.interface.writeAll("\x1b[0m");
                    }
                    try stdout_writer.interface.flush();
                    continue;
                }

                // Handle overlay keys
                if (self.overlay.active) {
                    if (n == 1) {
                        var stdout_writer = self.stdout.writer(&self.write_buf);
                        switch (buf[0]) {
                            'q' => {
                                self.overlay.toggle();
                                try Overlay.hide(&stdout_writer.interface);
                                // Reset attributes and request shell redraw via SIGWINCH
                                try stdout_writer.interface.writeAll("\x1b[0m");
                            },
                            'k', 'K' => {
                                self.overlay.scroll_offset += 1;
                                try self.overlay.render(&stdout_writer.interface, &self.terminal);
                            },
                            'j', 'J' => {
                                if (self.overlay.scroll_offset > 0) {
                                    self.overlay.scroll_offset -= 1;
                                }
                                try self.overlay.render(&stdout_writer.interface, &self.terminal);
                            },
                            else => {},
                        }
                        try stdout_writer.interface.flush();
                    }
                    continue;
                }

                // Forward to shell
                _ = posix.write(self.master_fd, buf[0..n]) catch break;
            }

            // Check for hangup
            if (pollfds[1].revents & posix.POLL.HUP != 0) break;
        }
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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var proxy = try TermProxy.init(allocator);
    defer proxy.deinit(allocator);

    try proxy.run();
}
