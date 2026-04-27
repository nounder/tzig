// Vendored from ghostty-org/ghostty
//   upstream: src/build/uucode_config.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   rewritten for uucode 2826a37 API. The original config used
//             config.default / config.Extension / config_x.wcwidth /
//             config_x.grapheme_break_no_control. Those are gone — uucode
//             now has built-in fields (wcwidth_standalone,
//             wcwidth_zero_in_grapheme, grapheme_break_no_control,
//             is_emoji_modifier, etc.) and the build_config exposes
//             `fields`, `build_components`, `get_components`, and `tables`
//             at module scope. Width and is_symbol are added here as new
//             extension fields with a build component each.

const std = @import("std");
const config = @import("config.zig");

pub const fields = &config.mergeFields(config.fields, &.{
    .{ .name = "width", .type = u2 },
    .{ .name = "is_symbol", .type = bool },
});

pub const build_components = &config.mergeComponents(config.build_components, &.{
    .{
        .Impl = WidthComponent,
        .inputs = &.{
            "wcwidth_standalone",
            "wcwidth_zero_in_grapheme",
            "is_emoji_modifier",
            "grapheme_break_no_control",
        },
        .fields = &.{"width"},
    },
    .{
        .Impl = IsSymbolComponent,
        .inputs = &.{ "block", "general_category" },
        .fields = &.{"is_symbol"},
    },
});

pub const get_components = config.get_components;

// Two tables matching the original ghostty layout: a "runtime" table for
// data we read at runtime (case folding, emoji presentation), and a
// "buildtime" table that holds the precomputed width and friends.
pub const tables: []const config.Table = &.{
    .{
        .name = "runtime",
        .fields = &.{
            "is_emoji_presentation",
            "case_folding_full",
        },
    },
    .{
        .name = "buildtime",
        .fields = &.{
            "width",
            "wcwidth_zero_in_grapheme",
            "grapheme_break_no_control",
            "is_symbol",
            "is_emoji_vs_base",
        },
    },
};

const setBuiltField = config.setBuiltField;

// Width computation matches the original ghostty logic exactly:
//
// This condition is needed as Ghostty currently has a singular concept for
// the `width` of a code point, while `uucode` splits the concept into
// `wcwidth_standalone` and `wcwidth_zero_in_grapheme`. The two cases where
// we want to use the `wcwidth_standalone` despite the code point occupying
// zero width in a grapheme (`wcwidth_zero_in_grapheme`) are emoji
// modifiers and prepend code points. For emoji modifiers we want to
// support displaying them in isolation as color patches, and if prepend
// characters were to be width 0 they would disappear from the output with
// Ghostty's current width 0 handling.
const WidthComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = allocator;
        _ = io;
        _ = backing;
        _ = tracking;

        for (0..config.num_code_points) |i| {
            const input = inputs.get(i);
            var row: Row = undefined;
            const w: u2 = if (input.wcwidth_zero_in_grapheme and
                !input.is_emoji_modifier and
                input.grapheme_break_no_control != .prepend)
                0
            else
                @min(2, input.wcwidth_standalone);
            setBuiltField(&row, "width", w);
            rows.append(row);
        }
    }
};

// is_symbol mirrors the original ghostty config: code points that should
// be treated as symbol-like for layout/shaping purposes.
const IsSymbolComponent = struct {
    pub fn build(
        comptime InputRow: type,
        comptime Row: type,
        allocator: std.mem.Allocator,
        io: std.Io,
        inputs: config.MultiSlice(InputRow),
        rows: *config.MultiSlice(Row),
        backing: anytype,
        tracking: anytype,
    ) !void {
        _ = allocator;
        _ = io;
        _ = backing;
        _ = tracking;

        for (0..config.num_code_points) |i| {
            const input = inputs.get(i);
            var row: Row = undefined;
            const block = input.block;
            const is_symbol = input.general_category == .other_private_use or
                block == .arrows or
                block == .dingbats or
                block == .emoticons or
                block == .miscellaneous_symbols or
                block == .enclosed_alphanumerics or
                block == .enclosed_alphanumeric_supplement or
                block == .miscellaneous_symbols_and_pictographs or
                block == .transport_and_map_symbols;
            setBuiltField(&row, "is_symbol", is_symbol);
            rows.append(row);
        }
    }
};
