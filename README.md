<p align="center">

<img width="370" height="145" alt="logo" src="https://github.com/user-attachments/assets/a105a377-e019-4f6b-a6f5-6d80fae22a34" />

a scrolling window manager for macOS, inspired by <a href="https://github.com/niri-wm/niri">Niri</a> and <a href="https://github.com/nikitabobko/AeroSpace">AeroSpace</a>
</p>

# about

# what makes emira different

all macOS window managers move windows using the macOS Accessibility (AX) APIs. these APIs are notoriously inconsistent: one action will take 10ms, the next 300ms. this sabotages the **feel** of window managers built on them -- when actions inevitably get delayed, it's perceived as lag or imprecision.

i built emira to experiment with a novel approach: **a compositor overlay**. emira animations are _screenshots_ of your windows being moved around, while the _real_ windows are snapping into place underneath. this does double duty: reliable, buttery-smooth animations _and_ hidden AX API latency.

# ai use

emira was written entirely by Claude. prose that's not obviously generated (e.g. code comments) was written by me (e.g. this!).
