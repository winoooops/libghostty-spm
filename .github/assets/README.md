# README assets

Kept here rather than under `docs/` on purpose: `pages.yml` triggers on
`docs/**`, and GitHub Pages is not enabled on this repo, so a README image
living there would turn every docs change into a failed workflow run.

## `cursor-*.gif`

One loop per shader — `warp`, `sweep`, `tail`, `ripple`, `sonic-boom` — shown in
a two-column grid under "What this unlocks downstream". Captured in a
[Vimeflow](https://github.com/winoooops/vimeflow) terminal pane running a build
of this package, with the shaders from
[`sahaj-b/ghostty-cursor-shaders`](https://github.com/sahaj-b/ghostty-cursor-shaders).

**440px wide, ~1.8 MB for all five.** This repo is an SPM dependency, so every
consumer clones these bytes on `swift package resolve` — keep the total in the
low megabytes. 440 is the width the grid renders them at, so there is nothing to
gain from shipping larger files.

## Recapturing

These shaders react to _movement_; a capture of a mostly-idle cursor shows
nothing. Use the same choreography for every effect so the grid stays
comparable — the only variable should be the shader:

1. Type a line of text at a steady pace.
2. Jump to the start of the line, hold, then jump to the end and hold. This is
   what makes `warp` and `sonic-boom` visible.
3. Hold an arrow key for a continuous run. This is what makes `tail` and `sweep`
   visible.
4. A few single-cell moves with pauses, so each `ripple` ring completes.

Then trim and convert. `gifski` quantizes per frame, which matters here — these
are smooth additive gradients, and a single global palette bands them visibly:

```bash
FRAMES=$(mktemp -d)

# Trim in ffmpeg — gifski has no seek. For the middle N seconds of a clip,
# start at (duration - N) / 2.
ffmpeg -v error -ss <start> -t 3 -i capture.mov \
  -vf "scale=440:-2:flags=lanczos" -r 20 "$FRAMES/%04d.png"

gifski --fps 20 --quality 90 -o .github/assets/cursor-<effect>.gif "$FRAMES"/*.png
rm -rf "$FRAMES"
```
