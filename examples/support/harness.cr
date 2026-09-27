# What the example programs share: raw mode and the alternate screen, the
# stream and its helpers, a timed wait for events, and the report every run
# writes for sending back.

require "../../src/termbuf-input"

alias Input = TermBuf::Input

class Harness
  COMMIT = {{ `git rev-parse --short HEAD 2>/dev/null || echo unknown`.stringify.strip }}

  # Ctrl+N skips a step and Ctrl+C stops the run. Neither is under test.
  SKIP = Input::Key.parse_one "Ctrl+N"
  QUIT = Input::Key.parse_one "Ctrl+C"

  enum Status
    # The terminal did what was expected.
    Pass

    # The terminal did something else. A bug here or in the terminal.
    Fail

    # The terminal says it does not do this, or did something that means it
    # does not. Not a bug.
    Unsupported

    # Skipped at the keyboard, or not run because an earlier answer ruled it
    # out.
    Skip

    # Recorded for the report, with nothing to judge.
    Info
  end

  record Result, status : Status, title : String, detail : String

  class Stopped < Exception
  end

  getter stream : Input::Stream
  getter modes : Input::Modes
  getter queries : Input::Queries
  getter results = [] of Result

  # Sequences that reached the key decoder as `Unknown`. During a query that
  # is a reply the parsers did not recognise, which is a bug.
  getter unrecognised = [] of String

  # What arrived unrecognised during the last `#ask`, if anything did.
  @garbled : String? = nil

  @saved : String
  @alternate : Bool

  def initialize(@program : String)
    @saved = stty "-g"
    stty "raw", "-echo"

    @stream = Input::Stream.new STDIN, blocking: true
    @modes = Input::Modes.new STDOUT
    @queries = Input::Queries.new @stream, STDOUT
    @alternate = false

    @stream.signals.before_exit { restore }
    @stream.signals.install
    @stream.start
  end

  def stty(*args : String) : String
    output = IO::Memory.new
    Process.run "stty", args.to_a, input: Process::Redirect::Inherit, output: output
    output.to_s.strip
  end

  # What `stty size` says, as columns and rows.
  def stty_size : {Int32, Int32}?
    rows, columns = stty("size").split.map &.to_i
    {columns, rows}
  rescue
    nil
  end

  def say(text : String = "") : Nil
    print text.gsub("\n", "\r\n"), "\r\n"
    STDOUT.flush
  end

  # Writes *text* at 1-based *row* and *column*.
  def at(row : Int32, column : Int32, text : String) : Nil
    print "\e[#{row};#{column}H", text
    STDOUT.flush
  end

  def enter_alternate : Nil
    print "\e[?1049h\e[H\e[2J"
    STDOUT.flush
    @alternate = true
  end

  def leave_alternate : Nil
    return unless @alternate

    print "\e[?1049l"
    STDOUT.flush
    @alternate = false
  end

  def clear : Nil
    print "\e[H\e[2J"
    STDOUT.flush
  end

  def record(status : Status, title : String, detail : String = "") : Nil
    @results << Result.new(status, title, detail)
  end

  # The next event within *timeout*, or `nil`. Raises `Stopped` on Ctrl+C.
  def next_event(timeout : Time::Span) : Input::Event?
    event = select
    when received = @stream.events.receive?
      received
    when timeout timeout
      nil
    end

    if event.is_a?(Input::Events::Key)
      raise Stopped.new if event.key == QUIT
      @unrecognised << String.new(event.bytes).inspect if event.key.is?(Input::Key::Name::Unknown)
    end

    event
  end

  # Asks *query* and waits for its answer or `Events::Unanswered`. `nil`
  # means not even the sentinel came back.
  def ask(query : Input::Query, timeout : Time::Span = 3.seconds) : Input::Event?
    seen = @unrecognised.size
    @queries.ask query
    deadline = Time.instant + timeout
    @garbled = nil

    loop do
      remaining = deadline - Time.instant
      return if remaining <= Time::Span.zero

      event = next_event remaining
      return unless event

      if reply? event
        @garbled = @unrecognised[seen..].join(" ") if @unrecognised.size > seen
        return event
      end
    end
  end

  # Records that *title* got no answer: `Unsupported`, unless a reply arrived
  # that nothing recognised, which is a bug.
  def no_answer(title : String, detail : String = "") : Nil
    if garbled = @garbled
      record Status::Fail, title, "a reply arrived that nothing recognised: #{garbled}"
    else
      record Status::Unsupported, title, detail
    end
  end

  def reply?(event : Input::Event) : Bool
    case event
    when Input::Events::CursorPosition, Input::Events::TextAreaSize,
         Input::Events::TextAreaPixels, Input::Events::CellPixels,
         Input::Events::ModeReport, Input::Events::KittyKeyboard,
         Input::Events::Color, Input::Events::DeviceAttributes,
         Input::Events::TerminalName, Input::Events::Unanswered
      true
    else
      false
    end
  end

  # Waits for y, n or Ctrl+N, and answers `Pass`, `Fail` or `Skip`.
  def confirm : Status
    loop do
      event = next_event 10.minutes
      next unless event.is_a?(Input::Events::Key)

      key = event.key
      return Status::Pass if key.is?('y')
      return Status::Fail if key.is?('n')
      return Status::Skip if key == SKIP
    end
  end

  def restore : Nil
    @modes.reset
    leave_alternate
    stty @saved
  end

  # Puts the terminal back, prints the results, and writes the report.
  def finish(stopped : Bool = false) : Nil
    @queries.settle
    restore
    @queries.close
    @stream.close

    report = String.build { |io| write_report io, stopped }
    path = "termbuf-input-#{@program}-#{terminal_slug}.txt"
    File.write path, report

    puts report
    puts "Saved as #{path}. Send that file back; it is everything above."
  end

  private def write_report(io : IO, stopped : Bool) : Nil
    io.puts "termbuf-input #{Input::VERSION} (#{COMMIT}) examples/#{@program}.cr"
    io.puts "TERM=#{ENV["TERM"]?} TERM_PROGRAM=#{ENV["TERM_PROGRAM"]?} TERM_PROGRAM_VERSION=#{ENV["TERM_PROGRAM_VERSION"]?}"
    io.puts "TMUX=#{ENV["TMUX"]? ? "set" : "unset"} #{Time.local.to_s "%F %T %z"}"
    io.puts "stopped early with Ctrl+C" if stopped
    io.puts
    io.puts "PASS as expected. FAIL a bug, here or in the terminal. UNSUPPORTED the terminal does not"
    io.puts "do this, which is fine. SKIP skipped. INFO recorded, nothing to judge."
    io.puts

    width = @results.max_of?(&.title.size) || 0
    @results.each do |result|
      io << result.status.to_s.upcase.ljust(12)
      io << (result.detail.empty? ? result.title : "#{result.title.ljust width}  #{result.detail}")
      io.puts
    end

    io.puts
    counts = Status.values.compact_map do |status|
      count = @results.count &.status.==(status)
      "#{count} #{status.to_s.downcase}" if count > 0
    end
    io.puts counts.join(", ")

    return if @unrecognised.empty?

    io.puts
    io.puts "Sequences nothing recognised (each one is a bug worth reporting):"
    @unrecognised.uniq.each { |bytes| io.puts "  #{bytes}" }
  end

  private def terminal_slug : String
    name = ENV["TERM_PROGRAM"]? || ENV["TERM"]? || "unknown"
    name.downcase.gsub(/[^a-z0-9]+/, "-").strip('-')
  end
end
