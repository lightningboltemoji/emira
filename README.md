<p align="center">

a scrolling window manager for macOS, inspired by <a href="https://github.com/niri-wm/niri">Niri</a> and <a href="https://github.com/nikitabobko/AeroSpace">AeroSpace</a>
</p>

# about

# motivation

all macOS window managers (that i'm aware of) move windows around using the macOS Accessibility (AX) APIs. these APIs are notoriously inconsistent: one action will take 10ms, the next 300ms. this sabotages the **feel** of window managers built on them, because when actions inevitably get delayed, it creates the perception of jank.

i built emira to experiment with a novel approach (i think?) to macOS window managers: **a compositor overlay**. emira animations are _screenshots_ of your windows being moved around, while the _real_ windows are snapping into place underneath. this does double duty: it gives us reliable, buttery-smooth animations _and_ hides the AX API latency spikes.

# ai use

emira was written entirely by Claude. any prose not obviously generated (like code comments) was written by hand.
