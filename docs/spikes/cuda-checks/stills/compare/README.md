# The CUDA engine's stills against Metal's (#277)

`sillage-cuda still` on the CPU target against the stills `sillage-render export --stills` drew on
an M4 Max, from the take of `../../render/take/` (scene-0031 at 200 k drawn from 50 k massive,
480 by 270), in the five looks of `../../render/looks/`, on its three shots (`close`, `wide` and
`pericentre`: frames 4, 12 and 19 of a video at the captured 3 a second). Metal's are
`../../render/stills/<look>-<shot>.png`.

`pairs/<look>-<shot>.png`: three panels side by side, Metal's frame, the CUDA frame as the CUDA
engine draws it (its PSNR against Metal's in the label) and their difference, the largest of
the three channels' absolute differences on a scale from black through red and yellow to white
at 32 levels of 255. `pairs/comparison.md` has the numbers, three ways: the CUDA engine as it
draws, with the particle passes blending in half floats as Metal's targets do, and Metal's own
accumulation (`../../render/targets/*/*/light.f16`) developed by the CUDA post-processing alone.

Made by `SILLAGE_CUDA_RENDER_TARGETS=<render folder> SILLAGE_CUDA_STILLS_OUT=<folder>
scripts/linux.sh test-cuda --filter theStillsAgreeWithMetal`, then
`scripts/still-pairs.py <render folder>/stills <folder> --out pairs`.
