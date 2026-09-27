require "./spec_helper"

# What the decoder makes of a focus report, without a stream in the way.
private def report(text : String) : TermBuf::Input::Events::Focus?
  TermBuf::Input::Focus.decode TermBuf::Input::Sequence.parse(text.to_slice)
end

# A stream over a pipe, so a report can be watched arriving as an event.
private class Window
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

private def with_window(&)
  window = Window.new
  window.start

  begin
    yield window
  ensure
    window.close
  end
end

Spectator.describe TermBuf::Input::Focus do
  describe "what happened" do
    it "reads focus gained" do
      event = report "\e[I"
      fail "nothing decoded" unless event

      expect(event.focused).to be_true
    end

    it "reads focus lost" do
      event = report "\e[O"
      fail "nothing decoded" unless event

      expect(event.focused).to be_false
    end
  end

  describe "what it refuses" do
    {% for description, text in {"a report with parameters"   => "\e[1I",
                                 "a modified key's shape"     => "\e[1;5O",
                                 "a private marker"           => "\e[?I",
                                 "an arrow key"               => "\e[A",
                                 "the application keypad's O" => "\eOI"} %}
      it "says nothing about {{ description.id }}" do
        expect(report({{ text }})).to be_nil
      end
    {% end %}
  end

  # The stream registers the pattern when it is built, so a report is
  # understood whoever turned mode 1004 on.
  describe "through the stream" do
    it "delivers a report as an event" do
      with_window do |window|
        window.send "\e[O\e[I"

        expect(window.event.as(TermBuf::Input::Events::Focus).focused).to be_false
        expect(window.event.as(TermBuf::Input::Events::Focus).focused).to be_true
      end
    end

    it "leaves the keys around it alone" do
      with_window do |window|
        window.send "\e[Ax"

        up = window.event.as TermBuf::Input::Events::Key
        expect(up.key.name).to eq TermBuf::Input::Key::Name::Up
        expect(window.event.as(TermBuf::Input::Events::Key).key.is?('x')).to be_true
      end
    end
  end
end
