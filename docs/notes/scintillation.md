# Two scintillations, and which slider reaches which

"Impossible de couper le clignotement des étoiles." There are two causes, they look identical
on screen, and `--flicker` tells them apart: it parks the playhead, leaves the camera alone,
and measures the root-mean-square difference between consecutive frames in 8-bit levels. With
nothing moving, two frames should be identical to the bit.

| | rms | pire écart | |
| --- | --- | --- | --- |
| tel quel | 6.038 | 33 | sur 99.2 % des pixels |
| sans bruit de détecteur | **0.000** | **0** | identique au bit |
| sans fond de ciel, bruit remis | 11.966 | 36 | *pire* |
| sans bruit ni fond de ciel | 0.000 | 0 | |

**The detector noise is the whole of it when nothing moves**, and it is the twenty-times
larger of the two. Note the third row: pulling the sky background *down* makes the noise more
visible, not less, because the log stretch is steepest near black — so the instinctive fix
makes it worse.

The second cause only exists in motion. Played slowly with the noise off, so that real
movement is a fraction of a pixel:

| noyau minimal | rms | pire écart |
| --- | --- | --- |
| 1.1 px (défaut) | 0.312 | **81** |
| 1.6 px | 0.205 | 46 |
| 2.4 px | 0.133 | 31 |
| 3.5 px | 0.091 | 16 |

A star drawn thinner than a pixel crosses pixel boundaries as it moves and twinkles on its
own. The rms is small because it is a few pixels in the frame, but the worst single pixel
jumps by 81 levels — a third of full scale — which is exactly what reads as a star winking.
No amount of turning the noise down touches it; the kernel floor is the only thing that does.

**And the control for it did not exist.** Five `RenderLook` fields had no slider at all —
`minimumKernel`, `maximumKernel`, `bloomSoftKnee`, `armPersistence`, `fieldOfView` — reachable
only by picking a preset. The noise slider did exist but was called "Bruit de détecteur", which
is what it is rather than what it does, and ran to 0.01 when every look sits between 0.0008 and
0.0022: the whole useful part of it was in the first sixth of the track and zero was three
pixels wide. Renamed, and the range cut to the values that are actually used.

Worth checking against `RenderLook` after adding a field: a knob nobody can reach is the same
as no knob.
