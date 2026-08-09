<p align="center">
  <img width="472" height="192" alt="logo" src="https://github.com/user-attachments/assets/ebca86ed-b91e-4b7e-83ad-fabeecc47b56" />
</p>
<p align="center">
  A tiling-scrolling window manager for macOS, inspired by <a href="https://github.com/niri-wm/niri">niri</a> and <a href="https://github.com/nikitabobko/AeroSpace">AeroSpace</a>
</p>

<p align="center">
  <b>Tiling:</b> windows are arranged in a non-overlapping grid
</p>
<p align="center">
  <img width="141" height="86" alt="tiling" src="https://github.com/user-attachments/assets/dd6f54a4-9ece-4ebf-9bb1-d762fb0b6805" />
</p>
<p align="center">
  <b>Scrolling:</b> your desktop is an infinite plane
</p>
<p align="center">
  <img width="141" height="86" alt="scrolling" src="https://github.com/user-attachments/assets/85d7605c-17de-4f0f-a87f-08b01c17d355" />
</p>

## About

emira makes managing many windows less painful.

Windows are arranged for you along an infinitely-wide strip. A slice of the strip is shown on your monitor. Scroll side-to-side to reveal the rest. Even better, you can have many strips and swap between them instantly. That's pretty much it!

<br />
<p align="center">
  <img width="600" height="389" alt="emira-demo" src="https://github.com/user-attachments/assets/8b6da0a8-3555-4e63-9aa9-02000e8e8ed8" />
</p>

## Features

- All basic window management features you'd expect (focus, move, resize, etc.)
- Virtual workspaces: move windows between multiple strips, toggle which strip is shown on screen
- Multi-monitor support: one strip on each monitor, focus between them
- Cursor integration: move mouse to focused windows, focus windows on hover, hide on focus
- Trackpad support: scroll side-to-side using a 3-finger swipe
- Supports native tabs
- Works with [SIP](https://support.apple.com/en-us/102149): requires only Accessibility and Screen Recording permissions

## Config

Read from `~/.config/emira/emira.toml`. Schema in [`emira.example.toml`](emira.example.toml). 

GUI is partially implemented under the menu bar > `Settings`.

## Install

[Homebrew](https://brew.sh) is recommended:

```bash
brew install --cask lightningboltemoji/tap/emira
```

or manually from the [releases page](https://github.com/lightningboltemoji/emira/releases).

## What makes emira different

macOS window managers usually rely on the Accessibility (AX) APIs to manipulate windows. These APIs are notoriously inconsistent: one action takes 10ms, the next 300ms. This can sabotage the _**feel**_ of window managers, because we expect window actions to be smooth and predictable.

I built emira to experiment with a novel approach: **a compositor overlay**. emira reconstructs your desktop during animations -- _screenshots_ of windows shuffle across the screen, while the _real_ windows snap into place underneath. This makes animations reliable, buttery-smooth, _and_ hides the latency of the AX API.

This approach is not without downsides, such as non-negligible latency capturing screenshots and video freezing during motion, but I do think it shows promise.

## AI use

emira's code was written almost entirely by Claude with architectural guidance.

Some prose is AI-generated, such as code comments, but anything that presents as human-authored or is expected to be read by humans (like this) was written by me.
