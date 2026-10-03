# Walks through everything the terminal sends — keys, paste, focus, the
# mouse, the kitty keyboard protocol, modifyOtherKeys and resizing — one
# step at a time, saying what to do and what should arrive.
#
#     crystal run examples/checklist.cr
#
# Run it outside tmux and screen. It takes about five minutes, and writes
# termbuf-input-checklist-<terminal>.txt in the current directory.
#
# Ctrl+N skips a step. Ctrl+C stops and still writes the report. A step
# that fails offers a retry, so a misclick costs nothing.
#
# What the statuses mean:
#
#     PASS         what arrived is what should have
#     FAIL         something else arrived: a bug here or in the terminal
#     UNSUPPORTED  the terminal does not do this, which is fine
#     SKIP         skipped at the keyboard
#     INFO         recorded for the report, nothing to judge

require "./support/harness"

alias Status = Harness::Status
alias Verdict = {Status, String}

class Checklist
  getter harness : Harness

  def initialize(@harness : Harness)
    @number = 0
  end

  NOTHING = -> { {Status::Fail, "nothing arrived"} }

  # Shows a step and its *marks*, each a 1-based row, column and text, then
  # hands every event to the block until it returns a verdict. A failure
  # offers a retry. Once *timeout* passes, *quiet* gives the verdict.
  def step(title : String, instruction : String, expected : String,
           timeout : Time::Span = 60.seconds, quiet : -> Verdict = NOTHING,
           marks : Array({Int32, Int32, String}) = [] of {Int32, Int32, String},
           &check : Input::Event -> Verdict?) : Nil
    @number += 1

    loop do
      show title, instruction, expected
      marks.each { |(row, column, text)| @harness.at row, column, text }
      verdict = wait timeout, quiet, &check

      unless verdict[0].fail?
        @harness.record verdict[0], title, verdict[1]
        return
      end

      @harness.at 16, 1, "\e[JFailed: #{verdict[1]}\r\n\r\nPress r to try again, or any other key to record the failure."
      next if retry?

      @harness.record verdict[0], title, verdict[1]
      return
    end
  end

  # A step that is settled by the next key pressed.
  def key(title : String, instruction : String, expected : String,
          unsupported : Proc(Input::Key, String?)? = nil,
          timeout : Time::Span = 60.seconds, quiet : -> Verdict = NOTHING,
          &match : Input::Key -> Bool) : Nil
    step title, instruction, expected, timeout, quiet do |event|
      next unless event.is_a?(Input::Events::Key)

      key = event.key
      bytes = String.new(event.bytes).inspect

      if match.call key
        {Status::Pass, "#{key} #{bytes}"}
      elsif reason = unsupported.try &.call(key)
        {Status::Unsupported, "#{reason}: #{key} #{bytes}"}
      else
        {Status::Fail, "expected #{expected}, got #{key} #{bytes}"}
      end
    end
  end

  def skip(title : String, status : Status, reason : String) : Nil
    @harness.record status, title, reason
  end

  private def show(title : String, instruction : String, expected : String) : Nil
    @harness.clear
    @harness.say "\e[1mStep #{@number}: #{title}\e[0m"
    @harness.say
    @harness.say instruction
    @harness.say
    @harness.say "Expected: #{expected}"
    @harness.say
    @harness.say "\e[2mCtrl+N skips this step. Ctrl+C stops and writes the report.\e[0m"
  end

  private def wait(timeout : Time::Span, quiet : -> Verdict, &check : Input::Event -> Verdict?) : Verdict
    deadline = Time.instant + timeout

    loop do
      remaining = deadline - Time.instant
      return quiet.call if remaining <= Time::Span.zero

      event = @harness.next_event remaining
      return quiet.call unless event

      if event.is_a?(Input::Events::Key) && event.key == Harness::SKIP
        return {Status::Skip, ""}
      end

      verdict = check.call event
      return verdict if verdict
    end
  end

  private def retry? : Bool
    loop do
      event = @harness.next_event 10.minutes
      return false unless event
      next unless event.is_a?(Input::Events::Key)

      return event.key.is?('r')
    end
  end
end

harness = Harness.new "checklist"
list = Checklist.new harness
stopped = false

# Whether the terminal says it supports DEC mode *number*, or `nil` when it
# does not answer. Terminal.app answers no DECRQM at all and still supports
# focus and SGR mouse reports, so silence rules nothing out.
def support(harness : Harness, number : Int32) : Bool?
  answer = harness.ask Input::Query.mode(number)
  answer.state.supported? if answer.is_a?(Input::Events::ModeReport)
end

# What a step records when nothing arrives: a failure where the terminal said
# it supports the mode, and unsupported where it said nothing.
def quiet(known : Bool?) : -> Verdict
  return Checklist::NOTHING if known

  -> { {Status::Unsupported, "nothing arrived, and the terminal did not say whether it supports this"} }
end

# A key an unconfigured Option key sends on a Mac: a character, not Alt.
option_character = ->(key : Input::Key) do
  "Option is not sending Esc+ (see the terminal's keyboard settings)" if key.character? && !key.alt? && key.char.ord > 0x7F
end

begin
  harness.enter_alternate

  focus = support harness, 1004
  mouse = support harness, 1006
  any_motion = support harness, 1003
  kitty = harness.ask(Input::Query::KITTY_KEYBOARD).is_a?(Input::Events::KittyKeyboard)

  # ------------------------------------------------------------------ keys

  list.key "letter", "Press a.", "a" { |key| key.character? && key.char == 'a' && key.modifiers.none? }
  list.key "shifted letter", "Press Shift+A.", "A" { |key| key.character? && key.char == 'A' }
  list.key "control letter", "Press Ctrl+A.", "Ctrl+A" { |key| key == Input::Key.parse_one("Ctrl+A") }
  list.key "alt letter", "Press Alt+A (Option+A on a Mac).", "Alt+a", option_character do |key|
    key == Input::Key.parse_one("Alt+a")
  end
  list.key "arrow", "Press Up.", "Up" { |key| key == Input::Key.parse_one("Up") }
  list.key "shifted arrow", "Press Shift+Right.", "Shift+Right" { |key| key == Input::Key.parse_one("Shift+Right") }
  list.key "home", "Press Home (Fn+Left on a Mac).", "Home" { |key| key.is? Input::Key::Name::Home }
  list.key "page up", "Press Page Up (Fn+Up on a Mac; Fn+Shift+Up in Terminal.app).", "PageUp" do |key|
    key.is? Input::Key::Name::PageUp
  end
  list.key "F1", "Press F1 (Fn+F1 on a Mac).", "F1" { |key| key == Input::Key.parse_one("F1") }
  list.key "F5", "Press F5 (Fn+F5 on a Mac).", "F5" { |key| key == Input::Key.parse_one("F5") }
  list.key "back tab", "Press Shift+Tab.", "Shift+Tab" { |key| key == Input::Key.parse_one("Shift+Tab") }
  list.key "backspace", "Press Backspace (delete on a Mac).", "Backspace" { |key| key == Input::Key.parse_one("Backspace") }
  list.key "delete", "Press Delete (Fn+delete on a Mac).", "Delete" { |key| key == Input::Key.parse_one("Delete") }
  list.key "enter", "Press Enter.", "Enter" { |key| key == Input::Key.parse_one("Enter") }
  list.key "escape", "Press Escape.", "Escape, arriving on its own after a short wait" do |key|
    key == Input::Key.parse_one("Escape")
  end

  # ----------------------------------------------------------------- paste

  harness.modes.enable Input::Mode::BRACKETED_PASTE
  list.step "bracketed paste", "Copy two or more lines of text from anywhere, and paste them here.",
    "one paste event holding every line, not a stream of keys" do |event|
    case event
    when Input::Events::Paste
      lines = event.text.count('\n') + event.text.count('\r')
      if event.complete && lines > 0
        {Status::Pass, "#{event.text.size} characters, complete"}
      elsif event.complete
        {Status::Fail, "complete, but only one line: #{event.text[0, 40].inspect}"}
      else
        {Status::Fail, "the paste never ended"}
      end
    when Input::Events::Key
      {Status::Fail, "arrived as typed keys, starting #{event.key}"}
    end
  end
  harness.modes.disable Input::Mode::BRACKETED_PASTE

  # ----------------------------------------------------------------- focus

  if focus != false
    harness.modes.enable Input::Mode::FOCUS_EVENTS
    lost = false
    list.step "focus", "Switch to another window (Cmd+Tab), then come back to this one.",
      "focus lost, then focus gained", quiet: quiet(focus) do |event|
      next unless event.is_a?(Input::Events::Focus)

      # Some terminals report the current focus when the mode goes on.
      if !event.focused
        lost = true
        nil
      elsif lost
        {Status::Pass, "lost, then gained"}
      end
    end
    harness.modes.disable Input::Mode::FOCUS_EVENTS
  else
    list.skip "focus", Status::Unsupported, "the terminal says mode 1004 is not supported"
  end

  # ----------------------------------------------------------------- mouse

  if mouse != false
    harness.modes.enable Input::Mode::MOUSE_SGR

    pressed = false
    list.step "click", "Click the X below with the left button.", "a left press and release at column 19, row 11",
      quiet: quiet(mouse), marks: [{12, 20, "X"}] do |event|
      next unless event.is_a?(Input::Events::Mouse)
      next if event.action.motion?

      where = "#{event.button} #{event.action} at column #{event.x}, row #{event.y}"
      if event.action.press?
        pressed = event.button.left? && event.x == 19 && event.y == 11
        pressed ? nil : {Status::Fail, where}
      elsif pressed
        pressed = false
        {Status::Pass, "press and release at column 19, row 11"}
      end
    end

    started = false
    moves = 0
    list.step "drag", "Press the left button on A, drag to B, and let go on B.",
      "a press at column 9, row 11, motion, a release at column 39, row 11",
      quiet: quiet(mouse), marks: [{12, 10, "A"}, {12, 40, "B"}] do |event|
      next unless event.is_a?(Input::Events::Mouse)

      where = "#{event.button} #{event.action} at column #{event.x}, row #{event.y}"
      case event.action
      when .press?
        started = event.button.left? && event.x == 9 && event.y == 11
        moves = 0
        started ? nil : {Status::Fail, "pressed at the wrong place: #{where}"}
      when .motion?
        moves += 1 if started && event.button.left?
        nil
      else
        next unless started

        started = false
        if moves.zero?
          {Status::Fail, "no motion reported between the press and the release"}
        elsif (event.x - 39).abs <= 1 && event.y == 11
          {Status::Pass, "#{moves} motion reports, released at column #{event.x}"}
        else
          {Status::Fail, "released at the wrong place: #{where}"}
        end
      end
    end

    list.step "right click", "Right-click anywhere.", "a right press", quiet: quiet(mouse) do |event|
      next unless event.is_a?(Input::Events::Mouse) && event.action.press?

      event.button.right? ? {Status::Pass, "at column #{event.x}, row #{event.y}"} : {Status::Fail, "#{event.button} pressed"}
    end

    list.step "wheel", "Scroll with the wheel or the trackpad.", "a wheel press, either direction",
      quiet: quiet(mouse) do |event|
      next unless event.is_a?(Input::Events::Mouse) && event.action.press?

      event.button.wheel? ? {Status::Pass, event.button.to_s} : {Status::Fail, "#{event.button} pressed"}
    end

    idle = 0
    list.step "no motion without a button", "Move the pointer around without pressing anything, for five seconds.",
      "nothing, under mode 1002 (this is recorded, not judged)", 5.seconds,
      -> { {Status::Info, "#{idle} motion reports with no button held under mode 1002"} } do |event|
      idle += 1 if event.is_a?(Input::Events::Mouse) && event.action.motion?
      nil
    end

    harness.modes.disable Input::Mode::MOUSE_SGR

    if any_motion != false
      harness.modes.enable Input::Mode::MOUSE_SGR_ANY
      list.step "hover", "Move the pointer across the window without pressing anything.",
        "motion reports with no button held", quiet: quiet(any_motion) do |event|
        next unless event.is_a?(Input::Events::Mouse) && event.action.motion?

        event.button.none? ? {Status::Pass, "motion at column #{event.x}, row #{event.y}"} : {Status::Fail, "motion with #{event.button} held"}
      end
      harness.modes.disable Input::Mode::MOUSE_SGR_ANY
    else
      list.skip "hover", Status::Unsupported, "the terminal says mode 1003 is not supported"
    end
  else
    %w[click drag right-click wheel hover].each do |title|
      list.skip title, Status::Unsupported, "the terminal says mode 1006 is not supported"
    end
  end

  # ---------------------------------------------------------- kitty keyboard

  if kitty
    harness.modes.enable Input::Mode::KITTY_KEYBOARD
    harness.stream.decoder.kitty_keyboard = true

    list.step "kitty escape", "Press Escape.", "Escape, sent as CSI 27 u" do |event|
      next unless event.is_a?(Input::Events::Key)

      bytes = String.new(event.bytes)
      if event.key == Input::Key.parse_one("Escape") && bytes == "\e[27u"
        {Status::Pass, bytes.inspect}
      else
        {Status::Fail, "#{event.key} #{bytes.inspect}"}
      end
    end

    list.key "kitty ctrl+i", "Press Ctrl+I.", "Ctrl+i, told apart from Tab" do |key|
      key.character? && key.char == 'i' && key.ctrl?
    end

    list.key "kitty shift+enter", "Press Shift+Enter.", "Shift+Enter" do |key|
      key.is?(Input::Key::Name::Enter) && key.shift?
    end

    harness.stream.decoder.kitty_keyboard = false
    harness.modes.disable Input::Mode::KITTY_KEYBOARD
  else
    %w[kitty-escape kitty-ctrl+i kitty-shift+enter].each do |title|
      list.skip title, Status::Unsupported, "the kitty keyboard protocol is not supported"
    end
  end

  # ------------------------------------------------------- modifyOtherKeys

  harness.modes.enable Input::Mode::MODIFY_OTHER_KEYS
  plain = ->(key : Input::Key) { "the terminal sent a plain '.'" if key.character? && key.char == '.' && !key.ctrl? }
  silent = -> { {Status::Unsupported, "nothing arrived, which is what Ctrl+. sends without the mode"} }
  list.key "modifyOtherKeys",
    "Press Ctrl+. (control and full stop) once, then press nothing else.\n" \
    "A terminal without modifyOtherKeys sends nothing, and after five seconds that is recorded as unsupported.",
    "Ctrl+., or nothing at all", plain, 5.seconds, silent do |key|
    key.character? && key.char == '.' && key.ctrl?
  end
  harness.modes.disable Input::Mode::MODIFY_OTHER_KEYS

  # ---------------------------------------------------------------- resize

  list.step "resize", "Resize this window by dragging its edge, then let go.",
    "a resize, and a size that matches the device's" do |event|
    next unless event.is_a?(Input::Events::Resize)

    # Let the drag finish before asking.
    while harness.next_event(700.milliseconds)
    end

    expected = harness.device_size
    case answer = harness.ask Input::Query::TEXT_AREA_SIZE
    when Input::Events::TextAreaSize
      if {answer.columns, answer.rows} == expected
        {Status::Pass, "#{answer.columns} × #{answer.rows}"}
      else
        {Status::Fail, "the terminal says #{answer.columns} × #{answer.rows}, the device says #{expected}"}
      end
    else
      {Status::Pass, "a resize arrived; the terminal does not report its size"}
    end
  end
rescue Harness::Stopped
  stopped = true
ensure
  harness.finish stopped
end
