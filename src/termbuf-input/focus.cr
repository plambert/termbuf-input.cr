require "./event"
require "./patterns"

module TermBuf
  module Input
    # What the terminal says about its window's focus, taken out of a focus
    # report.
    #
    # With DEC private mode 1004 on, the terminal sends `CSI I` when its window
    # gains focus and `CSI O` when it loses it. Neither is a key, so nothing is
    # lost by claiming them.
    #
    # Turning the reports on is the application's call, with
    # `Mode::FOCUS_EVENTS`, and only worth making where the terminal supports
    # them. Decoding is not: `Input::Stream` watches for both from the moment
    # it is built, so a report arrives as `Events::Focus` whoever asked for it.
    module Focus
      # The body of the report a window gaining focus sends.
      GAINED = "I"

      # The body of the report a window losing focus sends.
      LOST = "O"

      # What *sequence* says about focus, or `nil` if it is not a focus report.
      #
      # Only the bare forms count. A `CSI` with parameters and one of these
      # finals is something else, and carries on to the key decoder.
      def self.decode(sequence : Input::Sequence) : Events::Focus?
        return unless sequence.prefix.csi?

        case sequence.body
        when GAINED then Events::Focus.new true
        when LOST   then Events::Focus.new false
        end
      end
    end
  end
end
