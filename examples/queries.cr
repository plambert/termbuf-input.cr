# Asks the terminal every question this shard knows how to ask, checks each
# answer it can against something independent, and has you check the colours
# by eye.
#
#     crystal run examples/queries.cr
#
# Run it outside tmux and screen, which answer some of these for themselves.
# It writes termbuf-input-queries-<terminal>.txt in the current directory.
#
# What the statuses mean:
#
#     PASS         the answer is what it should be
#     FAIL         the answer is wrong, or a reply was garbled: a bug
#     UNSUPPORTED  the terminal says it does not do this, which is fine
#     INFO         recorded for the report, nothing to judge
#
# Anything under "Sequences nothing recognised" is a reply the parsers could
# not read, and is always a bug.

require "./support/harness"

alias Status = Harness::Status

harness = Harness.new "queries"
stopped = false

def hex(color : Input::Events::Color) : String
  "#%02x%02x%02x" % {color.red, color.green, color.blue}
end

def truecolor(color : Input::Events::Color) : String
  "#{color.red};#{color.green};#{color.blue}"
end

colors = {} of String => Input::Events::Color

begin
  harness.enter_alternate
  harness.say "Asking the terminal about itself. This takes a few seconds."

  # Who the terminal says it is.

  case answer = harness.ask Input::Query::DEVICE_ATTRIBUTES
  when Input::Events::DeviceAttributes
    harness.record Status::Info, "device attributes", answer.parameters.join(';')
  else
    harness.record Status::Fail, "device attributes", "every terminal should answer this"
  end

  case answer = harness.ask Input::Query::SECONDARY_DEVICE_ATTRIBUTES
  when Input::Events::DeviceAttributes
    harness.record Status::Info, "secondary device attributes", answer.parameters.join(';')
  else
    harness.no_answer "secondary device attributes"
  end

  case answer = harness.ask Input::Query::TERMINAL_NAME
  when Input::Events::TerminalName
    harness.record Status::Info, "terminal name", answer.text
  else
    harness.no_answer "terminal name"
  end

  # Where the cursor is, after putting it somewhere known.

  harness.at 5, 10, ""
  case answer = harness.ask Input::Query::CURSOR_POSITION
  when Input::Events::CursorPosition
    if answer.x == 9 && answer.y == 4
      harness.record Status::Pass, "cursor position", "column 9, row 4, where it was put"
    else
      harness.record Status::Fail, "cursor position", "expected column 9, row 4; got column #{answer.x}, row #{answer.y}"
    end
  else
    harness.record Status::Fail, "cursor position", "every terminal should answer this"
  end

  # Sizes, against the kernel's idea of the window and against each other.

  cells = nil
  case answer = harness.ask Input::Query::TEXT_AREA_SIZE
  when Input::Events::TextAreaSize
    cells = {answer.columns, answer.rows}
    expected = harness.stty_size
    if expected.nil?
      harness.record Status::Info, "text area size", "#{answer.columns} × #{answer.rows}; stty size failed"
    elsif cells == expected
      harness.record Status::Pass, "text area size", "#{answer.columns} × #{answer.rows}, as stty size says"
    else
      harness.record Status::Fail, "text area size", "#{answer.columns} × #{answer.rows}; stty size says #{expected[0]} × #{expected[1]}"
    end
  else
    harness.no_answer "text area size"
  end

  area = harness.ask Input::Query::TEXT_AREA_PIXELS
  cell = harness.ask Input::Query::CELL_PIXELS

  if area.is_a?(Input::Events::TextAreaPixels)
    harness.record Status::Info, "text area pixels", "#{area.width} × #{area.height}"
  else
    harness.no_answer "text area pixels"
  end

  if cell.is_a?(Input::Events::CellPixels)
    harness.record Status::Info, "cell pixels", "#{cell.width} × #{cell.height}"
  else
    harness.no_answer "cell pixels"
  end

  # The text area should be the cells times the cell size, give or take
  # less than one cell of padding.
  if area.is_a?(Input::Events::TextAreaPixels) && cell.is_a?(Input::Events::CellPixels) && cells
    width = cells[0] * cell.width
    height = cells[1] * cell.height
    detail = "cells × cell size is #{width} × #{height}, text area is #{area.width} × #{area.height}"
    close = (area.width - width).abs < cell.width && (area.height - height).abs < cell.height
    harness.record close ? Status::Pass : Status::Fail, "pixel sizes agree", detail
  end

  # The kitty keyboard protocol.

  case answer = harness.ask Input::Query::KITTY_KEYBOARD
  when Input::Events::KittyKeyboard
    harness.record Status::Info, "kitty keyboard", "flags #{answer.flags}"
  else
    harness.no_answer "kitty keyboard"
  end

  # Colours, checked by eye once the answers are all in.

  {
    "foreground" => Input::Query::FOREGROUND,
    "background" => Input::Query::BACKGROUND,
    "cursor"     => Input::Query::CURSOR_COLOR,
    "palette 0"  => Input::Query.palette(0),
    "palette 1"  => Input::Query.palette(1),
    "palette 15" => Input::Query.palette(15),
  }.each do |name, query|
    answer = harness.ask query
    if answer.is_a?(Input::Events::Color)
      colors[name] = answer
    else
      harness.no_answer "#{name} colour"
    end
  end

  # DEC modes: the ones this shard turns on, then ones it may decode later.

  {
    "bracketed paste (2004)"       => 2004,
    "focus events (1004)"          => 1004,
    "SGR mouse (1006)"             => 1006,
    "button-event mouse (1002)"    => 1002,
    "any-event mouse (1003)"       => 1003,
    "SGR-Pixels mouse (1016)"      => 1016,
    "synchronized output (2026)"   => 2026,
    "colour scheme updates (2031)" => 2031,
    "in-band resize (2048)"        => 2048,
  }.each do |name, number|
    answer = harness.ask Input::Query.mode(number)
    if answer.is_a?(Input::Events::ModeReport) && answer.state.supported?
      harness.record Status::Info, name, "supported, #{answer.state}"
    elsif answer.is_a?(Input::Events::ModeReport)
      harness.record Status::Unsupported, name, answer.state.to_s
    else
      harness.no_answer name, "no answer to DECRQM"
    end
  end

  harness.leave_alternate

  unless colors.empty?
    harness.say "Check the colours the terminal reported. Answer y or n, or Ctrl+N to skip."
    harness.say
  end

  if color = colors["background"]?
    harness.say "Background #{hex color}#{color.dark? ? ", read as dark" : ", read as light"}."
    harness.say "The box between the brackets should be invisible: [\e[48;2;#{truecolor color}m                    \e[0m]"
    harness.record harness.confirm, "background colour", hex(color)
    harness.say
  end

  if color = colors["foreground"]?
    harness.say "Foreground #{hex color}. Both words should be the same colour: sample \e[38;2;#{truecolor color}msample\e[0m"
    harness.record harness.confirm, "foreground colour", hex(color)
    harness.say
  end

  if color = colors["cursor"]?
    harness.say "Cursor #{hex color}. This block should be your cursor's colour: \e[48;2;#{truecolor color}m    \e[0m"
    harness.record harness.confirm, "cursor colour", hex(color)
    harness.say
  end

  pairs = {0, 1, 15}.compact_map do |index|
    color = colors["palette #{index}"]?
    next unless color

    "#{index} \e[48;5;#{index}m    \e[48;2;#{truecolor color}m    \e[0m"
  end

  unless pairs.empty?
    harness.say "Palette. In each pair, the two halves should be the same colour: #{pairs.join("   ")}"
    detail = {0, 1, 15}.compact_map { |index| colors["palette #{index}"]?.try { |entry| "#{index} #{hex entry}" } }
    harness.record harness.confirm, "palette colours", detail.join(", ")
    harness.say
  end
rescue Harness::Stopped
  stopped = true
ensure
  harness.finish stopped
end
