# Prints every event the terminal sends, with the modes that make them
# switched on and off from the keyboard.
#
#     crystal run examples/events.cr
#
# Each mode's support is asked about at the start. Every mode is reset on
# the way out, including on SIGTERM and SIGHUP.

require "../src/termbuf-input"

alias Input = TermBuf::Input

HELP = <<-TEXT
  p  bracketed paste    f  focus events      m  mouse: off, SGR, any-motion, clicks
  k  kitty keyboard     o  modifyOtherKeys
  c  cursor position    s  sizes             b  colours
  h  this help          q or Ctrl+C  quit
  TEXT

MICE = [
  {"off", nil},
  {"SGR with drag (1002)", Input::Mode::MOUSE_SGR},
  {"SGR with any motion (1003)", Input::Mode::MOUSE_SGR_ANY},
  {"SGR clicks only (1000)", Input::Mode::MOUSE_SGR_CLICKS},
]

def stty(*args : String) : String
  output = IO::Memory.new
  Process.run "stty", args.to_a, input: Process::Redirect::Inherit, output: output
  output.to_s.strip
end

def say(text : String) : Nil
  print text.gsub("\n", "\r\n"), "\r\n"
  STDOUT.flush
end

# ameba:disable Metrics/CyclomaticComplexity
def describe(event : Input::Event) : String
  case event
  when Input::Events::Key
    "key #{event.key} #{String.new(event.bytes).inspect}"
  when Input::Events::Paste
    "paste of #{event.text.size} characters#{event.complete ? "" : ", incomplete"}: #{event.text[0, 60].inspect}"
  when Input::Events::Pasting
    "pasting, #{event.bytes} bytes so far"
  when Input::Events::Mouse
    "mouse #{event.action} #{event.button} at #{event.x},#{event.y} #{event.modifiers}"
  when Input::Events::Focus
    event.focused ? "focus gained" : "focus lost"
  when Input::Events::CursorPosition
    "cursor at column #{event.x}, row #{event.y}"
  when Input::Events::TextAreaSize
    "text area #{event.columns} × #{event.rows} cells"
  when Input::Events::TextAreaPixels
    "text area #{event.width} × #{event.height} pixels"
  when Input::Events::CellPixels
    "cell #{event.width} × #{event.height} pixels"
  when Input::Events::ModeReport
    "mode #{event.mode} is #{event.state}#{event.state.supported? ? "" : ", unsupported"}"
  when Input::Events::KittyKeyboard
    "kitty keyboard flags #{event.flags}"
  when Input::Events::Color
    hex = "#%02x%02x%02x" % {event.red, event.green, event.blue}
    "#{event.slot}#{event.index.try { |index| " #{index}" }} is #{hex}, #{event.dark? ? "dark" : "light"}"
  when Input::Events::Unanswered
    "no answer to #{event.query}"
  when Input::Events::Signal
    "signal #{event.signal}"
  else
    event.inspect
  end
end

saved = stty "-g"
stty "raw", "-echo"

stream = Input::Stream.new STDIN, blocking: true
modes = Input::Modes.new STDOUT
queries = Input::Queries.new stream, STDOUT

restore = -> do
  modes.reset
  stty saved
end

stream.signals.before_exit { restore.call }
stream.signals.install
stream.start

say HELP
say ""

[Input::Mode::BRACKETED_PASTE, Input::Mode::FOCUS_EVENTS, Input::Mode::MOUSE_SGR,
 Input::Mode::KITTY_KEYBOARD].each { |mode| queries.ask mode }

mouse = 0

toggle = ->(mode : Input::Mode) do
  if modes.enabled? mode
    modes.disable mode
    say "#{mode.name} off"
  else
    modes.enable mode
    say "#{mode.name} on"
  end
end

begin
  loop do
    event = stream.events.receive?
    break unless event

    if event.is_a?(Input::Events::Key)
      key = event.key
      break if key.is?('q') || key == Input::Key.parse_one("Ctrl+C")

      case
      when key.is?('p') then next toggle.call Input::Mode::BRACKETED_PASTE
      when key.is?('f') then next toggle.call Input::Mode::FOCUS_EVENTS
      when key.is?('o') then next toggle.call Input::Mode::MODIFY_OTHER_KEYS
      when key.is?('h') then next say HELP
      when key.is?('k')
        toggle.call Input::Mode::KITTY_KEYBOARD
        stream.decoder.kitty_keyboard = modes.enabled? Input::Mode::KITTY_KEYBOARD
        next
      when key.is?('m')
        mouse = (mouse + 1) % MICE.size
        label, chosen = MICE[mouse]
        chosen ? modes.enable(chosen) : modes.disable(Input::Mode::MOUSE_SGR)
        say "mouse #{label}"
        next
      when key.is?('c')
        next queries.ask Input::Query::CURSOR_POSITION
      when key.is?('s')
        queries.ask Input::Query::TEXT_AREA_SIZE
        queries.ask Input::Query::TEXT_AREA_PIXELS
        queries.ask Input::Query::CELL_PIXELS
        next
      when key.is?('b')
        queries.ask Input::Query::FOREGROUND
        queries.ask Input::Query::BACKGROUND
        queries.ask Input::Query::CURSOR_COLOR
        next
      end
    end

    say describe(event)
  end
ensure
  restore.call
  queries.close
  stream.close
end
