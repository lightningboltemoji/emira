<p align="center">
  <img width="472" height="192" alt="logo" src="https://github.com/user-attachments/assets/ebca86ed-b91e-4b7e-83ad-fabeecc47b56" />
</p>
<p align="center">
  a tiling, scrolling window manager for macOS, inspired by <a href="https://github.com/niri-wm/niri">niri</a> and <a href="https://github.com/nikitabobko/AeroSpace">AeroSpace</a>
</p>

<table align="center">
<tr>
<td>
  <p align="center">
    <b>tiling:</b> windows are arranged in a non-overlapping grid
  </p>
  <p align="center">
    <img width="282" height="172" alt="tiling" src="https://github.com/user-attachments/assets/dd6f54a4-9ece-4ebf-9bb1-d762fb0b6805" />
  </p>
</td>
<td>
  <p align="center">
    <b>scrolling</b>: your desktop is an infinite plane
  </p>
  <p align="center">
    <img width="282" height="172" alt="scrolling" src="https://github.com/user-attachments/assets/85d7605c-17de-4f0f-a87f-08b01c17d355" />
  </p>
</td>
</tr>
</table>

## about

emira makes managing many windows less painful.

imagine if your monitor extended infinitely to both sides. your windows are arranged for you along this infinite strip; you control what slice is in view. that's pretty much what it does!

and even better, you can have as many strips of windows as you want, and swap between them at any time.

<br />
<p align="center">
  <img width="600" height="389" alt="emira-demo" src="https://github.com/user-attachments/assets/4c2d51f6-0d46-4d18-bf24-ae05d4b2425f" />
</p>

## config

driven by `~/.config/emira/emira.toml`

you can assign key binds to a number of commands:

- window (`focus`, `grow`, `shrink`, `move-window`, `fullscreen`, `float`, `consume-or-expel`)
- workspace (`focus-workspace`, `move-to-workspace`, `move-to-workspace-and-focus`)

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
