require "./key"
require "./mouse"
require "./focus"
require "./timers"

module TermBuf::Input
  # Anything the terminal has to say, in the order it happened.
  #
  # A marker module every event type includes, rather than a union of the ones
  # this shard happens to define. Channels, signatures and instance variables
  # are typed `Event` and keep working, and a shard that defines an event of
  # its own includes this and can send it down the same channel. termbuf's
  # own resize event is one such: it lives on the terminal side because it
  # carries a screen size, and it arrives on this channel like the rest.
  #
  # Being open, it cannot be `case`d exhaustively: a handler needs an `else`
  # for the event kinds it does not know about.
  module Event
  end

  # What a pattern returns for a sequence it claims and has nothing to say
  # about. The sequence goes no further: not to another pattern, not to the
  # key decoder, and not to the application.
  #
  # `Queries` claims the device attributes reply it asks for after every query
  # this way, since that reply only marks where the answers end.
  struct Claimed
    include Event
  end

  # What the input side tells the application about, delivered over one
  # channel.
  #
  # These are values rather than a class hierarchy. Each includes `Event`.
  module Events
    # A key press. *bytes* is what the terminal sent to say so, which matters
    # for the sequences the decoder could not name and for anything an
    # application would rather interpret itself.
    record Key, key : Input::Key, bytes : Bytes do
      include Event
    end

    # Text that arrived between bracketed paste markers.
    #
    # It is delivered whole rather than as key presses, which is the point of
    # the brackets: pasted text is not typing, and an application that treats
    # it as typing will run its key bindings over whatever was on the
    # clipboard.
    #
    # The markers arrive only once the application has turned them on with
    # `Input::Mode::BRACKETED_PASTE`.
    #
    # *complete* is false when the terminal never sent the closing marker and
    # the paste was ended on a stall or a size limit instead. What arrived is
    # still delivered, since it beats nothing, but an application storing it
    # somewhere permanent may want to know it might be half a clipboard.
    record Paste, text : String, complete : Bool do
      include Event
    end

    # A paste has been arriving long enough to be worth saying so on screen,
    # which is what stops a long one looking like a hung application.
    #
    # Repeated as it grows, no more often than the decoder's progress interval.
    # The `Paste` that follows is the signal to take the notice down.
    record Pasting, bytes : Int32, elapsed : Time::Span do
      include Event
    end

    # The pointer did something, out of an SGR mouse report.
    #
    # *x* and *y* are 0-based buffer cells, converted from the 1-based
    # coordinates the terminal sends, so they can be handed to a buffer's hit
    # test as they stand.
    #
    # These arrive only once the application has turned reporting on with
    # `Input::Mode::MOUSE_SGR` or one of its siblings.
    #
    # Nothing enables it for the application, because a terminal reporting the
    # mouse is one that no longer lets the person select text with it, and that
    # is not a trade a library makes on someone's behalf. Whatever turned the
    # mode on turns it off again on the way out.
    #
    # A wheel notch is an `Input::Mouse::Action::Press` whose button answers
    # `Input::Mouse::Button#wheel?`, and no release follows it.
    record Mouse, button : Input::Mouse::Button, x : Int32, y : Int32,
      modifiers : Modifiers, action : Input::Mouse::Action do
      include Event
    end

    # The terminal's window gained or lost focus, out of a focus report.
    #
    # These arrive only once the application has turned the reports on with
    # `Input::Mode::FOCUS_EVENTS`, and only from a terminal that supports them. Whatever
    # turned the mode on turns it off again on the way out.
    #
    # A terminal is not obliged to say where focus stands when the mode goes
    # on, so the first report may be a while coming.
    record Focus, focused : Bool do
      include Event
    end

    # Where the cursor is, in answer to `Input::Query::CURSOR_POSITION`.
    #
    # *x* and *y* are 0-based cells, like a mouse report's.
    record CursorPosition, x : Int32, y : Int32 do
      include Event
    end

    # How many columns and rows the text area has, in answer to
    # `Input::Query::TEXT_AREA_SIZE`.
    record TextAreaSize, columns : Int32, rows : Int32 do
      include Event
    end

    # How big the text area is in pixels, in answer to
    # `Input::Query::TEXT_AREA_PIXELS`.
    #
    # Pixels are whatever the terminal means by them. ghostty and kitty count
    # device pixels, so a Retina display doubles them; iTerm2 and Terminal.app
    # count points.
    record TextAreaPixels, width : Int32, height : Int32 do
      include Event
    end

    # How big one cell is in pixels, in answer to `Input::Query::CELL_PIXELS`,
    # in the terminal's own units as `TextAreaPixels` describes. iTerm2 and
    # Terminal.app do not answer.
    record CellPixels, width : Int32, height : Int32 do
      include Event
    end

    # What the terminal says about DEC private mode *mode*, in answer to
    # `Input::Query.mode` or a `Input::Mode#query`.
    record ModeReport, mode : Int32, state : Input::ModeState do
      include Event
    end

    # The kitty keyboard protocol flags in force, in answer to
    # `Input::Query::KITTY_KEYBOARD`. An answer at all means the terminal
    # speaks the protocol; zero means nothing is asked of it yet.
    record KittyKeyboard, flags : Int32 do
      include Event
    end

    # One of the terminal's colours, in answer to `Input::Query::FOREGROUND`,
    # `BACKGROUND`, `CURSOR_COLOR` or `Input::Query.palette`.
    #
    # *index* is the palette entry for `ColorSlot::Palette` and `nil` for the
    # rest. The components are scaled to eight bits whatever precision the
    # terminal answered in.
    record Color, slot : Input::ColorSlot, index : Int32?,
      red : UInt8, green : UInt8, blue : UInt8 do
      include Event

      # Whether this colour is dark, by its relative luminance. Asked of the
      # background, it is how an application picks a light or dark theme.
      def dark? : Bool
        0.2126 * red + 0.7152 * green + 0.0722 * blue < 128
      end
    end

    # The terminal's device attributes, in answer to
    # `Input::Query::DEVICE_ATTRIBUTES` or, with *secondary* set,
    # `Input::Query::SECONDARY_DEVICE_ATTRIBUTES`.
    record DeviceAttributes, secondary : Bool, parameters : Array(Int32) do
      include Event
    end

    # The name and version the terminal gives for itself, in answer to
    # `Input::Query::TERMINAL_NAME`.
    record TerminalName, text : String do
      include Event
    end

    # *query* went unanswered. The terminal answered the device attributes
    # request sent after it first, and terminals answer in order, so no
    # answer is coming.
    record Unanswered, query : Input::Query do
      include Event
    end

    # A complete escape sequence the terminal sent, which is to say an answer
    # to something that was asked of it.
    record Response, bytes : Bytes do
      include Event
    end

    # A timer the application armed with `Timers#after` has gone off.
    #
    # *nonce* is what `#after` handed back, which is how an application running
    # several timers tells them apart, and how one it no longer cares about is
    # recognised: a timer cancelled while its tick was already in flight is
    # dropped before it gets here, so anything that arrives was still wanted
    # when it was delivered.
    record Timer, nonce : Input::Nonce do
      include Event
    end

    # A signal arrived and the application is the one to act on it.
    #
    # Only for the signals whose mode is `Input::Signals::Mode::Event` or
    # `WarnThenExit`; the ones that mean "stop" restore the terminal and re-
    # raise themselves without ever reaching a channel. `SIGWINCH` is an event
    # by default and arrives like any other, unless a stage takes it: termbuf's
    # `:resize` consumes it and sends a resize event of its own in its place.
    #
    # *count* is how many of this signal have arrived since the count was last
    # cleared, counting from one. Under `WarnThenExit` it is what the warning
    # is made of: an application draws "press again to quit" on the first and
    # is gone by the last. `Input::Signals#reset_count` clears it.
    record Signal, signal : ::Signal, count : Int32 do
      include Event
    end

    # Something was wrong but not worth stopping for.
    #
    # Nothing in this shard sends one: it is here so that a driver and the
    # application have somewhere to say so, through `Stream#inject` or out of a
    # pattern or a stage. termbuf uses it for a capability override naming
    # something unknown.
    #
    # These never go to stderr. The screen belongs to the application, and
    # writing to it from underneath would corrupt the display.
    record Warning, message : String do
      include Event
    end

    # Something failed. The driver keeps going; the application decides.
    #
    # Sent by whoever failed, the same way as `Warning`. Nothing in this shard
    # sends one — a read that ends is `Closed`, not a failure.
    record Failure, error : Exception do
      include Event
    end

    # Input has ended, or the terminal is shutting down. Nothing follows.
    record Closed do
      include Event
    end
  end
end
