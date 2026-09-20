// Only user-driven navigation checks for updates; never poll or reload an open page.
const CURRENT_VERSION = "3.1.23";
const RELEASE_FILE = "./version.json";
const URL_MARKER = "psm_version";
const MIN_CHECK_GAP_MS = 60_000; // Network throttling, NOT a periodic timer.
let lastCheck = 0;
let checking = null;
let availableVersion = null;
let dismissedVersion = null;

async function fetchLatest() {
  const url = new URL(RELEASE_FILE, document.baseURI);
  url.searchParams.set("t", String(Date.now()));
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 3500);
  try {
    const response = await fetch(url, {cache: "no-store", signal: controller.signal});
    if (!response.ok) throw new Error(`Version check HTTP ${response.status}`);
    const metadata = await response.json();
    return typeof metadata?.version === "string" && /^\d+\.\d+\.\d+$/.test(metadata.version) ? metadata.version : null;
  } finally {
    clearTimeout(timeout);
  }
}

function reloadTo(version) {
  // A unique URL obtains the new index.html without losing its original query parameters.
  const url = new URL(location.href);
  url.searchParams.set(URL_MARKER, version);
  location.replace(url.href);
}

// Return true only when navigation to a fresh copy was initiated.
export async function checkOnLaunch() {
  try {
    const latest = await fetchLatest();
    if (!latest || latest === CURRENT_VERSION) return false;
    // This same target has already been tried. Prevent an infinite reload loop when
    // GitHub Pages serves stale HTML during a deployment or through an upstream cache.
    if (new URL(location.href).searchParams.get(URL_MARKER) === latest) return false;
    reloadTo(latest);
    return true;
  } catch (error) {
    console.warn("Version check skipped; starting existing application:", error);
    return false;
  }
}

function displayUpdate(version) {
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
    if (latest && latest !== CURRENT_VERSION) displayUpdate(latest);
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
    if (!availableVersion) return;
    // Only a deliberate click updates a page that is already open.
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
