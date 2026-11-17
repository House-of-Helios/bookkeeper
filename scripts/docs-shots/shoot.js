// Docs pictures drawn as HTML (macOS windows rebuilt as mock-ups, and diagrams), never a screen
// capture. Run through the Playwright MCP (browser_run_code_unsafe filename=...) from the repo
// root; file:// needs no server. Output goes to docs/site/img/. App screens come from
// `Bookkeeper Dev.app --snapshot` with BOOKKEEPER_SNAPSHOT_LIGHT=1 instead.
async (page) => {
  const ROOT = process.env.BOOKKEEPER_ROOT || process.cwd();
  const jobs = [["open-anyway", 960, 620], ["privacy-map", 1200, 740]];
  // One page, resized per job: a fresh context with deviceScaleFactor tiled the shot.
  for (const [n, w, h] of jobs) {
    await page.setViewportSize({ width: w, height: h });
    await page.goto(`file://${ROOT}/scripts/docs-shots/${n}.html`);
    await page.waitForLoadState("networkidle");
    await page.screenshot({ path: `${ROOT}/docs/site/img/${n}.png` });
  }
  return "ok";
}
