require "./spec_helper"

# The console's records exist only on Windows.
{% skip_file unless flag?(:win32) %}

private alias Lib = LibTermBufConsole

private def key(unit : Char | UInt16, down = true, repeat = 1, virtual_key = 0_u16) : Lib::InputRecord
  key = Lib::KeyEventRecord.new
  key.key_down = down ? 1 : 0
  key.repeat_count = repeat.to_u16
  key.virtual_key_code = virtual_key
  key.unicode_char = unit.is_a?(Char) ? unit.ord.to_u16 : unit

  event = Lib::InputEvent.new
  event.key_event = key

  record = Lib::InputRecord.new
  record.event_type = Lib::KEY_EVENT
  record.event = event
  record
end

private def keys(text : String) : Array(Lib::InputRecord)
  text.to_utf16.to_a.map { |unit| key unit }
end

private def window_size(columns : Int32, rows : Int32) : Lib::InputRecord
  size = Lib::WindowBufferSizeRecord.new
  coord = Lib::Coord.new
  coord.x = columns.to_i16
  coord.y = rows.to_i16
  size.size = coord

  event = Lib::InputEvent.new
  event.window_buffer_size_event = size

  record = Lib::InputRecord.new
  record.event_type = Lib::WINDOW_BUFFER_SIZE_EVENT
  record.event = event
  record
end

private def translate(translator, records : Array(Lib::InputRecord)) : TermBuf::Input::Console::Batch
  translator.translate Slice.new(records.to_unsafe, records.size)
end

Spectator.describe TermBuf::Input::Console::Translator do
  let(translator) { TermBuf::Input::Console::Translator.new }

  # The layout `ReadConsoleInputW` fills in. Anything else and every record
  # after the first is read from the wrong place.
  it "lays a record out as Windows does" do
    expect(sizeof(Lib::KeyEventRecord)).to eq 16
    expect(sizeof(Lib::InputRecord)).to eq 20
  end

  it "makes bytes of the keys that went down" do
    batch = translate translator, keys("hi")

    expect(String.new(batch.bytes)).to eq "hi"
    expect(batch.resized).to be_false
  end

  it "passes an escape sequence through as the bytes it is" do
    batch = translate translator, keys("\e[A")

    expect(batch.bytes).to eq "\e[A".to_slice
  end

  it "ignores a key coming back up" do
    batch = translate translator, [key('a'), key('a', down: false)]

    expect(String.new(batch.bytes)).to eq "a"
  end

  it "ignores a key that carries no character" do
    batch = translate translator, [key(0_u16), key('b')]

    expect(String.new(batch.bytes)).to eq "b"
  end

  it "takes the character an Alt code composed from Alt's release" do
    batch = translate translator, [key('é', down: false, virtual_key: Lib::VK_MENU)]

    expect(String.new(batch.bytes)).to eq "é"
  end

  it "repeats a key the console coalesced" do
    batch = translate translator, [key('x', repeat: 3)]

    expect(String.new(batch.bytes)).to eq "xxx"
  end

  it "makes UTF-8 of a surrogate pair" do
    batch = translate translator, keys("a😀b")

    expect(String.new(batch.bytes)).to eq "a😀b"
  end

  # A read can end between the halves. The high half waits for the next one
  # rather than becoming a replacement character, or an empty read that looks
  # like the end of input.
  it "holds the first half of a pair split across reads" do
    units = "😀".to_utf16
    first = translate translator, [key('a'), key(units[0])]
    second = translate translator, [key(units[1]), key('b')]

    expect(String.new(first.bytes)).to eq "a"
    expect(String.new(second.bytes)).to eq "😀b"
  end

  it "says the window changed size" do
    batch = translate translator, [window_size(100, 30)]

    expect(batch.resized).to be_true
    expect(batch.bytes).to be_empty
  end

  it "makes one change of several size records" do
    batch = translate translator, [window_size(100, 30), key('z'), window_size(90, 20)]

    expect(batch.resized).to be_true
    expect(String.new(batch.bytes)).to eq "z"
  end
end
