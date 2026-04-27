# Vendored ghostty-vt

This directory is a pruned, in-tree copy of [ghostty](https://github.com/ghostty-org/ghostty)'s
`src/terminal/` (and selected supporting files), ported to Zig 0.16. We own
this code now. Upstream is referenced for diffs, bug fixes, and feature
backports — not as a build dependency.

## Pinned upstream commit

    c74f6d56d1feef473033057bc0ff7e3f00cf6421

## Local upstream checkout (reference-only)

See `vendor/ghostty/` 

- `build.zig` does not invoke `b.dependency("ghostty", ...)` anywhere.
- `build.zig.zon` does not list ghostty in `dependencies`.
- The submodule's own `build.zig` no longer parses under Zig 0.16, which
  is exactly why we vendored. Don't try to "fix" it — we don't want it
  in our build graph.

To diff a single file against upstream at the pinned commit:

```sh
( cd vendor/ghostty && git checkout c74f6d56 -- . )
diff -u vendor/ghostty/src/terminal/Parser.zig src/vt/Parser.zig
```

To pull a newer upstream and re-pin:

```sh
( cd vendor/ghostty && git fetch && git checkout <new-commit> )
git log c74f6d56..<new-commit> -- src/terminal/ src/lib/ src/datastruct/ src/unicode/ src/simd/ src/os/
# Then update this file's commit hash and replay relevant changes into src/vt/.
```

If you want the submodule off-disk: `git submodule deinit vendor/ghostty`
(reversible). Don't `git rm` it without updating this file.

## Layout

We mirror upstream's `src/terminal/` layout exactly under `src/vt/`. So
upstream `src/terminal/Parser.zig` lives here as `src/vt/Parser.zig`,
`src/terminal/kitty/graphics_command.zig` lives at
`src/vt/kitty/graphics_command.zig`, etc.

`src/vt.zig` is our public surface, mirroring upstream's `src/lib_vt.zig`
minus the exports for code we skipped.

## File provenance header

Every vendored file starts with:

```zig
// Vendored from ghostty-org/ghostty
//   upstream: src/terminal/Parser.zig
//   commit:   c74f6d56d1feef473033057bc0ff7e3f00cf6421
//   pruned:   <one-line note if we removed things; omit if verbatim>
```

## Modification categories

Local modifications fall into these buckets. Note them in commit messages:

- **0.16-api**: Zig 0.16 API migration (Reader/Writer, std.Io, fs.File renames).
- **prune**: Removed code we don't use (selection, search, tmux, semantic
  prompts, kitty keyboard stack, formatter, C ABI, benchmark code).
- **tzig**: Behavior changes specific to tzig (multiplexer-only adjustments).

## Vendored files

(Filled in as we port. Mirrors upstream paths under `src/terminal/`.)

### Leaves (self-contained, near-verbatim)

- [ ] `ansi.zig`
- [ ] `apc.zig`
- [ ] `charsets.zig`
- [ ] `color.zig`
- [ ] `csi.zig`
- [ ] `cursor.zig`
- [ ] `dcs.zig`
- [ ] `device_status.zig`
- [ ] `hash_map.zig`
- [ ] `bitmap_allocator.zig`
- [ ] `hyperlink.zig`
- [ ] `modes.zig`
- [ ] `osc.zig`
- [ ] `osc/encoding.zig`
- [ ] `osc/parsers.zig`
- [ ] `osc/parsers/*` (only the ones we keep)
- [ ] `parse_table.zig`
- [ ] `Parser.zig`
- [ ] `point.zig`
- [ ] `ref_counted_set.zig`
- [ ] `sgr.zig`
- [ ] `size.zig`
- [ ] `style.zig`
- [ ] `Tabstops.zig`
- [ ] `UTF8Decoder.zig`
- [ ] `x11_color.zig`

### Core (port with pruning)

- [ ] `page.zig`
- [ ] `PageList.zig`
- [ ] `Screen.zig`
- [ ] `Terminal.zig`
- [ ] `stream.zig`
- [ ] `stream_readonly.zig`
- [ ] `render.zig`

## Skipped (out of scope for a multiplexer)

Confirmed not used by tzig. If something here turns out to be required,
move it to "Vendored files" above and port it.

- `Selection.zig`, `search.zig`, `search/`
- `tmux.zig`, `tmux/`
- `formatter.zig`
- `highlight.zig`
- `StringMap.zig`
- `ScreenSet.zig` (tzig manages screens itself via `Window`)
- `kitty/*` and `kitty.zig` — **deferred**, not skipped. To be ported in a
  follow-up so image passthrough survives overlay redraws.
- `c/` (C ABI exports)
- `res/`
- `benchmark*`
- `mouse.zig`, `osc/parsers/mouse_shape.zig` — kept only if needed by `osc.zig`/`Terminal.zig`
- All of `input/` (`paste.zig`, `key.zig`, `key_encode.zig`) — tzig proxies
  raw bytes; it doesn't call `ghostty_vt.input.*`.

## Tests

Upstream `test {}` blocks inside each vendored file are kept verbatim. They
run via `zig build test` and are our primary correctness signal during the
port.
