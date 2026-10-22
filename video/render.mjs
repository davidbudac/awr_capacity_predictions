// Render video.html to an MP4: seek each frame, screenshot it, pipe the PNGs into ffmpeg (libx264).
//   node render.mjs [out.mp4] [fps]      full video (default ../docs/assets/awrcap_tour.mp4, 30 fps)
//   node render.mjs - 30 "3,17.5,40"     stills only: still_<t>.png at those seconds
//   CRF=26 (default) sets the quality; CHROME points at a Chrome/Chromium binary.
import { chromium } from "playwright-core";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import ffmpeg from "ffmpeg-static";
import path from "node:path";
const here = path.dirname(fileURLToPath(import.meta.url));
const [,, outArg, fpsArg = "30", stills] = process.argv;
const out = path.resolve(outArg && outArg !== "-" ? outArg : path.join(here, "..", "docs", "assets", "awrcap_tour.mp4"));
const FPS = +fpsArg;
const browser = await chromium.launch({ executablePath: process.env.CHROME || "/usr/bin/google-chrome",
                                        args: ["--force-color-profile=srgb"] });
const page = await browser.newPage({ viewport: { width: 1920, height: 1080 } });
await page.goto("file://" + path.join(here, "video.html") + "?render");
await page.evaluate(() => document.fonts.ready);
const dur = await page.evaluate(() => window.__dur);
if (stills) {
  for (const t of stills.split(",").map(Number)) {
    await page.evaluate(t => window.__seek(t), t);
    await page.screenshot({ path: path.join(here, `still_${t}.png`) });
  }
  await browser.close(); process.exit(0);
}
const ff = spawn(ffmpeg, ["-y", "-f", "image2pipe", "-framerate", String(FPS), "-i", "-",
  "-c:v", "libx264", "-preset", "slow", "-crf", process.env.CRF || "26", "-pix_fmt", "yuv420p",
  "-movflags", "+faststart", out], { stdio: ["pipe", "inherit", "inherit"] });
const n = Math.round(dur * FPS);
for (let i = 0; i < n; i++) {
  await page.evaluate(t => window.__seek(t), i / FPS);
  const buf = await page.screenshot({ type: "png" });
  if (!ff.stdin.write(buf)) await new Promise(r => ff.stdin.once("drain", r));
  if (i % 300 === 0) console.error(`frame ${i}/${n}`);
}
ff.stdin.end();
await new Promise(r => ff.on("close", r));
await browser.close();
