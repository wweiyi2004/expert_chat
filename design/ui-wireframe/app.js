(() => {
  const app = document.getElementById("app");
  const device = document.getElementById("device");
  const tablet = document.getElementById("tablet");
  const hint = document.getElementById("screenHint");
  const tabbar = document.getElementById("tabbar");

  const TAB_SCREENS = new Set(["chat", "chat-plain", "ensemble", "list", "studio", "world", "char-detail"]);
  const ME_SCREENS = new Set(["me", "provider", "search-settings"]);

  function showScreen(name) {
    if (name === "tablet") {
      device.hidden = true;
      tablet.hidden = false;
      hint.textContent = "当前：平板双/三栏示意（阶段 2）";
      return;
    }

    device.hidden = false;
    tablet.hidden = true;

    const screens = app.querySelectorAll(".screen");
    let found = null;
    screens.forEach((s) => {
      const on = s.dataset.screen === name;
      s.classList.toggle("active", on);
      if (on) found = s;
    });

    if (!found) {
      showScreen("chat");
      return;
    }

    hint.textContent = `当前：${found.dataset.hint || name}`;

    // Tab highlight
    let tab = "chat";
    if (ME_SCREENS.has(name)) tab = "me";
    else if (name === "studio" || name === "world" || name === "char-detail") tab = "studio";
    else if (TAB_SCREENS.has(name)) tab = "chat";

    tabbar.querySelectorAll(".tab").forEach((t) => {
      t.classList.toggle("on", t.dataset.tab === tab);
    });

    // Hide tabbar on deep sheets? keep always for IA clarity
    tabbar.style.display = "";
  }

  function openOverlay(id) {
    const el = document.getElementById(id);
    if (el) el.hidden = false;
  }

  function closeOverlay(id) {
    const el = document.getElementById(id);
    if (el) el.hidden = true;
  }

  document.addEventListener("click", (e) => {
    const t = e.target.closest("[data-go], [data-close]");
    if (!t) return;

    const closeId = t.getAttribute("data-close");
    if (closeId) closeOverlay(closeId);

    const go = t.getAttribute("data-go");
    if (!go) return;

    if (go === "plot") {
      openOverlay("plot-sheet");
      hint.textContent = "当前：情节 Sheet（半屏起，可想象拖满）";
      return;
    }
    if (go === "new-menu") {
      openOverlay("new-menu");
      return;
    }
    if (go === "overflow") {
      openOverlay("overflow");
      return;
    }

    showScreen(go);
  });

  // Filter chips on list — visual only
  document.querySelectorAll(".list-filters .chip").forEach((chip) => {
    chip.addEventListener("click", () => {
      chip.parentElement.querySelectorAll(".chip").forEach((c) => c.classList.remove("on"));
      chip.classList.add("on");
    });
  });

  // Appearance mini-segs — visual only
  document.querySelectorAll(".mini-seg").forEach((seg) => {
    seg.querySelectorAll(".seg-item").forEach((item) => {
      item.addEventListener("click", () => {
        seg.querySelectorAll(".seg-item").forEach((i) => i.classList.remove("on"));
        item.classList.add("on");
      });
    });
  });

  showScreen("chat");
})();
