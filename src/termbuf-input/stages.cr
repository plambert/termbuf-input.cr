require "./stage"

module TermBuf
  module Input
    # The chain every event walks on its way to the application: an ordered
    # list of `Stage`, safe to change from any fibre while the dispatcher is
    # walking it.
    #
    # Every read takes a copy of the list under a mutex and works on that, so
    # an event part way through the chain when it changes finishes on the
    # chain it started on, and the next event uses the new one. Every write
    # happens under the same mutex, and since no copy leaves it and no array
    # given to it is kept, the list itself is only ever touched under the lock. `#each` and everything `Enumerable` builds on it (`#map`,
    # `#find`, `#to_a`, `#empty?`, `#size`) see one such copy; the block may
    # change the chain without deadlocking.
    #
    # Empty by default, which is the useful default: with nothing in it every
    # event goes to the channel as it was made. A driver puts its own
    # translations here — termbuf answers `SIGWINCH` in a stage called
    # `:resize`, which consumes the signal and sends a resize event in its
    # place — and an application adds, removes or reorders them:
    #
    #     stream.stages.push Stage.new(:drop_motion, handler)
    #
    #     stream.stages.replace stream.stages.reject { |stage| stage.name == :drop_motion }
    #
    # `Stream#inject` bypasses the chain entirely, since what the driver has to
    # say on its own account is not something a filter should be able to
    # swallow.
    class Stages
      include Enumerable(Stage)

      def initialize
        @mutex = Mutex.new
        @list = [] of Stage
      end

      # Adds *stage* at the end of the chain.
      def push(stage : Stage) : self
        @mutex.synchronize { @list << stage }
        self
      end

      # :ditto:
      def <<(stage : Stage) : self
        push stage
      end

      # Makes *stages*, in that order, the whole chain.
      def replace(stages : Enumerable(Stage)) : self
        @mutex.synchronize { @list = Array(Stage).new.concat stages }
        self
      end

      # Yields each stage of the chain as it was when the call began.
      def each(& : Stage ->) : Nil
        to_a.each { |stage| yield stage }
      end

      # The chain as it is now, as an array nobody else holds.
      def to_a : Array(Stage)
        @mutex.synchronize { @list.dup }
      end

      def to_s(io : IO) : Nil
        io << "Stages("
        to_a.join(io, ", ") { |stage, target| target << stage.name }
        io << ')'
      end
    end
  end
end
