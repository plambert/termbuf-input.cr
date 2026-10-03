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

## Related shards

* **[plambert/termbuf.cr](https://github.com/plambert/termbuf.cr)** — the screen: a cell buffer,
  capability detection, and a diffed repaint to the terminal
* **[plambert/termbuf-widgets.cr](https://github.com/plambert/termbuf-widgets.cr)** — layout, focus,
  keymaps, and widgets such as fields, lists, tables and overlays, drawn through termbuf

## Getting started

Add the dependency to `shard.yml` and run `shards install`:

```yaml
dependencies:
  termbuf-input:
    github: plambert/termbuf-input.cr
```

A stream owns the device only for reading. Raw mode is turned on and put back on its own, with
`RawMode`, which restores exactly the modes it found and, on Windows, sets what a console needs for
a resize to be reported. `Modes` turns on what the terminal reports, here bracketed paste and focus,
and `#reset` turns it off again.

```crystal
require "termbuf-input"

alias Input = TermBuf::Input

raw = Input::RawMode.new STDIN, STDOUT
raw.enter

modes = Input::Modes.new STDOUT
modes.enable Input::Mode::BRACKETED_PASTE
modes.enable Input::Mode::FOCUS_EVENTS

stream = Input::Stream.new STDIN, blocking: true
stream.start

loop do
  case event = stream.events.receive
  when Input::Events::Key
    break if event.key.is? 'q'
    print "key #{event.key}\r\n"
  when Input::Events::Paste
    print "pasted #{event.text.size} characters\r\n"
  when Input::Events::Focus
    print (event.focused ? "focus gained" : "focus lost"), "\r\n"
  when Input::Events::Closed
    break
  end
end

stream.close
modes.reset
raw.leave
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
| `Events::Focus` | `focused`, true when the window gained focus and false when it lost it |
| `Events::Response` | the `bytes` of a sequence, for a pattern with nothing more specific to say |
| `Events::CursorPosition`, `TextAreaSize`, `TextAreaPixels`, `CellPixels`, `ModeReport`, `KittyKeyboard`, `Color`, `DeviceAttributes`, `TerminalName` | the answer to a `Query` |
| `Events::Unanswered` | the `query` the terminal had no answer to |
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
| `.new(io, blocking)` | Builds one over *io*. SGR mouse and focus reports are watched for from this moment |
| `#preload(bytes)` | Decodes *bytes* ahead of anything read, for what a capability probe swallowed. Before `#start` |
| `#start` | Starts the reader and the dispatcher |
| `#events` | `Channel(Event)`, 256 deep. Once it fills, decoding stops and then reading does |
| `#after(span)`, `#cancel(nonce)` | A timer, in order with the bytes around it |
| `#inject(event)` | Sends an event without decoding anything, and without the stages |
| `#stages` | The chain every decoded event walks, a `Stages` |
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
terminal for it. Turning the reporting on is the application's call, with `Mode::MOUSE_SGR`: a
terminal reporting the mouse no longer lets the person select text with it.

A wheel notch is an `Action::Press` whose button answers `Button#wheel?`, and no release follows
it. An application that would rather have the bytes unregisters the stream's pattern and puts its
own on `CSI <`.

## Focus

`Focus.decode` reads a focus report into an `Events::Focus`: `CSI I` when the window gains focus
and `CSI O` when it loses it. A stream registers it when it is built, so a report arrives as an
event whoever asked the terminal for it. Only the bare forms count; a `CSI I` or `CSI O` with
parameters goes on to the key decoder.

Turning the reports on is the application's call, with `Mode::FOCUS_EVENTS`, and only worth making
on a terminal that supports them. One that does not ignores the request. termbuf probes for support
as `Capability::FocusEvents`.

## Modes

`Mode` names a terminal mode that changes what the terminal sends, with the `set` and `reset`
sequences for it. The constants are the modes whose effects this shard decodes:

| Mode | Makes the terminal send |
| --- | --- |
| `BRACKETED_PASTE` | paste markers, for `Events::Paste` |
| `FOCUS_EVENTS` | focus reports, for `Events::Focus` |
| `MOUSE_SGR` | SGR mouse reports of press, release and drag, for `Events::Mouse` |
| `MOUSE_SGR_ANY` | as `MOUSE_SGR`, plus motion with no button held |
| `MOUSE_SGR_CLICKS` | as `MOUSE_SGR`, without motion |
| `KITTY_KEYBOARD` | kitty keyboard protocol keys. Set `Decoder#kitty_keyboard?` with it |
| `MODIFY_OTHER_KEYS` | xterm's `CSI 27 ; m ; c ~` for modified keys it has no other code for |

`Modes` tracks what is on over one output. `#enable` writes nothing for a mode already on, and
writes the replacement for a mode sharing a name with one that is. The three mouse modes share
`mouse-sgr`, because the terminal has one tracking mode. `#disable` turns one off, and `#reset`
turns them all off in the reverse of the order they went on. It is guarded, so a signal hook can
reset while the application enables something elsewhere.

## Queries

A terminal answers questions about itself, and `Queries` asks them. `#ask` writes a `Query` and the
answer arrives on the stream's channel as an event, in its place among everything else.

```crystal
require "termbuf-input"

alias Input = TermBuf::Input

stream = Input::Stream.new STDIN, blocking: true
queries = Input::Queries.new stream, STDOUT
stream.start

queries.ask Input::Query::BACKGROUND
queries.ask Input::Mode::FOCUS_EVENTS

loop do
  case event = stream.events.receive
  when Input::Events::Color      then puts event.dark? ? "dark" : "light"
  when Input::Events::ModeReport then puts event.state.supported?
  when Input::Events::Unanswered then puts "no answer to #{event.query}"
  end
end
```

| Query | Answer |
| --- | --- |
| `CURSOR_POSITION` | `Events::CursorPosition`, 0-based `x` and `y` |
| `TEXT_AREA_SIZE` | `Events::TextAreaSize`, `columns` and `rows` |
| `TEXT_AREA_PIXELS`, `CELL_PIXELS` | `Events::TextAreaPixels`, `Events::CellPixels`, `width` and `height` |
| `FOREGROUND`, `BACKGROUND`, `CURSOR_COLOR`, `.palette(n)` | `Events::Color`, eight-bit components and `#dark?` |
| `.mode(n)`, and `Mode#query` through `#ask(mode)` | `Events::ModeReport`, a `ModeState` with `#supported?` |
| `KITTY_KEYBOARD` | `Events::KittyKeyboard`, the `flags` in force |
| `DEVICE_ATTRIBUTES`, `SECONDARY_DEVICE_ATTRIBUTES` | `Events::DeviceAttributes` |
| `TERMINAL_NAME` | `Events::TerminalName`, what XTVERSION says |

Every `#ask` writes a primary device attributes request after the query, which every terminal
answers. Terminals answer in order, so when that reply arrives first the query becomes
`Events::Unanswered`. Otherwise it is swallowed: a handler that returns `Claimed` keeps a sequence
from going anywhere.

Only the oldest query is waiting at any moment, so a reply shaped like a key is taken for an
answer only while its query is out. A cursor report has the shape of a modified F3, and a Ctrl+F3
pressed in that window reads as the answer.

`#settle` waits until nothing is outstanding. Call it before putting the terminal back in cooked
mode, or a reply still in flight lands on the shell's command line.

`Replies` holds the parsers, which take a `Sequence` and know nothing about who asked, for a
caller reading the device itself.

## Examples

Two programs test a terminal and write a report, `termbuf-input-<program>-<terminal>.txt` in the
current directory, marking each check PASS, FAIL, UNSUPPORTED, SKIP or INFO. Run them outside tmux
and screen.

| Program | Does |
| --- | --- |
| `examples/queries.cr` | Asks every query and checks what it can: the cursor against where it was put, the size against what the device says, the pixel sizes against each other. Asks you to compare the colours with swatches |
| `examples/checklist.cr` | Walks through keys, paste, focus, the mouse, the kitty keyboard protocol, modifyOtherKeys and resizing, saying what to do and what should arrive. A failed step offers a retry |
| `examples/events.cr` | Prints every event and toggles the modes from the keyboard. Judges nothing |

A FAIL, or anything under "Sequences nothing recognised", is a bug.

```bash
crystal run examples/queries.cr
crystal run examples/checklist.cr
```

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
the `final` byte for the kinds that end with one — and returns an event, `Claimed` to keep the
sequence and deliver nothing, or `nil` to mean "not mine after all", which sends the sequence on to
the next pattern and failing that to the key decoder.
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
modes = Input::Modes.new STDOUT
signals = stream.signals

signals.mode ::Signal::INT, Input::Signals::Mode::WarnThenExit
signals.threshold ::Signal::INT, 2
signals.before_exit { modes.reset }
signals.install
```

`Mode::Exit` runs the `#before_exit` hooks in the handler itself, resets the signal and re-raises
it, so the process dies of what it was sent. `Mode::Event` delivers an `Events::Signal` and carries
on. `Mode::WarnThenExit` delivers one each time and exits on the `#threshold`th, which is what
"press again to quit" is made of; `#reset_count` clears the tally. A `#on` hook runs instead of the
modes, for the signals whose answer is neither — `TSTP` gives the terminal back, `CONT` takes it
again. `TERM`, `INT` and `HUP` default to `Exit` and `WINCH` to `Event`; on Windows, which has
neither `HUP` nor `WINCH`, the defaults are `TERM`, `INT` and `BREAK`, all `Exit`.

`WINCH` does not arrive as an `Events::Signal`. The stream measures the window and sends an
`Events::Resize` with the size it is now and the size it last reported, through `Stream#measure`,
which is `SizeDetector.detect` unless something knows better. A Windows console reports the change
with the input rather than as a signal, and it arrives as the same event.

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

stream.stages.push Input::Stage.new(:drop_motion, handler)
```

The chain is empty by default. `Stages` guards itself with a mutex: `#push` and `#replace` change it
from any fibre, and `#each` and what `Enumerable` builds on it (`#map`, `#find`, `#to_a`) see a copy
taken when the call began. An event part way through the chain when it changes finishes on the
chain it started on. Removing or reordering is a `#replace`:

```crystal
stream.stages.replace stream.stages.reject { |stage| stage.name == :drop_motion }
```

termbuf answers `Events::Resize` in a stage called `:resize`, which consumes it, resizes its
buffer, and injects a resize of its own once the buffer matches. `#inject` bypasses the chain.

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
