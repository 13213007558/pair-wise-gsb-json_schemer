# frozen_string_literal: true
module JSONSchemer
  module Streaming
    # Incremental validator driven by Parser events. It keeps only a stack of
    # frames for the values currently being read (bounded by document depth
    # and by the property count of the objects currently open), so completed
    # array items are never retained.
    #
    # Errors use the same classic output shape as JSONSchemer::Schema#validate
    # and identical data_pointer/schema_pointer paths. One deliberate
    # difference: for container-level errors (required, dependentRequired,
    # min/maxProperties, min/maxItems) the data entry is nil because the
    # whole container is not kept in memory.
    class Validator
      Frame = Struct.new(:schemas, :kind, :path, :index, :keys, :prop_count, :current_key, :type_errors, :property_name_errors)
      SchemaRef = Struct.new(:value, :pointer)

      TRUE_REF = SchemaRef.new(true, nil).freeze

      TYPE_ERROR_MESSAGES = {
        'null' => 'is not null',
        'boolean' => 'is not a boolean',
        'number' => 'is not a number',
        'integer' => 'is not an integer',
        'string' => 'is not a string',
        'array' => 'is not an array',
        'object' => 'is not an object'
      }.freeze

      # Frames currently on the validator stack. Exposed so callers and tests
      # can verify that completed items are popped again.
      attr_reader :frames

      def initialize(schema, plan = Analyzer.new(schema).analyze, max_item_bytes: Streaming::DEFAULT_MAX_ITEM_BYTES, regexp_resolver: 'ruby')
        @root_schema = schema
        @buffered_pointers = plan.buffered.to_set
        @max_item_bytes = max_item_bytes
        @regexp_resolver = regexp_resolver
        @regexps = {}
        @frames = []
        @skip_depth = 0
        @buffer_state = nil
        @buffered_schemers = {}
      end

      def handle_event(type, payload, position)
        if @buffer_state
          feed_buffer(type, payload, position) { |error| yield error }
          return
        end

        if @skip_depth.positive?
          @skip_depth += 1 if type == :start_object || type == :start_array
          @skip_depth -= 1 if type == :end_object || type == :end_array
          return
        end

        case type
        when :start_object
          value_start(:object, nil, position) { |error| yield error }
        when :start_array
          value_start(:array, nil, position) { |error| yield error }
        when :end_object, :end_array
          close_frame { |error| yield error }
        when :key
          handle_key(payload) { |error| yield error }
        when :value
          value_start(json_kind(payload), payload, position) { |error| yield error }
        end
      end

    private

      def value_start(kind, value, position)
        schemas, path = next_value_schemas_and_path

        if schemas.any? { |schema_ref| schema_ref.pointer && @buffered_pointers.include?(schema_ref.pointer) }
          @buffer_state = {
            :schemas => schemas,
            :path => path,
            :start_position => position - 1,
            :builder => ValueBuilder.new
          }
          feed_buffer(buffer_event_type(kind), value, position) { |error| yield error }
          return
        end

        schemas.each do |schema_ref|
          yield false_schema_error(schema_ref, path, container_kind?(kind) ? nil : value) if schema_ref.value == false
        end
        active = schemas.reject { |schema_ref| schema_ref.value == false }

        if container_kind?(kind)
          if active.empty?
            @skip_depth = 1
          else
            # Container type errors are deferred to the matching close event
            # so they are emitted after child errors, matching the keyword
            # evaluation order of the regular validator.
            type_errors = active.filter_map { |schema_ref| build_type_error(schema_ref, kind, value, path) }
            @frames.push(Frame.new(active, kind, path, 0, kind == :object ? Set.new : nil, 0, nil, type_errors, []))
          end
        else
          validate_scalar(value, active, path) { |error| yield error }
        end
      end

      def container_kind?(kind)
        kind == :object || kind == :array
      end

      def buffer_event_type(kind)
        case kind
        when :object then :start_object
        when :array then :start_array
        else :value
        end
      end

      def next_value_schemas_and_path
        if @frames.empty?
          return [[SchemaRef.new(@root_schema, [])], []]
        end
        frame = @frames.last
        if frame.kind == :array
          index = frame.index
          frame.index += 1
          [frame.schemas.flat_map { |schema_ref| array_children(schema_ref, index) }, frame.path + [index]]
        else
          key = frame.current_key
          [frame.schemas.flat_map { |schema_ref| object_children(schema_ref, key) }, frame.path + [key]]
        end
      end

      def array_children(schema_ref, index)
        schema = schema_ref.value
        return [TRUE_REF] if schema == true
        if (prefix_items = schema['prefixItems']).is_a?(Array) && index < prefix_items.size
          [SchemaRef.new(prefix_items[index], schema_ref.pointer + ['prefixItems', index])]
        elsif schema.key?('items')
          [SchemaRef.new(schema['items'], schema_ref.pointer + ['items'])]
        else
          [TRUE_REF]
        end
      end

      def object_children(schema_ref, key)
        schema = schema_ref.value
        return [TRUE_REF] if schema == true
        children = []
        if (properties = schema['properties']).is_a?(Hash) && properties.key?(key)
          children << SchemaRef.new(properties[key], schema_ref.pointer + ['properties', key])
        end
        if (pattern_properties = schema['patternProperties']).is_a?(Hash)
          pattern_properties.each do |pattern, subschema|
            if regexp(pattern).match?(key)
              children << SchemaRef.new(subschema, schema_ref.pointer + ['patternProperties', pattern])
            end
          end
        end
        if children.empty? && schema.key?('additionalProperties')
          children << SchemaRef.new(schema['additionalProperties'], schema_ref.pointer + ['additionalProperties'])
        end
        children
      end

      def handle_key(key)
        frame = @frames.last
        frame.current_key = key
        frame.keys.add(key)
        frame.prop_count += 1
        frame.schemas.each do |schema_ref|
          schema = schema_ref.value
          next unless schema.is_a?(Hash) && schema.key?('propertyNames')
          property_names_ref = SchemaRef.new(schema['propertyNames'], schema_ref.pointer + ['propertyNames'])
          # Deferred to the close event so propertyNames errors are emitted
          # after child errors, matching the keyword evaluation order of the
          # regular validator.
          validate_scalar(key, [property_names_ref], frame.path) { |error| frame.property_name_errors << error }
        end
      end

      def close_frame
        frame = @frames.pop
        frame.property_name_errors.each { |error| yield error }
        frame.type_errors.each { |error| yield error }
        frame.schemas.each do |schema_ref|
          schema = schema_ref.value
          next unless schema.is_a?(Hash)
          if frame.kind == :object
            check_property_count(schema_ref, schema, frame) { |error| yield error }
            check_required(schema_ref, schema, frame) { |error| yield error }
            check_dependent_required(schema_ref, schema, frame) { |error| yield error }
          else
            check_item_count(schema_ref, schema, frame) { |error| yield error }
          end
        end
      end

      def check_required(schema_ref, schema, frame)
        required = schema['required']
        return unless required.is_a?(Array)
        missing = required - frame.keys.to_a
        return if missing.empty?
        yield error_hash(
          schema_ref, frame.path, nil, 'required',
          "object at #{formatted_location(frame.path)} is missing required properties: #{missing.join(', ')}",
          { 'missing_keys' => missing }
        )
      end

      def check_dependent_required(schema_ref, schema, frame)
        dependent_required = schema['dependentRequired']
        return unless dependent_required.is_a?(Hash)
        dependent_required.each do |trigger, dependencies|
          next unless frame.keys.include?(trigger)
          next if (dependencies - frame.keys.to_a).empty?
          path = frame.path + [trigger]
          yield error_hash(
            schema_ref, path, nil, 'dependentRequired',
            "object at #{formatted_location(path)} is missing required `dependentRequired` properties"
          )
        end
      end

      def check_property_count(schema_ref, schema, frame)
        if (max = schema['maxProperties']).is_a?(Numeric) && frame.prop_count > max
          yield error_hash(schema_ref, frame.path, nil, 'maxProperties', "object size at #{formatted_location(frame.path)} is greater than: #{max}")
        end
        if (min = schema['minProperties']).is_a?(Numeric) && frame.prop_count < min
          yield error_hash(schema_ref, frame.path, nil, 'minProperties', "object size at #{formatted_location(frame.path)} is less than: #{min}")
        end
      end

      def check_item_count(schema_ref, schema, frame)
        if (max = schema['maxItems']).is_a?(Numeric) && frame.index > max
          yield error_hash(schema_ref, frame.path, nil, 'maxItems', "array size at #{formatted_location(frame.path)} is greater than: #{max}")
        end
        if (min = schema['minItems']).is_a?(Numeric) && frame.index < min
          yield error_hash(schema_ref, frame.path, nil, 'minItems', "array size at #{formatted_location(frame.path)} is less than: #{min}")
        end
      end

      def build_type_error(schema_ref, kind, value, path)
        schema = schema_ref.value
        return nil unless schema.is_a?(Hash) && schema.key?('type')
        data = container_kind?(kind) ? nil : value
        case (types = schema['type'])
        when String
          unless type_matches?(types, kind, value)
            return error_hash(schema_ref, path, data, types, "value at #{formatted_location(path)} #{TYPE_ERROR_MESSAGES[types]}")
          end
        when Array
          unless types.any? { |type| type_matches?(type, kind, value) }
            return error_hash(schema_ref, path, data, 'type', "value at #{formatted_location(path)} is not one of the types: #{types}")
          end
        end
        nil
      end

      def type_matches?(type, kind, value)
        case type
        when 'null'
          kind == :null
        when 'boolean'
          kind == :boolean
        when 'number'
          kind == :number || kind == :integer
        when 'integer'
          kind == :integer || (kind == :number && value.floor == value)
        when 'string'
          kind == :string
        when 'array'
          kind == :array
        when 'object'
          kind == :object
        else
          true
        end
      end

      def json_kind(value)
        case value
        when Integer
          :integer
        when Numeric
          :number
        when String
          :string
        when true, false
          :boolean
        when nil
          :null
        end
      end

      def validate_scalar(value, schemas, path)
        schemas.each do |schema_ref|
          schema = schema_ref.value
          next unless schema.is_a?(Hash)
          if (type_error = build_type_error(schema_ref, json_kind(value), value, path))
            yield type_error
          end
          check_enum_const(schema_ref, schema, value, path) { |error| yield error }
          check_numeric(schema_ref, schema, value, path) { |error| yield error } if value.is_a?(Numeric)
          check_string(schema_ref, schema, value, path) { |error| yield error } if value.is_a?(String)
        end
      end

      def check_enum_const(schema_ref, schema, value, path)
        if (enum = schema['enum']).is_a?(Array) && !enum.include?(value)
          yield error_hash(schema_ref, path, value, 'enum', "value at #{formatted_location(path)} is not one of: #{enum}")
        end
        if schema.key?('const') && schema['const'] != value
          yield error_hash(schema_ref, path, value, 'const', "value at #{formatted_location(path)} is not: #{schema['const']}")
        end
      end

      def check_numeric(schema_ref, schema, value, path)
        if (multiple_of = schema['multipleOf']).is_a?(Numeric) && !BigDecimal(value.to_s).modulo(multiple_of).zero?
          yield error_hash(schema_ref, path, value, 'multipleOf', "number at #{formatted_location(path)} is not a multiple of: #{multiple_of}")
        end
        if (maximum = schema['maximum']).is_a?(Numeric) && value > maximum
          yield error_hash(schema_ref, path, value, 'maximum', "number at #{formatted_location(path)} is greater than: #{maximum}")
        end
        if (exclusive_maximum = schema['exclusiveMaximum']).is_a?(Numeric) && value >= exclusive_maximum
          yield error_hash(schema_ref, path, value, 'exclusiveMaximum', "number at #{formatted_location(path)} is greater than or equal to: #{exclusive_maximum}")
        end
        if (minimum = schema['minimum']).is_a?(Numeric) && value < minimum
          yield error_hash(schema_ref, path, value, 'minimum', "number at #{formatted_location(path)} is less than: #{minimum}")
        end
        if (exclusive_minimum = schema['exclusiveMinimum']).is_a?(Numeric) && value <= exclusive_minimum
          yield error_hash(schema_ref, path, value, 'exclusiveMinimum', "number at #{formatted_location(path)} is less than or equal to: #{exclusive_minimum}")
        end
      end

      def check_string(schema_ref, schema, value, path)
        if (max_length = schema['maxLength']).is_a?(Numeric) && value.size > max_length
          yield error_hash(schema_ref, path, value, 'maxLength', "string length at #{formatted_location(path)} is greater than: #{max_length}")
        end
        if (min_length = schema['minLength']).is_a?(Numeric) && value.size < min_length
          yield error_hash(schema_ref, path, value, 'minLength', "string length at #{formatted_location(path)} is less than: #{min_length}")
        end
        if (pattern = schema['pattern']).is_a?(String) && !regexp(pattern).match?(value)
          yield error_hash(schema_ref, path, value, 'pattern', "string at #{formatted_location(path)} does not match pattern: #{pattern}")
        end
      end

      def regexp(pattern)
        @regexps[pattern] ||= begin
          resolver = @regexp_resolver == 'ecma' ? Schema::ECMA_REGEXP_RESOLVER : Schema::RUBY_REGEXP_RESOLVER
          resolver.call(pattern)
        end
      end

      def feed_buffer(type, payload, position)
        state = @buffer_state
        if position - state[:start_position] > @max_item_bytes
          @buffer_state = nil
          raise ItemTooLargeError, "buffered value at #{json_pointer(state[:path])} exceeds max_item_bytes (#{@max_item_bytes})"
        end
        builder = state[:builder]
        builder.handle(type, payload)
        return unless builder.done?
        @buffer_state = nil
        state[:schemas].each do |schema_ref|
          validate_buffered(schema_ref, state[:path], builder.result) { |error| yield error }
        end
      end

      def validate_buffered(schema_ref, path, value)
        case schema_ref.value
        when false
          yield false_schema_error(schema_ref, path, value)
        when true
          nil
        else
          schemer = @buffered_schemers[schema_ref.pointer] ||= JSONSchemer.schema(schema_ref.value)
          schemer.validate(value).each do |error|
            yield remap_buffered_error(error, schema_ref, path)
          end
        end
      end

      def remap_buffered_error(error, schema_ref, path)
        prefix = json_pointer(path)
        sub_pointer = error['data_pointer']
        data_pointer = "#{prefix}#{sub_pointer}"
        old_location = sub_pointer.empty? ? 'root' : "`#{sub_pointer}`"
        error = error.dup
        error['data_pointer'] = data_pointer
        error['schema_pointer'] = "#{json_pointer(schema_ref.pointer)}#{error['schema_pointer']}"
        error['root_schema'] = @root_schema
        error['error'] = error['error'].sub(old_location, "`#{data_pointer}`")
        error
      end

      def false_schema_error(schema_ref, path, data)
        message =
          if schema_ref.pointer&.last == 'additionalProperties'
            "object property at #{formatted_location(path)} is a disallowed additional property"
          else
            "value at #{formatted_location(path)} does not match schema"
          end
        error_hash(schema_ref, path, data, 'schema', message)
      end

      def error_hash(schema_ref, path, data, type, message, details = nil)
        error = {
          'data' => data,
          'data_pointer' => json_pointer(path),
          'schema' => schema_ref.value,
          'schema_pointer' => json_pointer(schema_ref.pointer),
          'root_schema' => @root_schema,
          'type' => type,
          'error' => message
        }
        error['details'] = details if details
        error
      end

      def json_pointer(path)
        Analyzer.pointer_string(path)
      end

      def formatted_location(path)
        path.empty? ? 'root' : "`#{json_pointer(path)}`"
      end
    end
  end
end
