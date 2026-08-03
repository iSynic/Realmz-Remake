# Classic volcano flame

These eight 32x32 images are lossless decodes of the original Realmz `cicn`
resources 26178 through 26185. Keep the frames opaque and unmodified: each one
contains the local mountain and smoke background needed to reproduce the
classic animation exactly.

The original home-screen dialog places its 610x425 picture at `(12, 33)` and
draws the flame into `(474, 122, 506, 154)`. The resulting position relative to
the picture is `(462, 89)`. `MainLoop` advances the eight-frame loop every 20
classic ticks, approximately three frames per second.
