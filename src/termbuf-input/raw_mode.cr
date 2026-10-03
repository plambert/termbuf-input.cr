require "./screen_size"
{% if flag?(:win32) %}
  require "./win32/lib_console"
{% end %}

module TermBuf
  module Input
    # Stability: stable — changes only in a major release.
    #
    # Raw mode, and the way back to whatever the terminal was in before.
    #
    # A stream reads keys; it does not change how the terminal delivers them.
    # Without raw mode a terminal holds input until Enter, echoes it, and turns
    # Ctrl+C into a signal, so a program that wants keys as they are pressed
    # turns raw mode on first and puts the terminal back when it is done.
    #
    # Crystal's own `IO::FileDescriptor#raw!` does most of this, but it puts back
    # a *cooked* terminal rather than the one it found, which is not the same
    # thing when the program was started from something other than an ordinary
    # shell. And on Windows it leaves out what a console needs for a resize to
    # be reported and for the mouse to reach the program.
    #
    #     raw = Input::RawMode.new STDIN, STDOUT
    #     raw.enter
    #     begin
    #       # read keys
    #     ensure
    #       raw.leave
    #     end
    #
    # termbuf's `Tty` uses this for its own raw mode.
    class RawMode
      # Crystal's bindings carry `VMIN` but not `VTIME` on every platform, so the
      # index is filled in here when it is missing.
      {% if flag?(:win32) %}
        # Windows has no line discipline, and so no `VTIME`.
      {% elsif LibC.has_constant?(:VTIME) %}
        VTIME = LibC::VTIME
      {% elsif flag?(:darwin) || flag?(:bsd) %}
        VTIME = 17
      {% else %}
        VTIME = 5
      {% end %}

      # The console modes found on the input handle and, when it is a console
      # too, the output handle: what Windows has where a terminal has termios.
      record ConsoleModes, input : UInt32, output : UInt32?

      # Whether raw mode is on, by this.
      getter? active : Bool = false

      @input_fd : SizeDetector::Descriptor?
      @output_fd : SizeDetector::Descriptor?
      {% if flag?(:win32) %}
        @saved : ConsoleModes?
      {% else %}
        @saved : LibC::Termios?
      {% end %}

      # Raw mode for the terminal *input* reads from. *output* matters only on
      # Windows, where the console's output handle has modes of its own.
      # Either may be something other than a terminal, and then nothing here
      # changes it.
      def initialize(input : IO, output : IO? = nil)
        @input_fd = input.as?(IO::FileDescriptor).try &.fd
        @output_fd = output.as?(IO::FileDescriptor).try &.fd
      end

      # Turns raw mode on, keeping what was there so `#leave` can put it back.
      # Answers whether it is on: it is not when the input is not a terminal.
      #
      # Idempotent: calling it again keeps the modes first found, not the raw
      # ones, so `#leave` still has somewhere to go back to.
      def enter : Bool
        return true if @active

        fd = @input_fd
        return false unless fd

        {% if flag?(:win32) %}
          enter_console fd
        {% else %}
          original = uninitialized LibC::Termios
          return false unless LibC.tcgetattr(fd, pointerof(original)).zero?

          @saved = original
          raw = original

          raw.c_iflag &= ~(LibC::IGNBRK | LibC::BRKINT | LibC::PARMRK | LibC::ISTRIP |
                           LibC::INLCR | LibC::IGNCR | LibC::ICRNL | LibC::IXON)
          raw.c_oflag &= ~LibC::OPOST
          raw.c_lflag &= ~(LibC::ECHO | LibC::ECHONL | LibC::ICANON | LibC::ISIG | LibC::IEXTEN)
          raw.c_cflag &= ~(LibC::CSIZE | LibC::PARENB)
          raw.c_cflag |= LibC::CS8

          # Block until at least one byte arrives, with no inter-byte timer: the
          # reader wants to sleep rather than spin, and escape sequence timing is
          # decided further up, not here.
          raw.c_cc[LibC::VMIN] = 1_u8
          raw.c_cc[VTIME] = 0_u8

          LibC.tcsetattr fd, LibC::TCSANOW, pointerof(raw)
          @active = true
        {% end %}
      end

      # Puts back the modes `#enter` found. Idempotent, and safe to call when
      # raw mode was never entered.
      def leave : Nil
        fd = @input_fd
        saved = @saved
        return unless fd && saved

        @saved = nil
        @active = false

        {% if flag?(:win32) %}
          # Exactly the modes found, not a cooked console: whatever started this
          # process may have had its own reasons for the ones it set.
          LibC.SetConsoleMode LibC::HANDLE.new(fd), saved.input
          if (output = saved.output) && (out_fd = @output_fd)
            LibC.SetConsoleMode LibC::HANDLE.new(out_fd), output
          end
        {% else %}
          # A fresh local, because `pointerof` goes by the declared type and the
          # ivar's includes nil however narrow the check above made it.
          original = saved
          LibC.tcsetattr fd, LibC::TCSANOW, pointerof(original)
        {% end %}
      end

      {% if flag?(:win32) %}
        # Raw mode for a Windows console.
        #
        # Input: no line editing, no echo, and Ctrl+C as a byte rather than an
        # interrupt, which is what termios raw mode does too. Virtual terminal
        # input, so keys arrive as the escape sequences a terminal sends. Resizes
        # reported in the input. Quick edit off, because while it is on, dragging
        # the mouse in a classic console window selects text instead of
        # reaching the program.
        #
        # Output: escape sequences understood, and a line feed that does not
        # return the cursor, so the bottom right cell can be written without
        # scrolling the screen.
        private def enter_console(fd : SizeDetector::Descriptor) : Bool
          input = LibC::HANDLE.new fd
          return false if LibC.GetConsoleMode(input, out input_mode).zero?

          output_mode = nil
          if out_fd = @output_fd
            output_mode = console_mode LibC::HANDLE.new(out_fd)
          end

          @saved = ConsoleModes.new input_mode, output_mode

          raw = input_mode
          raw &= ~(LibC::ENABLE_PROCESSED_INPUT | LibC::ENABLE_LINE_INPUT | LibC::ENABLE_ECHO_INPUT |
                   LibTermBufConsole::ENABLE_QUICK_EDIT_MODE)
          raw |= LibC::ENABLE_VIRTUAL_TERMINAL_INPUT | LibTermBufConsole::ENABLE_WINDOW_INPUT |
                 LibTermBufConsole::ENABLE_EXTENDED_FLAGS
          LibC.SetConsoleMode input, raw

          if output_mode && (out_fd = @output_fd)
            LibC.SetConsoleMode LibC::HANDLE.new(out_fd),
              output_mode | LibC::ENABLE_VIRTUAL_TERMINAL_PROCESSING | LibTermBufConsole::DISABLE_NEWLINE_AUTO_RETURN
          end

          @active = true
        end

        # The console mode on *handle*, or `nil` when it is not a console.
        private def console_mode(handle : LibC::HANDLE) : UInt32?
          LibC.GetConsoleMode(handle, out mode).zero? ? nil : mode
        end
      {% end %}
    end
  end
end
