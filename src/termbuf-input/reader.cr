require "./signals"
require "./timers"
{% if flag?(:win32) %}
  require "./win32/console"
{% end %}

module TermBuf
  module Input
    # The fibre that reads the terminal and nothing else.
    #
    # It does no decoding, which is the point: a read from a real device blocks
    # its thread, so the only thing that should happen on that thread is the
    # read. What comes back goes onto a channel and someone else's fibre makes
    # sense of it.
    class Reader
      # One read's worth. Large enough that a paste arrives in few enough
      # pieces to be cheap, small enough to cost nothing when idle.
      BUFFER_SIZE = 4096

      # Reads waiting to be decoded. Once this fills the reader stops reading,
      # which is the right way round: the kernel's own buffer then applies
      # backpressure to the keyboard rather than memory growing here.
      CAPACITY = 16

      # Input has ended. Nothing follows it on the channel.
      record Eof

      # The window changed size. Sent by a Windows console, which reports a
      # resize in its input; a terminal says so with `SIGWINCH` instead.
      record Resized

      # What arrives on the inbound channel. A union rather than plain `Bytes`
      # so that the end of input is a value like any other, and so that a
      # wake-up that came from nowhere near the device has somewhere to go.
      #
      # The reader itself only ever sends `Bytes`, `Resized` and one `Eof`. A
      # `Timers::Tick` comes from a timer fibre and a `Signals::Signalled` from
      # Crystal's signal fibre, and both arrive here rather than on channels of
      # their own so that they are ordered against the bytes: what the terminal
      # said before a timer was armed, or before a signal landed, is always
      # dispatched before it.
      alias Inbound = Bytes | Timers::Tick | Signals::Signalled | Resized | Eof

      # What has been read, in the order it was read.
      getter inbound : Channel(Inbound)

      # Whether the reader is running.
      getter? started : Bool = false

      @context : Fiber::ExecutionContext::Isolated?

      {% if flag?(:win32) %}
        # The console being read, when the device is one.
        @console : Console? = nil
      {% end %}

      # Builds a reader over *io*, which is not read from until `#start`.
      #
      # *blocking* says whether a read on *io* blocks the thread it runs on,
      # which is what decides where `#start` puts the loop. See `#start`.
      def initialize(@io : IO, @blocking : Bool)
        @inbound = Channel(Inbound).new CAPACITY
      end

      # Starts reading.
      #
      # A blocking read on a real device needs a thread of its own, or it
      # stalls every fibre sharing one. An in-memory stream returns straight
      # away and does not.
      def start : Nil
        return if @started
        @started = true

        {% if flag?(:win32) %}
          # A console is read record by record, which is what reports a resize
          # and what can be stopped. See `Console`.
          if @blocking && (console = Console.for? @io)
            @console = console
            @context = Fiber::ExecutionContext::Isolated.new("termbuf-input") { run_console console }
            return
          end
        {% end %}

        if @blocking
          @context = Fiber::ExecutionContext::Isolated.new("termbuf-input") { run }
        else
          spawn(name: "termbuf-input") { run }
        end
      end

      # Stops reading, where the device allows it.
      #
      # A Windows console's read is woken and ends. A read from anything else
      # stays blocked until the device has something to say or closes, since
      # nothing can wake a blocked read portably; what it reads after this
      # goes nowhere.
      def stop : Nil
        {% if flag?(:win32) %}
          @console.try &.stop
        {% end %}
      end

      private def run : Nil
        buffer = Bytes.new BUFFER_SIZE

        loop do
          count = @io.read buffer
          break if count.zero?

          # The buffer is read into again straight away, so what goes on the
          # channel has to be a copy.
          @inbound.send buffer[0, count].dup
        end
      rescue IO::Error
        # The terminal went away, which is an ending like any other.
      rescue Channel::ClosedError
        # Nobody is decoding any more.
      ensure
        @inbound.send Eof.new rescue nil
      end

      {% if flag?(:win32) %}
        private def run_console(console : Console) : Nil
          loop do
            batch = console.read
            next unless batch

            @inbound.send batch.bytes unless batch.bytes.empty?
            @inbound.send Resized.new if batch.resized
          end
        rescue Console::Stopped
          # `#stop` was called.
        rescue IO::Error
          # The console went away, which is an ending like any other.
        rescue Channel::ClosedError
          # Nobody is decoding any more.
        ensure
          @inbound.send Eof.new rescue nil
        end
      {% end %}
    end
  end
end
