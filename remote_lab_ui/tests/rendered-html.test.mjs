import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import test from "node:test";
import { fileURLToPath } from "node:url";
import { Miniflare, convertV4MiniflareOptions } from "miniflare";

async function render() {
  // Exercise the actual Cloudflare runtime, including cloudflare: imports.
  const root = fileURLToPath(new URL("../dist/server/", import.meta.url));
  const files = await readdir(root, { recursive: true });
  const modules = ["index.js", ...files.filter((name) => name.endsWith(".js") && name !== "index.js")]
    .map((name) => ({ type: "ESModule", path: `${root}/${name}` }));
  const worker = new Miniflare(convertV4MiniflareOptions({
    workers: [{
    name: "expert-chat-test",
    modules,
    modulesRoot: fileURLToPath(new URL("../dist/server/", import.meta.url)),
    compatibilityDate: "2026-09-22",
    compatibilityFlags: ["nodejs_compat"],
    serviceBindings: { ASSETS: async () => new Response("Not found", { status: 404 }) },
    }],
  }));
  try {
    const response = await worker.dispatchFetch("http://localhost/", { headers: { accept: "text/html" } });
    return new Response(await response.text(), { status: response.status, headers: response.headers });
  } finally {
    await worker.dispose();
  }
}

test("server-renders the Expert Chat research settings entry", async () => {
  const response = await render();
  assert.equal(response.status, 200);
  assert.match(response.headers.get("content-type") ?? "", /^text\/html\b/i);

  const html = await response.text();
  assert.match(html, /<title>Expert Chat · 科研终端<\/title>/i);
  assert.match(html, /实验功能/);
  assert.match(html, /科研模式/);
  assert.match(html, /role="switch"/);
  assert.match(html, /aria-checked="false"/);
  assert.match(html, /移动端主导航/);
  assert.doesNotMatch(html, /Your site is taking shape|Building your site/);
});

test("research preference and responsive navigation stay wired in source", async () => {
  const [page, css, layout] = await Promise.all([
    readFile(new URL("../app/page.tsx", import.meta.url), "utf8"),
    readFile(new URL("../app/globals.css", import.meta.url), "utf8"),
    readFile(new URL("../app/layout.tsx", import.meta.url), "utf8"),
  ]);

  assert.match(page, /useSyncExternalStore/);
  assert.match(page, /expert-chat-research-mode/);
  assert.match(page, /role="switch"/);
  assert.match(page, /researchModeEnabled &&/);
  assert.match(page, /activeView === "terminal"/);
  assert.match(css, /\.mobile-nav\.has-research-mode/);
  assert.match(css, /grid-template-columns:\s*repeat\(3,\s*1fr\)/);
  assert.match(css, /grid-template-columns:\s*repeat\(4,\s*1fr\)/);
  assert.match(layout, /Expert Chat · 科研终端/);
  assert.doesNotMatch(page, /SkeletonPreview|codex-preview/);
});
