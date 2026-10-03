# A Windows pseudoconsole to run a program in, for tests: a program run
# inside one reads console input and writes console output exactly as it
# would under Windows Terminal or WezTerm, which host their programs the same
# way. The caller is the terminal. It types bytes into the input, resizes the
# console, and has the program's output kept drained for it. No window opens.
#
# Not part of the shard's API, and not required by `termbuf-input`. A spec
# that wants it asks for it:
#
#     require "termbuf-input/win32/pseudo_console"
{% skip_file unless flag?(:win32) %}

require "./lib_console"

lib LibTermBufPty
  alias HPCON = Void*

  PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = 0x00020016_u64
  EXTENDED_STARTUPINFO_PRESENT        = 0x00080000_u32
  STARTF_USESTDHANDLES                = 0x00000100_u32

  struct STARTUPINFOEXW
    startup_info : LibC::STARTUPINFOW
    attribute_list : Void*
  end

  fun CreatePipe(hReadPipe : LibC::HANDLE*, hWritePipe : LibC::HANDLE*, lpPipeAttributes : Void*, nSize : LibC::DWORD) : LibC::BOOL
  fun CreatePseudoConsole(size : LibTermBufConsole::Coord, hInput : LibC::HANDLE, hOutput : LibC::HANDLE, dwFlags : LibC::DWORD, phPC : HPCON*) : Int32
  fun ResizePseudoConsole(hPC : HPCON, size : LibTermBufConsole::Coord) : Int32
  fun ClosePseudoConsole(hPC : HPCON) : Void
  fun InitializeProcThreadAttributeList(lpAttributeList : Void*, dwAttributeCount : LibC::DWORD, dwFlags : LibC::DWORD, lpSize : LibC::SizeT*) : LibC::BOOL
  fun UpdateProcThreadAttribute(lpAttributeList : Void*, dwFlags : LibC::DWORD, attribute : LibC::SizeT, lpValue : Void*, cbSize : LibC::SizeT, lpPreviousValue : Void*, lpReturnSize : LibC::SizeT*) : LibC::BOOL
  fun DeleteProcThreadAttributeList(lpAttributeList : Void*) : Void
end

module TermBuf::Input
  class PseudoConsole
    @console : LibTermBufPty::HPCON
    @input : LibC::HANDLE
    @output : LibC::HANDLE
    @process : LibC::HANDLE
    @thread : LibC::HANDLE
    @attributes : Bytes
    @drained = IO::Memory.new
    @lock = Mutex.new
    @drainer : Fiber::ExecutionContext::Isolated? = nil

    # Starts *command* with *arguments* inside a pseudoconsole *columns* by
    # *rows*.
    def initialize(command : String, arguments : Array(String), columns : Int32, rows : Int32)
      LibTermBufPty.CreatePipe(out console_reads, out @input, nil, 0).zero? && raise IO::Error.from_winerror("CreatePipe")
      LibTermBufPty.CreatePipe(out @output, out console_writes, nil, 0).zero? && raise IO::Error.from_winerror("CreatePipe")

      result = LibTermBufPty.CreatePseudoConsole(coord(columns, rows), console_reads, console_writes, 0, out @console)
      raise "CreatePseudoConsole failed: 0x#{result.to_u32.to_s(16)}" unless result == 0

      # The pseudoconsole holds its own ends now.
      LibC.CloseHandle console_reads
      LibC.CloseHandle console_writes

      LibTermBufPty.InitializeProcThreadAttributeList(nil, 1, 0, out size)
      @attributes = Bytes.new size
      LibTermBufPty.InitializeProcThreadAttributeList(@attributes, 1, 0, pointerof(size)).zero? &&
        raise IO::Error.from_winerror("InitializeProcThreadAttributeList")
      LibTermBufPty.UpdateProcThreadAttribute(@attributes, 0, LibTermBufPty::PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
        @console, sizeof(LibTermBufPty::HPCON), nil, nil).zero? &&
        raise IO::Error.from_winerror("UpdateProcThreadAttribute")

      info = LibTermBufPty::STARTUPINFOEXW.new
      info.startup_info.cb = sizeof(LibTermBufPty::STARTUPINFOEXW)
      # Standard handles given as nothing, so the program attaches to the
      # pseudoconsole rather than inheriting whatever this process has, which
      # under a spec runner or CI is a pipe.
      info.startup_info.dwFlags = LibTermBufPty::STARTF_USESTDHANDLES
      info.attribute_list = @attributes.to_unsafe.as(Void*)

      line = ([command] + arguments).map { |part| %("#{part}") }.join(' ')
      wide = (line + "\0").to_utf16

      if LibC.CreateProcessW(nil, wide, nil, nil, 0, LibTermBufPty::EXTENDED_STARTUPINFO_PRESENT,
           nil, nil, pointerof(info).as(LibC::STARTUPINFOW*), out process_info).zero?
        raise IO::Error.from_winerror("CreateProcessW")
      end

      @process = process_info.hProcess
      @thread = process_info.hThread
      start_draining
    end

    # Types *text* into the console, as a terminal would send it.
    def type(text : String) : Nil
      bytes = text.to_slice
      LibC.WriteFile(@input, bytes, bytes.size, out _, nil).zero? && raise IO::Error.from_winerror("WriteFile")
    end

    def resize(columns : Int32, rows : Int32) : Nil
      result = LibTermBufPty.ResizePseudoConsole(@console, coord(columns, rows))
      raise "ResizePseudoConsole failed: 0x#{result.to_u32.to_s(16)}" unless result == 0
    end

    # Everything the program has written so far, as the console rendered it.
    def screen : String
      @lock.synchronize { @drained.to_s }
    end

    # Waits up to *timeout* for the program to end, and answers its exit code,
    # or `nil` if it is still running.
    def wait(timeout : Time::Span) : Int32?
      return unless LibC.WaitForSingleObject(@process, timeout.total_milliseconds.to_u32) == LibC::WAIT_OBJECT_0

      LibC.GetExitCodeProcess(@process, out code)
      code.to_i32!
    end

    # Ends the program if it is still running and closes the console.
    #
    # Terminating returns before the process is gone, and its executable stays
    # locked until it is, so this waits: the specs delete the executable when
    # they end.
    def close : Nil
      unless wait(0.seconds)
        LibC.TerminateProcess(@process, 1)
        wait 5.seconds
      end
      LibTermBufPty.ClosePseudoConsole @console
      LibTermBufPty.DeleteProcThreadAttributeList @attributes
      LibC.CloseHandle @input
      LibC.CloseHandle @process
      LibC.CloseHandle @thread
    end

    # A pseudoconsole stops when nobody reads its output, so a thread of its
    # own reads it for as long as there is any.
    private def start_draining : Nil
      output = @output
      drained = @drained
      lock = @lock

      @drainer = Fiber::ExecutionContext::Isolated.new("conpty-drain") do
        buffer = Bytes.new 4096
        loop do
          break if LibC.ReadFile(output, buffer, buffer.size, out count, nil).zero? || count.zero?
          lock.synchronize { drained.write buffer[0, count] }
        end
        LibC.CloseHandle output
      end
    end

    private def coord(columns : Int32, rows : Int32) : LibTermBufConsole::Coord
      size = LibTermBufConsole::Coord.new
      size.x = columns.to_i16
      size.y = rows.to_i16
      size
    end
  end
end
