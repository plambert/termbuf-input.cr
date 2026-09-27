# Asks the terminal every question this shard knows how to ask, and prints
# what came back.
#
#     crystal run examples/queries.cr
#
# The questions go out on the alternate screen, because a terminal that does
# not recognise one may print it instead of answering. The answers are
# printed on the normal screen once they are all in.

require "../src/termbuf-input"

alias Input = TermBuf::Input

def stty(*args : String) : String
  output = IO::Memory.new
  Process.run "stty", args.to_a, input: Process::Redirect::Inherit, output: output
  output.to_s.strip
end

# ameba:disable Metrics/CyclomaticComplexity
def describe(event : Input::Event) : String
  case event
  when Input::Events::Unanswered       then "no answer"
  when Input::Events::CursorPosition   then "column #{event.x}, row #{event.y} (from zero)"
  when Input::Events::TextAreaSize     then "#{event.columns} columns, #{event.rows} rows"
  when Input::Events::TextAreaPixels   then "#{event.width} × #{event.height} pixels"
  when Input::Events::CellPixels       then "#{event.width} × #{event.height} pixels"
  when Input::Events::ModeReport       then "#{event.state}#{event.state.supported? ? "" : " (unsupported)"}"
  when Input::Events::KittyKeyboard    then "flags #{event.flags}"
  when Input::Events::TerminalName     then event.text
  when Input::Events::DeviceAttributes then event.parameters.join(";")
  when Input::Events::Color
    hex = "#%02x%02x%02x" % {event.red, event.green, event.blue}
    "#{hex}#{event.dark? ? ", dark" : ", light"}"
  else
    event.inspect
  end
end

# What to ask, and what to call it in the table.
QUESTIONS = [
  {"device attributes", Input::Query::DEVICE_ATTRIBUTES},
  {"secondary device attributes", Input::Query::SECONDARY_DEVICE_ATTRIBUTES},
  {"terminal name", Input::Query::TERMINAL_NAME},
  {"cursor position", Input::Query::CURSOR_POSITION},
  {"text area size", Input::Query::TEXT_AREA_SIZE},
  {"text area pixels", Input::Query::TEXT_AREA_PIXELS},
  {"cell pixels", Input::Query::CELL_PIXELS},
  {"kitty keyboard", Input::Query::KITTY_KEYBOARD},
  {"foreground colour", Input::Query::FOREGROUND},
  {"background colour", Input::Query::BACKGROUND},
  {"cursor colour", Input::Query::CURSOR_COLOR},
  {"palette colour 0", Input::Query.palette(0)},
  {"palette colour 1", Input::Query.palette(1)},
  {"palette colour 15", Input::Query.palette(15)},
  {"bracketed paste (2004)", Input::Mode::BRACKETED_PASTE.query},
  {"focus events (1004)", Input::Mode::FOCUS_EVENTS.query},
  {"SGR mouse (1006)", Input::Mode::MOUSE_SGR.query},

  # Not decoded yet: asked to see which terminals have them.
  {"button-event mouse (1002)", Input::Query.mode(1002)},
  {"any-event mouse (1003)", Input::Query.mode(1003)},
  {"SGR-Pixels mouse (1016)", Input::Query.mode(1016)},
  {"synchronized output (2026)", Input::Query.mode(2026)},
  {"colour scheme updates (2031)", Input::Query.mode(2031)},
  {"in-band resize (2048)", Input::Query.mode(2048)},
].compact_map { |(label, query)| {label, query} if query }

saved = stty "-g"
stty "raw", "-echo"

stream = Input::Stream.new STDIN, blocking: true
queries = Input::Queries.new stream, STDOUT
stream.start

answers = [] of {String, String}
waiting = Deque(String).new

print "\e[?1049h"
STDOUT.flush

begin
  QUESTIONS.each do |(label, query)|
    waiting << label
    queries.ask query
  end

  # Every terminal answers the sentinel, so this is only for one that
  # stops answering altogether.
  deadline = stream.after 5.seconds

  until waiting.empty?
    event = stream.events.receive?
    break unless event

    case event
    when Input::Events::Timer
      break if event.nonce == deadline
    when Input::Events::Key, Input::Events::Mouse, Input::Events::Focus,
         Input::Events::Signal
      # Something the person did, or a report already switched on.
    else
      answers << {waiting.shift, describe(event)}
    end
  end
ensure
  print "\e[?1049l"
  STDOUT.flush
  queries.close
  stream.close
  stty saved
end

puts "TERM=#{ENV["TERM"]?} TERM_PROGRAM=#{ENV["TERM_PROGRAM"]?} #{ENV["TERM_PROGRAM_VERSION"]?}"
puts

width = QUESTIONS.max_of &.[0].size
answers.each { |(name, answer)| puts "#{name.ljust width}  #{answer}" }
waiting.each { |name| puts "#{name.ljust width}  nothing, not even the sentinel" }
