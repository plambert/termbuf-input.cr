# termbuf-input

Bytes and signals from a terminal, turned into events.

This is the input half of [termbuf](https://github.com/plambert/termbuf.cr), split out so that it
can be used on its own. It reads a device, decodes what arrives, and hands back keystrokes, pasted
text, mouse reports, timers, signals and the replies an application asked the terminal for. It
knows nothing about screens, cells, colours or capabilities, and it depends on nothing outside the
standard library.

termbuf depends on this shard; everything under `TermBuf::Input` lives here, and termbuf keeps
`TermBuf::Key` and `TermBuf::Events::*` as aliases onto it.

Requires Crystal 1.21 or later.

## Installation

Add the dependency to `shard.yml` and run `shards install`:

```yaml
dependencies:
  termbuf-input:
    github: plambert/termbuf-input.cr
```

## Usage

```crystal
require "termbuf-input"

stream = TermBuf::Input::Stream.new STDIN, blocking: false
stream.start

case event = stream.events.receive
when TermBuf::Input::Events::Key   then puts "key: #{event.key}"
when TermBuf::Input::Events::Paste then puts "pasted #{event.text.size} characters"
end

stream.close
```

A stream owns the device only for reading: putting the terminal in raw mode, turning mouse
reporting or bracketed paste on, and putting them back afterwards belong to whatever set the
terminal up.

## The stream

`Stream` is two fibres and one queue.

A reader fibre does the blocking read on the device and puts what it got on an internal queue.
`Timers` and `Signals` put their wake-ups on that same queue, which is the whole point of the
design: a timer tick and a `SIGWINCH` are ordered against the keystrokes around them rather than
racing them. A dispatcher fibre drains the queue, feeds bytes to the `Decoder` — which uses
`SequenceScanner` to cut the stream into complete escape sequences and `Patterns` to decide which
of those are replies the application registered for rather than keys — and turns each result into
an event. Before an event reaches the application's channel it walks the `stages` chain, an
ordered list of translations that a driver and the application can both add to; that is how
termbuf turns a `SIGWINCH` into a resize event without this shard knowing what a screen is.

The pieces are usable on their own: `Decoder` will turn a `Bytes` into events with no device
anywhere in sight, which is how most of the specs are written.

## Development

```bash
shards install
crystal spec -v --error-trace
crystal tool format --check
ameba
```

## License

MIT. See [LICENSE](LICENSE).
