require "./spec_helper"

private alias Button = TermBuf::Input::Mouse::Button
private alias Action = TermBuf::Input::Mouse::Action

# What the decoder makes of an SGR report, without a stream in the way.
private def report(text : String) : TermBuf::Input::Events::Mouse?
  TermBuf::Input::Mouse.decode TermBuf::Input::Sequence.parse(text.to_slice)
end

# A stream over a pipe, so a report can be watched arriving as an event.
private class Pointer
  getter stream : TermBuf::Input::Stream

  def initialize
    @device, @keys = IO.pipe
    @stream = TermBuf::Input::Stream.new @device, blocking: false
  end

  def start : Nil
    @stream.start
  end

  def send(text : String) : Nil
    @keys.print text
    @keys.flush
  end

  def event(timeout : Time::Span = 2.seconds) : TermBuf::Input::Event?
    select
    when received = @stream.events.receive?
      received
    when timeout timeout
      nil
    end
  end

  def close : Nil
    @keys.close rescue nil
    @stream.close
    @device.close rescue nil
  end
end

private def with_pointer(&)
  pointer = Pointer.new
  pointer.start

  begin
    yield pointer
  ensure
    pointer.close
  end
end

# A cell ten pixels wide and twenty high, for the pixel reports.
private CELL = TermBuf::Input::Events::CellPixels.new(10, 20)

# What the decoder makes of a report in pixels.
private def pixel_report(text : String) : TermBuf::Input::Events::Mouse?
  TermBuf::Input::Mouse.decode TermBuf::Input::Sequence.parse(text.to_slice), CELL
end

# What the stream's `CSI <` pattern makes of *text*, without starting the
# stream, so a spec decides when the channel holds something.
private def claim(stream : TermBuf::Input::Stream, text : String) : TermBuf::Input::Event?
  stream.patterns.match TermBuf::Input::Sequence.parse(text.to_slice)
end

private def x10(text : String) : TermBuf::Input::Events::Mouse?
  TermBuf::Input::Mouse.decode_x10 TermBuf::Input::Sequence.parse(text.to_slice)
end

Spectator.describe TermBuf::Input::Mouse do
  # `CSI M` and three bytes, each the value plus 32.
  describe ".decode_x10" do
    it "reads a press" do
      mouse = x10("\e[M #'")
      fail "no mouse" unless mouse

      expect(mouse.button).to eq Button::Left
      expect(mouse.action).to eq Action::Press
      expect(mouse.x).to eq 2
      expect(mouse.y).to eq 6
    end

    it "reads a release, which does not say which button" do
      mouse = x10("\e[M#!!")
      fail "no mouse" unless mouse

      expect(mouse.button).to eq Button::None
      expect(mouse.action).to eq Action::Release
    end

    it "reads a motion with no button held" do
      mouse = x10("\e[MCq!")
      fail "no mouse" unless mouse

      expect(mouse.action).to eq Action::Motion
      expect(mouse.x).to eq 80
    end

    it "says nothing about an SGR report" do
      expect(x10("\e[<0;1;1M")).to be_nil
    end
  end

  describe "what happened" do
    it "reads a press" do
      event = report "\e[<0;10;5M"
      fail "nothing decoded" unless event

      expect(event.action).to eq Action::Press
      expect(event.button).to eq Button::Left
    end

    it "reads a release" do
      event = report "\e[<0;10;5m"
      fail "nothing decoded" unless event

      expect(event.action).to eq Action::Release
      expect(event.button).to eq Button::Left
    end

    # Bit 32 turns a press into a drag: the button is still down and the
    # pointer moved.
    it "reads a motion" do
      event = report "\e[<32;10;5M"
      fail "nothing decoded" unless event

      expect(event.action).to eq Action::Motion
      expect(event.button).to eq Button::Left
    end

    # Nothing is held, which is what a terminal asked for all motion sends.
    it "reads a motion with no button held" do
      event = report "\e[<35;10;5M"
      fail "nothing decoded" unless event

      expect(event.action).to eq Action::Motion
      expect(event.button).to eq Button::None
    end
  end

  describe "which button" do
    {% for code, button in {  0 => "Left",
                              1 => "Middle",
                              2 => "Right",
                              3 => "None",
                             64 => "WheelUp",
                             65 => "WheelDown",
                             66 => "WheelLeft",
                             67 => "WheelRight",
                            128 => "Button8",
                            129 => "Button9",
                            130 => "Button10",
                            131 => "Button11"} %}
      it "reads button code {{ code }} as {{ button.id }}" do
        event = report "\e[<{{ code }};1;1M"
        fail "nothing decoded" unless event

        expect(event.button).to eq Button::{{ button.id }}
      end
    {% end %}

    # A wheel notch is a press with nothing to release afterwards, which is
    # why the four notches are buttons rather than an action of their own.
    it "calls the wheel a press and nothing else" do
      event = report "\e[<64;3;4M"
      fail "nothing decoded" unless event

      expect(event.action).to eq Action::Press
      expect(event.button.wheel?).to be_true
      expect(Button::Left.wheel?).to be_false
    end
  end

  describe "what was held" do
    it "reads no modifiers" do
      event = report "\e[<0;1;1M"
      fail "nothing decoded" unless event

      expect(event.modifiers).to eq TermBuf::Input::Modifiers::None
    end

    it "reads shift" do
      event = report "\e[<4;1;1M"
      fail "nothing decoded" unless event

      expect(event.modifiers).to eq TermBuf::Input::Modifiers::Shift
      expect(event.button).to eq Button::Left
    end

    it "reads alt" do
      event = report "\e[<8;1;1M"
      fail "nothing decoded" unless event

      expect(event.modifiers).to eq TermBuf::Input::Modifiers::Alt
    end

    it "reads ctrl" do
      event = report "\e[<16;1;1M"
      fail "nothing decoded" unless event

      expect(event.modifiers).to eq TermBuf::Input::Modifiers::Ctrl
    end

    it "reads all three at once" do
      event = report "\e[<30;1;1M"
      fail "nothing decoded" unless event

      expect(event.modifiers)
        .to eq TermBuf::Input::Modifiers::Shift | TermBuf::Input::Modifiers::Alt | TermBuf::Input::Modifiers::Ctrl
      expect(event.button).to eq Button::Right
    end
  end

  # The terminal numbers from one and every buffer coordinate in this shard is
  # numbered from zero. Subtracting that here is what lets an application hand
  # the event straight to `Terminal#hit`.
  describe "where" do
    it "numbers the cells from zero" do
      event = report "\e[<0;1;1M"
      fail "nothing decoded" unless event

      expect(event.x).to eq 0
      expect(event.y).to eq 0
    end

    it "keeps the column and the row the right way round" do
      event = report "\e[<0;80;24M"
      fail "nothing decoded" unless event

      expect(event.x).to eq 79
      expect(event.y).to eq 23
    end

    # SGR is the encoding that can name a column past 223, which is the whole
    # reason for decoding it rather than mode 1000's byte-packed form.
    it "reads a column no byte could carry" do
      event = report "\e[<0;500;300M"
      fail "nothing decoded" unless event

      expect(event.x).to eq 499
      expect(event.y).to eq 299
    end
  end

  describe "what it refuses" do
    {% for description, text in {"a body that is not a report"       => "\e[<A",
                                 "a field that is not a number"      => "\e[<0;x;5M",
                                 "too few fields"                    => "\e[<0;5M",
                                 "too many fields"                   => "\e[<0;1;2;3M",
                                 "no final byte it knows"            => "\e[<0;1;1R",
                                 "a column the terminal cannot mean" => "\e[<0;0;1M",
                                 "a row the terminal cannot mean"    => "\e[<0;1;0M",
                                 "a negative button"                 => "\e[<-1;1;1M",
                                 "nothing after the marker"          => "\e[<M"} %}
      it "says nothing about {{ description.id }}" do
        expect(report({{ text }})).to be_nil
      end
    {% end %}

    it "says nothing about a sequence that is not a CSI" do
      expect(TermBuf::Input::Mouse.decode(
        TermBuf::Input::Sequence.parse("\eO<0;1;1M".to_slice))).to be_nil
    end
  end

  # Under DEC mode 1016 the coordinates are pixels, from zero unless the
  # decoder is told otherwise, and the cell is found by dividing.
  describe "in pixels" do
    it "puts a cell's first pixel in that cell, at offset zero" do
      # Pixel 30 from zero: column 3, row 2.
      event = pixel_report "\e[<0;30;40M"
      fail "nothing decoded" unless event
      pixel = event.pixel
      fail "no pixel" unless pixel

      expect(event.x).to eq 3
      expect(event.y).to eq 2
      expect(pixel.x).to eq 30
      expect(pixel.y).to eq 40
      expect(pixel.offset_x).to eq 0
      expect(pixel.offset_y).to eq 0
      expect(pixel.fraction_x).to eq 0.0
      expect(pixel.cell).to eq CELL
    end

    it "puts a cell's last pixel in that cell, at the last offset" do
      event = pixel_report "\e[<0;39;59M"
      fail "nothing decoded" unless event
      pixel = event.pixel
      fail "no pixel" unless pixel

      expect(event.x).to eq 3
      expect(event.y).to eq 2
      expect(pixel.offset_x).to eq 9
      expect(pixel.offset_y).to eq 19
      expect(pixel.fraction_x).to eq 0.9
      expect(pixel.fraction_y).to eq 0.95
    end

    it "takes the origin off first for a terminal that numbers from one" do
      # xterm's pixel 31 is pixel 30 from zero: column 3, row 2, offset zero.
      event = TermBuf::Input::Mouse.decode TermBuf::Input::Sequence.parse("\e[<0;31;41M".to_slice), CELL, 1
      fail "nothing decoded" unless event
      pixel = event.pixel
      fail "no pixel" unless pixel

      expect({event.x, event.y}).to eq({3, 2})
      expect({pixel.x, pixel.y}).to eq({30, 40})
      expect(pixel.offset_x).to eq 0
    end

    it "keeps a negative coordinate, in the cell before the first" do
      # A held button past the left edge on a terminal that does not clamp.
      event = pixel_report "\e[<32;-1;5M"
      fail "nothing decoded" unless event
      pixel = event.pixel
      fail "no pixel" unless pixel

      expect({event.x, event.y}).to eq({-1, 0})
      expect({pixel.x, pixel.y}).to eq({-1, 5})
      expect(pixel.offset_x).to eq 9
    end

    it "keeps the button, the modifiers and the action" do
      event = pixel_report "\e[<36;15;15m"
      fail "nothing decoded" unless event

      expect(event.button).to eq Button::Left
      expect(event.modifiers).to eq TermBuf::Input::Modifiers::Shift
      expect(event.action).to eq Action::Release
    end

    it "leaves a report in cells without a pixel" do
      event = report "\e[<0;31;41M"
      fail "nothing decoded" unless event

      expect(event).to eq TermBuf::Input::Events::Mouse.new(
        Button::Left, 30, 40, TermBuf::Input::Modifiers::None, Action::Press)
      expect(event.pixel).to be_nil
    end
  end

  # The stream registers the `CSI <` pattern when it is built, so a report is
  # understood with or without a terminal around it.
  describe "through the stream" do
    it "delivers a report as an event" do
      with_pointer do |pointer|
        pointer.send "\e[<0;12;7M"
        event = pointer.event

        expect(event).to be_a TermBuf::Input::Events::Mouse
        mouse = event.as TermBuf::Input::Events::Mouse
        expect(mouse.button).to eq Button::Left
        expect(mouse.action).to eq Action::Press
        expect(mouse.x).to eq 11
        expect(mouse.y).to eq 6
      end
    end

    # Under a Windows console that asked for the mouse itself, motion can
    # arrive in this encoding, and its bytes used to arrive as keys.
    it "delivers an X10 report as an event, not as keys" do
      with_pointer do |pointer|
        pointer.send "\e[MCq!"
        event = pointer.event

        expect(event).to be_a TermBuf::Input::Events::Mouse
        expect(event.as(TermBuf::Input::Events::Mouse).action).to eq Action::Motion
        expect(pointer.event(100.milliseconds)).to be_nil
      end
    end

    # Columns and rows past 95 are bytes past 0x7F, which are not UTF-8.
    it "delivers an X10 report far into the window" do
      with_pointer do |pointer|
        # Button 0 + 32, column 200 + 32, row 100 + 32, which are x 199 and
        # y 99 counted from zero.
        pointer.send String.new(Bytes[0x1B, '['.ord, 'M'.ord, 32, 232, 132])
        event = pointer.event

        expect(event).to be_a TermBuf::Input::Events::Mouse
        mouse = event.as(TermBuf::Input::Events::Mouse)
        expect(mouse.x).to eq 199
        expect(mouse.y).to eq 99
      end
    end

    # A coordinate of zero is not a report, so this one falls through every
    # pattern, the reply parsers among them, with its byte past 0x7F.
    it "survives an X10 report it cannot read" do
      with_pointer do |pointer|
        # A query out, so the reply parsers look at the sequence too.
        TermBuf::Input::Queries.new(pointer.stream, IO::Memory.new).ask TermBuf::Input::Query::CURSOR_POSITION
        pointer.send String.new(Bytes[0x1B, '['.ord, 'M'.ord, 32, 32, 0xFF])
        expect(pointer.event).to be_a TermBuf::Input::Events::Key
      end
    end

    it "delivers the release that follows" do
      with_pointer do |pointer|
        pointer.send "\e[<0;12;7M\e[<0;12;7m"

        expect(pointer.event.as(TermBuf::Input::Events::Mouse).action).to eq Action::Press
        expect(pointer.event.as(TermBuf::Input::Events::Mouse).action).to eq Action::Release
      end
    end

    it "decodes in cells while the stream has no mouse cell" do
      with_pointer do |pointer|
        pointer.send "\e[<0;12;7M"
        mouse = pointer.event.as TermBuf::Input::Events::Mouse

        expect({mouse.x, mouse.y}).to eq({11, 6})
        expect(mouse.pixel).to be_nil
      end
    end

    it "decodes in pixels once the stream has a mouse cell" do
      with_pointer do |pointer|
        pointer.stream.mouse_cell = CELL
        pointer.send "\e[<0;39;59M"
        mouse = pointer.event.as TermBuf::Input::Events::Mouse

        expect({mouse.x, mouse.y}).to eq({3, 2})
        expect(mouse.pixel.try &.offset_x).to eq 9
      end
    end

    it "takes the stream's pixel origin off" do
      with_pointer do |pointer|
        pointer.stream.mouse_cell = CELL
        pointer.stream.pixel_origin = 1
        pointer.send "\e[<0;31;41M"
        mouse = pointer.event.as TermBuf::Input::Events::Mouse

        expect({mouse.x, mouse.y}).to eq({3, 2})
        expect(mouse.pixel.try &.x).to eq 30
      end
    end

    it "refuses a mouse cell with no size" do
      stream = TermBuf::Input::Stream.new IO::Memory.new, blocking: false

      expect { stream.mouse_cell = TermBuf::Input::Events::CellPixels.new(0, 20) }
        .to raise_error ArgumentError
      expect(stream.mouse_cell).to be_nil
    end

    # A pattern answering `nil` is saying "not mine after all", so the sequence
    # carries on to the key decoder rather than being dropped or guessed at.
    it "leaves a CSI < that is not a report to the key decoder" do
      with_pointer do |pointer|
        pointer.send "\e[<nonsense~"
        event = pointer.event

        expect(event).to be_a TermBuf::Input::Events::Key
        expect(event.as(TermBuf::Input::Events::Key).key.name).to eq TermBuf::Input::Key::Name::Unknown
      end
    end
  end

  # Motion in pixels is dropped while it stays in the cell of the last motion
  # delivered and the channel still holds something. These call the stream's
  # pattern directly and fill the channel with `#inject`, so nothing races.
  describe "coalescing" do
    let(stream) { TermBuf::Input::Stream.new IO::Memory.new, blocking: false }
    let(waiting) { TermBuf::Input::Events::Focus.new(true) }

    it "drops motion within a cell while the channel is busy" do
      stream.mouse_cell = CELL
      stream.inject waiting

      expect(claim(stream, "\e[<35;31;41M")).to be_a TermBuf::Input::Events::Mouse
      expect(claim(stream, "\e[<35;35;45M")).to be_a TermBuf::Input::Claimed
      expect(claim(stream, "\e[<35;39;59M")).to be_a TermBuf::Input::Claimed
    end

    it "delivers motion into another cell" do
      stream.mouse_cell = CELL
      stream.inject waiting

      claim stream, "\e[<35;31;41M"
      moved = claim(stream, "\e[<35;41;41M")

      expect(moved).to be_a TermBuf::Input::Events::Mouse
      expect(moved.as(TermBuf::Input::Events::Mouse).x).to eq 4
    end

    it "delivers motion within a cell once the channel is empty" do
      stream.mouse_cell = CELL

      expect(claim(stream, "\e[<35;31;41M")).to be_a TermBuf::Input::Events::Mouse
      expect(claim(stream, "\e[<35;35;45M")).to be_a TermBuf::Input::Events::Mouse
    end

    it "keeps presses, releases and wheel notches" do
      stream.mouse_cell = CELL
      stream.inject waiting

      claim stream, "\e[<32;31;41M"
      expect(claim(stream, "\e[<0;32;41M")).to be_a TermBuf::Input::Events::Mouse
      expect(claim(stream, "\e[<0;33;41m")).to be_a TermBuf::Input::Events::Mouse
      expect(claim(stream, "\e[<64;34;41M")).to be_a TermBuf::Input::Events::Mouse
      expect(claim(stream, "\e[<64;34;41M")).to be_a TermBuf::Input::Events::Mouse
    end

    it "delivers every motion when motion_every_pixel is set" do
      stream.mouse_cell = CELL
      stream.motion_every_pixel = true
      stream.inject waiting

      3.times do |step|
        expect(claim(stream, "\e[<35;#{31 + step};41M")).to be_a TermBuf::Input::Events::Mouse
      end
    end

    it "leaves reports in cells alone" do
      stream.inject waiting

      expect(claim(stream, "\e[<35;4;3M")).to be_a TermBuf::Input::Events::Mouse
      expect(claim(stream, "\e[<35;4;3M")).to be_a TermBuf::Input::Events::Mouse
    end
  end
end
