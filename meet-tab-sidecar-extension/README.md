# Meet Tab Sidecar

Meet Tab Sidecar is a Chrome extension for calls where Google Meet is in one tab and another browser tab needs to do the work: play a recording, speak a short intro, run a demo, or act as a controlled stage.

It is designed for the reliable Meet workflow:

1. Join the Google Meet in Chrome.
2. Open the Sidecar tab from the extension.
3. In Meet, choose Present now / Share screen.
4. Choose A tab.
5. Select the Sidecar tab.
6. Keep Also share tab audio enabled.
7. Start the intro, audio, or work in the Sidecar tab.

## What it includes

- Chrome extension popup for configuring the Meet URL, work URL, spoken intro, and audio URL.
- A Sidecar stage tab with:
  - spoken intro via browser speech synthesis
  - audio player
  - timer
  - Meet handoff checklist
- A small overlay inside `meet.google.com` with quick buttons to open the Sidecar or work tab.
- Installer-friendly zip packaging script.

## What it cannot do

Chrome and Google Meet do not allow an extension to silently join a call, click through Meet permissions, or inject another tab's audio into the microphone without a user share gesture. This app makes the supported path fast and hard to mess up, but the user still has to choose the tab-share target in Meet.

## Install locally

See [INSTALL.md](./INSTALL.md).

## Package

```bash
cd meet-tab-sidecar-extension
bash package-extension.sh
```

The zip is written to:

```text
../downloads/meet-tab-sidecar-extension.zip
```

## Default recording

The default work and audio URLs point at the GTMwAlex recording page:

```text
https://gtm.newaiyork.com/sandro-vonci-sunday-morning-call-20260526/
```

You can change them from the extension popup.
