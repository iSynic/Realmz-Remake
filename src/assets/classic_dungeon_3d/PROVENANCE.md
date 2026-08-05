# Classic dungeon 3D art provenance

These remake-owned presentation assets were curated from the registered Classic
Realmz data file `The Family Jewels.rsrc` (SHA-256
`2f21229c910fb8ff03f73c969f8e4895afda954fcdf31730204736cc79ede2d9`).
The resource fork, decoder output, and working crops are intentionally excluded
from this repository.

The zero-based source rectangles below, written as `x, y, width, height`, were
used as palette, proportion, and feature references. They are not stamped onto
the 3D geometry: their baked perspective and dense ordered dithering are not
suitable as surface materials under a moving camera. The committed atlas is a
remake-owned, low-resolution recreation with tileable masonry and floor
patterns, a redrawn wooden door, cut-stone trim, a stair portal, and pillar
stone. The wall surface was replaced with a SpriteCook-generated material
swatch using a deliberately restrained slate, brown-gray, and moss palette;
the selected source asset and hash are recorded in `spritecook-assets.json`.
The remaining doorway, arch, and floor colors were desaturated into the same
neutral stone and dark-walnut range so features remain distinct without the
earlier high-contrast olive and red presentation.

| Atlas region | Classic source | Crop |
|---|---:|---:|
| Wall | PICT 51 | `0, 0, 192, 144` |
| Wooden door | PICT 51 | `448, 225, 192, 144` |
| Stair portal | PICT 51 | `128, 225, 192, 144` |
| Arch trim | PICT 51 | `320, 0, 192, 144` |
| Floor | PICT 50 | `96, 128, 64, 64` |
| Dark ceiling | PICT 50 | `96, 0, 64, 64` |
| Pillar | PICT 55 | `0, 0, 70, 150` |

PICT 52 was retained as the side-perspective color and geometry reference. The
palette texture contains the 256 most frequent non-white colors across decoded
PICT 50, 51, 52, and 55. The Classic compass artwork is not included in this
first-person renderer; navigation chrome will be designed separately after the
per-square dungeon scene is established.

Decoded reference SHA-256 values:

- PICT 50: `eb46b08657070c3274b6bf053a1d82fc5cd072c62ce9e342c96e39200b995524`
- PICT 51: `67310219e9d8d55b4c53e8331fd31576a1a2c7d18d574e3b9780dbe000037549`
- PICT 52: `9ce32b8fb392b5a35e8c82c317aa6fa7c55d7a315551c28bd34a4ff61b1e12b8`
- PICT 55: `9352e53d683bcd5652f4508c5d19f44e44fc7539c3e8314b614eb53197982484`

Committed output SHA-256 values:

- `classic_dungeon_atlas.png`: `183d57647bf1ba70eb392417e6c8c804fc6f7ecd86ba115e71a4fc9f4ef640c9`
- `classic_dungeon_palette.png`: `3f5bb0f15f895a9609509fa96d70d0629537070416273127dbd5385f33d61ff2`
