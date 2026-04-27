// Vendored from ghostty-org/ghostty
//   upstream: src/terminal/osc/parsers/mouse_shape.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   import paths remapped: ../quirks.zig -> quirks.zig, ../lib/ -> lib/, ../tripwire.zig -> tripwire.zig, ../fastmem.zig -> fastmem.zig

const std = @import("std");

const assert = @import("../../quirks.zig").inlineAssert;

const Parser = @import("../../osc.zig").Parser;
const Command = @import("../../osc.zig").Command;

// Parse OSC 22
pub fn parse(parser: *Parser, _: ?u8) ?*Command {
    assert(parser.state == .@"22");
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
        .mouse_shape = .{
            .value = data[0 .. data.len - 1 :0],
        },
    };
    return &parser.command;
}

test "OSC 22: pointer cursor" {
    const testing = std.testing;

    var p: Parser = .init(null);

    const input = "22;pointer";
    for (input) |ch| p.next(ch);

    const cmd = p.end(null).?.*;
    try testing.expect(cmd == .mouse_shape);
    try testing.expectEqualStrings("pointer", cmd.mouse_shape.value);
}
