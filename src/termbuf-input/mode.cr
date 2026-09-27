require "./query"

module TermBuf
  module Input
    # A terminal mode that changes what the terminal sends, and the sequences
    # that turn it on and off.
    #
    # The constants here are the modes whose reports this shard decodes. An
    # application turns them on through `Modes`, which remembers what it set
    # and gives it back on the way out, or writes `#set` and `#reset` itself.
    #
    # The *name* is what identity means, not the sequences. The terminal has
    # one mouse tracking mode, so the three mouse modes share a name, and
    # enabling one after another replaces it rather than adding to it.
    #
    # *query* asks whether the terminal supports the mode, through
    # `Queries#ask`. `nil` for a mode there is no asking about.
    record Mode, name : String, set : String, reset : String, query : Query? = nil do
      # Pasted text arrives between markers, as `Events::Paste`, rather than as
      # a very fast typist triggering every key binding on the way past.
      BRACKETED_PASTE = new "bracketed-paste", "\e[?2004h", "\e[?2004l", Query.mode(2004)

      # The terminal reports its window gaining and losing focus, as
      # `Events::Focus`. Only worth asking for where the terminal supports it;
      # one that does not ignores the request, and nothing arrives.
      FOCUS_EVENTS = new "focus-events", "\e[?1004h", "\e[?1004l", Query.mode(1004)

      # Mouse reports in the SGR encoding, as `Events::Mouse`: press, release,
      # and motion while a button is held. This is mode 1002 with 1006, and
      # the one to reach for, since without motion nothing can be dragged.
      #
      # A terminal reporting the mouse no longer lets the person select text
      # with it, which is a trade only the application can weigh.
      #
      # All three mouse modes ask about 1006, the encoding, since a terminal
      # without it reports in a form this shard does not decode.
      MOUSE_SGR = new "mouse-sgr", "\e[?1002h\e[?1006h", "\e[?1006l\e[?1002l", Query.mode(1006)

      # As `MOUSE_SGR`, with motion reported when no button is held too, which
      # is what hover needs. Every cell the pointer crosses is a report.
      MOUSE_SGR_ANY = new "mouse-sgr", "\e[?1003h\e[?1006h", "\e[?1006l\e[?1003l", Query.mode(1006)

      # As `MOUSE_SGR`, with press and release only. Kept for measuring what a
      # terminal does under mode 1000, not for use.
      MOUSE_SGR_CLICKS = new "mouse-sgr", "\e[?1000h\e[?1006h", "\e[?1006l\e[?1000l", Query.mode(1006)

      # The kitty keyboard protocol, which tells apart keys an ordinary
      # terminal reports identically. The set pushes a flag set onto the
      # terminal's own stack and the reset pops it.
      #
      # Set `Decoder#kitty_keyboard?` alongside it, so that a lone escape is
      # held for the rest of its sequence instead of timed out.
      KITTY_KEYBOARD = new "kitty-keyboard", "\e[>1u", "\e[<u", Query::KITTY_KEYBOARD

      # xterm's modifyOtherKeys at level 2, which reports a modified key the
      # usual encodings cannot name, such as `Ctrl+.`, as `CSI 27 ; m ; c ~`.
      # The kitty protocol does the same job better where it is available.
      # Few terminals answer a question about this one, so it has no query.
      MODIFY_OTHER_KEYS = new "modify-other-keys", "\e[>4;2m", "\e[>4m"
    end

    # The modes an application has turned on, and the device it turned them
    # on through.
    #
    # Enabling a mode that is already on writes nothing, and enabling one that
    # shares a name with a mode already on writes the replacement. `#reset`
    # turns everything off in the reverse of the order it went on, which is
    # what a program owes the terminal before it exits.
    #
    # Guarded, so a signal hook can call `#reset` while the application is
    # enabling something elsewhere.
    class Modes
      include Enumerable(Mode)

      def initialize(@output : IO)
        @mutex = Mutex.new
        @modes = [] of Mode
      end

      # Turns *mode* on.
      def enable(mode : Mode) : Nil
        @mutex.synchronize do
          index = @modes.index { |current| current.name == mode.name }
          return if index && @modes[index] == mode

          if index
            @modes[index] = mode
          else
            @modes << mode
          end

          write mode.set
        end
      end

      # Turns *mode*, or whichever mode of the same name is on, off. A mode
      # that is not on is nothing to turn off.
      def disable(mode : Mode) : Nil
        @mutex.synchronize do
          index = @modes.index { |current| current.name == mode.name }
          return unless index

          write @modes.delete_at(index).reset
        end
      end

      # Turns every mode off, the last one enabled first.
      def reset : Nil
        @mutex.synchronize do
          until @modes.empty?
            write @modes.pop.reset
          end
        end
      end

      # Whether *mode* is on, by name.
      def enabled?(mode : Mode) : Bool
        @mutex.synchronize { @modes.any? &.name.==(mode.name) }
      end

      # Yields each mode that is on, in the order it went on, from a copy
      # taken when the call began.
      def each(& : Mode ->) : Nil
        @mutex.synchronize { @modes.dup }.each { |mode| yield mode }
      end

      private def write(sequence : String) : Nil
        @output << sequence
        @output.flush
      end
    end
  end
end
