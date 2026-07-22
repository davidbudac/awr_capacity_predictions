/* =====================================================================
   AWR Capacity Predictions — documentation site behaviour.
   Runs on every page from an identical markup shell:
     - marks the current page in the sidebar
     - builds the "On this page" list + scrollspy from section headings
     - builds the prev / next pager
     - drives the persisted light / dark theme toggle
   No dependencies. Progressive enhancement: without JS the plain links
   and system-preference theme still work.
   ===================================================================== */
(function () {
  "use strict";

  // Canonical page order — drives current-page marking and the pager.
  var PAGES = [
    { file: "index.html",     label: "Introduction" },
    { file: "concepts.html",  label: "How it works" },
    { file: "install.html",   label: "Installation" },
    { file: "usage.html",     label: "Usage" },
    { file: "testing.html",   label: "Testing" },
    { file: "reference.html", label: "Reference" }
  ];

  function currentFile() {
    var path = location.pathname;
    var f = path.substring(path.lastIndexOf("/") + 1);
    return f === "" ? "index.html" : f;
  }

  var here = currentFile();

  // ---- 1. mark the active page in the sidebar -----------------------
  var navLinks = [].slice.call(document.querySelectorAll(".nav-page"));
  navLinks.forEach(function (a) {
    var target = (a.getAttribute("href") || "").split("/").pop();
    if (target === here) {
      a.classList.add("current");
      a.setAttribute("aria-current", "page");
    }
  });

  // ---- 2. build "On this page" + scrollspy --------------------------
  var toc = document.getElementById("toc");
  var headed = [].slice.call(
    document.querySelectorAll(".main .section-head[id], .main .hero[id]")
  );
  if (toc && headed.length >= 2) {
    var group = document.createElement("div");
    group.className = "toc__group";
    group.textContent = "On this page";
    toc.appendChild(group);

    var map = {};
    headed.forEach(function (el) {
      var h = el.querySelector("h1, h2");
      if (!h) return;
      var a = document.createElement("a");
      a.href = "#" + el.id;
      a.textContent = h.textContent.trim();
      toc.appendChild(a);
      map[el.id] = a;
    });

    if ("IntersectionObserver" in window) {
      var obs = new IntersectionObserver(
        function (entries) {
          entries.forEach(function (e) {
            if (e.isIntersecting) {
              var link = map[e.target.id];
              if (!link) return;
              [].forEach.call(toc.querySelectorAll("a"), function (x) {
                x.classList.remove("active");
              });
              link.classList.add("active");
              link.scrollIntoView({ block: "nearest", inline: "nearest" });
            }
          });
        },
        { rootMargin: "-8% 0px -80% 0px", threshold: 0 }
      );
      headed.forEach(function (el) { obs.observe(el); });
    }
  }

  // ---- 3. build prev / next pager -----------------------------------
  var pager = document.getElementById("pager");
  if (pager) {
    var idx = -1;
    for (var i = 0; i < PAGES.length; i++) {
      if (PAGES[i].file === here) { idx = i; break; }
    }
    if (idx !== -1) {
      var prev = idx > 0 ? PAGES[idx - 1] : null;
      var next = idx < PAGES.length - 1 ? PAGES[idx + 1] : null;
      if (prev) pager.appendChild(pagerLink(prev, "prev", "← Previous"));
      else pager.appendChild(document.createElement("span")); // keep next right-aligned
      if (next) pager.appendChild(pagerLink(next, "next", "Next →"));
    }
    if (!pager.children.length) pager.style.display = "none";
  }

  function pagerLink(page, cls, dir) {
    var a = document.createElement("a");
    a.href = page.file;
    a.className = cls;
    var d = document.createElement("span");
    d.className = "dir";
    d.textContent = dir;
    var l = document.createElement("span");
    l.className = "lbl";
    l.textContent = page.label;
    a.appendChild(d);
    a.appendChild(l);
    return a;
  }

  // ---- 4. theme toggle (persisted; cycles system -> light -> dark) --
  var root = document.documentElement;
  var meta = document.querySelector('meta[name="color-scheme"]');
  var btn = document.getElementById("themeBtn");

  function labelFor(theme) {
    return theme === "dark" ? "● Dark"
         : theme === "light" ? "○ Light"
         : "◐ System";
  }
  function applyTheme(theme) {
    if (theme === "light" || theme === "dark") {
      root.setAttribute("data-theme", theme);
      if (meta) meta.setAttribute("content", theme);
    } else {
      root.removeAttribute("data-theme");
      if (meta) meta.setAttribute("content", "light dark");
    }
    if (btn) {
      btn.textContent = labelFor(theme);
      btn.setAttribute("aria-label", "Theme: " + (theme || "system") + ". Click to change.");
    }
  }

  // Reflect whatever the no-FOUC inline head script already applied.
  var stored = null;
  try { stored = localStorage.getItem("cap-theme"); } catch (e) {}
  applyTheme(stored || "");

  if (btn) {
    btn.addEventListener("click", function () {
      var cur = root.getAttribute("data-theme"); // "" | light | dark
      var nextT = cur === "dark" ? "" : cur === "light" ? "dark" : "light";
      applyTheme(nextT);
      try {
        if (nextT) localStorage.setItem("cap-theme", nextT);
        else localStorage.removeItem("cap-theme");
      } catch (e) {}
    });
  }
})();
