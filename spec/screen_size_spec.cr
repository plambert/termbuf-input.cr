require "./spec_helper"

Spectator.describe TermBuf::Input::ScreenSize do
  it "falls back to a size every terminal is at least as big as" do
    expect(TermBuf::Input::ScreenSize::DEFAULT.columns).to eq 80
    expect(TermBuf::Input::ScreenSize::DEFAULT.rows).to eq 24
  end

  it "rejects a size that is not positive" do
    expect { TermBuf::Input::ScreenSize.new(0, 24) }.to raise_error(ArgumentError)
    expect { TermBuf::Input::ScreenSize.new(80, -1) }.to raise_error(ArgumentError)
  end

  it "prints as a size" do
    expect(TermBuf::Input::ScreenSize.new(120, 40).to_s).to eq "120x40"
  end
end

Spectator.describe TermBuf::Input::SizeDetector do
  describe ".from_env" do
    it "reads COLUMNS and LINES" do
      size = TermBuf::Input::SizeDetector.from_env({"COLUMNS" => "120", "LINES" => "40"})

      expect(size).to eq TermBuf::Input::ScreenSize.new(120, 40)
    end

    it "needs both to be set" do
      expect(TermBuf::Input::SizeDetector.from_env({"COLUMNS" => "120"})).to be_nil
      expect(TermBuf::Input::SizeDetector.from_env({"LINES" => "40"})).to be_nil
    end

    it "ignores values that are not sizes" do
      expect(TermBuf::Input::SizeDetector.from_env({"COLUMNS" => "wide", "LINES" => "40"})).to be_nil
      expect(TermBuf::Input::SizeDetector.from_env({"COLUMNS" => "0", "LINES" => "40"})).to be_nil
      expect(TermBuf::Input::SizeDetector.from_env({"COLUMNS" => "-1", "LINES" => "40"})).to be_nil
    end
  end

  describe ".detect" do
    it "always comes back with a size" do
      size = TermBuf::Input::SizeDetector.detect env: {} of String => String

      expect(size.columns).to be > 0
      expect(size.rows).to be > 0
    end
  end

  # There is no answer to check against: whether the ioctl reports pixels at all
  # depends on the terminal the suite happens to be running under, and a pipe
  # reports nothing. What can be checked is that it either says nothing or says
  # something usable, and never raises or divides by zero.
  describe ".cell_pixels" do
    it "answers a cell's size or nothing at all" do
      cell = TermBuf::Input::SizeDetector.cell_pixels

      if cell
        expect(cell[0]).to be > 0
        expect(cell[1]).to be > 0
      else
        expect(cell).to be_nil
      end
    end

    it "says nothing for a descriptor that is not a terminal" do
      reader, writer = IO.pipe
      begin
        expect(TermBuf::Input::SizeDetector.cell_pixels(writer.fd)).to be_nil
      ensure
        reader.close
        writer.close
      end
    end
  end
end
