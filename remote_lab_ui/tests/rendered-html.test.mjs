import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

async function render() {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);

  return worker.fetch(
    new Request("http://localhost/", {
      headers: { accept: "text/html" },
    }),
    {
      ASSETS: {
        fetch: async () => new Response("Not found", { status: 404 }),
      },
    },
    {
      waitUntil() {},
      passThroughOnException() {},
    },
  );
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
