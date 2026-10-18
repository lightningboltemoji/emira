<p align="center">
  <img width="472" height="136" alt="emira" src=".github/logo/logo.webp" />
</p>
<p align="center">
  A tiling-scrolling window manager for macOS, inspired by <a href="https://github.com/niri-wm/niri">niri</a> and <a href="https://github.com/nikitabobko/AeroSpace">AeroSpace</a>
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

Read from `~/.config/emira/config.toml`. Schema in [`config.example.toml`](config.example.toml).

There's also a relatively rough settings GUI under the menu bar item's `Settings`.

## Install

[Homebrew](https://brew.sh) is recommended:

```bash
brew install --cask lightningboltemoji/tap/emira
```

or manually from the [releases page](https://github.com/lightningboltemoji/emira/releases).

## What makes emira different

macOS window managers usually rely on the Accessibility (AX) APIs to manipulate windows. These APIs are notoriously inconsistent: one action takes 10ms, the next 300ms. This can sabotage the _**feel**_ of window managers, because we expect window actions to be smooth and predictable.

I built emira to experiment with a novel approach: **a compositor overlay**. emira reconstructs your desktop during animations -- _screenshots_ of windows shuffle across the screen, while the _real_ windows snap into place underneath. This makes animations reliable and buttery-smooth, while also masking any behind-the-scenes delay in the AX APIs.

This approach is not without downsides, such as non-negligible latency capturing screenshots and video freezing during motion, but in my own usage, I find these to be very much worthwhile tradeoffs.
