<p align="center">

<img width="370" height="145" alt="logo" src="https://github.com/user-attachments/assets/30d509a9-378b-4ea0-bbd9-61a7dfff75a4" />

a scrolling window manager for macOS, inspired by <a href="https://github.com/niri-wm/niri">Niri</a> and <a href="https://github.com/nikitabobko/AeroSpace">AeroSpace</a>
</p>

# about

# what makes emira different

all macOS window managers (that i'm aware of) move windows around using the macOS Accessibility (AX) APIs. these APIs are notoriously inconsistent: one action will take 10ms, the next 300ms. this sabotages the **feel** of window managers built on them, because when actions inevitably get delayed, it creates the perception of jank.

i built emira to experiment with a novel approach (i think?) to macOS window managers: **a compositor overlay**. emira animations are _screenshots_ of your windows being moved around, while the _real_ windows are snapping into place underneath. this does double duty: it gives us reliable, buttery-smooth animations _and_ hides the AX API latency.

# ai use

emira was written entirely by Claude. prose that's not obviously generated (e.g. code comments) was written by me (e.g. this!).
