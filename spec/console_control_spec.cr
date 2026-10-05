require "./spec_helper"

# The console's control events exist only on Windows. There is no console to
# press Ctrl+C in under the spec runner, so the events are handed to
# `Signals#console_event` directly, which is what `ConsoleControl`'s thread
# does with each one.
{% skip_file unless flag?(:win32) %}

private alias Signals = TermBuf::Input::Signals
private alias Control = TermBuf::Input::ConsoleControl

private class Console
  getter signals : Signals
  getter departures = [] of Signals::Departure
  getter terminated = [] of ::Signal

  def initialize
    @inbound = Channel(TermBuf::Input::Reader::Inbound).new 16
    @signals = Signals.new @inbound

    terminated = @terminated
    @signals.terminate = ->(signal : ::Signal) : Nil { terminated << signal; nil }

    departures = @departures
    @signals.before_exit { |departure| departures << departure }
  end

  def received : Signals::Signalled?
    select
    when message = @inbound.receive?
      message.as? Signals::Signalled
    when timeout 1.second
      nil
    end
  end
end

Spectator.describe TermBuf::Input::Signals do
  describe "a console control event" do
    it "makes Ctrl+C an interrupt, handled by its mode" do
      console = Console.new
      console.signals.mode ::Signal::INT, Signals::Mode::Event

      console.signals.console_event Control::CTRL_C_EVENT

      signalled = console.received
      fail "no signal arrived" unless signalled
      expect(signalled.signal).to eq ::Signal::INT
      expect(console.terminated).to be_empty
    end

    it "makes Ctrl+Break a break" do
      console = Console.new
      console.signals.mode ::Signal::BREAK, Signals::Mode::Event

      console.signals.console_event Control::CTRL_BREAK_EVENT

      expect(console.received.try &.signal).to eq ::Signal::BREAK
    end

    it "runs the hooks as signalled and exits, for an interrupt that means stop" do
      console = Console.new

      console.signals.console_event Control::CTRL_C_EVENT

      expect(console.departures).to eq [Signals::Departure::Signalled]
      expect(console.terminated).to eq [::Signal::INT]
    end

    # Windows ends the process when the handler returns. Nothing here has to.
    it "runs the hooks as disconnected for a close, and leaves the ending to Windows" do
      console = Console.new

      console.signals.console_event Control::CTRL_CLOSE_EVENT

      expect(console.departures).to eq [Signals::Departure::Disconnected]
      expect(console.terminated).to be_empty
    end

    it "treats logging off and shutting down as a close" do
      console = Console.new

      console.signals.console_event Control::CTRL_LOGOFF_EVENT
      console.signals.console_event Control::CTRL_SHUTDOWN_EVENT

      expect(console.departures).to eq [Signals::Departure::Disconnected, Signals::Departure::Disconnected]
    end
  end

  describe "#install" do
    it "registers for the console's control events, and #uninstall gives them back" do
      console = Console.new

      console.signals.install
      begin
        expect(console.signals.installed?).to be_true
        expect(Control.started?).to be_true
      ensure
        console.signals.uninstall
      end

      expect(console.signals.installed?).to be_false
      expect(Control.started?).to be_false
    end
  end
end
