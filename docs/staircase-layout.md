# Staircase layout

This fork of [AeroSpace](https://github.com/nikitabobko/AeroSpace) adds one thing: a `staircase` layout,
a variant of accordion where **every** window sticks out, so you can see all of them and click any of them.

Based on upstream `v0.21.3-Beta`. Everything else behaves like upstream.

## Why

On a large monitor you can tile windows side by side. On a laptop screen tiling quickly makes windows too small
to be useful, so you end up in accordion mode almost all the time. But accordion only shows a sliver of the
two windows next to the focused one. With six windows open you can't see or click the other four.

Staircase fixes that.

```
h_staircase with 5 windows, 3rd one focused:

  ┌─┬─┬──────────────────────┬─┬─┐
  │ │ │                      │ │ │
  │1│2│          3           │4│5│
  │ │ │      (focused)       │ │ │
  └─┴─┴──────────────────────┴─┴─┘
```

Windows 1 and 2 show their left edge, 4 and 5 show their right edge. Click an edge to focus that window.

## How it works

- **Static geometry.** Every window has the same size, and window `i` is offset by `i * step` in tree order.
  `step` is `staircase-padding`, shrunk so the whole staircase takes at most `staircase-max-percent` percent
  of the container. Changing focus moves no windows. Only opening or closing a window does. Moving windows on
  every focus change was the first approach and it flickered badly.
- **Stacking.** Windows overlap, so what you see depends on which window is in front of which. The stack has to
  peak at the focused window and fall off to both sides. Focusing a window already raises it natively, so moving
  to a neighbor needs nothing extra. When the stack is out of order (jumping across several windows, wrapping
  around, cycling fast), AeroSpace reads the real front-to-back order from the window server and raises only the
  windows that are wrong, one after another. Repairs are capped so a raise that macOS ignores can't loop.

The layout code is in `Sources/AppBundle/layout/layoutRecursive.swift` (`layoutStaircase` and `raiseStaircase`).

## Usage

```toml
default-root-container-layout = 'staircase'   # or set it per workspace/container with the layout command

staircase-padding = 30        # size of each visible strip, in points
staircase-max-percent = 25    # the staircase never takes more than this share of the container

[mode.main.binding]
alt-s = 'layout v_staircase'
alt-w = 'layout h_staircase'
```

Commands: `layout h_staircase`, `layout v_staircase`, `layout staircase` (keeps the current orientation).
They work in `layout` toggles and with `--root`. Navigate with `focus left|right` in `h_staircase`
and `focus up|down` in `v_staircase`, same as accordion.

`list-windows` and the `%{window-parent-container-layout}` / `%{workspace-root-container-layout}` format
variables report `h_staircase` and `v_staircase`.

## Limitations

- **The focused window slides by one step as you move focus**, because the layout is static. It can't be both
  static and pinned in one place.
- **Strips are in tree order**, not most-recently-used order. MRU order would move windows on every focus change.
- **Stacking depends on macOS.** Windows are raised with the Accessibility API (`AXRaise`) without activating
  their app. That has only been tried on macOS 26 with a handful of apps (Opera, iTerm2, VS Code, Telegram,
  Obsidian, Spotify). If a strip gets covered by another window, that is the first place to look.
- Dragging a window in a staircase behaves like accordion.
- Not tested with native macOS tabs, which upstream is still working on.

## Building

Needs Xcode and [swiftly](https://github.com/swiftlang/swiftly). Swift 6.3.2 is pinned in `.swift-version`.

```bash
brew install swiftly bash xcodegen
swiftly init && swiftly install 6.3.2
PATH=/opt/homebrew/bin:$PATH script/build-local-app.sh
```

That produces `.local-release/AeroSpace.app` and `.local-release/aerospace`. It skips docs, man pages and shell
completion, so it doesn't need Ruby or Rust.

The default signature is ad-hoc. macOS ties the Accessibility permission to the signature, so you have to grant it
again after each rebuild. To keep it, create a self-signed code-signing certificate (see `dev-docs/development.md`)
and pass `--codesign-identity <name>`.

The app has the same bundle identifier as upstream AeroSpace (`bobko.aerospace`), so it replaces an installed
upstream copy rather than running next to it. Quit AeroSpace before installing.

To run the tests: `swiftly run swift test +6.4.0` (the test targets build with 6.4.0 here).

## Credits

AeroSpace is by [Nikita Bobko](https://github.com/nikitabobko) and is MIT licensed (see `LICENSE.txt`).
This is an unofficial fork. Don't report problems with it to upstream.
