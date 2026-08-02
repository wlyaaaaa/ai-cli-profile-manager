"use strict";

const fs = require("fs");
const path = require("path");
const { pathToFileURL } = require("url");
const { chromium } = require("playwright");

async function main() {
  const [edgePath, htmlPath, outputPath, timeoutText] = process.argv.slice(2);
  const timeoutMs = Number(timeoutText);
  if (!edgePath || !htmlPath || !outputPath || !Number.isFinite(timeoutMs)) {
    throw new Error("usage: node Print-HtmlPdfPlaywright.js EDGE HTML OUTPUT TIMEOUT_MS");
  }
  if (!fs.existsSync(edgePath) || !fs.existsSync(htmlPath)) {
    throw new Error("Edge executable or HTML input does not exist");
  }

  const browser = await chromium.launch({
    executablePath: edgePath,
    headless: true,
    timeout: timeoutMs,
  });
  try {
    const page = await browser.newPage();
    page.setDefaultTimeout(timeoutMs);
    page.setDefaultNavigationTimeout(timeoutMs);
    await page.goto(pathToFileURL(htmlPath).href, { waitUntil: "load" });
    await page.emulateMedia({ media: "print" });
    await page.evaluate(async () => {
      if (document.fonts && document.fonts.ready) await document.fonts.ready;
    });
    await page.pdf({
      path: outputPath,
      format: "A4",
      printBackground: true,
      preferCSSPageSize: true,
    });
  } finally {
    await browser.close();
  }

  const stats = fs.statSync(outputPath);
  if (!stats.isFile() || stats.size <= 1024) {
    throw new Error(`PDF output is missing or too small: ${path.basename(outputPath)}`);
  }
}

main().catch((error) => {
  process.stderr.write(`${error && error.stack ? error.stack : error}\n`);
  process.exitCode = 1;
});
