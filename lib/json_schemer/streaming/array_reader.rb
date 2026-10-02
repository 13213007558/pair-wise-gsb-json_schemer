# frozen_string_literal: true
require 'json'

module JSONSchemer
  class StreamingJSONParseError < JSON::ParserError; end

  # Reads a top-level JSON array from a chunked byte source without buffering
  # more than one element plus the current read chunk. JSON structural
  # characters are always ASCII, so scanning byte by byte cannot split an
  # escape sequence or a multi-byte UTF-8 character; the in-progress token is
  # the only element-sized state retained between chunks.
  class StreamingArrayReader
    EOF_SENTINEL = Object.new.freeze

    def initialize(source, chunk_size: 4096)
      @source = source
      @chunk_size = chunk_size
      @buffer = String.new(encoding: Encoding::BINARY)
      @pos = 0
      @source_offset = 0
      @state = :start
      @depth = nil
      @string = false
      @escape = false
      @element_start = 0
      # true while the parser still needs to see the start of the next
      # top-level element value (used to reject missing values and trailing
      # commas, including when they span chunk boundaries).
      @expect_value = true
      @had_comma = false
      @value_seen = false
      @container_stack = []
    end

    def each
      raise(ArgumentError, 'a block is required') unless block_given?
      until (element = next_element).equal?(EOF_SENTINEL)
        yield(element)
      end
      nil
    end

    # Returns the next parsed top-level element, or EOF_SENTINEL when the
    # array is exhausted. The previous element is not retained: callers only
    # need to release their own reference for it to become garbage
    # collectable.
    def next_element
      return EOF_SENTINEL if @state == :done
      loop do
        event, token = advance
        case event
        when :element
          return parse_element(token)
        when :end_element
          value = parse_element(token)
          drain_remaining!
          return value
        when :end
          @state = :done
          drain_remaining!
          return EOF_SENTINEL
        when :need_more
          if refill
            next
          elsif @state == :after_root
            @state = :done
            return EOF_SENTINEL
          else
            raise_unexpected_eof!
          end
        end
      end
    end

    # Reads only enough bytes to decide whether the top-level value is an
    # array. Returns the complete source String when it is not (including the
    # bytes already buffered), so the caller can fall back to whole-document
    # validation; returns nil for arrays.
    def non_array_source
      while @state == :start
        while @pos < @buffer.bytesize
          byte = @buffer.getbyte(@pos)
          if whitespace?(byte)
            consume!
          else
            return nil if byte == 0x5B # [
            return complete_source
          end
        end
        return nil unless refill
      end
      nil
    end

    def complete_source
      rest = @source.is_a?(String) ? @source.byteslice(@source_offset, @source.bytesize - @source_offset) : @source.read
      @source_offset = @source.bytesize if @source.is_a?(String)
      @buffer.force_encoding(Encoding::UTF_8) + rest.to_s.force_encoding(Encoding::UTF_8)
    end

  private

    # Returns [:element, token], [:end, nil] or [:need_more, nil].
    def advance
      while @pos < @buffer.bytesize
        byte = @buffer.getbyte(@pos)

        case @state
        when :start
          next if skip_whitespace!(byte)
          unless byte == 0x5B # [
            raise(StreamingJSONParseError, 'streaming validation requires a JSON array')
          end
          consume!
          @state = :elements
          @depth = 1
          @container_stack = [0x5B]
          @element_start = @pos
          @expect_value = true
          @had_comma = false
        when :elements
          event, token = scan_elements!(byte)
          return [event, token] if event
        when :after_root
          unless whitespace?(byte)
            raise(StreamingJSONParseError, 'unexpected trailing token after JSON array')
          end
          consume!
        end
      end
      [:need_more, nil]
    end

    def scan_elements!(byte)
      if @escape
        @escape = false
        consume!
      elsif @string
        if byte == 0x5C # backslash
          @escape = true
        elsif byte == 0x22 # closing quote
          @string = false
        end
        consume!
      else
        case byte
        when 0x22 # opening quote
          @string = true
          @expect_value = false
          @value_seen = true
          consume!
        when 0x7B, 0x5B # { [
          @depth += 1
          @expect_value = false
          @value_seen = true
          @container_stack << byte
          consume!
        when 0x7D, 0x5D # } ]
          opener = @container_stack.pop
          unless matching_closer?(opener, byte)
            raise(StreamingJSONParseError, "unexpected '#{byte.chr}' in JSON array")
          end
          @depth -= 1
          if @depth == 0
            return root_closed!
          end
          consume!
        when 0x2C # comma
          if @depth == 1
            raise_trailing_comma! if @expect_value && !@value_seen
            token = token_before_delimiter!
            @expect_value = true
            @had_comma = true
            @value_seen = false
            return [:element, token]
          end
          consume!
        else
          unless whitespace?(byte)
            @expect_value = false
            @value_seen = true
          end
          consume!
        end
      end
      nil
    end

    def root_closed!
      token = token_before_delimiter!
      if token.strip.empty?
        raise_trailing_comma! if @had_comma
        @state = :done
        @expect_value = false
        return [:end, nil]
      end
      @state = :after_root
      @expect_value = false
      [:end_element, token]
    end

    def token_before_delimiter!
      token = @buffer.byteslice(@element_start, @pos - @element_start)
      @buffer.slice!(0, @pos + 1)
      @pos = 0
      @element_start = 0
      token.force_encoding(Encoding::UTF_8)
      unless token.valid_encoding? || incomplete_utf8_tail?(token)
        raise(StreamingJSONParseError, 'invalid UTF-8 encoding in JSON token')
      end
      token
    end

    def parse_element(token)
      JSON.parse(token)
    rescue JSON::ParserError => e
      raise(StreamingJSONParseError, e.message)
    end

    def raise_trailing_comma!
      raise(StreamingJSONParseError, 'unexpected comma in JSON array')
    end

    def raise_unexpected_eof!
      raise(StreamingJSONParseError, 'unexpected end of JSON input')
    end

    def drain_remaining!
      loop do
        while @pos < @buffer.bytesize
          byte = @buffer.getbyte(@pos)
          unless whitespace?(byte)
            raise(StreamingJSONParseError, 'unexpected trailing token after JSON array')
          end
          consume!
        end
        return unless refill
      end
    end

    def skip_whitespace!(byte)
      return false unless whitespace?(byte)
      consume!
      true
    end

    def consume!
      @pos += 1
    end

    def refill
      chunk = read_chunk
      return false unless chunk
      @buffer << chunk.b
      true
    end

    def read_chunk
      if @source.is_a?(String)
        return nil if @source_offset >= @source.bytesize
        chunk = @source.byteslice(@source_offset, @chunk_size)
        @source_offset += chunk.bytesize
        chunk
      else
        @source.read(@chunk_size)
      end
    end

    def whitespace?(byte)
      byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09
    end

    def matching_closer?(opener, closer)
      (opener == 0x5B && closer == 0x5D) || (opener == 0x7B && closer == 0x7D)
    end

    # The only permitted invalidity is a multi-byte character whose lead byte
    # (plus any continuation bytes already received) sits at the very end of
    # the token; it is completed by the next chunk. Anything else is a real
    # encoding error.
    def incomplete_utf8_tail?(token)
      bytes = token.bytes
      index = 0
      while index < bytes.size
        byte = bytes[index]
        continuation = continuation_length(byte)
        unless continuation
          return false unless byte <= 0x7F
          index += 1
          next
        end
        available = bytes.size - index - 1
        if available < continuation
          return index + available == bytes.size - 1 &&
            bytes[(index + 1)..].all? { |b| b.between?(0x80, 0xBF) }
        end
        return false unless bytes[(index + 1), continuation].all? { |b| b.between?(0x80, 0xBF) }
        index += 1 + continuation
      end
      false
    end

    def continuation_length(byte)
      case byte
      when 0xF0..0xF7 then 3
      when 0xE0..0xEF then 2
      when 0xC2..0xDF then 1
      end
    end
  end
end
