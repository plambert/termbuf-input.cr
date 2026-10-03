require "./event"
require "./patterns"

module TermBuf
  module Input
    # What the terminal says the pointer did, taken out of an SGR mouse report.
    #
    # SGR — DEC private mode 1006 — is the encoding worth decoding: the older
    # one packs the coordinates into single bytes and cannot name a column past
    # 223, and it has no way to say which button was let go. An SGR report is
    # `CSI < button ; column ; row M` for a press and the same with a final `m`
    # for a release, all of it in decimal.
    #
    # Turning the reporting on is the application's call, with
    # `Mode::MOUSE_SGR` or one of its siblings. Decoding is not: `Input::Stream` watches for
    # `CSI <` from the moment it is built, so a report arrives as
    # `Events::Mouse` whoever asked for it.
    module Mouse
      # Which button, with the wheel counted as four of them because that is
      # how the terminal reports it: a wheel notch is a press and there is no
      # release to match it.
      #
      # `None` is the button field of a report with no button held, which is
      # what a bare motion carries and what most terminals send for a release.
      enum Button
        Left
        Middle
        Right

        # No button: a motion with nothing held, and the release a terminal
        # that does not say which button was let go sends.
        None

        WheelUp
        WheelDown

        # Horizontal wheel, or a trackpad's sideways scroll.
        WheelLeft

        # :ditto:
        WheelRight

        Button8
        Button9
        Button10
        Button11

        # Whether this is a wheel notch rather than a button, which matters
        # because a notch has no release and holding it means nothing.
        def wheel? : Bool
          in? WheelUp, WheelDown, WheelLeft, WheelRight
        end
      end

      # What happened to it.
      enum Action
        Press
        Release

        # The pointer moved. Reported only while a button is held unless the
        # application asked for all motion, which DEC mode 1000 does not.
        Motion
      end

      # The bit that says the pointer moved rather than being clicked.
      MOTION = 32

      # The bit that says the button field names a wheel notch.
      WHEEL = 64

      # The bit that says the button field names one of buttons 8 to 11.
      EXTENDED = 128

      # Shift was held.
      SHIFT = 4

      # Alt, or meta, was held.
      ALT = 8

      # Control was held.
      CTRL = 16

      # What *sequence* says the pointer did, or `nil` if it is not an SGR
      # mouse report after all.
      #
      # Returning `nil` is how a pattern says "not mine": a `CSI <` that is not
      # a report — a truncated one, a field that is not a number, a coordinate
      # at zero — carries on to the key decoder and arrives as
      # `Key::Name::Unknown`, which beats inventing a click nobody made.
      def self.decode(sequence : Input::Sequence) : Events::Mouse?
        return unless sequence.prefix.csi?

        body = sequence.body
        return unless body.starts_with? '<'

        final = body[-1]?
        return unless final && final.in?('M', 'm')

        fields = body[1..-2].split ';'
        return unless fields.size == 3

        code = fields[0].to_i?
        column = fields[1].to_i?
        row = fields[2].to_i?
        return unless code && column && row
        return unless code >= 0

        # The terminal numbers its columns and rows from one; every buffer
        # coordinate in this shard is numbered from zero. This is where the two
        # meet, so a buffer's hit test takes these coordinates as they stand.
        return unless column >= 1 && row >= 1

        Events::Mouse.new button(code), column - 1, row - 1,
          modifiers(code), action(code, final)
      end

      # What an X10 mouse report says the pointer did, or `nil` if *sequence*
      # is not one.
      #
      # `CSI M` and three bytes, each the value plus 32: the button code, the
      # column and the row. The code is the SGR one, except that a release is
      # button 3 and does not say which button came up. Nothing here asks for
      # this encoding; it is decoded so that a terminal sending it is heard as
      # a mouse rather than as three keys.
      def self.decode_x10(sequence : Input::Sequence) : Events::Mouse?
        return unless sequence.prefix.csi?

        bytes = sequence.bytes
        return unless bytes.size == 6 && bytes[2] == 'M'.ord

        code = bytes[3].to_i - 32
        column = bytes[4].to_i - 32
        row = bytes[5].to_i - 32
        return unless code >= 0 && column >= 1 && row >= 1

        released = code & 0b11 == 3 && !code.bits_set?(WHEEL) && !code.bits_set?(MOTION)
        action = if released
                   Action::Release
                 elsif code.bits_set? MOTION
                   Action::Motion
                 else
                   Action::Press
                 end

        Events::Mouse.new released ? Button::None : button(code), column - 1, row - 1,
          modifiers(code), action
      end

      # Which button *code* names.
      #
      # The button lives in the low two bits, and one of two flags above them
      # says which set of four to read them against: the wheel, buttons 8 to
      # 11, or — with neither flag — left, middle, right and none.
      def self.button(code : Int32) : Button
        offset = code & 0b11

        base = if code.bits_set? EXTENDED
                 Button::Button8
               elsif code.bits_set? WHEEL
                 Button::WheelUp
               else
                 Button::Left
               end

        Button.new base.value + offset
      end

      # What was held down alongside it.
      def self.modifiers(code : Int32) : Modifiers
        held = Modifiers::None
        held |= Modifiers::Shift if code.bits_set? SHIFT
        held |= Modifiers::Alt if code.bits_set? ALT
        held |= Modifiers::Ctrl if code.bits_set? CTRL
        held
      end

      # What happened. The final byte separates a press from a release, and the
      # motion bit turns a press into a drag.
      def self.action(code : Int32, final : Char) : Action
        return Action::Release if final == 'm'

        code.bits_set?(MOTION) ? Action::Motion : Action::Press
      end
    end
  end
end
