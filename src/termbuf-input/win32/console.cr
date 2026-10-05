require "./lib_console"

module TermBuf
  module Input
    # Reads a Windows console's input.
    #
    # Crystal reads a console with `ReadConsoleW`, which hands back characters
    # and nothing else. Three things go missing that way: a window that
    # changed size, which the console reports as a record in the input; a
    # read that can be told to stop, since `ReadConsoleW` cannot be woken; and
    # a deadline, since a console handle ignores `IO#read_timeout`. It can
    # also return nothing without the input having ended, when a read stops
    # between the halves of a surrogate pair, and the reader would take that
    # for the end.
    #
    # This reads the records themselves instead. With virtual terminal input
    # on, which raw mode turns on, the console delivers what a terminal would
    # send — escape sequences and all — as one key record per UTF-16 code
    # unit, so the bytes that come out are what the decoder already reads.
    class Console
      # Records asked for in one read.
      RECORDS = 128

      # `#read` was told to stop, by `#stop`.
      class Stopped < Exception
      end

      # What one read found: the bytes the keys made, and whether the window
      # changed size since the last read. Several size records in one read
      # are one change.
      record Batch, bytes : Bytes, resized : Bool

      # The console behind *io*, or `nil` when *io* is not one: a pipe, a file,
      # anything that is not an `IO::FileDescriptor`.
      def self.for?(io : IO) : Console?
        return unless io.is_a? IO::FileDescriptor

        handle = LibC::HANDLE.new io.fd
        return if LibC.GetConsoleMode(handle, out _).zero?

        new handle
      end

      def initialize(@handle : LibC::HANDLE)
        @translator = Translator.new
        @stop = LibTermBufConsole.CreateEventW(nil, 1, 0, nil)
        raise IO::Error.from_winerror("CreateEventW") if @stop.null?
      end

      # Waits for input and reads what there is, up to *timeout* if one is
      # given. `nil` when the time ran out first.
      #
      # A batch can be empty: the console signals for records nothing here
      # reads, such as a key being released or the mouse moving in a window
      # that is not reporting it. Raises `Stopped` once `#stop` has been
      # called, and `IO::Error` when the console cannot be read.
      def read(timeout : Time::Span? = nil) : Batch?
        handles = StaticArray[@stop, @handle]
        milliseconds = timeout ? timeout.total_milliseconds.clamp(0, LibC::INFINITE - 1).to_u32 : LibC::INFINITE.to_u32

        case LibTermBufConsole.WaitForMultipleObjects(2, handles.to_unsafe, 0, milliseconds)
        when LibC::WAIT_OBJECT_0
          raise Stopped.new
        when LibC::WAIT_OBJECT_0 + 1
          records = uninitialized LibTermBufConsole::InputRecord[RECORDS]
          if LibTermBufConsole.ReadConsoleInputW(@handle, records.to_unsafe, RECORDS, out count).zero?
            raise IO::Error.from_winerror("ReadConsoleInputW")
          end

          @translator.translate records.to_slice[0, count]
        when LibC::WAIT_TIMEOUT
          nil
        else
          raise IO::Error.from_winerror("WaitForMultipleObjects")
        end
      end

      # Makes the `#read` in progress, and every one after it, raise
      # `Stopped`. Safe from any thread.
      def stop : Nil
        LibTermBufConsole.SetEvent @stop
      end

      def finalize
        LibC.CloseHandle @stop
      end

      # Turns input records into bytes.
      #
      # Kept apart from the reading so that it can be given records made up by
      # hand, and hold its one piece of state — half a surrogate pair — between
      # reads.
      class Translator
        # A high surrogate that ended the last batch, waiting for its low half.
        @pending : UInt16? = nil

        def translate(records : Slice(LibTermBufConsole::InputRecord)) : Batch
          units = [] of UInt16
          if pending = @pending
            units << pending
            @pending = nil
          end

          resized = false

          records.each do |record|
            case record.event_type
            when LibTermBufConsole::KEY_EVENT
              key = record.event.key_event
              next unless (unit = character key)

              # A held key the console coalesced says how many times.
              Math.max(key.repeat_count.to_i, 1).times { units << unit }
            when LibTermBufConsole::WINDOW_BUFFER_SIZE_EVENT
              resized = true
            end
          end

          # A high surrogate at the end has its low half in the next read.
          if (last = units.last?) && high_surrogate? last
            @pending = units.pop
          end

          Batch.new String.from_utf16(Slice.new(units.to_unsafe, units.size)).to_slice.dup, resized
        end

        # The code unit a key record carries, or `nil` for one that carries
        # nothing to read.
        #
        # A key going down carries its character. A key coming back up
        # carries nothing, with one exception: releasing Alt after typing a
        # code on the numeric keypad is when the composed character arrives.
        private def character(key : LibTermBufConsole::KeyEventRecord) : UInt16?
          unit = key.unicode_char
          return if unit.zero?
          return unit unless key.key_down.zero?

          unit if key.virtual_key_code == LibTermBufConsole::VK_MENU
        end

        private def high_surrogate?(unit : UInt16) : Bool
          0xD800 <= unit <= 0xDBFF
        end
      end
    end
  end
end
