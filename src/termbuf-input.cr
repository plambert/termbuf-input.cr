require "./termbuf-input/key"
require "./termbuf-input/utf8"
require "./termbuf-input/event"
require "./termbuf-input/mouse"
require "./termbuf-input/focus"
require "./termbuf-input/replies"
require "./termbuf-input/query"
require "./termbuf-input/mode"
require "./termbuf-input/scanner"
require "./termbuf-input/patterns"
require "./termbuf-input/decoder"
require "./termbuf-input/signals"
require "./termbuf-input/stage"
require "./termbuf-input/stages"
require "./termbuf-input/timers"
require "./termbuf-input/reader"
require "./termbuf-input/stream"

module TermBuf
  # The input side of a terminal: the bytes it sends, turned into events.
  #
  # This is the whole of the `termbuf-input` shard, which depends on nothing
  # outside the standard library and knows nothing about screens, cells or
  # capabilities. termbuf is one thing built on it; a program that only wants
  # to read a keyboard needs nothing else.
  #
  # `Input::Stream` is the one to reach for. Give it the device and it gives
  # back a channel of events: `Input::Events::Key` for a keystroke,
  # `Input::Events::Paste` for what arrived between bracketed paste markers,
  # and whatever a registered `Input::Pattern` makes of a reply the application
  # asked for.
  #
  # `Input::Reader` reads, `Input::Decoder` decodes, `Input::SequenceScanner`
  # splits the byte stream into complete escape sequences, and
  # `Input::Patterns` says which of those are replies rather than keys.
  # `Input::Timers` puts wake-ups in the same queue as the bytes, which is how
  # `Input::Events::Timer` arrives in order with everything else, and
  # `Input::Signals` puts signals on it too, so that a resize or an interrupt
  # is ordered against the keystrokes around it. `Input::Mouse` decodes the SGR
  # mouse reports, which a stream watches for from the moment it is built, and
  # `Input::Focus` does the same for focus reports.
  #
  # `Input::Mode` names the terminal modes that make those reports, and the
  # others this shard decodes the effects of: bracketed paste, the kitty
  # keyboard protocol and modifyOtherKeys. `Input::Modes` turns them on
  # through an output and back off again on the way out.
  #
  # `Input::Query` is a request the terminal answers — where the cursor is,
  # how big the window is, what colour the background is, whether a mode is
  # supported — and `Input::Queries` sends one and delivers the answer as an
  # event, or says it went unanswered. `Input::Replies` holds the parsers.
  #
  # `Input::Stage` is the last thing an event passes: a chain the driver and
  # the application both put translations in, walked between the dispatcher
  # and the channel.
  #
  # Every one of them is usable on its own.
  module Input
    {% begin %}
    {% command = "shards version '" + __DIR__.gsub(%r{'}, "'\\''") + "'" %}
    VERSION = {{ `#{command.id}`.strip.stringify }}
    {% end %}
  end
end
