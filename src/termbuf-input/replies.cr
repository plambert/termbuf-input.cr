require "./event"
require "./patterns"

module TermBuf
  module Input
    # What a terminal says about one DEC private mode, in a `DECRQM` reply.
    enum ModeState
      # The terminal does not know the mode.
      NotRecognized = 0

      Set              = 1
      Reset            = 2
      PermanentlySet   = 3
      PermanentlyReset = 4

      # Whether the mode can be on: known, and not fixed off.
      def supported? : Bool
        set? || reset? || permanently_set?
      end
    end

    # Which of the terminal's colours a `Events::Color` is.
    enum ColorSlot
      Foreground
      Background
      Cursor
      Palette
    end

    # Parsers for the replies a terminal sends to a `Query`, each answering an
    # event or `nil` when the sequence is not that reply.
    #
    # They take a `Sequence` and know nothing about who asked, so a caller
    # reading the device itself, such as a capability probe, can use them on
    # sequences cut out of its own bytes.
    module Replies
      # `CSI row ; column R`.
      def self.cursor_position(sequence : Sequence) : Events::CursorPosition?
        return unless sequence.prefix.csi?
        return unless match = sequence.body.match /\A(\d+);(\d+)R\z/

        row, column = match[1].to_i, match[2].to_i
        return unless row >= 1 && column >= 1

        Events::CursorPosition.new column - 1, row - 1
      end

      # `CSI 8 ; rows ; columns t`.
      def self.text_area_size(sequence : Sequence) : Events::TextAreaSize?
        return unless pair = window_report(sequence, 8)

        Events::TextAreaSize.new pair[1], pair[0]
      end

      # `CSI 4 ; height ; width t`.
      def self.text_area_pixels(sequence : Sequence) : Events::TextAreaPixels?
        return unless pair = window_report(sequence, 4)

        Events::TextAreaPixels.new pair[1], pair[0]
      end

      # `CSI 6 ; height ; width t`.
      def self.cell_pixels(sequence : Sequence) : Events::CellPixels?
        return unless pair = window_report(sequence, 6)

        Events::CellPixels.new pair[1], pair[0]
      end

      # `CSI ? mode ; state $ y`, for *mode* alone when it is given.
      def self.mode_report(sequence : Sequence, mode : Int32? = nil) : Events::ModeReport?
        return unless sequence.prefix.csi?
        return unless match = sequence.body.match /\A\?(\d+);(\d+)\$y\z/

        number = match[1].to_i
        return if mode && number != mode

        state = ModeState.from_value?(match[2].to_i) || ModeState::NotRecognized
        Events::ModeReport.new number, state
      end

      # `CSI ? flags u`.
      def self.kitty_keyboard(sequence : Sequence) : Events::KittyKeyboard?
        return unless sequence.prefix.csi?
        return unless match = sequence.body.match /\A\?(\d+)u\z/

        Events::KittyKeyboard.new match[1].to_i
      end

      # `OSC 10`, `11` or `12 ; rgb:… ST` for the dynamic colours, and
      # `OSC 4 ; index ; rgb:… ST` for a palette entry. Either terminator.
      def self.color(sequence : Sequence) : Events::Color?
        return unless sequence.prefix.osc?

        fields = string_body(sequence).split ';'

        case fields.size
        when 2
          slot = case fields[0]
                 when "10" then ColorSlot::Foreground
                 when "11" then ColorSlot::Background
                 when "12" then ColorSlot::Cursor
                 end
          return unless slot

          color slot, nil, fields[1]
        when 3
          return unless fields[0] == "4"
          return unless index = fields[1].to_i?

          color ColorSlot::Palette, index, fields[2]
        end
      end

      # `CSI ? … c` for the primary attributes and `CSI > … c` for the
      # secondary.
      def self.device_attributes(sequence : Sequence) : Events::DeviceAttributes?
        return unless sequence.prefix.csi?
        return unless match = sequence.body.match /\A([?>])([\d;]*)c\z/

        parameters = match[2].split(';', remove_empty: true).map &.to_i
        Events::DeviceAttributes.new match[1] == ">", parameters
      end

      # `DCS > | text ST`.
      def self.terminal_name(sequence : Sequence) : Events::TerminalName?
        return unless sequence.prefix.dcs?

        body = string_body sequence
        return unless body.starts_with? ">|"

        Events::TerminalName.new body[2..]
      end

      # The two numbers after *code* in a window report, `CSI code ; a ; b t`.
      private def self.window_report(sequence : Sequence, code : Int32) : {Int32, Int32}?
        return unless sequence.prefix.csi?
        return unless match = sequence.body.match /\A(\d+);(\d+);(\d+)t\z/
        return unless match[1].to_i == code

        {match[2].to_i, match[3].to_i}
      end

      # A string sequence's body without its terminator, which is `ST` or a
      # bell, whichever the terminal chose.
      private def self.string_body(sequence : Sequence) : String
        body = sequence.body
        return body.rchop "\e\\" if body.ends_with? "\e\\"

        body.rchop '\a'
      end

      # `rgb:r/g/b`, or `rgba:r/g/b/a` with the alpha ignored, where each
      # component is one to four hex digits.
      private def self.color(slot : ColorSlot, index : Int32?, spec : String) : Events::Color?
        components = if spec.starts_with? "rgb:"
                       spec[4..].split '/'
                     elsif spec.starts_with? "rgba:"
                       spec[5..].split('/').first 3
                     end
        return unless components && components.size == 3

        red, green, blue = components.map { |hex| scale hex }
        return unless red && green && blue

        Events::Color.new slot, index, red, green, blue
      end

      # One hex component scaled to eight bits, so `ff` and `ffff` are both
      # 255 and `8` is 136.
      private def self.scale(hex : String) : UInt8?
        return unless 1 <= hex.size <= 4
        return unless value = hex.to_i?(16)

        maximum = (16 ** hex.size) - 1
        ((value * 255 + maximum // 2) // maximum).to_u8
      end
    end
  end
end
