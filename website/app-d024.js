// BHE 官网脚本：下载链接渲染 + 滚动进场。
// 主下载使用 dl 固定地址，OSS 原地址保留为备用。
const DOWNLOADS = {
  version: "最新版本",
  dlBase: "https://dl.envsystem.top",
  ossBase: "https://shengshengniannian.oss-cn-beijing.aliyuncs.com/shengshengniannian/basketball-highlight-editor/releases",
  ghBase: "https://github.com/fly7632785/basketball-highlight-editor/releases",
  files: {
    "mac-arm64": ["BHE-macos-arm64-latest.dmg"],
    "mac-x64": ["BHE-macos-x86_64-latest.dmg"],
    "win-x64": ["BHE-windows-x64-latest.zip"],
    "android-arm64": ["BHE-android-arm64-v8a-latest.apk"],
  },
  // Android uses the OSS custom domain so users in mainland China can download it directly.
  // Keep this path separate from the Baby project's latest.apk object.
  direct: {
    "android-arm64": "https://oss.shengshengniannian.com/shengshengniannian/app/android/bhe/latest.apk",
  },
};

function fileNameMeta(name) {
  if (name.endsWith(".dmg")) return { label: "下载 .dmg", sub: "安装包" };
  if (name.endsWith(".apk")) return { label: "下载 .apk", sub: "手机安装包" };
  return { label: "下载 .zip", sub: "解压即用" };
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
      a.download = name;
      a.textContent = meta.label;
      box.appendChild(a);
    });
    const mirror = document.createElement("a");
    mirror.className = "dl-link-gh";
    mirror.href = DOWNLOADS.direct[box.dataset.os] || `${DOWNLOADS.ossBase}/${files[0] || ""}`;
    mirror.rel = "noopener";
    mirror.textContent = "OSS 备用下载";
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

// Architecture is not reliably exposed by all browsers. Mac defaults to Apple
// silicon while keeping Intel and every other download visible in the list.
function setupRecommendedDownload() {
  const ua = navigator.userAgent || "";
  let os = null;
  if (/Android/i.test(ua)) os = "android-arm64";
  else if (/Windows/i.test(ua)) os = "win-x64";
  else if (/Macintosh|Mac OS X/i.test(ua) && !/iPhone|iPad|iPod/i.test(ua)) os = "mac-arm64";
  const hero = document.getElementById("hero-download");
  if (!hero || !os) return;
  const box = document.querySelector(`.dl-actions[data-os="${os}"]`);
  const link = box && box.querySelector("a.btn");
  if (!link) return;
  box.closest(".dl-card").classList.add("recommended");
  hero.textContent = ({"mac-arm64":"下载 Mac 版（Apple 芯片）", "win-x64":"下载 Windows 版", "android-arm64":"下载 Android 版"})[os];
  if (os === "mac-arm64") {
    const intel = document.createElement("a");
    intel.className = "hero-intel";
    intel.href = "#download";
    intel.textContent = "Intel Mac 或其他系统";
    hero.after(intel);
  }
}
setupRecommendedDownload();
