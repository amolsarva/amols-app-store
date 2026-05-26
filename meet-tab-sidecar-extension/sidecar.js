const message = document.querySelector("#message");
const audioUrl = document.querySelector("#audioUrl");
const audio = document.querySelector("#audio");
const state = document.querySelector("#state");
const clock = document.querySelector("#clock");

let startedAt = null;
let timerId = null;

function setState(text) {
  state.textContent = text;
}

function startTimer() {
  if (!startedAt) startedAt = Date.now();
  clearInterval(timerId);
  timerId = setInterval(() => {
    const elapsed = Math.floor((Date.now() - startedAt) / 1000);
    const minutes = String(Math.floor(elapsed / 60)).padStart(2, "0");
    const seconds = String(elapsed % 60).padStart(2, "0");
    clock.textContent = `${minutes}:${seconds}`;
  }, 250);
}

async function loadSettings() {
  const values = await chrome.storage.local.get(["message", "audioUrl"]);
  message.value = values.message || "";
  audioUrl.value = values.audioUrl || "";
  audio.src = audioUrl.value;
}

async function saveSettings() {
  audio.src = audioUrl.value.trim();
  await chrome.storage.local.set({
    message: message.value.trim(),
    audioUrl: audioUrl.value.trim()
  });
}

async function playAudio() {
  await saveSettings();
  await audio.play();
  startTimer();
  setState("Audio playing");
}

function speakIntroThenPlay() {
  saveSettings().then(() => {
    startTimer();
    if (!("speechSynthesis" in window) || !("SpeechSynthesisUtterance" in window) || !message.value.trim()) {
      return playAudio();
    }

    window.speechSynthesis.cancel();
    const utterance = new SpeechSynthesisUtterance(message.value.trim());
    utterance.rate = 0.96;
    utterance.onstart = () => setState("Speaking intro");
    utterance.onend = () => playAudio();
    utterance.onerror = () => playAudio();
    window.speechSynthesis.speak(utterance);
  }).catch((error) => setState(error.message));
}

document.querySelector("#playIntro").addEventListener("click", speakIntroThenPlay);
document.querySelector("#playAudio").addEventListener("click", () => playAudio().catch((error) => setState(error.message)));
document.querySelector("#pause").addEventListener("click", () => {
  audio.pause();
  window.speechSynthesis?.cancel();
  setState("Paused");
});
document.querySelector("#restart").addEventListener("click", () => {
  audio.currentTime = 0;
  startedAt = Date.now();
  playAudio().catch((error) => setState(error.message));
});

audio.addEventListener("ended", () => setState("Finished"));
audioUrl.addEventListener("change", saveSettings);
message.addEventListener("change", saveSettings);

loadSettings().catch((error) => setState(error.message));
