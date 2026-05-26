if (!document.getElementById("meet-tab-sidecar-panel")) {
  const panel = document.createElement("aside");
  panel.id = "meet-tab-sidecar-panel";
  panel.innerHTML = `
    <header>
      <strong>Meet Tab Sidecar</strong>
      <button class="mts-close" type="button" aria-label="Collapse">-</button>
    </header>
    <div class="mts-body">
      <p>Share the sidecar tab with tab audio enabled when you need another tab to do the work.</p>
      <div class="mts-actions">
        <button class="mts-primary" type="button" data-action="sidecar">Open sidecar</button>
        <button type="button" data-action="work">Open work tab</button>
      </div>
      <ol>
        <li>Present now</li>
        <li>A tab</li>
        <li>Sidecar tab</li>
        <li>Also share tab audio</li>
      </ol>
    </div>
  `;
  document.documentElement.appendChild(panel);

  panel.querySelector(".mts-close").addEventListener("click", () => {
    const collapsed = panel.dataset.collapsed === "true";
    panel.dataset.collapsed = collapsed ? "false" : "true";
    panel.querySelector(".mts-close").textContent = collapsed ? "-" : "+";
  });

  panel.addEventListener("click", (event) => {
    const button = event.target.closest("button[data-action]");
    if (!button) return;
    chrome.runtime.sendMessage({ type: button.dataset.action === "sidecar" ? "open-sidecar" : "open-work" });
  });
}
