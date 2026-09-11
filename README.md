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

## Getting started

Add the dependency to `shard.yml` and run `shards install`:

```yaml
dependencies:
  termbuf-input:
    github: plambert/termbuf-input.cr
```

A stream owns the device only for reading. Raw mode, mouse reporting and bracketed paste are
someone else's to turn on and to put back; the `stty` calls below are what that looks like with
nothing else in the program.

```crystal
require "termbuf-input"

alias Input = TermBuf::Input

def stty(*args : String) : Nil
  Process.run "stty", args.to_a, input: Process::Redirect::Inherit
end

stty "raw", "-echo"

stream = Input::Stream.new STDIN, blocking: true
stream.start

loop do
  case event = stream.events.receive
  when Input::Events::Key
    break if event.key.is? 'q'
    print "key #{event.key}\r\n"
  when Input::Events::Paste
    print "pasted #{event.text.size} characters\r\n"
  when Input::Events::Closed
    break
  end
end

stream.close
stty "sane"
```

`blocking:` says whether a read on this device blocks the thread it runs on. A terminal does, and
gets an isolated execution context to itself; an `IO::Memory` does not, and gets a fibre.

`Event` is a marker module rather than a union of the types below, so a `case` over it cannot be
exhaustive and nothing checks that every kind is handled: a driver, or the application, can put
events of its own on the same channel, and anything unmatched above is ignored.

## Events

| Event | Carries |
| --- | --- |
| `Events::Key` | `key`, and `bytes` as the terminal sent them |
| `Events::Paste` | `text` from between the bracketed paste markers, and `complete`, false when the paste ended on a stall or the size limit instead of a closing marker |
| `Events::Pasting` | `bytes` so far and `elapsed`, repeated while a long paste is still arriving |
| `Events::Mouse` | `button`, 0-based `x` and `y`, `modifiers`, `action` |
| `Events::Response` | the `bytes` of a sequence, for a pattern with nothing more specific to say |
| `Events::Timer` | the `nonce` `Stream#after` handed back |
| `Events::Signal` | the `signal`, and `count` deliveries of it since the count was last cleared |
| `Events::Warning`, `Events::Failure` | a message or an exception. Nothing here sends them; they are for a driver to `#inject` |
| `Events::Closed` | input ended or the stream was closed. Nothing follows |

## The stream

`Stream` is a reader and a dispatcher over one queue.

The reader does the read on the device and puts what it got on an internal channel. `Timers` and
`Signals` put their wake-ups on that same channel, which is the point of the design: a timer tick
and a `SIGWINCH` are ordered against the keystrokes around them rather than racing them. The
dispatcher fibre drains the queue, feeds bytes to the `Decoder` — which uses `SequenceScanner` to
cut the stream into complete escape sequences and `Patterns` to decide which of those are replies
the application registered for rather than keys — and turns each result into an event. Before an
event reaches the channel it walks the `#stages` chain.

| Member | Does |
| --- | --- |
| `.new(io, blocking)` | Builds one over *io*. SGR mouse reports are watched for from this moment |
| `#preload(bytes)` | Decodes *bytes* ahead of anything read, for what a capability probe swallowed. Before `#start` |
| `#start` | Starts the reader and the dispatcher |
| `#events` | `Channel(Event)`, 256 deep. Once it fills, decoding stops and then reading does |
| `#after(span)`, `#cancel(nonce)` | A timer, in order with the bytes around it |
| `#inject(event)` | Sends an event without decoding anything, and without the stages |
| `#stages`, `#stages=` | The chain every decoded event walks |
| `#patterns`, `#decoder`, `#timers`, `#signals` | The pieces, for registering and for tuning |
| `#close` | Stops delivering, resets the signal traps, disarms the timers |

`#close` leaves the reader where it is, blocked on a device only whoever opened it can close.
Nothing it reads after that reaches anyone.

## Keys

`Key` is a value: a `Name`, a `Char` for `Name::Character`, and the `Modifiers` held with it. What
the terminal sent is on the `Events::Key` around it.

`Key.parse` reads back what `Key#to_s` writes, so a binding table can be written as text:

```crystal
require "termbuf-input"

alias Input = TermBuf::Input

bindings = {
  Input::Key.parse_one("Ctrl+C") => :quit,
  Input::Key.parse_one("Alt+Up") => :promote,
  Input::Key.parse_one("F5")     => :refresh,
}

Input::Key.parse "Ctrl+X s" # => [Ctrl+X, s]
```

A space separates descriptions, which is unambiguous because the space key is written `Space`.
Descriptions are normalised to what the decoder emits for the same key press: `Ctrl` and a letter
is one C0 byte on the wire, so `Ctrl+I` parses to `Tab`, `Ctrl+M` and `Ctrl+J` to `Enter`, and
`Ctrl+[` to `Escape`. `Ctrl+H` keeps its modifier, because `0x08` and `0x7F` are two keys a
keyboard with both sends apart.

`Key#is?` is the ordinary test: `is? 'q'` ignores shift and nothing else, and `is? Key::Name::Up`
ignores every modifier.

Terminals speaking the kitty keyboard protocol report the keypad, the lock keys, the media keys,
the modifiers themselves and the function keys past F20, and those have `Name`s of their own.
Sequences in that form are decoded whether or not the protocol was asked for, since a terminal left
in that mode by whatever ran before should still work. What `Decoder#kitty_keyboard?` changes is
waiting: with the protocol on, the escape key arrives as `CSI 27 u`, so a lone `ESC` begins
something longer and there is nothing to time out.

## Mouse

`Mouse.decode` reads an SGR report — `CSI < button ; column ; row M` or `m` — into an
`Events::Mouse` with 0-based coordinates, or `nil` if the sequence is not one after all. A stream
registers it on `CSI <` when it is built, so a report arrives as an event whoever asked the
terminal for it. Turning the reporting on is the application's call: a terminal reporting the mouse
no longer lets the person select text with it.

A wheel notch is an `Action::Press` whose button answers `Button#wheel?`, and no release follows
it. An application that would rather have the bytes unregisters the stream's pattern and puts its
own on `CSI <`.

## Patterns

A reply and a keystroke cannot be told apart by looking at them: an arrow key sends `ESC [ A`, and
so could a terminal. What separates them is that the application asked for one.

```crystal
require "termbuf-input"

alias Input = TermBuf::Input

stream = Input::Stream.new STDIN, blocking: true

# The answer to CSI 6 n, which is CSI row ; col R.
cursor = stream.patterns.register Input::Prefix::CSI, terminator: "R" do |sequence|
  Input::Events::Response.new sequence.bytes
end

stream.patterns.unregister cursor
```

A handler is given a `Sequence` — the `bytes`, the `Prefix`, the `body` after the introducer, and
the `final` byte for the kinds that end with one — and returns an event, or `nil` to mean "not mine
after all", which sends the sequence on to the next pattern and failing that to the key decoder.
`Prefix.split` turns a written prefix such as `"\e[?"` into the `Prefix` and the head to match,
for an API that would rather keep taking a string.

## Timers and signals

`Stream#after` arms a timer and hands back the `Nonce` naming it; the `Events::Timer` arrives no
sooner than the span, and after whatever the terminal had already said. `#cancel` withdraws it,
including one whose fibre has already woken.

`Signals` traps nothing until `#install` is called, because traps are process-global and a stream
is not necessarily the process. Whatever installs must uninstall; `Stream#close` does.

```crystal
require "termbuf-input"

alias Input = TermBuf::Input

stream = Input::Stream.new STDIN, blocking: true
signals = stream.signals

signals.mode ::Signal::INT, Input::Signals::Mode::WarnThenExit
signals.threshold ::Signal::INT, 2
signals.before_exit { print "\e[?1049l" }
signals.on(::Signal::TSTP) { print "\e[?1049l" }
signals.install
```

`Mode::Exit` runs the `#before_exit` hooks in the handler itself, resets the signal and re-raises
it, so the process dies of what it was sent. `Mode::Event` delivers an `Events::Signal` and carries
on. `Mode::WarnThenExit` delivers one each time and exits on the `#threshold`th, which is what
"press again to quit" is made of; `#reset_count` clears the tally. A `#on` hook runs instead of the
modes, for the signals whose answer is neither — `TSTP` gives the terminal back, `CONT` takes it
again. `TERM`, `INT` and `HUP` default to `Exit` and `WINCH` to `Event`.

## Stages

A stage is handed each event and an `emit` proc. Calling it once passes the event on or replaces
it, not calling it consumes the event, and calling it more than once injects extras. Emitting hands
the event to the next stage, so a stage cannot loop.

```crystal
require "termbuf-input"

alias Input = TermBuf::Input

stream = Input::Stream.new STDIN, blocking: true

handler = ->(event : Input::Event, emit : Proc(Input::Event, Nil)) do
  mouse = event.as? Input::Events::Mouse
  return if mouse && mouse.action.motion?

  emit.call event
end

stream.stages = stream.stages.dup.tap &.push(Input::Stage.new(:drop_motion, handler))
```

The chain is empty by default. The array is swapped rather than mutated, as above: the dispatcher
takes a reference to it once per event, so mutating the one `#stages` returns is a race. termbuf
answers `SIGWINCH` in a stage called `:resize`, which consumes the signal and sends a resize event
in its place. `#inject` bypasses the chain.

## Decoding without a device

`Decoder` turns `Bytes` into events with no device anywhere in sight, which is how most of the
specs are written:

```crystal
require "termbuf-input"

decoder = TermBuf::Input::Decoder.new
decoder.feed "\e[1;5A".to_slice do |event|
  puts event.as(TermBuf::Input::Events::Key).key # => Ctrl+Up
end
```

A caller driving the decoder itself owes it the waiting: `#read_deadline` says how long it may
block before something held back has to be given up on, and `#tick` is what works out which
deadline it was. `nil` means there is nothing being held and nothing to wake up for.
`#escape_timeout`, `#paste_notice`, `#paste_progress` and `#paste_stall` are settable, and worth
raising over a slow link.

## Development

```bash
shards install
crystal spec -v --error-trace
crystal tool format --check
ameba
```

## License

MIT. See [LICENSE](LICENSE).
