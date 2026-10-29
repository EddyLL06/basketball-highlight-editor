// BHE website: render download links and reveal sections as they enter the viewport.
const DOWNLOADS = {
  version: "Latest version",
  dlBase: "https://dl.envsystem.top",
  ossBase: "https://shengshengniannian.oss-cn-beijing.aliyuncs.com/shengshengniannian/basketball-highlight-editor/releases",
  ghBase: "https://github.com/fly7632785/basketball-highlight-editor/releases",
  files: {
    "mac-arm64": ["BHE-macos-arm64-latest.dmg"],
    "mac-x64": ["BHE-macos-x86_64-latest.dmg"],
    "win-x64": ["BHE-windows-x64-latest.zip"],
    "android-arm64": ["BHE-android-arm64-v8a-latest.apk"],
  },
  // Android OSS fallback stays separate from the Baby project's latest.apk object.
  direct: {
    "android-arm64": "https://oss.shengshengniannian.com/shengshengniannian/app/android/bhe/latest.apk",
  },
};

function fileNameMeta(name) {
  if (name.endsWith(".dmg")) return { label: "Download .dmg", sub: "Installer" };
  if (name.endsWith(".apk")) return { label: "Download .apk", sub: "Android package" };
  return { label: "Download .zip", sub: "Unzip and run" };
}

function renderDownloads() {
  const versionEl = document.getElementById("dl-version");
  if (versionEl) versionEl.textContent = DOWNLOADS.version;

  document.querySelectorAll(".dl-actions[data-os]").forEach((box) => {
    const files = DOWNLOADS.files[box.dataset.os] || [];
    files.forEach((name) => {
      const meta = fileNameMeta(name);
      const a = document.createElement("a");
      a.className = "btn btn-ball";
      a.href = `${DOWNLOADS.dlBase}/${name}`;
      a.dataset.primary = "1";
      a.textContent = meta.label;
      box.appendChild(a);
    });
    const gh = document.createElement("a");
    gh.className = "dl-link-gh";
    gh.href = DOWNLOADS.ghBase;
    gh.target = "_blank";
    gh.rel = "noopener";
    gh.textContent = "GitHub fallback";
    box.appendChild(gh);
    const mirror = document.createElement("a");
    mirror.className = "dl-link-gh";
    mirror.href = DOWNLOADS.direct[box.dataset.os] || `${DOWNLOADS.ossBase}/${files[0] || ""}`;
    mirror.rel = "noopener";
    mirror.textContent = "Mirror for mainland China";
    box.appendChild(mirror);
  });
}

function setupReveal() {
  const els = Array.from(document.querySelectorAll(".reveal"));
  if (!els.length) return;
  if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    els.forEach((el) => el.classList.add("in"));
    return;
  }
  const check = () => {
    const vh = window.innerHeight || document.documentElement.clientHeight || 800;
    const line = vh * 0.9;
    for (let i = els.length - 1; i >= 0; i--) {
      if (els[i].getBoundingClientRect().top < line) {
        els[i].classList.add("in");
        els.splice(i, 1);
      }
    }
  };
  window.addEventListener("scroll", check, { passive: true });
  window.addEventListener("resize", check, { passive: true });
  check();
}

renderDownloads();
setupReveal();

// Recommend a platform without leaving the page or starting a download.
function setupRecommendedDownload() {
  const ua = navigator.userAgent || "";
  let os = null;
  if (/Android/i.test(ua)) os = "android-arm64";
  else if (/Windows/i.test(ua)) os = "win-x64";
  else if (/Macintosh|Mac OS X/i.test(ua) && !/iPhone|iPad|iPod/i.test(ua)) os = "mac-arm64";
  const hero = document.getElementById("hero-download");
  const box = os && document.querySelector(`.dl-actions[data-os="${os}"]`);
  if (!hero || !box) return;
  box.closest(".dl-card").classList.add("recommended");
  hero.textContent = ({"mac-arm64":"Download for Mac (Apple silicon)","win-x64":"Download for Windows","android-arm64":"Download for Android"})[os];
}
setupRecommendedDownload();
