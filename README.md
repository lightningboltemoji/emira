<p align="center">
  <img width="472" height="192" alt="logo" src="https://github.com/user-attachments/assets/ebca86ed-b91e-4b7e-83ad-fabeecc47b56" />
</p>
<p align="center">
  a tiling, scrolling window manager for macOS, inspired by <a href="https://github.com/niri-wm/niri">niri</a> and <a href="https://github.com/nikitabobko/AeroSpace">AeroSpace</a>
</p>

## about

_tiling_ means windows get arranged in a non-overlapping grid

_scrolling_ means your desktop is an infinite plane you can move through

## install

[Homebrew](https://brew.sh) is recommended:

```bash
brew install --cask lightningboltemoji/tap/emira
```

but there's always the [releases page](https://github.com/lightningboltemoji/emira/releases), too.

## what makes emira different

all macOS window managers i know of rely on the Accessibility (AX) APIs to manipulate windows. these APIs are notoriously fickle: one action takes 10ms, the next 300ms. this can sabotage the _**feel**_ of window managers, because we expect window actions to feel smooth and predictable.

i built emira to experiment with a novel approach: **a compositor overlay**. emira reconstructs your desktop during animations -- _screenshots_ of windows shuffle across the screen, while the _real_ windows snap into place underneath. this makes animations reliable, buttery-smooth, _and_ hides the latency of the AX API.

this approach is not without downsides, such as video freezing during motion and DRM content blurring, but i do think it shows promise.

## ai use

emira's code was written almost entirely by Claude. prose that presents as human-authored (such as this) was written by me.
