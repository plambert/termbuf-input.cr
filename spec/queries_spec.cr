require "./spec_helper"

private alias Query = TermBuf::Input::Query
private alias Events = TermBuf::Input::Events

# A stream over a pipe, with the far end of the pipe playing the terminal.
private class Conversation
  getter stream : TermBuf::Input::Stream
  getter queries : TermBuf::Input::Queries
  getter asked = IO::Memory.new

  def initialize
    @device, @terminal = IO.pipe
    @stream = TermBuf::Input::Stream.new @device, blocking: false
    @queries = TermBuf::Input::Queries.new @stream, @asked
    @stream.start
  end

  def reply(text : String) : Nil
    @terminal.print text
    @terminal.flush
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
    @terminal.close rescue nil
    @stream.close
    @device.close rescue nil
  end
end

private def with_conversation(&)
  conversation = Conversation.new

  begin
    yield conversation
  ensure
    conversation.close
  end
end

Spectator.describe TermBuf::Input::Queries do
  it "writes the query and then the sentinel" do
    with_conversation do |talk|
      talk.queries.ask Query::CURSOR_POSITION

      expect(talk.asked.to_s).to eq "\e[6n\e[c"
      expect(talk.queries.pending).to eq 1
    end
  end

  it "delivers the answer and swallows the sentinel's reply" do
    with_conversation do |talk|
      talk.queries.ask Query::CURSOR_POSITION
      talk.reply "\e[3;7R\e[?62c"

      expect(talk.event).to eq Events::CursorPosition.new(6, 2)
      expect(talk.event(200.milliseconds)).to be_nil
      expect(talk.queries.pending).to eq 0
    end
  end

  it "calls a query with no answer unanswered" do
    with_conversation do |talk|
      talk.queries.ask Query::KITTY_KEYBOARD
      talk.reply "\e[?62c"

      event = talk.event
      expect(event).to be_a Events::Unanswered
      expect(event.as(Events::Unanswered).query).to be Query::KITTY_KEYBOARD
    end
  end

  it "answers several queries in the order they were asked" do
    with_conversation do |talk|
      talk.queries.ask Query::TEXT_AREA_SIZE
      talk.queries.ask TermBuf::Input::Mode::FOCUS_EVENTS
      talk.queries.ask Query::BACKGROUND
      talk.reply "\e[8;24;80t\e[?62c\e[?1004;2$y\e[?62c\e[?62c"

      expect(talk.event).to eq Events::TextAreaSize.new(80, 24)
      expect(talk.event).to eq Events::ModeReport.new(1004, TermBuf::Input::ModeState::Reset)
      expect(talk.event).to be_a Events::Unanswered
    end
  end

  # The sentinel is the same request as this query, so both replies look
  # alike. The first is the answer and the second the end of its turn.
  it "tells the device attributes it was asked for from the sentinel's" do
    with_conversation do |talk|
      talk.queries.ask Query::DEVICE_ATTRIBUTES
      talk.reply "\e[?62;22c\e[?62;22c"

      expect(talk.event).to eq Events::DeviceAttributes.new(false, [62, 22])
      expect(talk.event(200.milliseconds)).to be_nil
    end
  end

  it "leaves keys typed while a query is out alone" do
    with_conversation do |talk|
      talk.queries.ask Query::CURSOR_POSITION
      talk.reply "x\e[A\e[1;1R\e[?62c"

      expect(talk.event.as(Events::Key).key.is?('x')).to be_true
      expect(talk.event.as(Events::Key).key.name).to eq TermBuf::Input::Key::Name::Up
      expect(talk.event).to eq Events::CursorPosition.new(0, 0)
    end
  end

  # With nothing asked, `CSI 1 ; 5 R` is Ctrl+F3, as it always was.
  it "takes nothing with no query out" do
    with_conversation do |talk|
      talk.reply "\e[1;5R"

      key = talk.event.as(Events::Key).key
      expect(key.name).to eq TermBuf::Input::Key::Name::F3
      expect(key.modifiers).to eq TermBuf::Input::Modifiers::Ctrl
    end
  end

  it "refuses to ask about a mode with no query" do
    with_conversation do |talk|
      expect { talk.queries.ask TermBuf::Input::Mode::MODIFY_OTHER_KEYS }.to raise_error ArgumentError
    end
  end
end
