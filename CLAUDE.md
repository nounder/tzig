## Project Overview

tzig is a terminal multiplexer like tmux, but simpler:
- No mouse capture (scrolling works natively in your terminal)
- No session management or detach/reattach
- Just scrollback history with a lightweight overlay

Built in Zig, uses Ghostty's virtual terminal library for terminal emulation.

## Build Commands

```bash
zig build          # Build the project
zig build run      # Build and run
zig build test     # Run tests
```

The built binary is at `./zig-out/bin/tzig`.

## Zig 0.16 API Notes

This project targets Zig 0.16. Most of the I/O surface moved from
`std.fs` to `std.Io`. Key differences:

### Entry point shape

```zig
pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    // ...
}
```
`init.io`, `init.gpa`, `init.arena`, and `init.minimal.{environ,args}` are
your entry points to the rest of stdlib. See
`/opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/process.zig` `Init` struct.

### File I/O Writers
Writers require an `io` and a buffer parameter:
```zig
var buf: [4096]u8 = undefined;
var writer = std.Io.File.stdout().writer(io, &buf);
const w = &writer.interface;
try w.writeAll("hello");
try w.flush();  // Don't forget to flush!
```

### Static file handles
```zig
const stdout = std.Io.File.stdout();
const stderr = std.Io.File.stderr();
const stdin  = std.Io.File.stdin();
// .handle gives you the raw `posix.fd_t`.
```

`std.fs.File.stdout()` does NOT exist in 0.16 (despite what some early
0.16 reference docs claim). Use `std.Io.File.stdout()`.

### Removed `std.posix.*` symbols

Many syscall wrappers were removed in 0.16. Common replacements:

- `posix.open` -> `std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write })`
- `posix.close(fd)` -> wrap in `std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }` and call `.close(io)`
- `posix.write` -> `Io.File.writeStreamingAll(io, bytes)` on a wrapper File
- `posix.read` -> still exists, no change needed
- `posix.fork`, `posix.exit`, `posix.dup2`, `posix.execvpeZ` -> drop to `std.c.*` (these don't fit the Io model)
- `posix.getenv` -> `init.minimal.environ.getPosix("X")` returning `?[:0]const u8`

See `src/vt/PORT_LESSONS.md` for the full mapping table and rationale.

## Project Structure

- `src/main.zig` - Main entry point, terminal proxy implementation
- `src/cli.zig` - CLI argument parsing (--help, --version)
- `build.zig` - Build configuration
- `vendor/ghostty/` - Ghostty dependency (provides ghostty-vt module)

## Architecture

The terminal proxy works by:
1. Opening a PTY (pseudo-terminal)
2. Forking a child process running the user's shell
3. Proxying I/O between the real terminal and the PTY
4. Using ghostty-vt to parse and track terminal state
5. Providing a scrollback overlay (Ctrl+] to toggle)
