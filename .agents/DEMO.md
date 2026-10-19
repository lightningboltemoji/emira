# emira: the demo video

How the README's video is made, so it can be made again whenever emira changes. A tape says what
happens, the director plays it on a display of its own under this checkout's daemon and records the
take, and the studio cuts the take into a video with a moving camera. The camera keys off markers the
tape leaves, not off pixels, so after a change a new take and a new render are all it takes.

```
.github/demo/
  emira.toml  the config the take's daemon runs with
  tapes/      what happens, a command a line (readme.tape)
  director/   plays a tape and records the take (Swift)
  takes/      recorded takes (not tracked)
  studio/     cuts takes into videos (Remotion); src/cuts/ has one per video
```

```sh
make demo                 # record tapes/readme.tape, then render studio/out/readme.webp
make demo-take TAPE=…     # just record
make demo-render CUT=…    # just render
make demo-studio          # preview the cuts in a browser, to tune the camera
```

## The stage

A take never touches the screens you work on, but it does borrow the desktop for about a minute:

- **The display is virtual.** `CGVirtualDisplay`, private CoreGraphics declared in the
  `VirtualDisplay` target, gives WindowServer a 1920×1080 point display drawn at 2x, which macOS
  places beside the others. Windows, the menu bar and screen recording all treat it as attached. It
  lives exactly as long as the director, so a crash can't leave it behind. macOS only offers its HiDPI
  mode a moment after it attaches, and only to a process that dequeues AppKit's events, which is why
  the director runs under `NSApp.run()` rather than an async `main`.
- **The daemon is this checkout's.** Every running `emira-daemon` is stopped with SIGTERM, which
  hands its windows back, and `.build/release/emira-daemon` starts on `.github/demo/emira.toml`.
  After the take it is stopped the same way and app-bundle daemons are opened again; one run from a
  build directory is only named.
- **The take display gets an empty workspace 1.** Everything on the other displays moves to
  workspace 9, and each of those displays hands its emptied workspace to the take display, since a
  workspace another display holds is where `focus-workspace` would go. A tape has 1–8 to itself.
- **Its windows are stand-ins.** Each is an app of its own, `standin`, built beside the director: one
  window of one colour, with no title bar and Fiber's traffic lights in their glass capsule. Nothing
  about it changes but where emira puts it, so the film is only windows moving, and it costs the
  encoder little. It opens as big as the biggest display, so the still emira opens it from is cropped
  to its tile rather than falling short of it (`window = "crop"`). It runs through a link in the
  take's folder named for its colour, because macOS names an app without a bundle after the path it
  ran from, and that name is what emira reports and a bar shows. They're quit when the take ends,
  before the daemon, so it doesn't hand their windows back.
- **The wallpaper is the Mac's.** The tape's colours were picked against macOS's solid Gold.
- **Input is real**, posted where the hardware's goes, so emira's hotkeys see a person. It only ever
  goes to an app the take started: a step that finds anything else frontmost stops the take. Moving
  the mouse or pressing a key stops it too, since the director's events carry a tag and anything
  without it is a person's. The pointer waits on another display, out of the picture.

It needs Accessibility and Screen Recording for the terminal it runs from, which the daemon and
`screencapture` inherit. Turn on Do Not Disturb first: macOS shows a notification on the display with
focus, which for the whole take is the take's.

## The recording

`screencapture -v` of the take display: H.264 at 3840×2160, at most 60 fps, only the frames that
changed. Not ScreenCaptureKit, which drops every window's drop shadow from a display capture, while
emira paints synthesized ones on the stills it animates, so a film would show shadows appear and
vanish at each animation. `screencapture` stamps no host times, so the take opens with a magenta
patch in the display's bottom-left corner, put up at a noted host time; the director finds its first
frame in the movie afterwards and writes `timeline.json` in movie time: markers, steps and the chords
pressed, each chord with the command `.github/demo/emira.toml` binds it to.

## Tapes

Settings come first; then the steps, one to a line. Steps before `Record` set the scene and aren't
recorded. `#` starts a comment.

| Setting | |
|---|---|
| `Display 1920x1080` | The take display's size in points |
| `Seed N` | Varies the rhythm of key presses, which is otherwise the same every take |
| `Color NAME RRGGBB` | A colour a stand-in can be, by name (no `#`, which starts a comment) |

| Step | |
|---|---|
| `Sleep 1.2s` | |
| `Key fn+shift+leftbracket …` | Presses each in turn; keys are named as `[keys]` names them |
| `Open NAME` | A stand-in of that colour. Waits for its window to take focus on the take display |
| `Wait windows N`, `Wait workspace NAME`, `Wait still` | The take display's workspace holds N windows; shows NAME; nothing emira draws is moving. Each takes a timeout, 10s by default |
| `Mark NAME [TARGET]` | Notes the time, and where TARGET is, for the camera. Mark what animates in once it has settled |
| `Record` | Starts recording |

A target is `display` (the default), `focused` (the focused window), `column` (its column),
`workspace` (the take display's windows together) or a rect in display points (`@X,Y,W,H`).

`readme.tape` fills an empty desktop with emira's green and three colours to go with it. Three
stand-ins open along the strip and two stack into a column, and the window beside it grows and
shrinks. The column's upper window goes fullscreen and back, then leaves the column, and focus walks
the row. A fourth opens at the end and moves all the way to the front. A repeated press is one `Key`
step, so its presses come quickly, as a person's do.

## The studio

A cut is a Remotion composition in `studio/src/cuts/`, listed in `cuts/index.ts`: the tapes whose
takes it uses, its size and length, and what it draws. Its pieces:

- **`Take`**: the take display where the camera sees it, a screen with rounded corners floating over
  the backdrop. Shots are keyed to the take (seconds, a marker, or a step's start or end by its line)
  and frame the display, a marker's rect, several markers' together, or a rect, so that it fills
  `fill` of the picture, tilted in 3D, or just past one side of it (`offscreen`). Moves ease
  `smooth`, `gentle`, `crash`, `whip`, `spring`, `emira` (emira's own critically damped spring) or
  `linear`, and zooms go about the one point that stays put. `drift` keeps pushing in slowly once a
  move settles. Fast moves are blurred in renders (not the preview), across half a frame: a pan by a
  blur along it, anything else by drawing the display at several instants and averaging them, which
  shifts a flat colour by a few levels.
- **`Keys`** shows the take's chords as keycaps, over the command each runs, kept on the display
  rather than half on the backdrop; **`Backdrop`** is what's behind it: one colour and the wordmark
  at rest, drawn by `.github/logo/scene.ts`.

The README's cut opens on the wordmark. The desktop slides over it from the right like a column onto
the strip, holds still at one size while the windows move, and slides on out to the left, uncovering
the wordmark for the loop to start from. The desktop is the subject, and a still camera leaves the
encoder only the windows that move.

The README's video is an animated WebP, the one kind GitHub plays inline and on a loop without a
click: drop `out/readme.webp` into the README's editor on github.com and use the `user-attachments`
URL it gives. A free plan takes images up to 10 MB. Remotion renders near lossless to
`out/<cut>-master.mp4`, in BT.709 with the tag that says so, and `encode.sh` scales that to 800 wide
at 60 fps and encodes it lossless, which fits; lossy, at any size that fits, leaves blocks wherever
something fades. It needs ffmpeg and img2webp (`brew install ffmpeg webp`).
