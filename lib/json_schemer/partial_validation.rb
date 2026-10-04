# frozen_string_literal: true

module JSONSchemer
  module PartialValidation
    class UnknownValue
      def inspect
        'JSONSchemer::PartialValidation::UNKNOWN'
      end
      alias to_s inspect
    end

    UNKNOWN = UnknownValue.new.freeze
    Outcome = Struct.new(:status, :unresolved, keyword_init: true)

    class << self
      def validate(schema, instance, access_mode: nil)
        Validator.new(schema, access_mode).validate(schema.send(:deep_stringify_keys, instance))
      end

      def unknown?(value)
        case value
        when UnknownValue
          true
        when Hash
          value.any? { |_key, item| unknown?(item) }
        when Array
          value.any? { |item| unknown?(item) }
        else
          false
        end
      end
    end

    class Validator
      IGNORED_KEYWORDS = %w[
        $schema $vocabulary $id $anchor $dynamicAnchor $recursiveAnchor id
        $defs definitions $comment title description default examples deprecated x-error
        contentEncoding contentMediaType
      ].freeze

      def initialize(schema, access_mode)
        @schema = schema
        @access_mode = access_mode
      end

      def validate(instance)
        outcome = schema(@schema, instance, '', Set.new)
        {
          'valid' => { :valid => true, :invalid => false, :pending => nil }.fetch(outcome.status),
          'status' => outcome.status.to_s,
          'unresolved' => outcome.unresolved
        }
      end

    private

      def valid
        Outcome.new(:status => :valid, :unresolved => [])
      end

      def invalid
        Outcome.new(:status => :invalid, :unresolved => [])
      end

      def pending(source, pointer, _instance, reason = 'unknown value')
        keyword = source.is_a?(Keyword) ? source.error_key : '$ref'
        Outcome.new(
          :status => :pending,
          :unresolved => [{
            'keyword' => keyword,
            'schemaLocation' => source.schema_pointer,
            'instanceLocation' => pointer,
            'reason' => reason
          }]
        )
      end

      def combine(outcomes)
        return invalid if outcomes.any? { |outcome| outcome.status == :invalid }

        pending_outcomes = outcomes.select { |outcome| outcome.status == :pending }
        return valid if pending_outcomes.empty?

        Outcome.new(:status => :pending, :unresolved => pending_outcomes.flat_map(&:unresolved))
      end

      def schema(value, instance, pointer, active)
        active_key = [value.object_id, pointer]
        return pending(value, pointer, instance, 'recursive schema') if active.include?(active_key)

        active = active.dup.add(active_key)
        return invalid if value.value == false
        return valid if value.value == true
        return concrete(value, instance) unless PartialValidation.unknown?(instance)
        return valid unless value.value.is_a?(Hash)

        outcomes = []
        custom_keywords = value.root.custom_keywords.keys & value.value.keys
        custom_keywords.each { |keyword| outcomes << unsupported(keyword, value, pointer) }

        value.parsed.each do |keyword, source|
          next if IGNORED_KEYWORDS.include?(keyword) || custom_keywords.include?(keyword)
          next if source.is_a?(Draft202012::Vocab::Core::UnknownKeyword)

          outcomes << keyword_result(keyword, source, value, instance, pointer, active)
        end

        combine(outcomes)
      ensure
        active.delete(active_key)
      end

      def concrete(value, instance)
        value.valid?(instance, :access_mode => @access_mode) ? valid : invalid
      end

      def keyword_result(keyword, source, value, instance, pointer, active)
        case keyword
        when '$ref'
          schema(source.ref_schema, instance, pointer, active)
        when '$dynamicRef', '$recursiveRef'
          pending(source, pointer, instance, 'unsupported dynamic reference')
        when 'type'
          type(source, instance, pointer)
        when 'enum', 'const'
          enum_value(source, instance, pointer)
        when 'required'
          required(source, value, instance, pointer)
        when 'properties'
          properties(source, instance, pointer, active)
        when 'patternProperties'
          pattern_properties(source, instance, pointer, active)
        when 'additionalProperties'
          additional_properties(source, value, instance, pointer, active)
        when 'prefixItems'
          tuple_items(source, source.parsed, instance, pointer, active)
        when 'items'
          items(source, value, instance, pointer, active)
        when 'additionalItems'
          additional_items(source, value, instance, pointer, active)
        when 'allOf'
          combine(source.parsed.map { |subschema| schema(subschema, instance, pointer, active) })
        when 'anyOf'
          any_of(source, instance, pointer, active)
        when 'oneOf'
          one_of(source, instance, pointer, active)
        when 'not'
          not_schema(source, instance, pointer, active)
        when 'readOnly', 'writeOnly'
          access_mode(source, keyword)
        else
          pending(source, pointer, instance, 'unsupported keyword')
        end
      end

      def type(source, instance, pointer)
        return pending(source, pointer, instance) if instance.is_a?(UnknownValue)
        keyword_outcome(source, instance, pointer)
      end

      def enum_value(source, instance, pointer)
        return pending(source, pointer, instance) if PartialValidation.unknown?(instance)
        keyword_outcome(source, instance, pointer)
      end

      def required(source, value, instance, pointer)
        return pending(source, pointer, instance) if instance.is_a?(UnknownValue)
        return valid unless instance.is_a?(Hash)

        required_keys = source.value.dup
        if @access_mode && (properties = value.parsed['properties'])
          properties.parsed.each do |property, subschema|
            read_only = subschema.parsed['readOnly']&.parsed == true
            write_only = subschema.parsed['writeOnly']&.parsed == true
            inaccessible = (@access_mode == 'write' && read_only) || (@access_mode == 'read' && write_only)
            required_keys.delete(property) if inaccessible
          end
        end

        (required_keys - instance.keys).empty? ? valid : invalid
      end

      def properties(source, instance, pointer, active)
        return pending(source, pointer, instance) if instance.is_a?(UnknownValue)
        return valid unless instance.is_a?(Hash)

        outcomes = source.parsed.filter_map do |property, subschema|
          next unless instance.key?(property)
          schema(subschema, instance.fetch(property), pointer_join(pointer, property), active)
        end
        combine(outcomes)
      end

      def pattern_properties(source, instance, pointer, active)
        return pending(source, pointer, instance) if instance.is_a?(UnknownValue)
        return valid unless instance.is_a?(Hash)

        outcomes = []
        source.parsed.each do |pattern, subschema|
          regexp = source.root.resolve_regexp(pattern)
          instance.each do |property, value|
            next unless regexp.match?(property)
            outcomes << schema(subschema, value, pointer_join(pointer, property), active)
          end
        end
        combine(outcomes)
      end

      def additional_properties(source, value, instance, pointer, active)
        return pending(source, pointer, instance) if instance.is_a?(UnknownValue)
        return valid unless instance.is_a?(Hash)

        evaluated = Set.new(value.parsed['properties']&.parsed&.keys)
        value.parsed['patternProperties']&.parsed&.each_key do |pattern|
          regexp = source.root.resolve_regexp(pattern)
          instance.each_key { |property| evaluated.add(property) if regexp.match?(property) }
        end

        outcomes = instance.reject { |property, _value| evaluated.include?(property) }.map do |property, value_instance|
          schema(source.parsed, value_instance, pointer_join(pointer, property), active)
        end
        combine(outcomes)
      end

      def items(source, value, instance, pointer, active)
        return pending(source, pointer, instance) if instance.is_a?(UnknownValue)
        return valid unless instance.is_a?(Array)

        if source.parsed.is_a?(Array)
          tuple_items(source, source.parsed, instance, pointer, active)
        else
          offset = value.parsed['prefixItems']&.parsed&.size || 0
          each_item(source.parsed, instance, offset...instance.size, pointer, active)
        end
      end

      def additional_items(source, value, instance, pointer, active)
        return pending(source, pointer, instance) if instance.is_a?(UnknownValue)
        return valid unless instance.is_a?(Array)

        tuple_items = value.parsed['items']&.parsed
        return valid unless tuple_items.is_a?(Array)

        each_item(source.parsed, instance, tuple_items.size...instance.size, pointer, active)
      end

      def tuple_items(source, tuple_schemas, instance, pointer, active)
        return pending(source, pointer, instance) if instance.is_a?(UnknownValue)
        return valid unless instance.is_a?(Array)

        each_item(nil, instance, 0...[tuple_schemas.size, instance.size].min, pointer, active, tuple_schemas)
      end

      def each_item(item_schema, instance, indexes, pointer, active, tuple_schemas = nil)
        combine(indexes.map do |index|
          current_schema = tuple_schemas ? tuple_schemas.fetch(index) : item_schema
          schema(current_schema, instance.fetch(index), pointer_join(pointer, index.to_s), active)
        end)
      end

      def any_of(source, instance, pointer, active)
        outcomes = source.parsed.map { |subschema| schema(subschema, instance, pointer, active) }
        return valid if outcomes.any? { |outcome| outcome.status == :valid }
        return invalid if outcomes.all? { |outcome| outcome.status == :invalid }

        unresolved = outcomes.select { |outcome| outcome.status == :pending }.flat_map(&:unresolved)
        Outcome.new(:status => :pending, :unresolved => unresolved)
      end

      def one_of(source, instance, pointer, active)
        outcomes = source.parsed.map { |subschema| schema(subschema, instance, pointer, active) }
        valid_count = outcomes.count { |outcome| outcome.status == :valid }

        return invalid if valid_count > 1
        return valid if valid_count == 1 && outcomes.none? { |outcome| outcome.status == :pending }
        return invalid if valid_count == 0 && outcomes.all? { |outcome| outcome.status == :invalid }

        unresolved = outcomes.select { |outcome| outcome.status == :pending }.flat_map(&:unresolved)
        Outcome.new(:status => :pending, :unresolved => unresolved)
      end

      def not_schema(source, instance, pointer, active)
        outcome = schema(source.parsed, instance, pointer, active)
        case outcome.status
        when :valid
          invalid
        when :invalid
          valid
        else
          Outcome.new(:status => :pending, :unresolved => outcome.unresolved)
        end
      end

      def keyword_outcome(source, instance, pointer)
        context = Schema::Context.new(instance, [], nil, true, @access_mode)
        source.validate(instance, pointer, Location.root, context).valid ? valid : invalid
      end

      def access_mode(source, keyword)
        return valid unless source.parsed == true && @access_mode

        valid_access = (keyword == 'readOnly' && @access_mode == 'read') ||
          (keyword == 'writeOnly' && @access_mode == 'write')
        valid_access ? valid : invalid
      end

      def unsupported(keyword, value, pointer)
        Outcome.new(
          :status => :pending,
          :unresolved => [{
            'keyword' => keyword,
            'schemaLocation' => "#{value.schema_pointer}/#{Location.escape_json_pointer_token(keyword)}",
            'instanceLocation' => pointer,
            'reason' => 'unsupported keyword'
          }]
        )
      end

      def pointer_join(pointer, token)
        "#{pointer}/#{Location.escape_json_pointer_token(token)}"
      end
    end
  end
end
