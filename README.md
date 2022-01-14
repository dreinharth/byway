# byway

byway is a [Wayland](https://wayland.freedesktop.org/) compositor,
inspired by [cwm](http://cvsweb.openbsd.org/cgi-bin/cvsweb/xenocara/app/cwm/),
based on [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots),
and written in [Zig](https://ziglang.org/). It aims to be concise both
visually and in its implementation. Ease of maintenance is also a goal; Zig, wlroots,
and Wayland are all moving quickly, and the intent is for byway to keep pace.
byway began life as a fork of
[TinyWL](https://gitlab.freedesktop.org/wlroots/wlroots/-/tree/master/tinywl),
and borrows significant code from [sway](https://github.com/swaywm/sway/).

byway is in the early stages of development, and bugs, including crashes, should be expected.
However, byway is mostly feature-complete, and development is intended to consist of bug fixes,
and adding support for Wayland protocols as needed.  Additional features will be considered
based on how much value they provide, and whether they can be implemented without significantly expanding
the size or complexity of the codebase.

## Installation

First ensure dependencies are installed, and then run `zig build` with any desired
options, e.g.

```
zig build install -Drelease-safe -p ~/.local
```

### Dependencies

- zig (0.10.0-dev)
- wlroots (0.15.0.r10)
- wayland
- wayland-protocols
- xkbcommon
- xcb
- libinput
- pixman

## Configuration

Behavior can be customized via `$HOME/.config/byway/config.json`.
See [config.json.example](./config.json.example) for a sample configuration.

- `tap_to_click`: `true` or `false`
- `natural_scrolling`: `true` or `false`
- `background_color`: array of values between 0 and 1 corresponding to RGBA
- `border_color`: array of values between 0 and 1 corresponding to RGBA
- `focused_color`: array of values between 0 and 1 corresponding to RGBA
- `grabbed_color`: array of values between 0 and 1 corresponding to RGBA
- `active_border_width`: pixels
- `hotkeys`: array of `{modifiers, key, action, arg}`; See below
- `mouse_move_modifiers`: modifier keys to move a toplevel view with the mouse
- `mouse_move_button`: button to move a toplevel view with the mouse
- `mouse_grow_modifiers`: modifier keys to grow or shrink a toplevel view with the mouse
- `mouse_grow_button`: button to grow or shrink a toplevel view with the mouse
- `autostart`: array of commands to run on startup
- `move_pixels`: pixels
- `grow_pixels`: pixels
- `damage_tracking`: one of `"minimal"` (redraws all outputs, but only on updates),
`"partial"` (redraws whole surfaces on updates), and `"full"` (only redraws damaged areas),

Hotkey Actions:

| Action | Description | `arg` value |
| ------ | ----------- | ----------- |
| `"command"` | Executes the command as a child process | command to execute |
| `"toplevel_to_front"` | Raises the toplevel view with keyboard focus to the top of the stack | `""` |
| `"toplevel_to_back"` | Lowers the toplevel view with keyboard focus to the bottom of the stack | `""` |
| `"cycle_groups"` | Raises and focuses a window of the next application in the stack | `"1"` to cycle forward, '"-1" to cycle backward |
| `"cycle_toplevels"` | Raises and focuses the next window of the currently-focused application | `"1"` to cycle forward, '"-1" to cycle backward |
| `"move_toplevel"` | Moves the toplevel view with keyboard focus in the specified direction | One of `"up"`, `"down"`, `"left"`, `"right"` |
| `"grow_toplevel"` | Grows or shrinks the toplevel view with keyboard focus by moving the bottom or rightmost edge | `"up"`, `"down"`, `"left"`, `"right"` |
| `"toggle_fullscreen"` | Toggles fullscreen for the toplevel view with keyboard focus | `""` |
| `"switch_to_workspace"` | Changes the currently visible workspace | character corresponding to workspace number, `"0"` to `"9"` |
| `"toplevel_to_workspace"` | Moves the toplevel view with keyboard focus to the specified workspace | character corresponding to workspace number, `"0"` to `"9"` |
| `"quit"` | Quits byway | `""` |
| `"chvt"` | Changes to the specified virtual terminal | character corresponding to VT, e.g. `"1"` for tty1 |
| `"reload_config"` | Reloads the configuration from `$HOME/.config/byway/config.json` | `""` |

## Contributing

Issues are welcome as are bug fix PRs.  New functionality will be considered on a case-by-case basis. 
