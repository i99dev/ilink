#!/usr/bin/env node
// Rasterize an SVG to a square PNG.
//
// Why this exists: flutter_launcher_icons (v0.14.x) only accepts PNG
// input, but the launcher icon design master is `assets/branding/
// ilink_icon.svg`. Use this script to re-export the PNG that the
// launcher generator consumes — typically:
//
//   node scripts/svg2png.mjs \
//        assets/branding/ilink_icon.svg \
//        assets/branding/ilink_icon.png \
//        1024
//   dart run flutter_launcher_icons
//
// Density is set to 600 so SVGs at viewBox=512 rasterise crisply
// without sub-pixel artefacts; sharp's contain-fit pads transparent
// pixels when the SVG isn't perfectly square (ours is).
//
// Dependency: `sharp` (pure-JS + native libvips, install via
// `npm install -g sharp` or run inside a folder that has it).

import sharp from 'sharp';
import { readFileSync } from 'fs';

const args = process.argv.slice(2);
if (args.length < 3) {
  console.error('usage: node scripts/svg2png.mjs <input.svg> <output.png> <size>');
  process.exit(1);
}
const [inSvg, outPng, sizeStr] = args;
const size = parseInt(sizeStr, 10);
if (!Number.isFinite(size) || size < 16 || size > 4096) {
  console.error(`invalid size: ${sizeStr}`);
  process.exit(2);
}

const buf = readFileSync(inSvg);
await sharp(buf, { density: 600 })
  .resize(size, size, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
  .png()
  .toFile(outPng);
console.log(`wrote ${outPng} (${size}x${size})`);
