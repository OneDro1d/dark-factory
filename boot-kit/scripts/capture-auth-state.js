#!/usr/bin/env node
/**
 * Capture Clerk authentication state for Playwright testing.
 *
 * Opens a headed browser, navigates to the target app's login page,
 * waits for you to complete Clerk sign-in (supports SSO, MFA, etc.),
 * then saves the full storageState (cookies + localStorage) to a JSON file.
 *
 * Usage:
 *   node boot-kit/scripts/capture-auth-state.js \
 *     --url http://localhost:5173 \
 *     --output playwright/.auth/clerk-session.json \
 *     [--wait-for-path /onboarding]  # optional: wait until redirect confirms login
 *
 * The saved state file can then be loaded by Playwright MCP:
 *   npx @playwright/mcp@0.0.41 --storage-state playwright/.auth/clerk-session.json
 *
 * Or in playwright.config.ts:
 *   use: { storageState: 'playwright/.auth/clerk-session.json' }
 */

import { chromium } from 'playwright';
import { parseArgs } from 'node:util';
import { mkdirSync, existsSync } from 'node:fs';
import { dirname } from 'node:path';

const { values } = parseArgs({
  options: {
    url: { type: 'string', default: 'http://localhost:5173' },
    output: { type: 'string', default: 'playwright/.auth/clerk-session.json' },
    'wait-for-path': { type: 'string', default: '' },
    timeout: { type: 'string', default: '300000' }, // 5 min default
  },
});

const outputDir = dirname(values.output);
if (!existsSync(outputDir)) {
  mkdirSync(outputDir, { recursive: true });
}

console.log(`Opening ${values.url} in headed browser...`);
console.log('Complete Clerk sign-in, then the state will be captured automatically.');
console.log(`Output: ${values.output}`);
console.log(`Timeout: ${parseInt(values.timeout) / 1000}s`);
console.log('');

const browser = await chromium.launch({ headless: false });
const context = await browser.newContext();
const page = await context.newPage();

await page.goto(values.url);

// Wait for sign-in to complete
if (values['wait-for-path']) {
  console.log(`Waiting for redirect to ${values['wait-for-path']}...`);
  await page.waitForURL(`**${values['wait-for-path']}**`, {
    timeout: parseInt(values.timeout),
  });
} else {
  // Wait for Clerk's SignedIn state — look for the app shell to appear
  // (Clerk removes SignedOut content and renders SignedIn content)
  console.log('Waiting for Clerk sign-in to complete...');
  console.log('(Looking for the app shell to appear after login)');
  await page.waitForFunction(() => {
    // Check common indicators that Clerk auth succeeded:
    // 1. Clerk's __clerk_db_jwt cookie exists
    // 2. The URL changed away from root login
    // 3. Any element with data-clerk-signed-in exists
    const hasCookie = document.cookie.includes('__clerk');
    const notOnRoot = window.location.hash !== '' && window.location.hash !== '#/';
    return hasCookie || notOnRoot;
  }, { timeout: parseInt(values.timeout) });

  // Give Clerk a moment to fully hydrate
  await page.waitForTimeout(2000);
}

console.log('Sign-in detected! Saving storage state...');
await context.storageState({ path: values.output });
console.log(`Auth state saved to: ${values.output}`);

await browser.close();
console.log('Done. Use this state with:');
console.log(`  npx @playwright/mcp@0.0.41 --storage-state ${values.output}`);
