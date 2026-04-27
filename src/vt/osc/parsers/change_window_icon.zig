// Vendored from ghostty-org/ghostty
//   upstream: src/terminal/osc/parsers/change_window_icon.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   import paths remapped: ../quirks.zig -> quirks.zig, ../lib/ -> lib/, ../tripwire.zig -> tripwire.zig, ../fastmem.zig -> fastmem.zig

const std = @import("std");
const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

/// Parse OSC 1
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    const cap = if (parser.capture) |*c| c else {
        parser.state = .invalid;
        return null;
    };
    cap.writer.writeByte(0) catch {
        parser.state = .invalid;
        return null;
    };
    const data = cap.trailing();
    parser.command = .{
        .change_window_icon = data[0 .. data.len - 1 :0],
    };
    return &parser.command;
}

test "OSC 1: change_window_icon" {
    const testing = std.testing;

    var p: Parser = .init(null);
    p.next('1');
    p.next(';');
    p.next('a');
    p.next('b');
    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .change_window_icon);
    try testing.expectEqualStrings("ab", cmd.change_window_icon);
}
