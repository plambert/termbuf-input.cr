require "./spec_helper"

private alias Mode = TermBuf::Input::Mode

private def modes : {TermBuf::Input::Modes, IO::Memory}
  output = IO::Memory.new
  {TermBuf::Input::Modes.new(output), output}
end

Spectator.describe TermBuf::Input::Modes do
  it "writes the set sequence when a mode goes on" do
    set, output = modes
    set.enable Mode::FOCUS_EVENTS

    expect(output.to_s).to eq "\e[?1004h"
    expect(set.enabled?(Mode::FOCUS_EVENTS)).to be_true
  end

  it "writes nothing for a mode that is already on" do
    set, output = modes
    set.enable Mode::BRACKETED_PASTE
    set.enable Mode::BRACKETED_PASTE

    expect(output.to_s).to eq "\e[?2004h"
  end

  # The terminal has one mouse tracking mode, so asking for another replaces
  # it, and the reset that goes out later is the replacement's.
  it "replaces a mode of the same name" do
    set, output = modes
    set.enable Mode::MOUSE_SGR
    set.enable Mode::MOUSE_SGR_ANY
    set.reset

    expect(output.to_s)
      .to eq "\e[?1002h\e[?1006h\e[?1003h\e[?1006h\e[?1006l\e[?1003l"
    expect(set.to_a).to be_empty
  end

  it "resets in the reverse of the order the modes went on" do
    set, output = modes
    set.enable Mode::BRACKETED_PASTE
    set.enable Mode::FOCUS_EVENTS
    output.clear
    set.reset

    expect(output.to_s).to eq "\e[?1004l\e[?2004l"
  end

  it "turns off one mode and leaves the rest" do
    set, output = modes
    set.enable Mode::BRACKETED_PASTE
    set.enable Mode::KITTY_KEYBOARD
    output.clear
    set.disable Mode::BRACKETED_PASTE

    expect(output.to_s).to eq "\e[?2004l"
    expect(set.to_a).to eq [Mode::KITTY_KEYBOARD]
  end

  it "writes nothing to turn off a mode that is not on" do
    set, output = modes
    set.disable Mode::MODIFY_OTHER_KEYS
    set.reset

    expect(output.to_s).to be_empty
  end
end
