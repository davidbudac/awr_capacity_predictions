# The one-minute video tour

`docs/assets/awrcap_tour.mp4` (and its poster `docs/assets/awrcap_tour_poster.jpg`)
is rendered from `video.html`: a 1920×1080 page whose `seek(t)` draws any moment of the
62-second timeline. Edit `video.html`, never the MP4. Every number in it comes from the
sample report in `docs/demo/` and the series embedded in `docs/tutorial.html`; if the demo
is regenerated, update the numbers here too.

Needs Node and a Chrome or Chromium binary (`CHROME`, default `/usr/bin/google-chrome`).

```sh
cd video
npm install                      # playwright-core + ffmpeg-static
node shots.mjs                   # img/: dashboard PNGs + captures of the two HTML demos
open video.html                  # plays the timeline live in a browser
node render.mjs - 30 "3,22,45"   # still_<t>.png at those seconds, for a quick look
node render.mjs                  # writes ../docs/assets/awrcap_tour.mp4 (about 7 min)
```

Refresh the poster from the finished video (the forecast's advice card):

```sh
"$(node -p "require('ffmpeg-static')")" -y -ss 27.3 -i ../docs/assets/awrcap_tour.mp4 \
  -frames:v 1 -vf scale=1280:-1 -q:v 4 ../docs/assets/awrcap_tour_poster.jpg
```
