# The parts of the Windows console API that Crystal's own `LibC` does not
# bind: the screen buffer's geometry, and the console mode flags beyond the
# few the standard library uses itself.
#
# A lib of its own, named for the shard, rather than more of `LibC`. A later
# Crystal binding the same function with a different signature would stop
# every build that required this one, and a name of our own cannot clash.
#
# termbuf reads the screen size through this too, which is why it is here
# and not in the reader that needs it first: termbuf already depends on this
# shard, and two bindings of one struct would be two things to keep right.
lib LibTermBufConsole
  # Input mode flags, for `GetConsoleMode` and `SetConsoleMode` on an input
  # handle. `LibC` carries processed, line, echo and virtual terminal input.

  # A window that changed size is reported in the input, as a
  # `WINDOW_BUFFER_SIZE_EVENT` record.
  ENABLE_WINDOW_INPUT = 0x0008_u32

  # The mouse is reported in the input, as `MOUSE_EVENT` records.
  ENABLE_MOUSE_INPUT = 0x0010_u32

  # Dragging the mouse selects text in the console's own window instead of
  # reaching the program. Only changeable with `ENABLE_EXTENDED_FLAGS` set in
  # the same call.
  ENABLE_QUICK_EDIT_MODE = 0x0040_u32

  # Says that the call is setting `ENABLE_QUICK_EDIT_MODE` and
  # `ENABLE_INSERT_MODE` too, rather than leaving them alone.
  ENABLE_EXTENDED_FLAGS = 0x0080_u32

  # Output mode flags, for an output handle. `LibC` carries virtual terminal
  # processing.

  # A line feed moves the cursor down without returning it to the first
  # column, and writing the last column waits for the next character before
  # wrapping, as a terminal does. Without it the bottom right cell scrolls.
  DISABLE_NEWLINE_AUTO_RETURN = 0x0008_u32

  struct Coord
    x : Int16
    y : Int16
  end

  struct SmallRect
    left : Int16
    top : Int16
    right : Int16
    bottom : Int16
  end

  # What `GetConsoleScreenBufferInfo` fills in. *size* is the whole buffer,
  # scrollback included in a classic console window; *window* is the part
  # showing, inclusive at both ends, and the only part that is the screen.
  struct ConsoleScreenBufferInfo
    size : Coord
    cursor_position : Coord
    attributes : UInt16
    window : SmallRect
    maximum_window_size : Coord
  end

  fun GetConsoleScreenBufferInfo(hConsoleOutput : LibC::HANDLE, lpConsoleScreenBufferInfo : ConsoleScreenBufferInfo*) : LibC::BOOL

  # What an input record is, in `InputRecord#event_type`. Mouse, menu and
  # focus records exist too; nothing here reads them.
  KEY_EVENT                = 0x0001_u16
  WINDOW_BUFFER_SIZE_EVENT = 0x0004_u16

  # The Alt key, whose release carries the character an Alt+numpad code
  # composed.
  VK_MENU = 0x12_u16

  struct KeyEventRecord
    key_down : LibC::BOOL
    repeat_count : UInt16
    virtual_key_code : UInt16
    virtual_scan_code : UInt16
    # A union of a UTF-16 code unit and an 8-bit character in C; the console
    # fills the UTF-16 side for `ReadConsoleInputW`.
    unicode_char : UInt16
    control_key_state : UInt32
  end

  struct WindowBufferSizeRecord
    size : Coord
  end

  # The other members are as large as a key record or smaller, so these two
  # give the union its size: sixteen bytes, four-byte aligned.
  union InputEvent
    key_event : KeyEventRecord
    window_buffer_size_event : WindowBufferSizeRecord
  end

  struct InputRecord
    event_type : UInt16
    event : InputEvent
  end

  fun ReadConsoleInputW(hConsoleInput : LibC::HANDLE, lpBuffer : InputRecord*, nLength : LibC::DWORD, lpNumberOfEventsRead : LibC::DWORD*) : LibC::BOOL

  fun CreateEventW(lpEventAttributes : Void*, bManualReset : LibC::BOOL, bInitialState : LibC::BOOL, lpName : UInt16*) : LibC::HANDLE
  fun SetEvent(hEvent : LibC::HANDLE) : LibC::BOOL
  fun WaitForMultipleObjects(nCount : LibC::DWORD, lpHandles : LibC::HANDLE*, bWaitAll : LibC::BOOL, dwMilliseconds : LibC::DWORD) : LibC::DWORD
end
