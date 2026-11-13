# Variable time: the prototype behind docs/notes/variable-time.md

`story-pace.py` reads `curves.csv` files and prints, for each story, where its simulated time
goes (before the story, engaged, after) and how long its video would play at 1x and at the
automatic pace the note describes. `story-pace.txt` is its output on the twenty explore stories
at 7 and the 8 M hires of scene-0031 at 3.5 kept on `assets/225-doubled-step`
(`docs/spikes/doubled-step/explore/dt7-scenes.tgz` and `hires/dt35/curves-hires.csv`; the hires
is the row named `dt35`):

    python3 story-pace.py explore/dt7s/scene-*/curves.csv hires/dt35/curves-hires.csv
