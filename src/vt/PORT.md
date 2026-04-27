# Zig 0.15.2 -> 0.16.0 port lessons (tzig vendoring of ghostty-vt)

A running list of patterns we've discovered while porting vendored ghostty
files. Update this file as new lessons are learned. Subagents doing
porting work should read this **and** ~/Projects/nom/ZigIO.md before
starting.

## Working build target

Only `zig build test-vt` works during the port. The exe target is broken
(src/main.zig still references old `ghostty-vt` types we haven't ported)
and that's expected — don't try to fix it as a side task.

## Project conventions

- Mirror upstream paths under `src/vt/`. Upstream `src/terminal/Foo.zig` ->
  `src/vt/Foo.zig`. Upstream `src/lib/foo.zig` -> `src/vt/lib/foo.zig`
  (note: `src/vt/lib.zig` is the terminal-package shim, sibling to the
  `src/vt/lib/` package).
- Provenance header on **every** vendored file:
  ```zig
  // Vendored from ghostty-org/ghostty
  //   upstream: src/terminal/Parser.zig
  //   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
  //   pruned:   <one-line summary if anything was removed; omit if verbatim>
  ```
- Modification categories for commit messages: `0.16-api`, `prune`, `tzig`.
- Keep upstream `test {}` blocks. They are the correctness signal.
- terminal_options is wired in build.zig (not a vendored module). Flags:
  c_abi=false, oniguruma=false, simd=false, slow_runtime_safety=false,
  kitty_graphics=false, tmux_control_mode=false.

## Pruning rules of thumb

- Anything gated by `build_options.kitty_graphics` -> can stay; the comptime
  branch evaluates to false for tzig and the unreachable arms are dead code.
  Don't strip these — leaves diffs against upstream tiny.
- Anything that imports `ghostty.h` (C ABI codegen) -> strip. tzig is
  zig-target only.
- Anything that imports `font/*` -> strip. tzig has no font shaping.
- Selection, search, tmux, formatter, highlight, StringMap, ScreenSet,
  semantic prompts, kitty keyboard stack -> already excluded; if the file
  you're porting references them, prune the references.

## ZigIO.md errata (DON'T BLINDLY TRUST THE REFERENCE)

The `~/Projects/nom/ZigIO.md` doc was written before the final 0.16 release
and has at least one wrong example. **Verify against actual stdlib** when
in doubt:

- ZigIO.md says `std.fs.File.stdout()` — **wrong in actual 0.16**. The
  correct call is `std.Io.File.stdout()`. `std.fs.File` is gone; almost
  all of `std.fs` is now deprecated re-exports of `std.Io.Dir` /
  `std.Io.File`. Same for `std.fs.File.stderr()` / `stdin()`.
- General rule: if a `std.fs.X` symbol is referenced and Zig says it
  doesn't exist, look for `std.Io.X` instead.

## Zig 0.16 API changes encountered (PRIMARY REFERENCE: ~/Projects/nom/ZigIO.md, but see errata above)

### `@Type` builtin split into `@Enum` / `@Struct` / `@Union` / `@Int` / etc.

Zig 0.16 removed `@Type(...)` and replaced it with separate builtins, one
per kind. The signatures also changed: instead of passing a single
`std.builtin.Type.X` payload (with field records that bundled name + type
+ attrs together), each builtin takes parallel slices — names separately
from types, attrs in their own struct types.

Authoritative reference: ZIR codegen at
`/opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/zig/AstGen.zig` around lines
9290-9421 (search for `.reify_int`/`.reify_struct`/etc.).

Type-info structs (with their new attribute helpers) live in
`/opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/builtin.zig` ~lines 656-770:
`StructField.Attributes`, `UnionField.Attributes`, `Fn.Attributes`,
`Enum.Mode` (`.exhaustive` / `.nonexhaustive`).

#### `@Enum(tag_type, mode, field_names, field_values)`

```zig
// 0.15
const T = @Type(.{ .@"enum" = .{
    .tag_type = TagType,
    .fields = &[_]std.builtin.Type.EnumField{ .{ .name = "a", .value = 0 }, ... },
    .decls = &.{},
    .is_exhaustive = true,
}});

// 0.16
const T = @Enum(TagType, .exhaustive, &field_names, &field_values);
```

- `field_names`: `[]const []const u8` (NOT `[:0]const u8` per element).
- `field_values`: `[]const TagType` — element type is the **tag type
  itself**, not `comptime_int`. This is a real constraint: if you pick
  the tag type based on field count (e.g. `IntFittingRange(0, n-1)`),
  you must compute `n` first, then build the values array typed as that
  tag. See `src/vt/lib/enum.zig` for the two-pass pattern.
- mode is `.exhaustive` or `.nonexhaustive` (was `is_exhaustive: bool`).
- `decls` is gone from the API; you can't add decls via reify anymore.

Stdlib examples: `std/meta.zig` `FieldEnum`/`DeclEnum`,
`std/testing/Smith.zig`.

#### `@Struct(layout, backing_ty, field_names, field_types, field_attrs)`

```zig
// 0.15
@Type(.{ .@"struct" = .{
    .layout = .@"extern",
    .fields = &fields, // []StructField with name+type+default+is_comptime+alignment
    .decls = &.{},
    .is_tuple = false,
}});

// 0.16
@Struct(.@"extern", null, &field_names, &field_types, &field_attrs);
```

- `layout`: `std.builtin.Type.ContainerLayout` (`.auto` / `.@"extern"` /
  `.@"packed"`).
- `backing_ty`: `?type` — only meaningful for `.@"packed"`; pass `null`
  otherwise.
- `field_attrs`: `[]const std.builtin.Type.StructField.Attributes` where
  `Attributes = struct { @"comptime": bool = false, @"align": ?usize =
  null, default_value_ptr: ?*const anyopaque = null }`.
- `is_tuple` is **gone** from the reify API. (Tuples are still a thing,
  just not constructible via `@Struct`.)
- **Gotcha:** `std.builtin.Type.StructField.alignment` changed from
  `usize` (0 == unset) in 0.15 to `?usize` (null == unset) in 0.16. Old
  code doing `if (field.alignment > 0) ... else @alignOf(...)` must be
  rewritten as `field.alignment orelse @alignOf(...)`.

Stdlib examples: `std/multi_array_list.zig`, `std/enums.zig`,
`std/meta/trailer_flags.zig`.

**Packed struct via `@Struct(.@"packed", null, ...)`**: works fine even
without an explicit `backing_ty`. Pass `null` for `backing_ty` and Zig
will compute the natural backing integer from the field types. Field
attrs use `@"align" = null` (the old "alignment = 0" idiom became
"align = null"). `default_value_ptr` still accepts a pointer to a
comptime-known value of the field type. See `src/vt/modes.zig`'s
`ModePacked` for an example with `bool` fields and per-field defaults.

#### `@Union(layout, tag_type, field_names, field_types, field_attrs)`

```zig
// 0.15
@Type(.{ .@"union" = .{
    .layout = .@"extern",
    .tag_type = null,
    .fields = &union_fields, // []UnionField with name+type+alignment
    .decls = &.{},
}});

// 0.16
@Union(.@"extern", null, &field_names, &field_types, &field_attrs);
```

- `field_attrs`: `[]const std.builtin.Type.UnionField.Attributes` where
  `Attributes = struct { @"align": ?usize = null }`.
- `decls` gone. `tag_type` still nullable (untagged union when null).

Stdlib examples: `std/multi_array_list.zig`, `std/Io.zig`,
`std/os/windows.zig`.

#### Other reify builtins (not used yet but listed for completeness)

- `@Int(signedness, bit_count)` — replaces `@Type(.{ .int = ... })`.
- `@Pointer(size, attrs, child, sentinel)` — 4 args.
- `@Fn(param_types, param_attrs, return_type, fn_attrs)` — 4 args.
- `@Tuple(field_types)` — single arg.
- `@EnumLiteral` — zero-arg, gives the enum-literal type itself.

Affected files in our tree (all ported, tests pass as of this note):
- src/vt/lib/enum.zig
- src/vt/lib/struct.zig
- src/vt/lib/union.zig

### File I/O, Reader/Writer, std.Io

See ~/Projects/nom/ZigIO.md sections 3-6. Most of our vendored code is
parser/page/screen logic that doesn't touch file I/O directly — main hits
will be in test code that does `std.testing.allocator` or anything using
the old `fs.File.read*`/`write*` APIs. Replace per the reference.

### `EnvMap` removed

`std.process.EnvMap` is gone. Upstream's Config.zig uses it; tzig doesn't
import Config so this likely won't bite us, but flag if encountered.

### `std.meta.intToEnum` removed -> `std.enums.fromInt`

```zig
// 0.15
const e = std.meta.intToEnum(E, i) catch return error.X;

// 0.16
const e = std.enums.fromInt(E, i) orelse return error.X;
```

`std.enums.fromInt(E, i)` returns `?E` — `orelse` swaps in for the old
`catch` chain. The function lives in `std/enums.zig`. Used in:
- `src/vt/color.zig` `Dynamic.next` — pattern is `orelse null` since
  the function already returns optional.
- `src/vt/osc/parsers/color.zig` — multiple call sites converted from
  `catch return result` / `catch continue` to `orelse return result` /
  `orelse continue` (the chained `std.math.cast(...) orelse ...` stays
  unchanged inside the parens).

### `std.Thread.Mutex` / `std.Thread.Condition` -> `std.Io.Mutex` / `std.Io.Condition`

Per ZigIO.md section 14, sync primitives moved under `std.Io` and now
require an `Io` instance to lock/unlock (e.g. `m.lock(io)` returns a
`Cancelable!void`). There is no zero-arg blocking lock anymore — the
old "default-init a Mutex anywhere" idiom is gone.

Workaround used in `src/vt/datastruct/blocking_queue.zig`: the only
upstream caller of BlockingQueue is `src/vt/search/Thread.zig`, which
tzig hard-sets to `void` for the `.lib` artifact (see `search.zig`).
The blocking-queue tests only exercise non-blocking paths from a
single thread, so we provide a private `Mutex` and `Condition` stub
(empty `lock`/`unlock`/`signal`, `timedWait` returns `error.Timeout`).
This unblocks the test without pulling in `std.Io` plumbing for dead
code. If we ever wire blocking-queue into a real threaded path, we
need to rewrite this to take an `Io` instance and call `std.Io.Mutex`.

### `std.SegmentedList` removed

Per ZigIO.md section 16, `SegmentedList` is gone in 0.16. Replacement
strategy depends on whether stable element pointers are required:

- **Pointers don't need to be stable**: drop in `std.ArrayList(T)`. Note
  in 0.16 `std.ArrayList(T)` *is* the unmanaged form — methods take an
  allocator (`list.append(alloc, item)`, `list.deinit(alloc)`), and
  there's a decl literal `.empty` for zero-init. Default-initializer
  `.{}` does NOT work because `items: []T` has no default.

  Used in `src/vt/osc/parsers/color.zig` for `pub const List`. The
  parser-side `addOne(alloc)` / `deinit(alloc)` call sites carry over
  with no API changes; the consumer side (Parser.zig, stream.zig,
  stream_terminal.zig, osc.zig) still uses the SegmentedList iterator
  API (`.count()`, `.constIterator(0)`) and will need follow-up edits.

- **Pointers must be stable** (e.g. SegmentedPool's libuv write
  requests): keep an inline `[prealloc]T` buffer for the prealloc
  region, plus an `ArrayList(*T)` of separately heap-allocated extras
  for growth. See `src/vt/datastruct/segmented_pool.zig` for the
  pattern. Don't substitute `ArrayList(T)` directly — its `addOne`
  pointer is invalidated on grow.

### Vector indexing requires comptime index

In 0.16, `vec[i]` on a `@Vector` type only compiles when `i` is
comptime-known. Old runtime `while (i < info.len) : (i += 1) vec[i]`
loops break with "vector index not comptime known". Fix: use
`inline for (0..info.len) |i|`. The vector length is comptime, so
this unrolls cleanly.

Used in `src/vt/datastruct/comparison.zig` `expectApproxEqualInner`.

### `std.testing.refAllDeclsRecursive` removed

Replaced with non-recursive `std.testing.refAllDecls(@This())`. Used
inside test blocks to keep all decls referenced for testing. Losing
the recursive variant is fine — most of our files import their child
modules via test blocks of their own, so the transitive coverage still
happens.

Used in `src/vt/mouse.zig`.

### Packed unions: all variants must share bit width

In 0.16 a `packed union { ... }` requires every field to have the
same bit width (it doesn't auto-pad to the widest). 0.15 was lax.

In `src/vt/page.zig` Cell content union the variants were:
- `codepoint: u21` (Unicode codepoint)
- `color_palette: u8` (256-color palette index)
- `color_rgb: RGB` (packed struct of u8/u8/u8 = 24 bits)

Fix: widen `codepoint` and `color_palette` to `u24`. Cells are always
zero-initialized via `@bitCast(@as(u64, 0))` before any variant is
written, so the upper bits stay 0; the union still occupies exactly
24 bits inside the u64 packed Cell layout. Readers that expected u21
need an explicit `@intCast` (e.g. `Cell.codepoint()` accessor). Other
constructors that wrote `'A'`, `0xFFFD`, `@intCast(x)` etc. all coerce
fine to u24 with no source change.

### `std.heap.MemoryPool` API change

In Zig 0.16 `std.heap.MemoryPool(T)` (and `MemoryPoolAligned`) is the
*unmanaged* pool. The deprecated managed variants live under
`std.heap.MemoryPoolManaged` / similar.

Old (0.15) → New (0.16):

| 0.15                                  | 0.16                                            |
| ------------------------------------- | ----------------------------------------------- |
| `Pool.initPreheated(alloc, n)`        | `Pool.initCapacity(alloc, n)` (returns Pool)    |
| `pool.create()`                       | `pool.create(alloc)`                            |
| `pool.destroy(ptr)`                   | `pool.destroy(ptr)` (unchanged)                 |
| `pool.deinit()`                       | `pool.deinit(alloc)`                            |
| `pool.reset(mode)`                    | `pool.reset(alloc, mode)`                       |
| `pool.arena` / `pool.arena.child_allocator` | gone — store the allocator yourself     |

`pool.arena_state` is the new field (`std.heap.ArenaAllocator.State`),
but it's an opaque-ish state struct; you can't read `child_allocator`
through it. So if your wrapper struct uses both pools and needs the
backing allocator(s), store them as fields on your wrapper.

PageList.zig followed this pattern: the `MemoryPool` wrapper struct
gained a `page_alloc: Allocator` field alongside the existing `alloc`,
and all `pool.pages.arena.child_allocator` accesses became
`pool.page_alloc`.

#### ArenaAllocator internal Node layout changed

`ArenaAllocator.State` no longer has `buffer_list`. It exposes
`used_list: ?*Node` and `free_list: ?*Node`. The `Node` is private,
but its layout is `{ size: Size (usize-sized packed struct), end_index:
usize, next: ?*Node }`, with the buffer being `[*]u8 ptr-cast of node`
for `size.toInt()` bytes minus `@sizeOf(Node)` header.

PageList.zig's reset() block that walks the arena to zero out retained
buffers was hand-mirroring private Node layout; the 0.16 port mirrors
the new layout via a private `extern struct ArenaNode { size, end_index,
next }` and walks both `used_list` and `free_list` through `arena_state`.

### `posix.PROT.READ` is now a packed struct field

In Zig 0.16, `std.posix.PROT` (across linux/darwin/bsd) became a
`packed struct(u32) { READ: bool, WRITE: bool, EXEC: bool, ... }`, so
the old `PROT.READ | PROT.WRITE` integer-OR no longer compiles. Use
struct literal:

```zig
// 0.15
posix.PROT.READ | posix.PROT.WRITE
// 0.16
.{ .READ = true, .WRITE = true }
```

On macOS the type is `std.macho.vm_prot_t`, which has the same shape
plus a `COPY` field. Used in `src/vt/page.zig` `AllocPosix.alloc`.

### `std.io.fixedBufferStream` removed

In 0.16 `std.io` is gone. `std.io.fixedBufferStream(buf).writer()` →
`std.Io.Writer.fixed(buf)` (returns `std.Io.Writer` *value*; take its
address with `&` to pass to API expecting `*std.Io.Writer`). To get the
written slice afterwards: instead of `stream.getWritten()`, use
`buf[0..stream.end]` (the writer's `end` field is the bytes-written
cursor).

```zig
// 0.15
var stream = std.io.fixedBufferStream(buf);
const w = stream.writer();
try w.writeByte('x');
return stream.getWritten();

// 0.16
var stream = std.Io.Writer.fixed(buf);
const w = &stream;
try w.writeByte('x');
return buf[0..stream.end];
```

Used in `src/vt/Terminal.zig` printAttributes and `src/vt/formatter.zig`
HTML/VT header generation.

### `std.ArrayList` consumer-side cleanup (post-SegmentedList port)

After the previous round swapped `std.SegmentedList(T, N)` for
`std.ArrayList(T)`, consumer code still using SegmentedList API needed:

| SegmentedList call            | ArrayList equivalent                |
| ----------------------------- | ----------------------------------- |
| `.count()`                    | `.items.len`                        |
| `.at(i)` (returns `*T`)       | `&list.items[i]`                    |
| `.at(i).*`                    | `list.items[i]`                     |
| `.constIterator(0)` + `.next()` (returns `*const T`) | `for (list.items) \|item\|` (item is `T`, not pointer) |
| `.{}` zero-init               | `.empty` (decl literal — slice has no default) |

When converting iterators that previously yielded `*T`, callers reading
`req.*` should drop the `.*`. See `src/vt/Parser.zig` test fixups,
`src/vt/stream_terminal.zig` `colorOperation`, and
`src/vt/osc/parsers/color.zig`.

### Cell content packed-union widening fallout

Previously the `page.zig` Cell content packed union was widened from
`u21`/`u8` variants to `u24`/`u24` to satisfy the 0.16 packed-union
"all variants same width" rule. Readers that expected the original
narrower types now need explicit `@intCast`:

- `src/vt/Terminal.zig:387` (`u24 -> u21` for codepoint)
- `src/vt/render.zig:553` (`u24 -> u8` for palette index)
- `src/vt/formatter.zig:1383` (`u24 -> u21`)
- `src/vt/formatter.zig:1483` (`u24 -> u8`)

### Comptime-asserted struct sizes break across SegmentedList -> ArrayList

`src/vt/osc.zig`'s `Command` had `comptime { assert(@sizeOf(Command) ==
... 64 ...); }` that documented an intentional size budget. After
swapping `SegmentedList(Request, 2)` (inline-storage) for
`ArrayList(Request)` (slice + capacity = 24 bytes regardless of count),
the size grows. The assertion was removed with a comment explaining
why; if a tighter budget matters in the future, re-measure after the
port settles.

### Tests that depend on `slow_runtime_safety = true`

`Terminal.zig`'s `"Terminal: fullReset tracked pins"` calls
`PageList.pinIsValid` which has `comptime assert(slow_runtime_safety)`.
With `slow_runtime_safety = false` (tzig's default) the test fails to
compile. Gated the test body with
`if (comptime !build_options.slow_runtime_safety) return error.SkipZigTest;`
so it skips at runtime when the flag is off.

### build.zig blocker (NOT FIXED — outside the file allowlist)

`Run.captureStdOut` in 0.16 takes a `CapturedStdIo.Options` argument.
`build.zig:96-97` calls it zero-arg. Until that's fixed (e.g.
`captureStdOut(.{})`), `zig build test-vt` fails before reaching the
vt module. Direct compilation via
`zig test --dep terminal_options --dep unicode_tables -Mroot=src/vt/main.zig ...`
works (after providing stub modules) and reports only `uucode`
not-found errors at the leaf imports.

## uucode v0.2.0 -> 2826a37 (jacobsandlund/main) API changes

The vendored ghostty's `src/build/uucode_config.zig` (verbatim copy at
`vendor/ghostty/src/build/uucode_config.zig`, our adapted copy at
`src/build/uucode_config.zig`) was written for uucode 0.2.0. The
build.zig.zon now pins the upstream main branch which has sweeping
restructuring. Mapping for porters:

| 0.2.0 (old)                         | 2826a37 (new)                               |
| ----------------------------------- | ------------------------------------------- |
| `@import("config.x.zig")`           | gone — no `src/x/` subdir anymore           |
| `config.default`                    | gone — built-in fields are at module scope  |
| `config.Extension { inputs, compute, fields }` | `config.Component { Impl, inputs, fields }` where `Impl` is a struct with a `pub fn build(...)` method |
| `config_x.wcwidth`                  | built into `config.fields` (`wcwidth_standalone` / `wcwidth_zero_in_grapheme`) and produced by `config.build_components` (the `Wcwidth` component) |
| `config_x.grapheme_break_no_control`| built into `config.fields` and produced by `GraphemeBreakNoControlComponent` |
| `default.field("foo")`              | just the field-name string `"foo"`          |
| `Table { name, extensions, fields: []Field }` | `Table { name, fields: []const [:0]const u8 }` — fields are name-strings only |

The build_config module must export FOUR pub decls (was just `tables`):
```zig
pub const fields = &config.mergeFields(config.fields, &.{ /* extension Field defs */ });
pub const build_components = &config.mergeComponents(config.build_components, &.{ /* Component defs with Impl */ });
pub const get_components = config.get_components;
pub const tables: []const config.Table = &.{ ... };
```

### Component `build` method signature

Replaces the old `compute` callback. Lives on a struct passed as `Impl`:
```zig
const Foo = struct {
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
        for (0..config.num_code_points) |i| {
            const input = inputs.get(i);
            var row: Row = undefined;
            config.setBuiltField(&row, "my_field", computeIt(input));
            rows.append(row);
        }
    }
};
```

Use `inputs.get(i)` (returns a row struct with named fields matching the
declared `inputs`) and `rows.append(row)` to populate. Some examples in
`zig-pkg/uucode-*/src/test/build_config.zig` use the `rows.items(.field)`
slice form instead — both work; `append` is simpler when only one
component-output field needs to be set.

### Width computation preserved exactly

Tzig's adapted `src/build/uucode_config.zig` keeps the original ghostty
width logic verbatim — `grapheme_break_no_control` is still a built-in
in the new uucode (file `src/components.zig`, `GraphemeBreakNoControlComponent`),
so no compromise was needed.

### `uucode.x.*` namespace removed in 2826a37

The old `uucode.x.types.*` and `uucode.x.grapheme.*` paths are gone in
the new uucode. Everything is now flat:

| 0.2.0 (old)                                        | 2826a37 (new)                                |
| -------------------------------------------------- | -------------------------------------------- |
| `uucode.x.types.GraphemeBreakNoControl`            | `uucode.types.GraphemeBreakNoControl`        |
| `uucode.x.grapheme.computeGraphemeBreakNoControl`  | `uucode.grapheme.computeGraphemeBreakNoControl` |

`src/vt/unicode/root.zig` exports `pub const types = @import("types.zig");`
and `pub const grapheme = @import("grapheme.zig");` directly.

Affected files: `src/vt/unicode/props.zig`, `src/vt/unicode/grapheme.zig`.

### `pub fn main` signature change for build-time generators

In Zig 0.16, build-time generator binaries (e.g.
`src/vt/unicode/props_uucode.zig`, `symbols_uucode.zig`) that need
stdio require an `Io` instance to call `.writer()` on a `File`. The
old `std.fs.File.stdout().writer(buf)` is now a 2-arg call:
`std.Io.File.stdout().writer(io, buf)`.

To get an `Io`, change the entry point from `pub fn main() !void` to
`pub fn main(init: std.process.Init) !void` and grab `init.io`. This
is the canonical 0.16 entry-point shape for binaries that need stdio,
allocators, or environment access — see
`/opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/crypto/benchmark.zig:499`
and `std/process.zig` `Init` struct for the field list (`minimal`,
`arena`, `gpa`, `io`, `environ_map`, `preopens`).

Used in `src/vt/unicode/symbols_uucode.zig` and
`src/vt/unicode/props_uucode.zig`.

### Cell content u24 widening fallout — additional sites

Beyond `Terminal.zig:387`, `render.zig:553`, `formatter.zig:1383/1483`
already documented, several **more** sites surfaced once the build got
past the unicode generator step. All take `cell.content.codepoint` (now
u24) and pass it where u21 is expected — fix with `@intCast`:

- `src/vt/Screen.zig:2659, 2805, 2823` (three `&[_]u21{...}` literals
  inside `std.mem.indexOfAny` calls in `selectWord` and a sibling
  whitespace scan)
- `src/vt/Terminal.zig:410` (`unicode.table.get(prev.cell.content.codepoint)`)
- `src/vt/Terminal.zig:460` (`self.printCell(prev_cp, .wide)` — `prev_cp`
  was loaded earlier as the now-u24 codepoint)
- `src/vt/Terminal.zig:605` (`unicode.table.get(prev.content.codepoint)`)

Pattern is always `@intCast(...)` on the load site.

### `std.posix.*` removals — process & file primitives

Quite a few syscall wrappers were removed from `std.posix` in 0.16. Mapping:

| 0.15 (gone in 0.16)         | 0.16 replacement                                       |
| --------------------------- | ------------------------------------------------------ |
| `posix.open(path, ...)`     | `std.Io.Dir.openFileAbsolute(io, path, .{ .mode = .read_write })` (use `.read_only` etc as needed) |
| `posix.close(fd)`           | `std.Io.File{ .handle = fd, .flags = .{ .nonblocking = false } }.close(io)` for raw fds |
| `posix.write(fd, buf)`      | `std.Io.File{ .handle = fd, ... }.writeStreamingAll(io, buf)` |
| `posix.read`                | **still exists** in 0.16 (`std/posix.zig:400`); leave as-is |
| `posix.fork()`              | `std.c.fork()` (libc) — returns `c_int`, not error union |
| `posix.exit(code)`          | `std.c._exit(code)` (skip atexit handlers in forked child) |
| `posix.dup2(old, new)`      | `std.c.dup2(old, new)` — returns `c_int` |
| `posix.execvpeZ(...)`       | `std.c.execve(path_z, argv_z, envp_z)` — note: no `vp`/`vpe` variant in 0.16 stdlib; SHELL paths are virtually always absolute, so plain `execve` works |
| `posix.getenv("X")`         | `init.minimal.environ.getPosix("X")` (returns `?[:0]const u8`) or `std.c.getenv(name_z)` (returns `?[*:0]u8`) |
| `posix.STDIN_FILENO` etc.   | `std.Io.File.stdin().handle` (still present as constants too) |

#### `std.Io.File.OpenFlags` shape (renamed `OpenFileOptions`)

```zig
pub const OpenFileOptions = struct {
    mode: Mode = .read_only,                // .read_only / .write_only / .read_write
    allow_directory: bool = true,
    path_only: bool = false,
    lock: File.Lock = .none,
    lock_nonblocking: bool = false,
    /// Set this to allow the opened file to automatically become the
    /// controlling TTY for the current process.
    allow_ctty: bool = false,               // <-- equivalent of NOCTTY (default already gives O_NOCTTY)
    follow_symlinks: bool = true,
    resolve_beneath: bool = false,
    pub const Mode = enum { read_only, write_only, read_write };
};
```

For `/dev/ptmx` the right call is just
`std.Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{ .mode = .read_write })`.
Default `allow_ctty = false` corresponds to `O_NOCTTY`.

#### `std.Io.File` literal must include `flags`

`std.Io.File` now has two fields, `handle` and `flags: Flags{ nonblocking: bool }`.
`std.Io.File{ .handle = fd }` no longer compiles. Use:
```zig
const f: std.Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
```
The `stdin/stdout/stderr` helpers already do this for you.

#### Why `std.c.*` for fork/exec/_exit (no `Io` equivalent)

`fork`, `_exit`, `dup2`, `execve` are inherently process-level primitives that
don't fit the `Io` model: they bypass the I/O scheduler and have global side
effects on the process image. There's no `std.Io.process.fork` or similar in
0.16. After `fork()` in a child, only async-signal-safe libc calls are safe to
make before `execve`, so dropping to `std.c.*` is also the **correct** choice
on safety grounds — using `Io.File` methods (which may take locks or touch
allocators in a vtable) post-fork is unsound.

#### Stream handler `vt` callback signature

The stream `Handler.vt` callback must return `void`, not `!void`. Stream
internals call `handler.vt(action, value)` without `try`, so an error union
return is rejected with "error union is ignored".

The pattern in `stream_terminal.zig` (and the right pattern for downstream
handlers) is to wrap a fallible inner function:

```zig
pub fn vt(self: *Self, comptime action: Action.Tag, value: Action.Value(action)) void {
    self.vtFallible(action, value) catch |err| {
        std.log.warn("vt action={} err={}", .{ action, err });
    };
}

inline fn vtFallible(self: *Self, comptime action: Action.Tag, value: Action.Value(action)) !void {
    switch (action) {
        .print => try self.terminal.print(value.cp),
        // ...
    }
}
```

Used in `src/vt.zig` `VTHandler`.

#### Stream `nextSlice` returns `void`

`Stream.nextSlice` returns `void` in this branch of ghostty (errors are
swallowed and logged via the handler-warning path above). Don't put `try` in
front of it.

#### Action enum lost individual `prompt_*` tags

The vendored ghostty merged the per-prompt action tags (`prompt_start`,
`prompt_continuation`, `prompt_end`, `end_of_input`, `end_of_command`) into a
single `semantic_prompt` tag carrying an `osc.Command.SemanticPrompt`
sub-action. Handlers route via `.semantic_prompt => try
self.terminal.semanticPrompt(value)`. Several `Terminal` methods that used
to be `!void` (e.g. `restoreCursor`, `horizontalTab`, `horizontalTabBack`,
`scrollViewport`) are now `void` — drop the `try`.

### `osc.zig` Command.color_operation requires explicit deinit

Once `color.List` (the inner `requests` field) became
`std.ArrayList(Request)` (was `SegmentedList(Request, 2)` with inline
storage and no allocations for small N), the OSC parser's `reset()`
must call `requests.deinit(alloc)`. The old code lumped
`.color_operation` into the no-op cleanup arm because SegmentedList
needed nothing freed.

Fix in `src/vt/osc.zig` `Parser.reset()`:

```zig
.color_operation => |*v| color_operation: {
    v.requests.deinit(self.alloc orelse break :color_operation);
},
```

This eliminates the leak across ~20 tests in `formatter.zig`,
`stream_terminal.zig`, `Parser.zig`, `render.zig`, and `osc/parsers/color.zig`.

If a test creates a Parser without an allocator and an OSC parse
unexpectedly populates `requests`, the leak still surfaces — but the
parser refuses to allocate without an allocator (`ensureAllocator`
short-circuits to `.invalid`), so this should never happen in practice.
