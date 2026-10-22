// Collect the screenshots the "outputs" scene shows into img/:
// the lab dashboard PNGs from docs/assets, plus fresh captures of the two HTML demos.
import { chromium } from "playwright-core";
import { mkdirSync, copyFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";
const here = path.dirname(fileURLToPath(import.meta.url));
const docs = path.join(here, "..", "docs");
const img = path.join(here, "img");
mkdirSync(img, { recursive: true });
for (const f of ["apex-overview.png", "grafana-tablespaces.png", "kibana-fleet-anomalies.png"])
  copyFileSync(path.join(docs, "assets", f), path.join(img, f));
const browser = await chromium.launch({ executablePath: process.env.CHROME || "/usr/bin/google-chrome" });
for (const [demo, out, scheme] of [["cap_report_demo.html", "html_report.png", "dark"], ["cap_brief_demo.html", "brief.png", "light"]]) {
  const page = await browser.newPage({ viewport: { width: 1400, height: 1000 }, colorScheme: scheme });
  await page.goto("file://" + path.join(docs, "demo", demo));
  await page.waitForTimeout(500);
  await page.screenshot({ path: path.join(img, out) });
}
await browser.close();
