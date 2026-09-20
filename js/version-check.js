// Release metadata is checked only on launch and after intentional app navigation.
// Keep the running version in index.html; this module is cached independently.
const CURRENT_VERSION = document.querySelector('meta[name="psm-app-version"]')?.content;
const RELEASE_FILE = "./version.json";
const URL_MARKER = "psm_version";
const MIN_CHECK_GAP_MS = 60_000; // Rate-limit navigation checks; this is not a timer.
const VERSION_PATTERN = /^\d+\.\d+\.\d+$/;
let lastCheck = 0;
let checking = null;
let availableVersion = null;
let dismissedVersion = null;

function compareVersions(a, b) {
  if (!VERSION_PATTERN.test(a || "") || !VERSION_PATTERN.test(b || "")) return null;
  const left = a.split(".").map(Number);
  const right = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) {
    if (left[i] !== right[i]) return left[i] > right[i] ? 1 : -1;
  }
  return 0;
}

function isNewer(version) {
  return compareVersions(version, CURRENT_VERSION) === 1;
}

async function fetchLatest() {
  const url = new URL(RELEASE_FILE, document.baseURI);
  url.searchParams.set("t", String(Date.now()));
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3500);
  try {
    const response = await fetch(url, {cache: "no-store", signal: controller.signal});
    if (!response.ok) throw new Error(`Version check HTTP ${response.status}`);
    const metadata = await response.json();
    return typeof metadata?.version === "string" && VERSION_PATTERN.test(metadata.version) ? metadata.version : null;
  } finally {
    clearTimeout(timeout);
  }
}

function reloadTo(version) {
  const url = new URL(location.href);
  url.searchParams.set(URL_MARKER, version);
  location.replace(url.href);
}

export async function checkOnLaunch() {
  try {
    const latest = await fetchLatest();
    // A stale version.json must never make a newer page reload or show an update notice.
    if (!isNewer(latest)) return false;
    // Avoid a reload loop while the new index.html is still propagating on the host.
    if (new URL(location.href).searchParams.get(URL_MARKER) === latest) return false;
    reloadTo(latest);
    return true;
  } catch (error) {
    console.warn("Version check skipped; starting existing application:", error);
    return false;
  }
}

function displayUpdate(version) {
  if (!isNewer(version)) return;
  availableVersion = version;
  const notice = document.getElementById("appUpdateNotice");
  const menu = document.getElementById("appUpdateMenu");
  if (menu) {
    menu.hidden = false;
    menu.querySelector("small").textContent = `最新版 v${version} に更新できます`;
  }
  if (notice && dismissedVersion !== version) {
    notice.hidden = false;
    notice.querySelector("small").textContent = `最新版 v${version} が公開されました。操作が終わったら更新してください。`;
  }
}

async function checkWhileOpen() {
  if (availableVersion || checking || document.visibilityState !== "visible") return;
  if (Date.now() - lastCheck < MIN_CHECK_GAP_MS) return;
  lastCheck = Date.now();
  checking = fetchLatest();
  try {
    const latest = await checking;
    if (isNewer(latest)) displayUpdate(latest);
  } catch (error) {
    console.warn("Update notification check skipped:", error);
  } finally {
    checking = null;
  }
}

export function watchForUpdates() {
  document.getElementById("appUpdateLater")?.addEventListener("click", () => {
    dismissedVersion = availableVersion;
    document.getElementById("appUpdateNotice").hidden = true;
  });
  const applyUpdate = () => {
    if (!isNewer(availableVersion)) return;
    reloadTo(availableVersion);
  };
  document.getElementById("appUpdateNow")?.addEventListener("click", applyUpdate);
  document.getElementById("appUpdateMenu")?.addEventListener("click", applyUpdate);
  document.querySelectorAll(".tabs button[data-tab]").forEach(button => {
    button.addEventListener("click", () => { void checkWhileOpen(); });
  });
  document.getElementById("menuButton")?.addEventListener("click", () => {
    void checkWhileOpen();
  });
}
