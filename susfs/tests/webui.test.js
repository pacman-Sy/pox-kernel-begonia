// Test harness for the native SUSFS WebUI.
//
// Renders susfs/module/webroot/index.html in jsdom, injects a `ksu` bridge
// whose exec() runs in a sandbox module directory (same layout the real APatch
// bridge gives it: /data/adb/modules/<id>/conf + tools/ksu_susfs), and drives
// the UI the way a user would.
//
// The bridge path is redirected by bind-mounting the sandbox over the real
// /data/adb/modules/susfs_apatch for the duration of the test.

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const { JSDOM } = require("jsdom");

const SANDBOX = process.env.SANDBOX;
const WEBROOT = "/content/susfs-port/vendor/pox-kernel-begonia/susfs/module/webroot";
const fail = [];
const ok = [];

function check(name, cond, extra = "") {
  (cond ? ok : fail).push(name + (extra ? ` -> ${extra}` : ""));
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${extra ? ` -> ${extra}` : ""}`);
}

const STUB = `#!/bin/sh
case "$1" in
  show)
    case "$2" in
      version) [ -n "$SUSFS_TEST_NO_VERSION" ] && { echo "ksu_susfs: usage: ksu_susfs <CMD>"; exit 1; }; echo v2.3.0 ;;
      variant) echo NON-GKI ;;
      enabled_features) echo "CONFIG_KSU_SUSFS_SUS_PATH CONFIG_KSU_SUSFS_SUS_MOUNT CONFIG_KSU_SUSFS_SUS_MAP" ;;
    esac; exit 0 ;;
esac
echo "$*" >> ${SANDBOX}/kernel-calls.log
exit 0
`;

function setupSandbox() {
  fs.mkdirSync(path.join(SANDBOX, "conf"), { recursive: true });
  fs.mkdirSync(path.join(SANDBOX, "tools"), { recursive: true });
  const tool = path.join(SANDBOX, "tools", "ksu_susfs");
  fs.writeFileSync(tool, STUB.replace("${SANDBOX}", SANDBOX));
  fs.chmodSync(tool, 0o755);
  fs.writeFileSync(path.join(SANDBOX, "conf", "sus_path.txt"), "# comment line\n/data/adb/modules\n");
  fs.writeFileSync(path.join(SANDBOX, "conf", "sus_kstat.txt"), "");
  fs.writeFileSync(path.join(SANDBOX, "conf", "sus_map.txt"), "");
  fs.writeFileSync(path.join(SANDBOX, "conf", "open_redirect.txt"), "");
  fs.writeFileSync(path.join(SANDBOX, "conf", "enable_log.txt"), "0\n");
  fs.writeFileSync(path.join(SANDBOX, "conf", "uname.txt"), "# release|version\n");
  fs.writeFileSync(path.join(SANDBOX, "conf", "fake_cmdline_path.txt"), `${SANDBOX}/conf/fake_cmdline.txt\n`);
  fs.writeFileSync(path.join(SANDBOX, "conf", "fake_cmdline.txt"), "androidboot.verifiedbootstate=orange\n");
  // action.sh: record that it ran
  fs.writeFileSync(
    path.join(SANDBOX, "action.sh"),
    `#!/bin/sh\necho applied >> ${SANDBOX}/action.log\nexit 0\n`
  );
  fs.chmodSync(path.join(SANDBOX, "action.sh"), 0o755);
  fs.writeFileSync(path.join(SANDBOX, "action.log"), "");
  fs.writeFileSync(path.join(SANDBOX, "kernel-calls.log"), "");
  // the tool path inside app.js is absolute; point the sandbox at it
  return tool;
}

// The UI hardcodes MODDIR/TOOL as absolute device paths.  Rather than patch
// app.js, mount the sandbox at that path (needs root; we already are).
function mountSandbox() {
  // This sandbox blocks bind mounts, so always rewrite the absolute device
  // paths in app.js for the test run.  Same code path as a real device, only
  // the module directory differs.
  return false;
}

async function main() {
  setupSandbox();
  const mounted = mountSandbox();

  const html = fs.readFileSync(path.join(WEBROOT, "index.html"), "utf8");
  const js = fs.readFileSync(path.join(WEBROOT, "app.js"), "utf8");

  const dom = new JSDOM(html, { runScripts: "outside-only", url: "file:///webroot/index.html" });
  const { window } = dom;

  const calls = [];
  window.ksu = {
    exec(cmd) {
      calls.push(cmd);
      try {
        return execSync(cmd, { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
      } catch (e) {
        return "";
      }
    },
    toast(m) {
      window.__lastToast = m;
    },
  };

  if (!mounted) {
    // rewrite the absolute device paths to the sandbox for the test run
    const patched = js.split("/data/adb/modules/susfs_apatch").join(SANDBOX);
    window.eval(patched);
  } else {
    window.eval(js);
  }
  window.document.dispatchEvent(new window.Event("DOMContentLoaded"));
  await new Promise((r) => setTimeout(r, 300));

  const $ = (s) => window.document.querySelector(s);
  const $$ = (s) => [...window.document.querySelectorAll(s)];
  const conf = (f) => fs.readFileSync(path.join(SANDBOX, "conf", f), "utf8");

  // ── status ───────────────────────────────────────────────
  check("status shows kernel version", $("#stVersion").textContent.trim() === "v2.3.0", $("#stVersion").textContent);
  check("variant parsed", $("#stVariant").textContent.trim() === "NON-GKI", $("#stVariant").textContent);
  check(
    "features listed",
    $("#stFeatures").innerHTML.includes("CONFIG_KSU_SUSFS_SUS_PATH"),
    $("#stFeatures").textContent.trim().slice(0, 40)
  );
  check("mount count rendered", /^\d+$/.test($("#stMounts").textContent.trim()), $("#stMounts").textContent);
  check("kallsyms row rendered", $("#stKallsyms").textContent.trim().length > 0, $("#stKallsyms").textContent.trim());

  // ── comment lines are not treated as entries ─────────────
  check("comment lines filtered out", $("#listPaths").children.length === 1, `${$("#listPaths").children.length} rows`);
  check(
    "existing entry rendered",
    $("#listPaths").textContent.includes("/data/adb/modules"),
    $("#listPaths").textContent.trim()
  );

  // ── add a path ───────────────────────────────────────────
  $("#pathInput").value = "/data/local/tmp/probe with space";
  $('[data-add="paths"]').click();
  await new Promise((r) => setTimeout(r, 200));
  check("path appended to config", conf("sus_path.txt").includes("probe with space"), conf("sus_path.txt").trim().split("\n").pop());
  check("action.sh ran after add", fs.readFileSync(path.join(SANDBOX, "action.log"), "utf8").trim().length > 0);
  check("list shows the new path", $("#listPaths").textContent.includes("probe with space"));

  // ── shell metacharacters must not escape the quoting ─────
  $("#pathInput").value = "/tmp/x'; touch /tmp/opencode/uitest/PWNED; echo '";
  $('[data-add="paths"]').click();
  await new Promise((r) => setTimeout(r, 200));
  check("injection attempt did not execute", !fs.existsSync("/tmp/opencode/uitest/PWNED"));
  check("injection stored literally", conf("sus_path.txt").includes("touch /tmp/opencode/uitest/PWNED"));

  // ── remove it again ──────────────────────────────────────
  const rows = $$("#listPaths li").length;
  $$("#listPaths li")[rows - 1].querySelector("button.del").click();
  await new Promise((r) => setTimeout(r, 200));
  check("entry removed from config", !conf("sus_path.txt").includes("PWNED"));
  check("entry removed from list", !$("#listPaths").textContent.includes("PWNED"));

  // ── kstat ────────────────────────────────────────────────
  $("#kstatPath").value = "/system/etc/hosts";
  $("#kstatIno").value = "1234";
  $("#kstatSize").value = "42";
  $('[data-add="kstat"]').onclick();
  await new Promise((r) => setTimeout(r, 200));
  check(
    "kstat line has defaults filled in",
    conf("sus_kstat.txt").trim() === "/system/etc/hosts 1234 default default 42",
    conf("sus_kstat.txt").trim()
  );
  $("#btnKstatApply").click();
  await new Promise((r) => setTimeout(r, 200));
  const kc = fs.readFileSync(path.join(SANDBOX, "kernel-calls.log"), "utf8");
  check("add_sus_kstat issued", kc.includes("add_sus_kstat /system/etc/hosts"), kc.trim().split("\n")[0] || "");
  check("update_sus_kstat issued", kc.includes("update_sus_kstat /system/etc/hosts"));

  // ── redirect ─────────────────────────────────────────────
  $("#rdTarget").value = "/system/etc/hosts";
  $("#rdTo").value = "/data/local/tmp/hosts";
  $("#rdScheme").value = "3";
  $('[data-add="redirect"]').onclick();
  await new Promise((r) => setTimeout(r, 200));
  check(
    "redirect line written with scheme",
    conf("open_redirect.txt").trim() === "/system/etc/hosts /data/local/tmp/hosts 3",
    conf("open_redirect.txt").trim()
  );

  // ── uname ────────────────────────────────────────────────
  $("#unameRelease").value = "4.14.317";
  $("#unameVersion").value = "#1 SMP PREEMPT";
  $("#btnUname").click();
  await new Promise((r) => setTimeout(r, 200));
  check("uname saved as release|version", conf("uname.txt").trim() === "4.14.317|#1 SMP PREEMPT", conf("uname.txt").trim());

  // ── cmdline ──────────────────────────────────────────────
  check("cmdline textarea loaded from fake file", $("#cmdlineText").value.includes("verifiedbootstate=orange"), $("#cmdlineText").value.trim());
  $("#cmdlineText").value = "androidboot.verifiedbootstate=green\n";
  $("#btnCmdlineApply").click();
  await new Promise((r) => setTimeout(r, 200));
  check(
    "cmdline file rewritten",
    fs.readFileSync(path.join(SANDBOX, "conf", "fake_cmdline.txt"), "utf8").includes("green"),
    fs.readFileSync(path.join(SANDBOX, "conf", "fake_cmdline.txt"), "utf8").trim()
  );

  // ── log toggle ───────────────────────────────────────────
  $("#tglLog").checked = true;
  $("#tglLog").dispatchEvent(new window.Event("change"));
  await new Promise((r) => setTimeout(r, 200));
  check("log toggle persisted", conf("enable_log.txt").trim() === "1", conf("enable_log.txt").trim());

  // ── avc disabled when not compiled in ────────────────────
  check("avc switch disabled (feature absent)", $("#tglAvc").disabled === true);
  check("avc explains why", $("#avcNote").textContent.includes("Not compiled in"), $("#avcNote").textContent);

  // ── logs tab ─────────────────────────────────────────────
  $("#btnLogModule").click();
  await new Promise((r) => setTimeout(r, 150));
  check("module log pane filled", $("#logOut").textContent.length > 0);

  // ── 1.3.8 tool must not look healthy ─────────────────────
  const dom2 = new JSDOM(html, { runScripts: "outside-only", url: "file:///webroot/index.html" });
  dom2.window.ksu = {
    exec(cmd) {
      if (cmd.includes("show version")) return "ksu_susfs: usage: ksu_susfs <CMD> [CMD options]\nksu_susfs:    add_sus_path ...";
      return "";
    },
    toast() {},
  };
  const patched2 = mounted ? js : js.split("/data/adb/modules/susfs_apatch").join(SANDBOX);
  dom2.window.eval(patched2);
  dom2.window.document.dispatchEvent(new dom2.window.Event("DOMContentLoaded"));
  await new Promise((r) => setTimeout(r, 200));
  check(
    "1.3.8 tool flagged as wrong tool",
    dom2.window.document.querySelector("#stVersion").textContent.trim() === "wrong tool (susfs 1.3.8 build)",
    dom2.window.document.querySelector("#stVersion").textContent.trim().split("\n")[0]
  );
  check(
    "1.3.8 tool -> no features claimed",
    dom2.window.document.querySelector("#hdrFeatures").textContent.includes("not answering"),
    dom2.window.document.querySelector("#hdrFeatures").textContent.trim()
  );

  console.log(`\n${ok.length} passed, ${fail.length} failed`);
  if (fail.length) {
    console.log("failed:\n  " + fail.join("\n  "));
    process.exit(1);
  }
}

main().catch((e) => {
  console.error("harness error:", e);
  process.exit(2);
});