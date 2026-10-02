# frozen_string_literal: true
module JSONSchemer
  module Streaming
    # Incremental, SAX-style JSON parser. It reads from an IO in bounded
    # chunks and yields parse events, so arbitrarily large documents can be
    # processed without loading them into memory. Only the parser buffer and
    # the current token are kept alive; consumed bytes are discarded.
    #
    # Events are yielded as (type, payload) pairs where payload is only set
    # for :key (String) and :value (String, Integer, Float, true, false
    # or nil) events:
    #
    #   :start_object / :end_object
    #   :start_array  / :end_array
    #   :key          (object member name)
    #   :value        (scalar)
    class Parser
      DEFAULT_CHUNK_SIZE = 16 * 1024

      BOM = "\xEF\xBB\xBF".b
      BACKSLASH = 0x5C
      QUOTE = 0x22
      OPEN_OBJECT = 0x7B
      CLOSE_OBJECT = 0x7D
      OPEN_ARRAY = 0x5B
      CLOSE_ARRAY = 0x5D
      COMMA = 0x2C
      COLON = 0x3A

      WHITESPACE = [0x20, 0x09, 0x0A, 0x0D].freeze
      NUMBER_BYTES = begin
        table = Array.new(256, false)
        [0x2B, 0x2D, 0x2E, 0x45, 0x65, *(0x30..0x39)].each { |byte| table[byte] = true }
        table.freeze
      end
      NUMBER_REGEX = /\A-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?\z/
      HEX_ESCAPE_REGEX = /\A[0-9a-fA-F]{4}\z/

      # Absolute byte offset of the next unconsumed byte.
      attr_reader :position

      def initialize(io, chunk_size: DEFAULT_CHUNK_SIZE)
        raise ArgumentError, 'chunk_size must be a positive Integer' unless chunk_size.is_a?(Integer) && chunk_size.positive?
        @io = io
        @chunk_size = chunk_size
        @buffer = +''.b
        @buffer_pos = 0
        @position = 0
        @eof = false
      end

      def each_event
        return enum_for(:each_event) unless block_given?

        skip_bom

        # Explicit stack state machine (no recursion) so deeply nested
        # documents cannot overflow the Ruby stack.
        stack = []
        state = :value

        loop do
          skip_whitespace
          byte = peek_byte

          case state
          when :value
            raise ParseError, "unexpected end of input at byte #{position}" if byte.nil?
            case byte
            when OPEN_OBJECT
              advance
              yield :start_object, nil
              stack.push(:object)
              state = :object_key_or_end
            when OPEN_ARRAY
              advance
              yield :start_array, nil
              stack.push(:array)
              state = :array_value_or_end
            when QUOTE
              yield :value, parse_string
              state = after_value_state(stack)
            when 0x74
              expect_literal('true')
              yield :value, true
              state = after_value_state(stack)
            when 0x66
              expect_literal('false')
              yield :value, false
              state = after_value_state(stack)
            when 0x6E
              expect_literal('null')
              yield :value, nil
              state = after_value_state(stack)
            when 0x2D, 0x30..0x39
              yield :value, parse_number
              state = after_value_state(stack)
            else
              raise ParseError, "unexpected character at byte #{position}"
            end
          when :array_value_or_end
            raise ParseError, "unexpected end of input at byte #{position}" if byte.nil?
            if byte == CLOSE_ARRAY
              advance
              stack.pop
              yield :end_array, nil
              state = after_value_state(stack)
            else
              state = :value
            end
          when :object_key_or_end
            raise ParseError, "unexpected end of input at byte #{position}" if byte.nil?
            if byte == CLOSE_OBJECT
              advance
              stack.pop
              yield :end_object, nil
              state = after_value_state(stack)
            elsif byte == QUOTE
              yield :key, parse_string
              state = :object_colon
            else
              raise ParseError, "unexpected character at byte #{position}"
            end
          when :object_key
            raise ParseError, "unexpected end of input at byte #{position}" if byte.nil?
            if byte == QUOTE
              yield :key, parse_string
              state = :object_colon
            else
              raise ParseError, "unexpected character at byte #{position}"
            end
          when :object_colon
            raise ParseError, "unexpected end of input at byte #{position}" if byte.nil?
            raise ParseError, "unexpected character at byte #{position}" unless byte == COLON
            advance
            state = :value
          when :object_comma
            raise ParseError, "unexpected end of input at byte #{position}" if byte.nil?
            if byte == COMMA
              advance
              state = :object_key
            elsif byte == CLOSE_OBJECT
              advance
              stack.pop
              yield :end_object, nil
              state = after_value_state(stack)
            else
              raise ParseError, "unexpected character at byte #{position}"
            end
          when :array_comma
            raise ParseError, "unexpected end of input at byte #{position}" if byte.nil?
            if byte == COMMA
              advance
              state = :value
            elsif byte == CLOSE_ARRAY
              advance
              stack.pop
              yield :end_array, nil
              state = after_value_state(stack)
            else
              raise ParseError, "unexpected character at byte #{position}"
            end
          else
            raise ParseError, "unexpected trailing data at byte #{position}" if byte
            break
          end
        end
      end

    private

      def after_value_state(stack)
        if stack.empty?
          :done
        elsif stack.last == :array
          :array_comma
        else
          :object_comma
        end
      end

      def fill_buffer
        return false if @eof
        chunk = @io.read(@chunk_size)
        if chunk.nil? || chunk.empty?
          @eof = true
          return false
        end
        compact_buffer
        @buffer << chunk.b
        true
      end

      def compact_buffer
        return if @buffer_pos.zero?
        @buffer.slice!(0, @buffer_pos)
        @buffer_pos = 0
      end

      def peek_byte
        loop do
          return @buffer.getbyte(@buffer_pos) if @buffer_pos < @buffer.bytesize
          return nil unless fill_buffer
        end
      end

      def peek_bytes(count)
        fill_buffer while !@eof && @buffer.bytesize - @buffer_pos < count
        @buffer.byteslice(@buffer_pos, count)
      end

      def read_byte
        byte = peek_byte
        raise ParseError, "unexpected end of input at byte #{position}" if byte.nil?
        advance
        byte
      end

      def advance
        @buffer_pos += 1
        @position += 1
      end

      def skip_bom
        return unless peek_bytes(3) == BOM
        3.times { advance }
      end

      def skip_whitespace
        while (byte = peek_byte) && WHITESPACE.include?(byte)
          advance
        end
      end

      def expect_literal(rest)
        rest.each_byte do |expected|
          byte = read_byte
          raise ParseError, "invalid literal at byte #{position - 1}" unless byte == expected
        end
      end

      def parse_string
        advance
        out = +''.b
        loop do
          byte = read_byte
          case byte
          when QUOTE
            break
          when BACKSLASH
            out << parse_escape
          when 0x00..0x1F
            raise ParseError, "unescaped control character in string at byte #{position - 1}"
          else
            out << byte
          end
        end
        out.force_encoding(Encoding::UTF_8)
        raise ParseError, "invalid UTF-8 in string at byte #{position}" unless out.valid_encoding?
        out
      end

      def parse_escape
        case (escape = read_byte)
        when QUOTE, BACKSLASH, 0x2F
          escape.chr
        when 0x62
          "\b"
        when 0x66
          "\f"
        when 0x6E
          "\n"
        when 0x72
          "\r"
        when 0x74
          "\t"
        when 0x75
          parse_unicode_escape
        else
          raise ParseError, "invalid escape sequence at byte #{position - 1}"
        end
      end

      def parse_unicode_escape
        codepoint = read_hex4
        if codepoint.between?(0xD800, 0xDBFF)
          unless read_byte == BACKSLASH && read_byte == 0x75
            raise ParseError, "unpaired surrogate in unicode escape at byte #{position}"
          end
          low = read_hex4
          unless low.between?(0xDC00, 0xDFFF)
            raise ParseError, "unpaired surrogate in unicode escape at byte #{position}"
          end
          codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (low - 0xDC00)
        elsif codepoint.between?(0xDC00, 0xDFFF)
          raise ParseError, "unpaired surrogate in unicode escape at byte #{position}"
        end
        [codepoint].pack('U').b
      end

      def read_hex4
        hex = +''.b
        4.times { hex << read_byte }
        raise ParseError, "invalid unicode escape at byte #{position}" unless hex.match?(HEX_ESCAPE_REGEX)
        hex.to_i(16)
      end

      def parse_number
        token = +''.b
        while (byte = peek_byte) && NUMBER_BYTES[byte]
          token << byte
          advance
        end
        raise ParseError, "invalid number at byte #{position - token.bytesize}" unless token.match?(NUMBER_REGEX)
        if token.include?('.') || token.include?('e') || token.include?('E')
          Float(token)
        else
          Integer(token)
        end
      end
    end
  end
end
