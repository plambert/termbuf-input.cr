# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/plambert/termbuf-input.cr/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/plambert/termbuf-input.cr/releases/tag/v0.1.0
