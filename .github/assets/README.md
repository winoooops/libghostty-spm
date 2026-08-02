# README assets

Kept here rather than under `docs/` on purpose: `pages.yml` triggers on
`docs/**`, and GitHub Pages is not enabled on this repo, so a README image
living there would turn every docs change into a failed workflow run.

## `cursor-shaders.gif` — pending capture

The README's showcase image is commented out until this file exists. Once it is
here, uncomment the `![...]` line in the top-level README.

What it should show, in one loop of roughly 8–12 seconds: a terminal pane with a
visible cursor, cycling through the effects so the difference between them is
legible. Move the cursor deliberately — these shaders react to movement, and a
capture of a mostly-idle cursor shows nothing.

Suggested shot list:

1. `tail` — hold a line of text, move left/right across it a few times.
2. `ripple` — a few single-cell moves with pauses between, so each ring completes.
3. `sonic-boom` — a large jump (end of line → start of line) to trigger the shockwave.
4. `warp` — continuous movement, so the stretch stays visible.

Capture with any screen recorder, then convert. This produces a reasonably small
looping GIF at a readable frame rate:

```bash
ffmpeg -i capture.mov \
  -vf "fps=20,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" \
  -loop 0 .github/assets/cursor-shaders.gif
```

Keep it under a few MB — GitHub serves README images inline and a large GIF
makes the page crawl. If it lands too big, drop `fps` to 15 or `scale` to 720.
