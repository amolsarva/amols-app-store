const fields = {
  meetUrl: document.querySelector("#meetUrl"),
  workUrl: document.querySelector("#workUrl"),
  message: document.querySelector("#message")
};

const status = document.querySelector("#status");

function setStatus(text) {
  status.textContent = text;
}

async function loadSettings() {
  const response = await chrome.runtime.sendMessage({ type: "get-defaults" });
  if (!response.ok) throw new Error(response.error);
  fields.meetUrl.value = response.values.meetUrl || "";
  fields.workUrl.value = response.values.workUrl || "";
  fields.message.value = response.values.message || "";
}

async function saveSettings() {
  await chrome.storage.local.set({
    meetUrl: fields.meetUrl.value.trim(),
    workUrl: fields.workUrl.value.trim(),
    message: fields.message.value.trim()
  });
}

async function run(action, success) {
  try {
    await saveSettings();
    const response = await chrome.runtime.sendMessage({ type: action });
    if (!response.ok) throw new Error(response.error);
    setStatus(success);
  } catch (error) {
    setStatus(error.message);
  }
}

function checklistText() {
  return [
    "Meet Tab Sidecar checklist:",
    "1. Join the Google Meet in Chrome.",
    "2. Open the sidecar or work tab.",
    "3. In Meet, choose Present now / Share screen.",
    "4. Pick A tab.",
    "5. Select the sidecar or work tab.",
    "6. Keep Also share tab audio enabled.",
    "7. Start the sidecar audio or automation."
  ].join("\n");
}

document.querySelector("#openMeet").addEventListener("click", () => run("open-meet", "Opened Meet."));
document.querySelector("#openWork").addEventListener("click", () => run("open-work", "Opened work tab."));
document.querySelector("#openSidecar").addEventListener("click", () => run("open-sidecar", "Opened sidecar tab."));
document.querySelector("#copyChecklist").addEventListener("click", async () => {
  await saveSettings();
  await navigator.clipboard.writeText(checklistText());
  setStatus("Checklist copied.");
});

loadSettings().catch((error) => setStatus(error.message));
