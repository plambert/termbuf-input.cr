# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.1] - 2026-10-06

### Fixed

- A timer spec could wait forever. It slept past a 5 ms timer, cancelled it, and then read the
  channel with no timeout; when the OS coalesced the two wake-ups, as macOS does at background QoS
  and can on a loaded CI runner, the cancel came first and no tick was ever sent. The timer specs
  now take the tick off the channel, with a time limit, before cancelling. The library is
  unchanged.

## [0.7.0] - 2026-10-05

This release runs on Windows, in Windows Terminal and in WezTerm. Both host a program in a Windows
console, and the console's input is read directly.

### Added

- Windows support. On Windows the reader reads the console's input records, so it sees a resize
  and can be stopped, and holds a surrogate pair split across two reads until its second half
  comes. `Input::Console` does the reading; its `Translator` turns keys going down, the character
  Alt+numpad composes, and repeat counts into the bytes a terminal would send.
- `Events::Resize`, with the new size and the size reported before it (`nil` the first time). The
  stream sends it when the window changes size, from SIGWINCH on POSIX and from the console's
  resize records on Windows. It skips a size already reported. `Stream#measure` says how the size
  is taken; it is `SizeDetector.detect` unless set.
- `Input::ScreenSize` and `Input::SizeDetector`, moved from termbuf, which aliases them. On Windows
  the size comes from the console's screen buffer.
- `Input::RawMode`, moved from termbuf's `Tty`, so a program that reads keys with this shard alone
  can turn raw mode on and put the terminal back as it found it. On Windows it turns on virtual
  terminal input and window input, and turns off line input, echo, quick edit and the console's own
  mouse input. With mouse input on, the console asks the terminal for mouse tracking on its own and
  passes the reports to the program, which never asked for them.
- Console control events on Windows. Ctrl+C is `INT` and Ctrl+Break is `BREAK`, handled by their
  modes as signals are on POSIX; `Mode::Exit` exits with `0xC000013A`, the status of a console
  program stopped by Ctrl+C. Closing the console, logging off and shutting down run the
  `before_exit` hooks, and the handler waits up to 4.5 seconds for them, because Windows ends the
  process as soon as it returns. WezTerm's kill-pane ends the process without an event, so no hook
  runs there.
- `before_exit` hooks receive a `Departure`: `Signalled`, or `Disconnected` when the terminal has
  gone. A block that takes no argument still works.
- X10 mouse reports, `CSI M` and three raw bytes, decode to `Events::Mouse` through
  `Mouse.decode_x10`. They used to become keys; column 81 is a `q`.
- `Input::PseudoConsole`, for specs on Windows: it runs a program in a Windows console the spec
  plays the terminal for, types into it, resizes it and reads its screen, with no window. It is not
  required by default; require `termbuf-input/win32/pseudo_console`.
- `TERMBUF_INPUT_UNATTENDED` makes the examples' harness skip every question meant for a person.

### Changed

- The stream sends `Events::Resize` in place of `Events::Signal` for `WINCH`.
- A query left unanswered when the sentinel's reply arrives still takes its answer for
  `Queries::LATE_GRACE`, 500ms, delivered after the `Events::Unanswered`. A Windows console answers
  the device attributes itself and passes other queries on to the terminal, so their answers can
  come after; WezTerm's XTVERSION answer came 34ms late and was read as keys, Alt+P among them.
- On Windows, `DEFAULT_MODES` are `TERM`, `INT` and `BREAK`, since Windows has neither `HUP` nor
  `WINCH`.
- The examples use `RawMode` instead of `stty`, and the checklist's resize step runs on Windows.
  The report names Windows Terminal from `WT_SESSION`.

### Fixed

- A sequence body that is not UTF-8, such as an X10 mouse report past column 95, no longer stops
  the dispatcher. The reply parsers' regular expressions raised on it; `Sequence.parse` now scrubs
  the body, and `Sequence#bytes` keeps the bytes as they came.
- `VERSION` is read on Windows too. The compiler runs a macro's command there with no shell, so the
  single quotes around the shard's directory reached `shards` as part of the path, and every build
  that required this shard stopped there. Windows gets the directory in double quotes, which its
  command line honours; elsewhere nothing changes.
- The examples build on Windows. The harness asks `cmd` for its `git rev-parse ... || echo unknown`
  fallback there, since no shell reads the `||`.

## [0.6.0] - 2026-09-27

### Added

- `Events::Focus` and `Input::Focus`, decoding the `CSI I` and `CSI O` focus reports of DEC mode
  1004. A stream watches for them from the moment it is built; turning the reports on belongs to
  whoever set the terminal up, where the terminal supports them.
- `Input::Mode`, the terminal modes whose effects this shard decodes, with their set and reset
  sequences: `BRACKETED_PASTE`, `FOCUS_EVENTS`, `MOUSE_SGR`, `MOUSE_SGR_ANY`, `MOUSE_SGR_CLICKS`,
  `KITTY_KEYBOARD` and `MODIFY_OTHER_KEYS`. The record and the first six move here from termbuf's
  `Tty`.
- `Input::Modes`, which turns modes on through an output, writes nothing for one already on, and
  resets them all in reverse order on the way out.
- `Input::Query` and `Input::Queries`, which ask the terminal where the cursor is, how big the
  text area and a cell are, what its colours are, whether it supports a mode, which kitty keyboard
  flags are in force, its device attributes and its name. The answer arrives as an event, or as
  `Events::Unanswered` when the device attributes request sent after every query is answered
  first. `Mode#query` asks about a mode's support.
- `Queries#settle`, which waits for outstanding queries before the terminal goes back to cooked
  mode, so no reply lands on the shell's command line.
- `Input::Replies`, the parsers for those answers, usable on sequences read without a stream.
- `Input::Claimed`, which a pattern returns to keep a sequence and deliver nothing.
- `examples/queries.cr` and `examples/checklist.cr`, which test a terminal, say what should happen,
  and write a report; `examples/events.cr`, which prints every event with the modes toggled from
  the keyboard.

## [0.5.0] - 2026-09-11

### Changed

- `Stream#stages` is a `Stages`, a mutex-guarded list with `#push`, `#replace` and a snapshotting
  `#each`, in place of an array that had to be copied and reassigned. `Stream#stages=` is gone;
  what assigned a chain now calls `#replace`.

- The README maps the public API and opens with a program that compiles, and the doc comments no
  longer name things that live in termbuf rather than here.

## [0.1.0] - 2026-09-04

### Added

- The input side of [termbuf](https://github.com/plambert/termbuf.cr), extracted into a shard of
  its own. Every type is where it was, under `TermBuf::Input`; termbuf keeps its `TermBuf::Key` and
  `TermBuf::Events::*` aliases and now depends on this.
- `Input::Stream`, a reader fibre and a dispatcher fibre over one queue, handing events to a
  channel: `Events::Key`, `Events::Paste`, `Events::Pasting`, `Events::Mouse`, `Events::Response`,
  `Events::Timer`, `Events::Signal`, `Events::Warning`, `Events::Failure` and `Events::Closed`.
- `Input::Decoder`, turning bytes into keys with modifiers, bracketed paste, and the kitty keyboard
  protocol where the driver says it is on; `Input::SequenceScanner`, cutting the stream into
  complete escape sequences; `Input::Patterns`, deciding which of those are replies the application
  registered for rather than keys.
- `Input::Timers` and `Input::Signals`, putting wake-ups and signals on the reader's own queue so
  that they are ordered against the keystrokes around them rather than racing them.
- `Input::Stage`, an ordered chain of translations a driver and an application both add to, walked
  between the dispatcher and the channel. termbuf's resize handling is a stage.
- `Input::Mouse`, decoding SGR mouse reports into buffer cells numbered from zero. A stream watches
  for them from the moment it is built; turning the reporting on belongs to whoever set the
  terminal up.

[Unreleased]: https://github.com/plambert/termbuf-input.cr/compare/v0.7.1...HEAD
[0.7.1]: https://github.com/plambert/termbuf-input.cr/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/plambert/termbuf-input.cr/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/plambert/termbuf-input.cr/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/plambert/termbuf-input.cr/compare/v0.1.0...v0.5.0
[0.1.0]: https://github.com/plambert/termbuf-input.cr/releases/tag/v0.1.0
