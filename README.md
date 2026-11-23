# Rune's Metal blits cost a fixed ~135 MB of driver memory

Upstream issue: https://github.com/anomalyco/rune/issues/1753. Rune `86b903de7fef9c6b683e05dc23440de4ebbc4347`, macOS 27.2.1 on an Apple M5 Max, Xcode 27.1 (Swift 6.4), Rust 1.99.

## Steps

```sh
git clone https://github.com/ryoppippi-bug-repro/rune-metal-blit-driver-memory
cd rune-metal-blit-driver-memory
./probe.sh   # bare Metal, no Rune: footprint after each kind of encoder
./repro.sh   # Rune examples/hello --snap, as shipped and with RUNE_NOBLIT=1
```

`repro.sh` clones Rune at the commit above, applies `rune-cpu-uploads.patch` and builds `hello` with `--features rune/tooling`. It needs `git` and the Rust toolchain Rune's `rust-toolchain.toml` names; `probe.sh` needs `swiftc` from Xcode or the Command Line Tools.

## What happens

On Apple silicon, any process that commits a blit (or compute) encoder is charged a fixed ~135 MB of driver memory, on top of the ~185 MB a render pass costs. It shows in `vmmap` / `footprint` as "Owned physical footprint (unmapped) (graphics)" and counts towards the footprint Activity Monitor shows. The size doesn't depend on how much is copied, repeating the encoder adds nothing, and the driver frees it about a second after the GPU goes idle, then charges it again on the next frame that blits.

Rune's Metal backend blits in the first frame of every app and in every frame that uploads a glyph or an image, so `examples/hello` peaks at 371 MB. With the same frames done without a blit encoder, it peaks at 218 MB:

| `examples/hello --snap hello.png --scene on` | peak footprint |
|---|---|
| Rune as shipped | 371 MB |
| `RUNE_NOBLIT=1` (shared textures, `replaceRegion`, no readback) | 218 MB |

Bare Metal from Swift, no Rune (`probe.swift`, 64x64 work, footprint after each step):

| steps | footprint |
|---|---|
| (device and queue) | 4 MB |
| `render` | 188 MB |
| `blit` | 140 MB |
| `compute` | 123 MB |
| `replace` (`replaceRegion` into a shared texture) | 4 MB |
| `replace render` | 4 → 188 MB |
| `render render blit blit` | 188, 188, 323, 323 MB |
| `render blit idle render` | 188, 323, 10, 189 MB |

## Cause

In Rune `86b903de` (and still on `dev` at `cc051b12`), `crates/rune-gpu/src/metal`:

- `device.rs`, `create_texture`: every new texture is zeroed with a blit (`encode.rs`, `zero_texture`), committed ahead of the next submit. The first frame always creates textures (the image atlas, the glyph atlas, the window's surfaces), so the first frame always blits.
- `submit.rs`, `write_texture`, and `encode.rs`, `copy_buffer_to_texture` (which `rune-staging` uses for atlas rows): uploads stage through a blit.
- `resource.rs`, `device_texture`: textures are always `MTLStorageModePrivate`, so the CPU can't write them directly.
- `encode.rs`, `copy_texture_to_buffer`: the `--snap` readback is a blit too.

A breakpoint on `-[AGXG17XFamilyCommandBuffer blitCommandEncoder]` in a headless run of an app built on Rune stops in `rune::render::Renderer::texture` → `create_texture` (zeroing), `rune_staging::Staging::flush` → `copy_buffer_to_texture`, and `rune_staging::buffer::Readback::copy_from` → `copy_texture_to_buffer`. With `RUNE_NOBLIT=1` the only encoder left in `hello --snap` is one render pass.

## Analysis

The ~135 MB looks like per-process state the AGX driver keeps for the compute channel, which blits run on; the render pass charge is the same thing for the render channel. Rune can't avoid the render charge while it draws with Metal, but it can avoid the compute one by not encoding blits or compute work on frames that don't need them:

1. On Apple silicon (unified memory), create CPU-written textures with `MTLStorageModeShared` and write rows with `replaceRegion` instead of a staged blit. This is #1245's first idea; it needs a rule for a region the GPU may still be reading (a spare page, or a blit only then).
2. Zero a new texture without a blit: `replaceRegion` with zeros for a shared texture, or a clear load action on the first render pass for a render target, or skip it for a texture whose first use writes all of it.
3. Read back shared textures with `getBytes` once their command buffer completes, so a headless `--snap` measures what a window costs.

`rune-cpu-uploads.patch` in the reproduction does 1–3 crudely behind `RUNE_NOBLIT=1` to measure the saving: it writes at record time without regard to in-flight GPU reads and drops the readback, so `hello.png` is wrong under it. It is a measurement, not a proposed fix. I didn't measure the Intel/AMD Mac or iOS drivers.

Related: #1245 reports the steady-state side of this (a window that keeps uploading keeps ~200 MB more graphics memory) and suggests (1). The zeroing blit in `create_texture` isn't covered there, and it fires on every app's first frame, upload or not, so fixing uploads alone would leave the startup peak where it is.

## How it was found

A launcher built on Rune ([x-ryoppippi/dupin#36](https://github.com/x-ryoppippi/dupin/issues/36)) peaked at ~380 MB in its first frame and settled at ~30 MB. Bisecting with `/usr/bin/time -l`, `footprint`, and lldb breakpoints on the AGX command buffer's encoder methods showed the peak was driver memory charged per kind of encoder, and that every blit in the app's frames came from Rune's Metal backend. The launcher isn't needed to reproduce it: `examples/hello` shows the same peak.

## Files

- `probe.swift`, `probe.sh`: one piece of bare Metal work per argument, printing the footprint after each.
- `rune-cpu-uploads.patch`: behind `RUNE_NOBLIT=1`, textures are `MTLStorageModeShared`, new textures are zeroed and uploads written with `replaceRegion`, and `copy_texture_to_buffer` does nothing. Without the variable, Rune behaves as shipped.
- `repro.sh`: builds `hello` with the patch and prints its `--snap` peak footprint with and without `RUNE_NOBLIT=1`.
