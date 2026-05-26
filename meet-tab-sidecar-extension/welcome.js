document.querySelector("#openSidecar").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "open-sidecar" });
});

document.querySelector("#openMeet").addEventListener("click", () => {
  chrome.runtime.sendMessage({ type: "open-meet" });
});
