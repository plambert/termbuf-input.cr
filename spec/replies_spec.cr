require "./spec_helper"

private alias Replies = TermBuf::Input::Replies
private alias Events = TermBuf::Input::Events

private def sequence(text : String) : TermBuf::Input::Sequence
  TermBuf::Input::Sequence.parse text.to_slice
end

Spectator.describe TermBuf::Input::Replies do
  describe ".cursor_position" do
    it "reads the row and column from one" do
      expect(Replies.cursor_position(sequence "\e[5;12R")).to eq Events::CursorPosition.new(11, 4)
    end

    {% for description, text in {"a private marker" => "\e[?5;12R",
                                 "a zero row"       => "\e[0;12R",
                                 "one number"       => "\e[5R",
                                 "another final"    => "\e[5;12H"} %}
      it "says nothing about {{ description.id }}" do
        expect(Replies.cursor_position(sequence {{ text }})).to be_nil
      end
    {% end %}
  end

  describe "window reports" do
    it "reads the text area in cells, columns first" do
      expect(Replies.text_area_size(sequence "\e[8;24;80t")).to eq Events::TextAreaSize.new(80, 24)
    end

    it "reads the text area in pixels, width first" do
      expect(Replies.text_area_pixels(sequence "\e[4;600;800t")).to eq Events::TextAreaPixels.new(800, 600)
    end

    it "reads a cell in pixels, width first" do
      expect(Replies.cell_pixels(sequence "\e[6;18;9t")).to eq Events::CellPixels.new(9, 18)
    end

    it "keeps the reports apart" do
      expect(Replies.text_area_size(sequence "\e[4;600;800t")).to be_nil
      expect(Replies.cell_pixels(sequence "\e[8;24;80t")).to be_nil
    end
  end

  describe ".mode_report" do
    it "reads the mode and its state" do
      report = Replies.mode_report sequence("\e[?1004;2$y")
      fail "nothing decoded" unless report

      expect(report.mode).to eq 1004
      expect(report.state).to eq TermBuf::Input::ModeState::Reset
      expect(report.state.supported?).to be_true
    end

    it "calls an unknown mode unsupported" do
      report = Replies.mode_report sequence("\e[?1004;0$y")
      fail "nothing decoded" unless report

      expect(report.state.supported?).to be_false
    end

    it "says nothing about another mode than the one asked about" do
      expect(Replies.mode_report(sequence("\e[?2004;1$y"), 1004)).to be_nil
    end
  end

  it "reads the kitty keyboard flags" do
    expect(Replies.kitty_keyboard(sequence "\e[?1u")).to eq Events::KittyKeyboard.new(1)
    expect(Replies.kitty_keyboard(sequence "\e[1u")).to be_nil
  end

  describe ".color" do
    it "reads the background, ended by ST" do
      color = Replies.color sequence("\e]11;rgb:1e1e/1e1e/2e2e\e\\")
      fail "nothing decoded" unless color

      expect(color.slot).to eq TermBuf::Input::ColorSlot::Background
      expect({color.red, color.green, color.blue}).to eq({0x1e_u8, 0x1e_u8, 0x2e_u8})
      expect(color.dark?).to be_true
    end

    it "reads the foreground, ended by a bell, at any precision" do
      color = Replies.color sequence("\e]10;rgb:f/ff/fff\a")
      fail "nothing decoded" unless color

      expect(color.slot).to eq TermBuf::Input::ColorSlot::Foreground
      expect({color.red, color.green, color.blue}).to eq({255_u8, 255_u8, 255_u8})
      expect(color.dark?).to be_false
    end

    it "reads a palette entry and its index" do
      color = Replies.color sequence("\e]4;3;rgb:8080/0000/ffff\e\\")
      fail "nothing decoded" unless color

      expect(color.slot).to eq TermBuf::Input::ColorSlot::Palette
      expect(color.index).to eq 3
      expect(color.red).to eq 128
    end

    it "ignores an alpha component" do
      color = Replies.color sequence("\e]11;rgba:0000/0000/0000/ffff\a")
      fail "nothing decoded" unless color

      expect(color.blue).to eq 0
    end

    it "says nothing about a colour it cannot read" do
      expect(Replies.color(sequence "\e]11;#000000\a")).to be_nil
      expect(Replies.color(sequence "\e]11;rgb:zz/00/00\a")).to be_nil
    end
  end

  describe ".device_attributes" do
    it "reads the primary attributes" do
      expect(Replies.device_attributes(sequence "\e[?62;22c"))
        .to eq Events::DeviceAttributes.new(false, [62, 22])
    end

    it "reads the secondary attributes" do
      expect(Replies.device_attributes(sequence "\e[>1;4000;0c"))
        .to eq Events::DeviceAttributes.new(true, [1, 4000, 0])
    end
  end

  it "reads the terminal's name" do
    expect(Replies.terminal_name(sequence "\eP>|ghostty 1.2.0\e\\"))
      .to eq Events::TerminalName.new("ghostty 1.2.0")
  end
end
