# frozen_string_literal: true
module JSONSchemer
  module Streaming
    # Builds a single Ruby value from parser events. Used only when the
    # schema contains whole-value keywords and the caller explicitly opted
    # into bounded buffering (buffer_items / max_item_bytes).
    class ValueBuilder
      attr_reader :result

      def initialize
        @stack = []
        @key = nil
        @done = false
        @result = nil
      end

      def done?
        @done
      end

      def handle(type, payload)
        case type
        when :start_object
          @stack.push({})
        when :start_array
          @stack.push([])
        when :end_object, :end_array
          add(@stack.pop)
        when :key
          @key = payload
        when :value
          add(payload)
        end
      end

    private

      def add(value)
        if @stack.empty?
          @result = value
          @done = true
        elsif (top = @stack.last).is_a?(Array)
          top << value
        else
          top[@key] = value
        end
      end
    end
  end
end
