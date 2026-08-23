/**
 * Auth modes + the drawn cursor.
 *
 * Cursor: Playwright's recordVideo captures the page's own rendered frames, which contain
 * no pointer — a real mouse would be invisible and the result reads as a slideshow. So we
 * draw one, and drive the CSS transition rather than tweening from Node, which keeps motion
 * smooth without a round-trip per frame.
 */

export const APP = process.env.WT_APP || "";
const AUTH = process.env.WT_AUTH || "none";

// ---------------------------------------------------------------- auth modes

async function mintClerkTicket() {
  const key = process.env.CLERK_SECRET_KEY;
  const userId = process.env.CLERK_USER_ID;
  if (!key || !userId) {
    throw new Error("clerk-ticket mode needs CLERK_SECRET_KEY and CLERK_USER_ID");
  }
  const res = await fetch("https://api.clerk.com/v1/sign_in_tokens", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({ user_id: userId, expires_in_seconds: 600 }),
  });
  if (!res.ok) throw new Error(`sign_in_tokens returned ${res.status}`);
  const token = (await res.json()).token;
  if (!token) throw new Error("sign_in_tokens returned no token");
  return token;
}

/**
 * Bring the page to a signed-in, ready state. Returns when the app is usable.
 *
 * The ticket flow waits for the REDIRECT away from the sign-in route rather than sleeping a
 * fixed interval: the widget consumes the ticket asynchronously and intermittently misses
 * the first one, so "sleep long enough" works until the run where it doesn't.
 */
export async function signIn(page, { readySelector } = {}) {
  const ready = readySelector || process.env.WT_READY_SELECTOR || "";

  if (AUTH === "none" || AUTH === "storage-state") {
    if (APP) await page.goto(APP, { waitUntil: "domcontentloaded", timeout: 45000 });
    if (ready) await page.waitForSelector(ready, { timeout: 45000 });
    return true;
  }

  if (AUTH !== "clerk-ticket") throw new Error(`unknown WT_AUTH: ${AUTH}`);

  const signInPath = process.env.WT_SIGNIN_PATH || "/sign-in";
  for (let attempt = 1; attempt <= 3; attempt++) {
    const ticket = await mintClerkTicket();
    await page.goto(`${APP}${signInPath}?__clerk_ticket=${ticket}`, {
      waitUntil: "domcontentloaded",
      timeout: 45000,
    });
    try {
      await page.waitForURL((u) => !u.toString().includes(signInPath), { timeout: 45000 });
      if (ready) await page.waitForSelector(ready, { timeout: 45000 });
      return true;
    } catch {
      console.log(`  sign-in attempt ${attempt} did not land, retrying with a fresh ticket`);
    }
  }
  throw new Error("sign-in failed after 3 attempts");
}

/** Extra context options per auth mode (storageState is applied at context creation). */
export function contextOptions() {
  const opts = {};
  if (AUTH === "storage-state") {
    const p = process.env.WT_STORAGE_STATE;
    if (!p) throw new Error("storage-state mode needs WT_STORAGE_STATE");
    opts.storageState = p;
  }
  return opts;
}

// ------------------------------------------------------------- drawn cursor

export const CURSOR_INIT_SCRIPT = `(() => {
  const install = () => {
    if (!document.body || document.getElementById('__wt_cursor')) return;
    const s = document.createElement('style');
    s.textContent = \`
      #__wt_cursor{position:fixed;z-index:2147483647;width:24px;height:24px;margin:-12px 0 0 -12px;
        border-radius:50%;background:rgba(15,23,42,.85);border:2.5px solid #fff;
        box-shadow:0 3px 12px rgba(0,0,0,.5);pointer-events:none;left:-200px;top:-200px;
        transition:left .55s cubic-bezier(.22,.61,.36,1),top .55s cubic-bezier(.22,.61,.36,1);}
      #__wt_ripple{position:fixed;z-index:2147483646;width:20px;height:20px;margin:-10px 0 0 -10px;
        border-radius:50%;border:3px solid #10b981;pointer-events:none;opacity:0;left:-200px;top:-200px;}
      @keyframes __wt_pop{0%{transform:scale(.4);opacity:.95}100%{transform:scale(3.6);opacity:0}}
      .__wt_pop{animation:__wt_pop .6s ease-out forwards;}
    \`;
    document.head.appendChild(s);
    for (const id of ['__wt_cursor','__wt_ripple']) {
      const d = document.createElement('div'); d.id = id; document.body.appendChild(d);
    }
  };
  // SPA route changes can replace large subtrees; re-install cheaply rather than tracking them.
  const boot = () => { install(); setInterval(install, 1000); };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
  window.__wtMove = (x, y) => {
    const c = document.getElementById('__wt_cursor');
    if (c) { c.style.left = x + 'px'; c.style.top = y + 'px'; }
  };
  window.__wtRipple = (x, y) => {
    const r = document.getElementById('__wt_ripple');
    if (!r) return;
    r.style.left = x + 'px'; r.style.top = y + 'px';
    r.classList.remove('__wt_pop'); void r.offsetWidth;
    r.style.opacity = 1; r.classList.add('__wt_pop');
  };
})();`;

const GLIDE_MS = 600;

/** Glide the drawn cursor to an element's centre. Returns the point, or null. */
export async function glideTo(page, locator) {
  const box = await locator.boundingBox().catch(() => null);
  if (!box) return null;
  const x = Math.round(box.x + box.width / 2);
  const y = Math.round(box.y + box.height / 2);
  await page.evaluate(([px, py]) => window.__wtMove && window.__wtMove(px, py), [x, y]);
  await page.waitForTimeout(GLIDE_MS);
  return { x, y };
}

/** Glide, ripple, then really click — so the video shows the click it performs. */
export async function showClick(page, locator, { timeout = 20000 } = {}) {
  await locator.waitFor({ state: "visible", timeout });
  const pt = await glideTo(page, locator);
  if (pt) {
    await page.evaluate(([x, y]) => window.__wtRipple && window.__wtRipple(x, y), [pt.x, pt.y]);
    await page.waitForTimeout(220);
  }
  await locator.click({ timeout });
  return pt;
}
