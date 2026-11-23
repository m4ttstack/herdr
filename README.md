# herdr (mattstack fork)

A fork of [herdrdev/herdr](https://github.com/herdrdev/herdr) 0.9.5 that mattstack and Flock run. It adds what they need from herdr on top of an upstream release.

## What's different

- **Mouse.** Accepts Flock's `terminal.mouse` shape on terminal session control and reports when a pane captures the mouse.
- **Host theme.** `terminal.host_theme` on terminal session control, so panes follow the host app's light or dark theme.
- **Theme timing and live-handoff restart.** Agents resume with the host theme once its whole theme line has landed, and the theme survives a live handoff to a new server.
- **Kitty images.** Kitty graphics images reach session-control clients in terminal frames.
- **Updates come from this fork.** `herdr update` installs only this fork's releases, never stock herdr. There is no preview channel.

## Installation

`rt setup` and Flock install it for you. To install it by hand, download the asset for your Mac from the [latest release](https://github.com/m4ttstack/herdr/releases/latest) (`herdr-macos-aarch64` for Apple silicon, `herdr-macos-x86_64` for Intel) to `~/.local/bin/herdr`, then run `chmod +x ~/.local/bin/herdr`.

Versions read `<upstream version>-ms.<n>`, for example `0.9.5-ms.1`.

## Everything else

For what herdr is and how to use it, read the upstream README:

- [Upstream README at 0.9.5](https://github.com/herdrdev/herdr/blob/v0.9.5/README.md), the version this fork is built on
- [Latest upstream README](https://github.com/herdrdev/herdr#readme)

This fork is not made or endorsed by herdr's maintainers.

## License

Apache-2.0, same as upstream. See [LICENSE](LICENSE).
