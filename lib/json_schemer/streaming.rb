# frozen_string_literal: true
require 'json_schemer/streaming/parser'
require 'json_schemer/streaming/analyzer'
require 'json_schemer/streaming/value_builder'
require 'json_schemer/streaming/validator'

module JSONSchemer
  # Streaming validation for very large JSON documents (typically a
  # top-level array with hundreds of thousands of items) that should not be
  # loaded into memory all at once.
  #
  # The schema is analyzed first (see Streaming::Analyzer) to prove it can
  # be validated with bounded memory. The document is then read from an IO
  # in bounded chunks (see Streaming::Parser) and validated incrementally,
  # yielding one classic-format error at a time with the same
  # data_pointer/schema_pointer paths that validating the parsed document
  # with JSONSchemer::Schema#validate would produce.
  module Streaming
    class ParseError < StandardError; end
    class UnsupportedKeywordError < StandardError; end
    class ItemTooLargeError < StandardError; end

    DEFAULT_MAX_ITEM_BYTES = 1024 * 1024

    class << self
      # Analyzes whether a schema can be validated with bounded memory while
      # streaming. Returns an Analyzer::Plan:
      #
      # - plan.streamable?  => validate_each can run fully incrementally
      # - plan.unsupported  => entries for keywords that can never be
      #   streamed (whole-document rules at the root, references)
      # - plan.buffered     => subschema pointers that need the whole item
      #   value and require validate_each(buffer_items: true)
      def analyze(schema)
        Analyzer.new(normalize_schema(schema)).analyze
      end

      # Lazily yields classic-format validation errors for a JSON document
      # read incrementally from io (anything responding to #read, e.g. IO,
      # StringIO, File).
      #
      # Options:
      # - chunk_size: read buffer size in bytes (default 16KB). UTF-8
      #   characters and escape sequences split across chunks are handled.
      # - buffer_items: set to true to allow subschemas containing
      #   whole-value keywords (uniqueItems, contains, if/then/else, ...).
      #   Each affected item is then buffered and validated with the regular
      #   in-memory validator. This is an explicit, bounded cache: ...
      # - max_item_bytes: maximum size in bytes of a single buffered item
      #   (default 1MB). Exceeding it raises ItemTooLargeError.
      #
      # Raises UnsupportedKeywordError before reading any data when the
      # schema cannot be validated with bounded memory.
      # Raises ParseError (while enumerating) on malformed JSON, including
      # truncated input and trailing data after the root value.
      def validate_each(schema, io, chunk_size: Parser::DEFAULT_CHUNK_SIZE, buffer_items: false, max_item_bytes: DEFAULT_MAX_ITEM_BYTES)
        schema = normalize_schema(schema)
        plan = Analyzer.new(schema).analyze

        unless plan.unsupported.empty?
          raise UnsupportedKeywordError, unsupported_message(plan.unsupported)
        end
        if !buffer_items && plan.buffered.any?
          pointers = plan.buffered.map { |pointer| Analyzer.pointer_string(pointer) }
          raise UnsupportedKeywordError, "schema contains keywords that require the whole item value at: #{pointers.join(', ')}; pass buffer_items: true to validate each item with a bounded buffer (max_item_bytes)"
        end

        enumerator = Enumerator.new do |yielder|
          parser = Parser.new(io, :chunk_size => chunk_size)
          validator = Validator.new(schema, plan, :max_item_bytes => max_item_bytes)
          parser.each_event do |type, payload|
            validator.handle_event(type, payload, parser.position) do |error|
              yielder << error
            end
          end
        end

        block_given? ? enumerator.each { |error| yield error } : enumerator
      end

    private

      def normalize_schema(schema)
        schema = JSON.parse(schema) if schema.is_a?(String)
        case schema
        when Hash
          schema.each_with_object({}) { |(key, value), out| out[key.to_s] = deep_stringify(value) }
        when Array
          schema.map { |value| deep_stringify(value) }
        else
          schema
        end
      end

      def deep_stringify(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, child), out| out[key.to_s] = deep_stringify(child) }
        when Array
          value.map { |child| deep_stringify(child) }
        else
          value
        end
      end

      def unsupported_message(unsupported)
        details = unsupported.map do |entry|
          "#{entry['keyword']} at #{entry['schema_pointer'].empty? ? '/' : entry['schema_pointer']} (#{entry['reason']})"
        end
        "schema cannot be validated with bounded memory: #{details.join(', ')}"
      end
    end
  end
end
