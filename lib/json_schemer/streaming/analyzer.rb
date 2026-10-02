# frozen_string_literal: true
module JSONSchemer
  module Streaming
    # Analyzes a schema (before any bytes are read) to decide whether it can
    # be validated with bounded memory while streaming.
    #
    # Keywords are classified as:
    #
    # - streamable: local constraints that only need the current value
    #   (types, numeric and string constraints, properties, required,
    #   prefixItems/items, size limits, ...);
    # - whole-value: rules that need the entire value at once (uniqueItems,
    #   contains, if/then/else, allOf/anyOf/oneOf/not, unevaluated*, ...).
    #   Below the document root these may still be handled by buffering each
    #   item (see the buffer_items option of validate_each); at the root
    #   they are rejected because they would require the whole document;
    # - unsupported: references, which streaming cannot resolve.
    class Analyzer
      STREAMABLE_KEYWORDS = %w[
        type enum const
        minimum maximum exclusiveMinimum exclusiveMaximum multipleOf
        minLength maxLength pattern
        properties required patternProperties additionalProperties propertyNames dependentRequired
        prefixItems items minItems maxItems minProperties maxProperties
      ].freeze

      ANNOTATION_KEYWORDS = %w[
        $id $schema $anchor $comment $defs
        title description default deprecated readOnly writeOnly examples format
      ].freeze

      WHOLE_VALUE_KEYWORDS = %w[
        uniqueItems contains minContains maxContains
        if then else allOf anyOf oneOf not
        dependentSchemas dependencies
        unevaluatedItems unevaluatedProperties
        contentEncoding contentMediaType contentSchema
      ].freeze

      REFERENCE_KEYWORDS = %w[$ref $dynamicRef $recursiveRef].freeze

      Plan = Struct.new(:schema, :unsupported, :buffered) do
        # True when the schema can be validated incrementally without any
        # buffering of whole values.
        def streamable?
          unsupported.empty? && buffered.empty?
        end
      end

      def initialize(schema)
        @schema = schema
        @unsupported = []
        @buffered = []
      end

      def analyze
        walk(@schema, [], false)
        Plan.new(@schema, @unsupported, @buffered)
      end

    private

      def walk(schema, pointer, bufferable)
        return unless schema.is_a?(Hash)

        whole_value_keywords = []

        schema.each do |keyword, value|
          case keyword
          when *REFERENCE_KEYWORDS
            @unsupported << entry(keyword, pointer, 'references are not supported by streaming validation')
          when *WHOLE_VALUE_KEYWORDS
            whole_value_keywords << keyword
          when 'enum'
            whole_value_keywords << keyword unless value.is_a?(Array) && value.all? { |element| scalar?(element) }
          when 'const'
            whole_value_keywords << keyword unless scalar?(value)
          end
        end

        if whole_value_keywords.any?
          if bufferable
            @buffered << pointer.freeze
            return
          end
          whole_value_keywords.each do |keyword|
            @unsupported << entry(keyword, pointer, 'requires the whole value and cannot be bounded at the document root')
          end
        end

        walk_subschemas(schema, pointer)
      end

      def walk_subschemas(schema, pointer)
        if (properties = schema['properties']).is_a?(Hash)
          properties.each do |property, subschema|
            walk(subschema, pointer + ['properties', property], true)
          end
        end
        if (pattern_properties = schema['patternProperties']).is_a?(Hash)
          pattern_properties.each do |pattern, subschema|
            walk(subschema, pointer + ['patternProperties', pattern], true)
          end
        end
        walk(schema['additionalProperties'], pointer + ['additionalProperties'], true)
        walk(schema['items'], pointer + ['items'], true)
        if (prefix_items = schema['prefixItems']).is_a?(Array)
          prefix_items.each_with_index do |subschema, index|
            walk(subschema, pointer + ['prefixItems', index], true)
          end
        end
        # propertyNames applies to complete strings, so whole-value rules
        # inside it cannot be buffered and are rejected instead.
        walk(schema['propertyNames'], pointer + ['propertyNames'], false)
      end

      def scalar?(value)
        value.nil? || value == true || value == false || value.is_a?(Numeric) || value.is_a?(String)
      end

      def entry(keyword, pointer, reason)
        {
          'keyword' => keyword,
          'schema_pointer' => self.class.pointer_string(pointer),
          'reason' => reason
        }
      end

      def self.pointer_string(pointer)
        pointer.map { |token| "/#{Location.escape_json_pointer_token(token.to_s)}" }.join
      end
    end
  end
end
