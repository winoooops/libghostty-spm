# Third-party licenses

The published `GhosttyKit.xcframework` statically links the libraries below.
Anyone redistributing a binary built from this package must carry these notices
with it.

These files are copied verbatim from the exact dependency tarballs Ghostty pins
— not from the projects' current `main` — so they match what is actually linked.
Re-copy them whenever `Ghostty.ref` moves.

| Library      | License                                                | Source of this copy                                                                   |
| ------------ | ------------------------------------------------------ | ------------------------------------------------------------------------------------- |
| glslang      | BSD-3-Clause, BSD-2-Clause, MIT, Apache-2.0 (see file) | `pkg/glslang` → `glslang-12201278a1a05c0ce0b6eb6026c65cd3e9247aa041b1c260324bf29cee559dd23ba1.tar.gz` |
| SPIRV-Cross  | Apache-2.0 (plus MIT, CC-BY-4.0, Khronos Free Use)     | `pkg/spirv-cross` → `spirv_cross-1220fb3b5586e8be67bc3feb34cbe749cf42a60d628d2953632c2f8141302748c8da.tar.gz` |

Both are linked only when the shader compiler is built in, which is this
package's default. A build made with `--no-custom-shaders` contains neither, and
these notices do not apply to it.

Ghostty itself, and the rest of the statically linked dependencies, are covered
by the upstream Ghostty license referenced in the top-level [README](../README.md).
