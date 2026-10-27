// Offline browser checks. Usage: node Test-ReportBrowser.cjs <report.html> <artifact-directory>
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { pathToFileURL } = require('node:url');
const { chromium } = require('playwright');

(async () => {
  const report = path.resolve(process.argv[2]);
  const artifacts = path.resolve(process.argv[3]);
  fs.mkdirSync(artifacts, { recursive: true });
  const browser = await chromium.launch({ headless: true, channel: 'msedge' });
  const page = await browser.newPage({ viewport: { width: 1440, height: 1100 } });
  const errors = [];
  const remoteRequests = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('request', request => { if (/^https?:/.test(request.url())) remoteRequests.push(request.url()); });
  try {
    await page.goto(pathToFileURL(report).href);
    await page.waitForSelector('html.interactive');
    const total = await page.locator('#events tbody tr').count();
    assert.ok(total > 0);
    assert.equal(await page.locator('#outcome').innerText(), 'Failed');
    const stepsBefore = await page.locator('.steps').innerText();
    await page.getByRole('button', { name: 'Sort by sequence', exact: true }).click();
    assert.equal(await page.locator('#events tbody tr').first().locator('td').first().innerText(), String(total));
    assert.equal(await page.locator('.steps').innerText(), stepsBefore, 'Sorting must preserve the step summary.');
    await page.getByLabel('Show severity').selectOption('ERROR');
    const shown = await page.locator('#events tbody tr:visible').count();
    assert.ok(shown > 0 && shown < total);
    for (const severity of await page.locator('#events tbody tr:visible').evaluateAll(rows => rows.map(row => row.dataset.severity))) {
      assert.equal(severity, 'ERROR');
    }
    await page.getByLabel('Search messages, steps, or actions').fill('connection loss');
    assert.equal(await page.locator('#events tbody tr:visible').count(), 1);
    await page.getByLabel('Search messages, steps, or actions').fill('not-a-real-event-unique');
    assert.equal(await page.locator('#events tbody tr:visible').count(), 0);
    assert.ok((await page.locator('#count').innerText()).startsWith('0 of '));
    await page.getByRole('button', { name: 'Reset view' }).click();
    assert.equal(await page.locator('#events tbody tr:visible').count(), total);
    assert.equal(await page.locator('#events tbody tr').first().locator('td').first().innerText(), '1');
    await page.getByRole('button', { name: 'Sort by time', exact: true }).click();
    const times = await page.locator('#events tbody td.time').evaluateAll(cells => cells.map(cell => Number(cell.dataset.sort)));
    assert.ok(times.every(Number.isFinite));
    assert.deepEqual(times, [...times].sort((a,b) => a-b));
    await page.getByLabel('Show severity').selectOption('ERROR');
    await page.evaluate(() => window.dispatchEvent(new Event('beforeprint')));
    assert.equal(await page.locator('#events tbody tr:visible').count(), total, 'Printing includes the entire journal.');
    await page.evaluate(() => window.dispatchEvent(new Event('afterprint')));
    assert.equal(await page.locator('#events tbody tr:visible').count(), shown, 'Print restores the previous view.');
    await page.getByRole('button', { name: 'Reset view' }).click();
    const rawLink = await page.getByRole('link', { name: 'sample-scanstate.log', exact: true }).getAttribute('href');
    assert.equal(rawLink, 'Raw/sample-scanstate.log');
    assert.ok(fs.existsSync(path.join(path.dirname(report), rawLink)));
    await page.screenshot({ path: path.join(artifacts, 'report-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: path.join(artifacts, 'report-mobile.png'), fullPage: true });
    assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), 'Small screens scroll the table, not the page.');
    assert.deepEqual(errors, []);
    assert.deepEqual(remoteRequests, [], 'No report assets require a network connection.');
    const offline = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 1440, height: 1100 } });
    const staticPage = await offline.newPage();
    await staticPage.goto(pathToFileURL(report).href);
    assert.equal(await staticPage.locator('#events tbody tr:visible').count(), total, 'All events remain readable without JavaScript.');
    assert.equal(await staticPage.locator('.controls').isVisible(), false);
    await staticPage.screenshot({ path: path.join(artifacts, 'report-no-script.png'), fullPage: true });
    await offline.close();
    console.log('PASS: sorting, search, filters, reset, chronological summary, print view, raw links, mobile layout, offline assets, and no-script readability.');
    console.log('Browser artifacts: ' + artifacts);
  } finally { await browser.close(); }
})().catch(error => { console.error(error); process.exitCode = 1; });
