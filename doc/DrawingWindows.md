# Drawing Floating Windows Over Terminal Content

This document analyzes different approaches for rendering floating windows that overlay terminal content while the background terminal continues to update.

## The Problem

When implementing floating windows over a terminal:
1. The main terminal (shell) continues producing output
2. Output causes the terminal viewport to scroll
3. The floating window must stay at a fixed position
4. We want to preserve colors, terminal features, and scrollback history

## Current Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    Host Terminal                         │
│              (iTerm, Ghostty, etc.)                      │
│  ┌───────────────────────────────────────────────────┐  │
│  │                                                   │  │
│  │                 tzig process                      │  │
│  │  ┌─────────────┐      ┌─────────────────────┐    │  │
│  │  │   PTY       │      │   ghostty-vt        │    │  │
│  │  │  (shell)    │─────▶│   Terminal Buffer   │    │  │
│  │  └─────────────┘      └─────────────────────┘    │  │
│  │         │                       │                │  │
│  │         │ raw output            │ parsed state   │  │
│  │         ▼                       ▼                │  │
│  │  ┌─────────────────────────────────────────┐    │  │
│  │  │           Rendering Layer               │    │  │
│  │  └─────────────────────────────────────────┘    │  │
│  │                      │                          │  │
│  │                      ▼                          │  │
│  │               stdout to host                    │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

## The Ghost Window Problem

When we pass through shell output directly while a floating window is visible:

```
Time T1: Floating window rendered at row 10
┌────────────────────────────────────┐
│ line 1                             │
│ line 2                             │
│ ╭──── Floating Window ────╮        │
│ │ Hello                   │        │
│ │                         │        │
│ ╰─────────────────────────╯        │
│ line 6                             │
└────────────────────────────────────┘

Time T2: Shell outputs new line, terminal scrolls EVERYTHING up
┌────────────────────────────────────┐
│ line 2                             │
│ ╭──── Floating Window ────╮        │  ← Ghost! (scrolled up)
│ │ Hello                   │        │
│ │                         │        │
│ ╰─────────────────────────╯        │
│ line 6                             │
│ line 7 (new)                       │
└────────────────────────────────────┘

Time T3: We render floating window at fixed position again
┌────────────────────────────────────┐
│ line 2                             │
│ ╭──── Floating Window ────╮        │  ← Ghost still here!
│ │ Hello                   │        │
│ ╭──── Floating Window ────╮        │  ← New render
│ │ Hello                   │        │
│ ╰─────────────────────────╯        │
│ line 7 (new)                       │
└────────────────────────────────────┘
```

**Root cause:** The terminal's scroll operation moves ALL pixels, including our previously-rendered floating window. We then render a new copy, creating duplicates.

---

## Solution 1: Alternate Screen Buffer

Use the terminal's alternate screen buffer to isolate our rendering.

### How It Works

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  On floating window OPEN:                               │
│  ┌───────────────────────────────────────────────────┐  │
│  │ 1. Send \x1b[?1049h (enter alternate screen)      │  │
│  │ 2. Terminal saves primary screen state            │  │
│  │ 3. We now control entire alternate screen         │  │
│  └───────────────────────────────────────────────────┘  │
│                         │                               │
│                         ▼                               │
│  While floating window VISIBLE:                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │ Shell output ──▶ ghostty-vt buffer (no passthru)  │  │
│  │                         │                         │  │
│  │                         ▼                         │  │
│  │ Render main window from buffer (with colors)      │  │
│  │                         │                         │  │
│  │                         ▼                         │  │
│  │ Render floating window on top                     │  │
│  └───────────────────────────────────────────────────┘  │
│                         │                               │
│                         ▼                               │
│  On floating window CLOSE:                              │
│  ┌───────────────────────────────────────────────────┐  │
│  │ 1. Render current main window state from buffer   │  │
│  │ 2. Send \x1b[?1049l (exit alternate screen)       │  │
│  │ 3. Send SIGWINCH to sync shell cursor/prompt      │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Data Flow

```
                    Floating Window VISIBLE

Shell ──▶ PTY ──▶ ghostty-vt buffer ──▶ Render to alternate screen
                        │
                        │ (no pass-through to host terminal)
                        │
                        ▼
              ┌─────────────────┐
              │ Main content    │
              │ (from buffer)   │
              │ ┌─────────────┐ │
              │ │  Floating   │ │
              │ │   Window    │ │
              │ └─────────────┘ │
              └─────────────────┘
                        │
                        ▼
                  Host Terminal
               (alternate screen)
```

### Pros
- Clean separation - alternate screen is designed for full-screen apps
- Terminal handles cursor save/restore automatically
- Crash recovery: exiting alternate screen restores primary screen
- No ghost windows possible (we control all pixels)

### Cons
- **No scrollback in host terminal** while floating window is open
- Mode switching complexity
- Must render main window with full color/style support from buffer
- Brief flash possible during transitions

---

## Solution 2: Full Re-render Without Mode Switch

Don't pass through shell output when floating window is visible. Render everything from our buffer.

### How It Works

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  On floating window OPEN:                               │
│  ┌───────────────────────────────────────────────────┐  │
│  │ 1. Stop pass-through mode                         │  │
│  │ 2. Render floating window on top of current view  │  │
│  └───────────────────────────────────────────────────┘  │
│                         │                               │
│                         ▼                               │
│  While floating window VISIBLE:                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │ Shell output ──▶ ghostty-vt buffer (no passthru)  │  │
│  │                         │                         │  │
│  │                         ▼                         │  │
│  │ Clear screen                                      │  │
│  │                         │                         │  │
│  │                         ▼                         │  │
│  │ Render main window from buffer (with colors)      │  │
│  │                         │                         │  │
│  │                         ▼                         │  │
│  │ Render floating window on top                     │  │
│  └───────────────────────────────────────────────────┘  │
│                         │                               │
│                         ▼                               │
│  On floating window CLOSE:                              │
│  ┌───────────────────────────────────────────────────┐  │
│  │ 1. Re-render main window from buffer              │  │
│  │ 2. Resume pass-through mode                       │  │
│  │ 3. Send SIGWINCH to sync shell                    │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Comparison with Solution 1

| Aspect | Solution 1 (Alt Screen) | Solution 2 (Full Re-render) |
|--------|------------------------|----------------------------|
| Ghost windows | No | No |
| Host scrollback | Lost while open | Lost while open |
| Mode switching | Yes | No |
| Crash recovery | Good (auto-restore) | Poor (corrupted screen) |
| Implementation | More complex | Simpler |
| Code paths | Different open/close | Same render path always |

### Pros
- Simpler implementation - no mode switching
- Same rendering code path always
- No state to track

### Cons
- **No scrollback in host terminal** while floating window is open
- No safety net if crash (screen stays corrupted)
- Must handle cursor position manually

---

## Solution 3: Pass-through with Synchronized Redraw

Pass through shell output (preserving scrollback) and use synchronized updates to redraw floating window atomically.

### How It Works

```
┌─────────────────────────────────────────────────────────┐
│                                                         │
│  On each shell output while floating window visible:    │
│                                                         │
│  ┌───────────────────────────────────────────────────┐  │
│  │ 1. Begin synchronized update (\x1b[?2026h)        │  │
│  │                         │                         │  │
│  │                         ▼                         │  │
│  │ 2. Pass through shell output to terminal          │  │
│  │    (terminal scrolls, ghost appears)              │  │
│  │                         │                         │  │
│  │                         ▼                         │  │
│  │ 3. Clear floating window region                   │  │
│  │    (erase the ghost)                              │  │
│  │                         │                         │  │
│  │                         ▼                         │  │
│  │ 4. Redraw floating window at fixed position       │  │
│  │                         │                         │  │
│  │                         ▼                         │  │
│  │ 5. End synchronized update (\x1b[?2026l)          │  │
│  │    (terminal renders all changes atomically)      │  │
│  └───────────────────────────────────────────────────┘  │
│                                                         │
└─────────────────────────────────────────────────────────┘
```

### Data Flow

```
Shell output arrives
        │
        ▼
┌───────────────────┐
│ Begin sync update │ ──▶ \x1b[?2026h
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Pass through to   │ ──▶ Terminal scrolls (ghost created in buffer)
│ host terminal     │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Clear window area │ ──▶ Erase ghost pixels
│ (spaces + cursor  │
│  positioning)     │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ Redraw floating   │ ──▶ Fresh window at correct position
│ window            │
└───────────────────┘
        │
        ▼
┌───────────────────┐
│ End sync update   │ ──▶ \x1b[?2026l (atomic render)
└───────────────────┘
        │
        ▼
   User sees clean frame
   (no intermediate ghost state)
```

### Clearing the Ghost

The key insight is that the ghost appears at a **predictable location** - it's the floating window shifted up by however many lines scrolled:

```
Before scroll:                After scroll + clear + redraw:
┌──────────────────────┐      ┌──────────────────────┐
│ line 1               │      │ line 2               │
│ line 2               │      │ [cleared area]       │
│ ╭─── Window ───╮     │      │ [cleared area]       │
│ │ content      │     │      │ ╭─── Window ───╮     │
│ ╰──────────────╯     │      │ │ content      │     │
│ line 5               │      │ ╰──────────────╯     │
│                      │      │ line 6 (new)         │
└──────────────────────┘      └──────────────────────┘
```

### Pros
- Colors and terminal features preserved (pass-through)
- No buffer rendering complexity needed
- Main window stays "live" during floating window

### Cons
- Requires terminal support for synchronized updates (DEC mode 2026)
- More complex redraw logic (must clear ghost area)
- Potential flicker on terminals without sync support
- Must track/estimate scroll amount to know where ghost is
- **Scrollback pollution** (see below)

### Critical Issue: Scrollback Pollution

While Solution 3 preserves scrollback, the scrollback becomes **polluted with floating window artifacts**. Each time we clear and redraw the floating window, those pixels become part of the permanent scrollback history:

```
What user sees when scrolling up in host terminal:
┌────────────────────────────────────┐
│ line 1                             │
│ line 2                             │
│ ╭──── Floating Window ────╮        │  ← baked into history
│ │ Hello                   │        │
│ ╰─────────────────────────╯        │
│ line 5                             │
│ line 6                             │
│ ╭──── Floating Window ────╮        │  ← another snapshot
│ │ Hello                   │        │
│ ╰─────────────────────────╯        │
│ line 9                             │
│ line 10                            │
│ ╭──── Floating Window ────╮        │  ← yet another
│ │ Hello                   │        │
│ ...                                │
└────────────────────────────────────┘
```

The floating window becomes **permanently baked into the scrollback record** at every position it was rendered during output. This is arguably worse than having no scrollback at all.

### Terminal Support for Synchronized Updates

| Terminal | Supported |
|----------|-----------|
| iTerm2 | Yes |
| Kitty | Yes |
| Ghostty | Yes |
| WezTerm | Yes |
| Terminal.app | No |
| Windows Terminal | Partial |

---

## Solution Comparison Matrix

| Aspect | Solution 1 | Solution 2 | Solution 3 |
|--------|------------|------------|------------|
| **Ghost windows** | None | None | None |
| **Host scrollback** | Frozen | Frozen | Polluted with artifacts |
| **Colors preserved** | Must render | Must render | Native |
| **Terminal features** | Must emulate | Must emulate | Native |
| **Crash recovery** | Good | Poor | Good |
| **Implementation** | Medium | Simple | Medium |
| **Terminal support** | Universal | Universal | Needs sync update |
| **Performance** | Full redraw | Full redraw | Incremental |
| **Clean history** | Yes (frozen) | Yes (frozen) | No (artifacts) |

---

## Recommendation

### If simplicity is important: **Solution 2**

Full re-render without mode switching is the simplest to implement. Same code path for all cases. Scrollback is frozen while floating window is open, but remains clean.

### If crash safety is important: **Solution 1**

Alternate screen provides automatic recovery if the process crashes - the terminal will restore the primary screen. Good for production stability. Scrollback frozen but clean.

### Avoid Solution 3 for most use cases

While Solution 3 keeps the main window "live", the scrollback pollution makes it unsuitable for most use cases. Users scrolling up will see repeated floating window snapshots baked into history, which is arguably worse than frozen scrollback.

---

## The Fundamental Tradeoff

There is no perfect solution. The core issue is that we're trying to overlay content on a terminal that wasn't designed for overlays:

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   Option A: Take control (Solutions 1 & 2)                  │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ • We render everything from our buffer              │   │
│   │ • Clean display, no artifacts                       │   │
│   │ • But: scrollback frozen, must handle colors        │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                             │
│   Option B: Share control (Solution 3)                      │
│   ┌─────────────────────────────────────────────────────┐   │
│   │ • Terminal handles main content natively            │   │
│   │ • We overlay floating window                        │   │
│   │ • But: artifacts pollute scrollback                 │   │
│   └─────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Solutions 1 and 2 are recommended** because clean frozen scrollback is better than polluted live scrollback.

---

## Implementation Requirements

All solutions require rendering from the ghostty-vt buffer with proper styling:

### Cell Rendering with Colors

```zig
fn renderCell(writer: anytype, cell: Cell) !void {
    const style = cell.style();

    // Set foreground color
    if (style.fg) |fg| {
        try writer.print("\x1b[38;2;{};{};{}m", .{fg.r, fg.g, fg.b});
    }

    // Set background color
    if (style.bg) |bg| {
        try writer.print("\x1b[48;2;{};{};{}m", .{bg.r, bg.g, bg.b});
    }

    // Set attributes (bold, italic, etc.)
    if (style.bold) try writer.writeAll("\x1b[1m");
    if (style.italic) try writer.writeAll("\x1b[3m");
    if (style.underline) try writer.writeAll("\x1b[4m");

    // Write character
    const cp = cell.codepoint();
    if (cp == 0) {
        try writer.writeByte(' ');
    } else {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch 1;
        try writer.writeAll(buf[0..len]);
    }

    // Reset attributes
    try writer.writeAll("\x1b[0m");
}
```

### Synchronized Update Wrapper (Solution 3)

```zig
fn withSyncUpdate(writer: anytype, render_fn: anytype) !void {
    // Begin synchronized update
    try writer.writeAll("\x1b[?2026h");

    // Perform rendering
    try render_fn(writer);

    // End synchronized update
    try writer.writeAll("\x1b[?2026l");
}
```
