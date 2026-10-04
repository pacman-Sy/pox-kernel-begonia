/*
 * Pox Kernel downloads page.
 * Static, dependency-free. Reads the GitHub Releases API for this repo.
 */
(function () {
  "use strict";

  var OWNER = "pacman-Sy";
  var REPO = "pox-kernel-begonia";
  var API = "https://api.github.com/repos/" + OWNER + "/" + REPO + "/releases?per_page=100";

  var ZIP_RE = /^(Pox-.*\.zip)$/i;

  var $ = function (id) { return document.getElementById(id); };

  var grid = $("grid");
  var statusEl = $("status");
  var emptyEl = $("empty");
  var searchEl = $("search");
  var chipsEl = $("branchChips");
  var hidePreEl = $("hidePre");
  var tpl = $("cardTpl");

  var state = { releases: [], branch: "all", q: "", hidePre: false };

  /* ---------------------------------------------------------------- utils */

  function humanSize(bytes) {
    if (!bytes && bytes !== 0) return "";
    var u = ["B", "KB", "MB", "GB"], i = 0, n = bytes;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return (i === 0 ? n : n.toFixed(1)) + " " + u[i];
  }

  function timeAgo(iso) {
    var then = new Date(iso).getTime();
    if (isNaN(then)) return "";
    var s = Math.max(0, (Date.now() - then) / 1000);
    var table = [
      [31536000, "y"], [2592000, "mo"], [604800, "w"],
      [86400, "d"], [3600, "h"], [60, "m"]
    ];
    for (var i = 0; i < table.length; i++) {
      if (s >= table[i][0]) return Math.floor(s / table[i][0]) + table[i][1] + " ago";
    }
    return "just now";
  }

  // Tags look like: Pox-<version>-<Edition>-<branch>-<sha>
  // The branch may contain hyphens and slashes (e.g. feature/nomount-vfs-integration),
  // so it is matched greedily and anchored on the trailing hex sha.
  function parseTag(tag) {
    var m = /^Pox-([^-]+)-([^-]+)-(.+)-([0-9a-f]{7,40})$/.exec(tag || "");
    if (!m) return { version: "", edition: "Release", branch: "other", sha: "" };
    return { version: m[1], edition: m[2], branch: m[3], sha: m[4] };
  }

  function el(tag, cls, text) {
    var n = document.createElement(tag);
    if (cls) n.className = cls;
    if (text != null) n.textContent = text;
    return n;
  }

  /* ----------------------------------------------------------------- data */

  function load() {
    statusEl.className = "status";
    statusEl.textContent = "Loading releases…";
    emptyEl.hidden = true;
    grid.textContent = "";

    for (var i = 0; i < 3; i++) grid.appendChild(el("div", "skeleton"));

    fetch(API, { headers: { Accept: "application/vnd.github+json" } })
      .then(function (r) {
        if (!r.ok) throw new Error("HTTP " + r.status);
        return r.json();
      })
      .then(function (data) {
        state.releases = Array.isArray(data) ? data : [];
        buildChips();
        render();
      })
      .catch(function (err) {
        grid.textContent = "";
        statusEl.className = "status error";
        statusEl.textContent =
          "Could not load releases (" + err.message + "). Check your connection and press Refresh.";
      });
  }

  /* ----------------------------------------------------------------- chips */

  function buildChips() {
    var counts = {}, order = [];
    state.releases.forEach(function (r) {
      var b = parseTag(r.tag_name).branch;
      if (!(b in counts)) { counts[b] = 0; order.push(b); }
      counts[b]++;
    });

    chipsEl.textContent = "";
    addChip("all", "All", state.releases.length);
    order.sort().forEach(function (b) { addChip(b, b, counts[b]); });
  }

  function addChip(value, label, count) {
    var b = el("button", "chip", label + "  " + count);
    b.type = "button";
    b.setAttribute("aria-pressed", String(state.branch === value));
    b.dataset.branch = value;
    b.addEventListener("click", function () {
      state.branch = value;
      Array.prototype.forEach.call(chipsEl.children, function (c) {
        c.setAttribute("aria-pressed", String(c.dataset.branch === value));
      });
      render();
    });
    chipsEl.appendChild(b);
  }

  /* --------------------------------------------------------------- filter */

  function visible() {
    var q = state.q.trim().toLowerCase();
    return state.releases.filter(function (r) {
      var info = parseTag(r.tag_name);
      if (state.branch !== "all" && info.branch !== state.branch) return false;
      if (state.hidePre && r.prerelease) return false;
      if (!q) return true;
      return (
        (r.tag_name || "").toLowerCase().indexOf(q) !== -1 ||
        (r.name || "").toLowerCase().indexOf(q) !== -1 ||
        info.edition.toLowerCase().indexOf(q) !== -1 ||
        info.branch.toLowerCase().indexOf(q) !== -1
      );
    });
  }

  /* ---------------------------------------------------------------- cards */

  function render() {
    var list = visible();
    grid.textContent = "";

    if (!state.releases.length) {
      statusEl.textContent = "This repository has no published releases yet.";
      return;
    }
    if (!list.length) {
      statusEl.textContent = list.length + " of " + state.releases.length + " releases";
      emptyEl.hidden = false;
      return;
    }

    statusEl.textContent =
      list.length + " release" + (list.length === 1 ? "" : "s") +
      " shown" + (list.length !== state.releases.length
        ? " of " + state.releases.length : "");

    emptyEl.hidden = true;
    list.forEach(function (r) { grid.appendChild(card(r)); });
  }

  function card(r) {
    var info = parseTag(r.tag_name);
    var node = tpl.content.firstElementChild.cloneNode(true);

    node.querySelector(".edition").textContent = info.edition;
    node.querySelector(".tag").textContent = r.tag_name || r.name || "(untitled)";

    var flags = node.querySelector(".card-flags");
    if (r.latest) flags.appendChild(el("span", "flag latest", "Latest"));
    if (r.prerelease) flags.appendChild(el("span", "flag pre", "Pre-release"));

    var meta = node.querySelector(".meta");
    if (info.sha) meta.appendChild(el("span", "sha", info.sha.slice(0, 9)));
    var when = timeAgo(r.published_at || r.created_at);
    if (when) meta.appendChild(el("span", "when", when));

    // assets
    var zip = null;
    var ul = node.querySelector(".assets");
    (r.assets || []).forEach(function (a) {
      var row = el("li");
      row.appendChild(el("span", "asset-name", a.name));

      var right = el("span");
      right.style.display = "flex";
      right.style.gap = "10px";
      right.style.alignItems = "center";

      var sz = humanSize(a.size);
      if (sz) right.appendChild(el("span", "asset-size", sz));

      var dl = el("a", "asset-dl", "Get");
      dl.href = a.browser_download_url;
      dl.setAttribute("download", "");
      dl.rel = "noopener";
      right.appendChild(dl);

      row.appendChild(right);
      ul.appendChild(row);

      if (!zip && ZIP_RE.test(a.name)) zip = a;
    });

    // primary action
    var cta = node.querySelector(".download-zip");
    if (zip) {
      cta.href = zip.browser_download_url;
      cta.setAttribute("download", "");
      cta.rel = "noopener";
      cta.textContent = "Download flashable ZIP  (" + humanSize(zip.size) + ")";
    } else {
      cta.setAttribute("aria-disabled", "true");
      cta.removeAttribute("href");
      cta.textContent = "No flashable ZIP";
      cta.style.cursor = "default";
    }

    var notes = node.querySelector(".release-link");
    notes.href = r.html_url;
    notes.rel = "noopener";

    return node;
  }

  /* ---------------------------------------------------------------- wiring */

  var debounce;
  searchEl.addEventListener("input", function () {
    clearTimeout(debounce);
    debounce = setTimeout(function () {
      state.q = searchEl.value;
      render();
    }, 130);
  });

  hidePreEl.addEventListener("change", function () {
    state.hidePre = hidePreEl.checked;
    render();
  });

  $("refreshBtn").addEventListener("click", load);

  // theme
  var themeBtn = $("themeBtn");
  var stored = null;
  try { stored = localStorage.getItem("pox-theme"); } catch (e) {}
  var prefersLight = window.matchMedia &&
    window.matchMedia("(prefers-color-scheme: light)").matches;
  apply(stored || (prefersLight ? "light" : "dark"));

  function apply(mode) {
    document.documentElement.setAttribute("data-theme", mode);
    themeBtn.querySelector("[data-theme-icon]").textContent = mode === "dark" ? "☀" : "☾";
    try { localStorage.setItem("pox-theme", mode); } catch (e) {}
  }

  themeBtn.addEventListener("click", function () {
    var cur = document.documentElement.getAttribute("data-theme");
    apply(cur === "dark" ? "light" : "dark");
  });

  load();
})();