/* SUSFS for APatch - native web UI
 *
 * Everything here goes through the `ksu` bridge APatch injects into module
 * WebViews (addJavascriptInterface(webViewInterface, "ksu")).  `ksu.exec(cmd)`
 * runs in a root shell and returns stdout, so no async plumbing is needed.
 * It is only available inside APatch's manager; opening index.html in a plain
 * browser shows a banner instead of failing silently.
 */

const MODDIR = "/data/adb/modules/susfs_apatch";
const CONF = MODDIR + "/conf";
const TOOL = MODDIR + "/tools/ksu_susfs";
const LOG = MODDIR + "/susfs.log";

/* POSIX single quoting: everything the user types ends up inside a shell
 * command, so it has to survive quotes, spaces, $, ; and newlines. */
const q = (s) => "'" + String(s).replace(/'/g, "'\\''") + "'";

function exec(cmd) {
  if (typeof ksu === "undefined") throw new Error("no ksu bridge");
  return ksu.exec(cmd) || "";
}

const read = (name) =>
  exec(`cat ${q(CONF + "/" + name)} 2>/dev/null`).split("\n");

/* config files keep one entry per line, '#' comments and blanks ignored */
const entries = (name) =>
  read(name)
    .map((l) => l.replace(/\r$/, ""))
    .filter((l) => l.trim() && !l.trim().startsWith("#"));

const write = (name, lines) =>
  exec(`{ printf '%s\\n' ${lines.map(q).join(" ") || '""'}; } > ${q(CONF + "/" + name)}`);

const append = (name, line) => exec(`printf '%s\\n' ${q(line)} >> ${q(CONF + "/" + name)}`);

const remove = (name, line) =>
  exec(
    `grep -F -x -v ${q(line)} ${q(CONF + "/" + name)} > ${q(CONF + "/" + name + ".tmp")} 2>/dev/null; mv ${q(CONF + "/" + name + ".tmp")} ${q(CONF + "/" + name)}`
  );

const toast = (m) => {
  try {
    ksu.toast(m);
  } catch (_) {}
  console.log(m);
};

function busy(on) {
  document.getElementById("busy").classList.toggle("hidden", !on);
}

/* Every mutation ends with an apply: the kernel only changes state when the
 * tool is run, so editing a file alone does nothing until then. */
function apply(what) {
  busy(true);
  try {
    const out = exec(`sh ${q(MODDIR + "/action.sh")}`);
    busy(false);
    refreshStatus();
    if (out.includes("ERROR")) toast("susfs: " + out.split("\n").pop());
    else toast(`susfs: ${what} applied`);
  } catch (e) {
    busy(false);
    toast("susfs: " + e.message);
  }
}

/* ── lists ──────────────────────────────────────────────────── */
function renderList(el, lines, onRemove) {
  el.innerHTML = "";
  if (!lines.length) {
    el.innerHTML = '<li class="empty">nothing configured</li>';
    return;
  }
  lines.forEach((line) => {
    const li = document.createElement("li");
    const span = document.createElement("span");
    span.className = "entry";
    span.textContent = line;
    const btn = document.createElement("button");
    btn.textContent = "✕";
    btn.className = "del";
    btn.onclick = () => {
      onRemove(line);
    };
    li.append(span, btn);
    el.append(li);
  });
}

function renderAllLists() {
  renderList(document.getElementById("listPaths"), entries("sus_path.txt"), (line) => {
    remove("sus_path.txt", line);
    renderAllLists();
    apply("remove sus_path");
  });

  renderList(document.getElementById("listKstat"), entries("sus_kstat.txt"), (line) => {
    remove("sus_kstat.txt", line);
    renderAllLists();
    apply("remove sus_kstat");
  });

  renderList(document.getElementById("listMaps"), entries("sus_map.txt"), (line) => {
    remove("sus_map.txt", line);
    renderAllLists();
    apply("remove sus_map");
  });

  renderList(document.getElementById("listRedirect"), entries("open_redirect.txt"), (line) => {
    remove("open_redirect.txt", line);
    renderAllLists();
    apply("remove open_redirect");
  });

  /* spoof fields */
  const u = (entries("uname.txt")[0] || "").split("|");
  document.getElementById("unameRelease").value = u[0] && u[0] !== "#" ? u[0] : "";
  document.getElementById("unameVersion").value = u[1] || "";
  document.getElementById("tglLog").checked = (entries("enable_log.txt")[0] || "0") === "1";
  const path = entries("fake_cmdline_path.txt")[0];
  document.getElementById("cmdlineText").value = path
    ? exec(`cat ${q(path)} 2>/dev/null`)
    : exec("cat /proc/cmdline 2>/dev/null");
}

/* ── status ─────────────────────────────────────────────────── */
function refreshStatus() {
  let version = "";
  try {
    version = exec(`${q(TOOL)} show version 2>/dev/null | head -n1`).trim();
  } catch (_) {}

  /* The 1.3.8 tool answers 'show' with its usage text; that is not a version. */
  const hasV2 = /^v[0-9]/.test(version);

  document.getElementById("hdrVersion").textContent = hasV2 ? version : "—";
  document.getElementById("stVersion").textContent = hasV2
    ? version
    : version
    ? "wrong tool (susfs 1.3.8 build)"
    : "not detected";

  document.getElementById("stVariant").textContent = hasV2
    ? exec(`${q(TOOL)} show variant 2>/dev/null`).trim()
    : "n/a";
  document.getElementById("stTool").textContent = TOOL;

  const features = hasV2
    ? exec(`${q(TOOL)} show enabled_features 2>/dev/null`).split(/\s+/).filter(Boolean)
    : [];
  document.getElementById("stFeatures").innerHTML = features.length
    ? features.map((f) => `<li>${f.replace(/</g, "&lt;")}</li>`).join("")
    : "<li>none reported</li>";
  document.getElementById("hdrFeatures").textContent = features.length
    ? features.length + " features active"
    : "kernel side not answering";

  const mounts = exec("grep -c ' /data/adb' /proc/self/mounts 2>/dev/null").trim();
  document.getElementById("stMounts").textContent = mounts === "" ? "?" : mounts;

  /* avc spoofing is a compile time option; say so instead of offering a dead switch */
  const hasAvc = features.some((f) => f.includes("AVC"));
  const avc = document.getElementById("tglAvc");
  avc.disabled = !hasAvc;
  document.getElementById("avcNote").textContent = hasAvc
    ? "Drops *all* SELinux denied records, including genuine policy violations."
    : "Not compiled in (CONFIG_KSU_SUSFS_ENABLE_AVC_LOG_SPOOFING is off).";
}

/* ── wiring ─────────────────────────────────────────────────── */
function addFrom(inputId, file, transform) {
  const el = document.getElementById(inputId);
  const value = el.value.trim();
  if (!value) return;
  append(file, transform ? transform(value) : value);
  el.value = "";
  renderAllLists();
  apply("add to " + file);
}

function init() {
  if (typeof ksu === "undefined") {
    document.body.innerHTML =
      '<div class="nobridge">This page is the SUSFS module WebUI.<br><br>' +
      "Open it from the APatch manager: Modules → SUSFS for APatch.</div>";
    return;
  }

  document.querySelectorAll("#tabs button").forEach((b) => {
    b.onclick = () => {
      document.querySelectorAll("#tabs button").forEach((x) => x.classList.remove("active"));
      document.querySelectorAll(".tab").forEach((x) => x.classList.remove("active"));
      b.classList.add("active");
      document.getElementById(b.dataset.tab).classList.add("active");
    };
  });

  document.querySelector('[data-add="paths"]').onclick = () => addFrom("pathInput", "sus_path.txt");
  document.querySelector('[data-add="maps"]').onclick = () => addFrom("mapInput", "sus_map.txt");

  document.querySelector('[data-add="kstat"]').onclick = () => {
    const path = document.getElementById("kstatPath").value.trim();
    if (!path) return;
    const f = (id) => document.getElementById(id).value.trim() || "default";
    addFrom("kstatPath", "sus_kstat.txt", () =>
      [path, f("kstatIno"), f("kstatDev"), f("kstatNlink"), f("kstatSize")].join(" ")
    );
  };

  document.querySelector('[data-add="redirect"]').onclick = () => {
    const from = document.getElementById("rdTarget").value.trim();
    const to = document.getElementById("rdTo").value.trim();
    if (!from || !to) return;
    const scheme = document.getElementById("rdScheme").value;
    append("open_redirect.txt", `${from} ${to} ${scheme}`);
    document.getElementById("rdTarget").value = "";
    document.getElementById("rdTo").value = "";
    renderAllLists();
    apply("add open_redirect");
  };

  document.getElementById("btnApply").onclick = () => apply("configuration");
  document.getElementById("btnRefreshStatus").onclick = refreshStatus;

  document.getElementById("btnKstatApply").onclick = () => {
    const lines = entries("sus_kstat.txt");
    if (!lines.length) return toast("susfs: no kstat entries");
    /* add_sus_kstat must run before the bind mount, update_sus_kstat after it;
     * running both now is what makes it work for files already in place. */
    exec(`while read -r line; do set -- $line; ${q(TOOL)} add_sus_kstat "$1" >/dev/null 2>&1; ${q(TOOL)} update_sus_kstat "$1" >/dev/null 2>&1; done < ${q(CONF + "/sus_kstat.txt")}`);
    toast(`susfs: kstat applied to ${lines.length} path(s)`);
  };

  document.getElementById("btnUname").onclick = () => {
    const rel = document.getElementById("unameRelease").value.trim();
    const ver = document.getElementById("unameVersion").value.trim();
    if (!rel && !ver) return toast("susfs: fill release and version");
    write("uname.txt", [`${rel}|${ver || "default"}`]);
    apply("uname spoof");
  };
  document.getElementById("btnUnameClear").onclick = () => {
    write("uname.txt", []);
    renderAllLists();
    apply("uname spoof");
  };

  const cmdPath = entries("fake_cmdline_path.txt")[0] || `${CONF}/fake_cmdline.txt`;
  document.getElementById("btnCmdlineApply").onclick = () => {
    const text = document.getElementById("cmdlineText").value;
    exec(`cat > ${q(cmdPath)} <<'SUSFS_EOF'\n${text}\nSUSFS_EOF`);
    write("fake_cmdline_path.txt", [cmdPath]);
    apply("cmdline spoof");
  };
  document.getElementById("btnCmdlineReset").onclick = () => {
    document.getElementById("cmdlineText").value = exec("cat /proc/cmdline 2>/dev/null");
  };

  document.getElementById("tglLog").onchange = (e) => {
    write("enable_log.txt", [e.target.checked ? "1" : "0"]);
    apply("kernel logging");
  };
  document.getElementById("tglAvc").onchange = (e) => {
    exec(`${q(TOOL)} enable_avc_log_spoofing ${e.target.checked ? 1 : 0}`);
    toast(`susfs: avc log spoofing ${e.target.checked ? "on" : "off"}`);
  };

  const showLog = (cmd) => {
    document.getElementById("logOut").textContent = exec(cmd) || "(empty)";
  };
  document.getElementById("btnLogModule").onclick = () => showLog(`tail -n 200 ${q(LOG)} 2>/dev/null`);
  document.getElementById("btnLogDmesg").onclick = () => showLog("dmesg 2>/dev/null | grep -i susfs | tail -n 200");
  document.getElementById("btnLogRefresh").onclick = () => {
    const active = document.querySelector("#tabs button.active");
    if (active && active.dataset.tab === "logs") showLog(`tail -n 200 ${q(LOG)} 2>/dev/null`);
  };

  refreshStatus();
  renderAllLists();
  showLog(`tail -n 100 ${q(LOG)} 2>/dev/null`);
}

document.addEventListener("DOMContentLoaded", init);