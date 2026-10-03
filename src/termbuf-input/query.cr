require "./event"
require "./patterns"
require "./replies"

module TermBuf
  module Input
    # A request the terminal answers, and how to read the answer.
    #
    # The constants and class methods here cover what this shard decodes.
    # `Queries#ask` sends one and delivers the answer as an event, or
    # `Events::Unanswered` when the terminal has nothing to say.
    class Query
      # What to call this query when saying it went unanswered.
      getter name : String

      # What is written to the terminal to ask.
      getter request : String

      def initialize(@name : String, @request : String, &@decode : Sequence -> Event?)
      end

      # What the answer in *sequence* says, or `nil` if it is not the answer.
      def decode(sequence : Sequence) : Event?
        @decode.call sequence
      end

      def to_s(io : IO) : Nil
        io << @name
      end

      # Where the cursor is, as `Events::CursorPosition`.
      #
      # The reply has the shape of a modified F3, so while this is outstanding
      # a Ctrl+F3 pressed at the right moment reads as the answer.
      CURSOR_POSITION = new("cursor position", "\e[6n") { |sequence| Replies.cursor_position sequence }

      # The text area in cells, as `Events::TextAreaSize`.
      TEXT_AREA_SIZE = new("text area size", "\e[18t") { |sequence| Replies.text_area_size sequence }

      # The text area in pixels, as `Events::TextAreaPixels`.
      TEXT_AREA_PIXELS = new("text area pixels", "\e[14t") { |sequence| Replies.text_area_pixels sequence }

      # One cell in pixels, as `Events::CellPixels`.
      CELL_PIXELS = new("cell pixels", "\e[16t") { |sequence| Replies.cell_pixels sequence }

      # The kitty keyboard flags in force, as `Events::KittyKeyboard`. A
      # terminal without the protocol leaves this unanswered.
      KITTY_KEYBOARD = new("kitty keyboard", "\e[?u") { |sequence| Replies.kitty_keyboard sequence }

      # The default foreground colour, as `Events::Color`.
      FOREGROUND = new("foreground colour", "\e]10;?\a") { |sequence| Replies.color sequence }

      # The default background colour, as `Events::Color`.
      BACKGROUND = new("background colour", "\e]11;?\a") { |sequence| Replies.color sequence }

      # The cursor colour, as `Events::Color`.
      CURSOR_COLOR = new("cursor colour", "\e]12;?\a") { |sequence| Replies.color sequence }

      # The primary device attributes, as `Events::DeviceAttributes`.
      DEVICE_ATTRIBUTES = new("device attributes", "\e[c") do |sequence|
        Replies.device_attributes(sequence).try { |event| event unless event.secondary }
      end

      # The secondary device attributes, as `Events::DeviceAttributes`.
      SECONDARY_DEVICE_ATTRIBUTES = new("secondary device attributes", "\e[>c") do |sequence|
        Replies.device_attributes(sequence).try { |event| event if event.secondary }
      end

      # The terminal's own name and version, as `Events::TerminalName`.
      TERMINAL_NAME = new("terminal name", "\e[>0q") { |sequence| Replies.terminal_name sequence }

      # Palette entry *index*, as `Events::Color`.
      def self.palette(index : Int32) : Query
        new("palette colour #{index}", "\e]4;#{index};?\a") do |sequence|
          Replies.color(sequence).try { |event| event if event.index == index }
        end
      end

      # DEC private mode *number*, as `Events::ModeReport`.
      def self.mode(number : Int32) : Query
        new("mode #{number}", "\e[?#{number}$p") { |sequence| Replies.mode_report sequence, number }
      end
    end

    # Queries sent to a terminal and not yet answered, and the patterns that
    # read the answers.
    #
    # Every `#ask` writes the query and then a primary device attributes
    # request, which every terminal answers. Terminals answer in order, so a
    # device attributes reply arriving while a query has no answer means none
    # is coming, and that query becomes `Events::Unanswered`. The device
    # attributes reply itself is `Claimed`, and goes nowhere.
    #
    # Answers are read in order too. Only the oldest query is waiting at any
    # moment, so a reply the same shape as a key is taken for an answer only
    # between that query going out and its answer coming back.
    class Queries
      # Asked after every query, to mark where its answer would have ended.
      SENTINEL = "\e[c"

      # How long a query called unanswered still takes its answer.
      #
      # The sentinel's reply is taken to mean every answer before it is in,
      # which holds for a terminal and not for a Windows console in front of
      # one. The console answers the device attributes itself, at once, and
      # passes other queries on to the terminal hosting it: measured against
      # WezTerm 20240203, its XTVERSION reply came 34 milliseconds after the
      # console's. Such an answer is still delivered, after the
      # `Events::Unanswered`, rather than reaching the key decoder as keys.
      LATE_GRACE = 500.milliseconds

      private class Entry
        getter query : Query
        property? answered : Bool = false

        def initialize(@query : Query)
        end
      end

      # A query called unanswered, and until when it still takes an answer.
      private record Late, query : Query, until : Time::Instant

      @watching : Array(Pattern)

      # See `LATE_GRACE`. Replaceable for the specs.
      property late_grace : Time::Span = LATE_GRACE

      @late = Deque(Late).new

      # Reads the answers through *patterns* and writes the questions to
      # *output*.
      def initialize(@patterns : Patterns, @output : IO)
        @state = Mutex.new
        @writing = Mutex.new
        @pending = Deque(Entry).new
        @watching = [Prefix::CSI, Prefix::OSC, Prefix::DCS].map do |prefix|
          @patterns.register(prefix) { |sequence| answer sequence }
        end
      end

      # Reads the answers through *stream*'s patterns.
      def self.new(stream : Stream, output : IO) : Queries
        new stream.patterns, output
      end

      # Sends *query*. Its answer, or `Events::Unanswered`, arrives on the
      # stream's channel in its place among everything else.
      def ask(query : Query) : Nil
        # One lock keeps the queue in the order the questions went out; the
        # other keeps the dispatcher from waiting on a write.
        @writing.synchronize do
          @state.synchronize { @pending << Entry.new(query) }
          @output << query.request << SENTINEL
          @output.flush
        end
      end

      # Sends *mode*'s query, which asks whether the terminal supports it.
      def ask(mode : Mode) : Nil
        query = mode.query
        raise ArgumentError.new "there is no asking about #{mode.name}" unless query

        ask query
      end

      # How many queries are still waiting for an answer or the sentinel.
      def pending : Int32
        @state.synchronize { @pending.size }
      end

      # Waits until every query has been answered or given up on, for no
      # longer than *timeout*, and says whether they all were.
      #
      # For the way out. A reply still in flight when the terminal goes back
      # to cooked mode lands on the shell's command line as text.
      def settle(timeout : Time::Span = 1.second) : Bool
        deadline = Time.instant + timeout

        until pending.zero?
          return false if Time.instant >= deadline

          sleep 5.milliseconds
        end

        true
      end

      # Forgets every outstanding query. A late answer then arrives as whatever
      # the patterns and the key decoder make of it.
      def clear : Nil
        @state.synchronize do
          @pending.clear
          @late.clear
        end
      end

      # Stops reading answers, and forgets every outstanding query.
      def close : Nil
        clear
        @watching.each { |pattern| @patterns.unregister pattern }
        @watching.clear
      end

      # What *sequence* means to the oldest outstanding query: its answer, the
      # end of its turn, or nothing, in which case it goes on to the next
      # pattern.
      private def answer(sequence : Sequence) : Event?
        @state.synchronize do
          entry = @pending.first?
          return late(sequence) unless entry

          unless entry.answered?
            if event = entry.query.decode sequence
              entry.answered = true
              return event
            end
          end

          attributes = Replies.device_attributes sequence
          return late(sequence) if attributes.nil? || attributes.secondary

          @pending.shift
          return Claimed.new if entry.answered?

          @late << Late.new(entry.query, Time.instant + @late_grace)
          Events::Unanswered.new(entry.query)
        end
      end

      # The answer to a query already called unanswered, if *sequence* is one
      # and the query is still within its grace. The caller holds the lock.
      private def late(sequence : Sequence) : Event?
        now = Time.instant
        @late.reject! { |waiting| waiting.until <= now }

        @late.each_with_index do |waiting, index|
          if event = waiting.query.decode sequence
            @late.delete_at index
            return event
          end
        end

        nil
      end
    end
  end
end
