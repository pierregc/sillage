# The picture is not free

The setup screen's preview was taking most of the GPU while nobody touched anything: it never
steps, and it was redrawing three hundred thousand particles sixty times a second to show the
same still. It draws on demand now — `--presets` went from 353 draws over its walk to 7.
Anything that changes what the preview shows has to say so, through `redrawPreview()`.

The running canvas draws at sixty rather than a hundred and twenty, and can be switched off
entirely while a scene is computed: `showCanvasWhileRunning` takes the `MTKView` out of the
hierarchy, and `draw(in:)` refuses anyway, because the view outlives its removal by a frame or
two. With a finish and a destination set, `quitWhenFinished` closes the application once the
take is on disk.
