# Windows only. Without this, `crystal docs` elsewhere compiles it and fails.
{% skip_file unless flag?(:win32) %}

require "./lib_console"

module TermBuf
  module Input
    # The Windows console's control events: Ctrl+C, Ctrl+Break, and the
    # console closing, the user logging off or the system shutting down.
    #
    # Windows calls a control handler on a thread it makes for the purpose,
    # which Crystal's runtime knows nothing about, so the handler here does no
    # more than note which event came and wake a thread that does know Crystal.
    # Everything else happens on that thread.
    #
    # Closing, logging off and shutting down end the process as soon as the
    # handler returns. For those the handler waits, up to `CLOSE_WAIT`, for
    # that thread to say it has finished, which is what gives an application
    # the time to write down what it was doing. Crystal's `Process.on_terminate`
    # returns at once and does not.
    #
    # Process-global, as the handler is: one is started, by the first `#start`.
    module ConsoleControl
      extend self

      # How long a close waits for the hooks. Windows allows five seconds
      # before it ends the process regardless.
      CLOSE_WAIT = 4500

      CTRL_C_EVENT        = 0_u32
      CTRL_BREAK_EVENT    = 1_u32
      CTRL_CLOSE_EVENT    = 2_u32
      CTRL_LOGOFF_EVENT   = 5_u32
      CTRL_SHUTDOWN_EVENT = 6_u32

      # Events the handler has noted and the listener has not taken yet, one
      # bit each. A second Ctrl+C before the first is taken is the same bit.
      @@pending = Atomic(UInt32).new(0_u32)

      # Set by the handler when something is pending.
      @@request = LibC::HANDLE.null

      # Set by the listener when it has dealt with a close.
      @@done = LibC::HANDLE.null

      @@listener : Proc(UInt32, Nil)? = nil
      @@context : Fiber::ExecutionContext::Isolated? = nil
      @@routine : LibC::PHANDLER_ROUTINE? = nil

      # Whether `#start` has registered the handler.
      def started? : Bool
        !@@routine.nil?
      end

      # Registers the handler and starts the thread that calls *listener*
      # with each event's number. A second call replaces the listener.
      def start(&listener : UInt32 ->) : Nil
        @@listener = listener
        return if started?

        @@request = LibTermBufConsole.CreateEventW(nil, 0, 0, nil)
        @@done = LibTermBufConsole.CreateEventW(nil, 0, 0, nil)

        @@context = Fiber::ExecutionContext::Isolated.new("termbuf-console-control") { listen }

        routine = LibC::PHANDLER_ROUTINE.new do |event|
          bit = case event
                when CTRL_C_EVENT        then 1_u32
                when CTRL_BREAK_EVENT    then 2_u32
                when CTRL_CLOSE_EVENT    then 4_u32
                when CTRL_LOGOFF_EVENT   then 8_u32
                when CTRL_SHUTDOWN_EVENT then 16_u32
                else                          next 0
                end

          @@pending.or bit
          LibTermBufConsole.SetEvent @@request

          if bit >= 4
            LibC.WaitForSingleObject @@done, CLOSE_WAIT
          end

          1
        end

        @@routine = routine
        LibC.SetConsoleCtrlHandler routine, 1
      end

      # Unregisters the handler, so the console's own handling applies again.
      # The listener thread stays, idle.
      def stop : Nil
        if routine = @@routine
          LibC.SetConsoleCtrlHandler routine, 0
          @@routine = nil
        end
        @@listener = nil
      end

      private def listen : Nil
        loop do
          LibC.WaitForSingleObject @@request, LibC::INFINITE

          pending = @@pending.swap(0_u32)
          {CTRL_C_EVENT, CTRL_BREAK_EVENT, CTRL_CLOSE_EVENT, CTRL_LOGOFF_EVENT, CTRL_SHUTDOWN_EVENT}.each_with_index do |event, index|
            next if (pending & (1_u32 << index)).zero?

            begin
              @@listener.try &.call(event)
            ensure
              LibTermBufConsole.SetEvent @@done if event >= CTRL_CLOSE_EVENT
            end
          end
        end
      end
    end
  end
end
