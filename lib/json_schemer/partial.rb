# frozen_string_literal: true
module JSONSchemer
  # Partial validation for instances that contain unknown values.
  #
  # Unknown values are marked with the explicit +UNKNOWN+ placeholder (or a
  # custom placeholder passed via the +:unknown+ option). The result is
  # three-valued:
  #
  # - +:valid+ -- every possible replacement of the unknown values is valid
  # - +:invalid+ -- every possible replacement of the unknown values is invalid
  # - +:unknown+ -- the outcome depends on the unknown values (pending)
  #
  # Constraints that cannot be decided yet are listed in +Result#unresolved+.
  # Pending results are conservative, but definite conclusions are reliable:
  # replacing all unknown values with concrete values converges to the same
  # result as the regular validator.
  #
  # Supported keywords: +type+, +enum+, +const+, +required+, +properties+,
  # +items+, +prefixItems+, +allOf+, +anyOf+, +oneOf+, +not+, and +$ref+.
  # Any other assertion keyword (e.g. +minimum+, +pattern+, +format+,
  # +additionalProperties+) is *not* evaluated by the partial validator:
  #
  # - if the (sub)instance it applies to contains no unknown values, the
  #   keyword is evaluated exactly by the regular validator;
  # - otherwise it is reported as an unresolved constraint and the result
  #   becomes pending (+:unknown+) unless it is already definitely invalid.
  module Partial
    # Explicit placeholder for a value that exists but is not known yet.
    # Distinct from a missing object key and from +nil+ (JSON null).
    UNKNOWN = Object.new
    class << UNKNOWN
      def inspect
        'JSONSchemer::Partial::UNKNOWN'
      end
      alias to_s inspect
    end
    UNKNOWN.freeze

    # Keywords that never assert anything and are always safe to ignore.
    ANNOTATION_KEYWORDS = %w[
      $schema $id id $anchor $dynamicAnchor $recursiveAnchor $vocabulary $comment
      title description default examples deprecated readOnly writeOnly $defs definitions
    ].freeze

    # Keywords whose behavior depends on evaluation context outside their own
    # subschema, so a subschema containing them cannot be safely delegated to
    # the regular validator on its own.
    UNSAFE_DELEGATION_KEYWORDS = %w[$dynamicRef $recursiveRef unevaluatedItems unevaluatedProperties].freeze

    class Result
      attr_reader :status, :unresolved, :errors

      def initialize(status, unresolved, errors)
        @status = status
        @unresolved = unresolved.freeze
        @errors = errors.freeze
      end

      # Definitely valid: every replacement of the unknown values is valid.
      def valid?
        status == :valid
      end

      # Definitely invalid: every replacement of the unknown values is invalid.
      def invalid?
        status == :invalid
      end

      # Pending: the outcome depends on the unknown values.
      def unknown?
        status == :unknown
      end
      alias pending? unknown?

      def to_h
        {
          'status' => status.to_s,
          'valid' => valid?,
          'unresolved' => unresolved,
          'errors' => errors
        }
      end
    end

    class Evaluator
      def initialize(schema, unknown: UNKNOWN)
        @schema = schema
        @unknown = unknown
        @access_mode = schema.configuration.access_mode
        @delegatable = {}
      end

      def evaluate(instance)
        instance = deep_stringify(instance)
        status, errors, unresolved =
          if contains_unknown?(instance)
            eval_node(@schema, instance, '', [])
          elsif @schema.valid?(instance)
            [:valid, [], []]
          else
            [:invalid, [error_entry(nil, '', @schema.schema_pointer, 'value does not match schema')], []]
          end
        Result.new(status, unresolved, errors)
      end

    private

      # Returns [status, errors, unresolved] where status is one of
      # :valid, :invalid, or :unknown.
      def eval_node(schema, instance, instance_location, ref_stack)
        if !contains_unknown?(instance) && delegatable?(schema)
          return concrete_result(schema, instance, instance_location)
        end

        if schema.value == false
          return [:invalid, [error_entry(nil, instance_location, schema.schema_pointer, 'value does not match `false` schema')], []]
        end

        statuses = []
        errors = []
        unresolved = []

        schema.parsed.each do |name, keyword|
          status, keyword_errors, keyword_unresolved = eval_keyword(schema, name, keyword, instance, instance_location, ref_stack)
          statuses << status
          errors.concat(keyword_errors)
          unresolved.concat(keyword_unresolved)
        end

        custom_keywords = schema.root.custom_keywords
        if custom_keywords.any? && schema.value.is_a?(Hash)
          custom_keywords.each_key do |name|
            next unless schema.value.key?(name)
            statuses << :unknown
            unresolved << unresolved_entry(name, instance_location, join_schema_location(schema.schema_pointer, name), 'custom keywords are not supported by partial validation')
          end
        end

        [combine_and(statuses), errors, unresolved]
      end

      def eval_keyword(schema, name, keyword, instance, instance_location, ref_stack)
        case name
        when 'type'
          eval_type(keyword, instance, instance_location)
        when 'enum', 'const'
          eval_enum_const(keyword, instance, instance_location)
        when 'required'
          eval_required(keyword, instance, instance_location)
        when 'properties'
          eval_properties(keyword, instance, instance_location, ref_stack)
        when 'prefixItems'
          eval_positioned_items(keyword, keyword.parsed, instance, instance_location, ref_stack)
        when 'items'
          eval_items(schema, keyword, instance, instance_location, ref_stack)
        when 'allOf'
          combine_nodes(keyword.parsed.map { |subschema| eval_node(subschema, instance, instance_location, ref_stack) })
        when 'anyOf'
          eval_any_of(keyword, instance, instance_location, ref_stack)
        when 'oneOf'
          eval_one_of(keyword, instance, instance_location, ref_stack)
        when 'not'
          eval_not(keyword, instance, instance_location, ref_stack)
        when '$ref'
          eval_ref(keyword, instance, instance_location, ref_stack)
        else
          if ANNOTATION_KEYWORDS.include?(name) || keyword.is_a?(Schema::UNKNOWN_KEYWORD_CLASS)
            [:valid, [], []]
          else
            [:unknown, [], [unresolved_entry(name, instance_location, keyword.schema_pointer, 'keyword is not supported by partial validation')]]
          end
        end
      end

      def eval_type(keyword, instance, instance_location)
        return unknown_value(keyword, instance_location) if unknown?(instance)

        types = keyword.value
        valid = types.is_a?(String) ? valid_type?(types, instance) : types.any? { |type| valid_type?(type, instance) }
        return [:valid, [], []] if valid

        [:invalid, [error_entry('type', instance_location, keyword.schema_pointer, "value is not of type: #{types.is_a?(Array) ? types.join(', ') : types}")], []]
      end

      def eval_enum_const(keyword, instance, instance_location)
        return unknown_value(keyword, instance_location) if contains_unknown?(instance)

        name = keyword.keyword
        valid = name == 'enum' ? keyword.value.include?(instance) : keyword.value == instance
        return [:valid, [], []] if valid

        [:invalid, [error_entry(name, instance_location, keyword.schema_pointer, "value is not #{name == 'enum' ? 'one of' : 'equal to'}: #{keyword.value}")], []]
      end

      def eval_required(keyword, instance, instance_location)
        return unknown_value(keyword, instance_location) if unknown?(instance)
        return [:valid, [], []] unless instance.is_a?(Hash)

        if @access_mode
          return [:unknown, [], [unresolved_entry('required', instance_location, keyword.schema_pointer, '`required` with `access_mode` is not supported by partial validation')]]
        end

        missing = keyword.value - instance.keys
        return [:valid, [], []] if missing.empty?

        [:invalid, [error_entry('required', instance_location, keyword.schema_pointer, "missing required properties: #{missing.join(', ')}")], []]
      end

      def eval_properties(keyword, instance, instance_location, ref_stack)
        return unknown_value(keyword, instance_location) if unknown?(instance)
        return [:valid, [], []] unless instance.is_a?(Hash)

        results = []
        keyword.parsed.each do |property, subschema|
          next unless instance.key?(property)
          results << eval_node(subschema, instance.fetch(property), join_instance_location(instance_location, property), ref_stack)
        end
        combine_nodes(results)
      end

      def eval_positioned_items(keyword, subschemas, instance, instance_location, ref_stack)
        return unknown_value(keyword, instance_location) if unknown?(instance)
        return [:valid, [], []] unless instance.is_a?(Array)

        results = []
        instance.each_with_index do |item, index|
          break if index >= subschemas.size
          results << eval_node(subschemas.fetch(index), item, join_instance_location(instance_location, index.to_s), ref_stack)
        end
        combine_nodes(results)
      end

      def eval_items(schema, keyword, instance, instance_location, ref_stack)
        return unknown_value(keyword, instance_location) if unknown?(instance)
        return [:valid, [], []] unless instance.is_a?(Array)

        parsed = keyword.parsed
        # pre-2020-12 drafts allow items to hold an array of schemas
        return eval_positioned_items(keyword, parsed, instance, instance_location, ref_stack) if parsed.is_a?(Array)

        prefix_items = schema.parsed['prefixItems']
        offset = prefix_items ? prefix_items.parsed.size : 0
        results = []
        instance.each_with_index do |item, index|
          next if index < offset
          results << eval_node(parsed, item, join_instance_location(instance_location, index.to_s), ref_stack)
        end
        combine_nodes(results)
      end

      def eval_any_of(keyword, instance, instance_location, ref_stack)
        results = keyword.parsed.map { |subschema| eval_node(subschema, instance, instance_location, ref_stack) }
        statuses = results.map(&:first)

        if statuses.include?(:valid)
          [:valid, [], []]
        elsif statuses.include?(:unknown)
          [:unknown, [], results.flat_map { |result| result[2] }]
        else
          [:invalid, results.flat_map { |result| result[1] }, []]
        end
      end

      def eval_one_of(keyword, instance, instance_location, ref_stack)
        results = keyword.parsed.map { |subschema| eval_node(subschema, instance, instance_location, ref_stack) }
        statuses = results.map(&:first)
        valid_count = statuses.count(:valid)

        if valid_count > 1
          [:invalid, [error_entry('oneOf', instance_location, keyword.schema_pointer, 'value matches more than one `oneOf` schema')], []]
        elsif valid_count == 1 && statuses.include?(:unknown)
          [:unknown, [], results.flat_map { |result| result[2] }]
        elsif valid_count == 1
          [:valid, [], []]
        elsif statuses.include?(:unknown)
          [:unknown, [], results.flat_map { |result| result[2] }]
        else
          [:invalid, results.flat_map { |result| result[1] } + [error_entry('oneOf', instance_location, keyword.schema_pointer, 'value does not match any `oneOf` schema')], []]
        end
      end

      def eval_not(keyword, instance, instance_location, ref_stack)
        status, _errors, unresolved = eval_node(keyword.parsed, instance, instance_location, ref_stack)

        case status
        when :valid
          [:invalid, [error_entry('not', instance_location, keyword.schema_pointer, 'value matches `not` schema')], []]
        when :invalid
          [:valid, [], []]
        else
          [:unknown, [], unresolved]
        end
      end

      def eval_ref(keyword, instance, instance_location, ref_stack)
        target = keyword.ref_schema
        key = [target.object_id, instance.object_id]

        if ref_stack.include?(key)
          return [:unknown, [], [unresolved_entry('$ref', instance_location, keyword.schema_pointer, 'recursive `$ref` cannot be resolved for unknown values')]]
        end

        eval_node(target, instance, instance_location, ref_stack + [key])
      end

      def concrete_result(schema, instance, instance_location)
        context = Schema::Context.new(instance, [], nil, true, @access_mode)
        return [:valid, [], []] if schema.validate_instance(instance, Location.root, Location.root, context).valid

        [:invalid, [error_entry(nil, instance_location, schema.schema_pointer, 'value does not match schema')], []]
      end

      # AND-combines child results: every error and unresolved constraint is
      # kept because all children must hold for the node to hold.
      def combine_nodes(results)
        statuses = results.map(&:first)
        status =
          if statuses.include?(:invalid)
            :invalid
          elsif statuses.include?(:unknown)
            :unknown
          else
            :valid
          end
        [status, results.flat_map { |result| result[1] }, results.flat_map { |result| result[2] }]
      end

      def combine_and(statuses)
        return :invalid if statuses.include?(:invalid)
        return :unknown if statuses.include?(:unknown)
        :valid
      end

      def unknown_value(keyword, instance_location)
        [:unknown, [], [unresolved_entry(keyword.keyword, instance_location, keyword.schema_pointer, 'value is unknown')]]
      end

      def unresolved_entry(keyword, instance_location, schema_location, reason)
        {
          'keyword' => keyword,
          'instance_location' => instance_location,
          'schema_location' => schema_location,
          'reason' => reason
        }
      end

      def error_entry(keyword, instance_location, schema_location, message)
        {
          'keyword' => keyword,
          'instance_location' => instance_location,
          'schema_location' => schema_location,
          'message' => message
        }
      end

      def valid_type?(type, instance)
        case type
        when 'null'
          instance.nil?
        when 'boolean'
          instance == true || instance == false
        when 'number'
          instance.is_a?(Numeric)
        when 'integer'
          Draft202012::Vocab::Validation::Type.valid_integer?(instance)
        when 'string'
          instance.is_a?(String)
        when 'array'
          instance.is_a?(Array)
        when 'object'
          instance.is_a?(Hash)
        else
          true
        end
      end

      def unknown?(instance)
        instance.equal?(@unknown)
      end

      def contains_unknown?(instance)
        case instance
        when Hash
          instance.any? { |_key, value| contains_unknown?(value) }
        when Array
          instance.any? { |value| contains_unknown?(value) }
        else
          unknown?(instance)
        end
      end

      def delegatable?(schema)
        @delegatable.fetch(schema.object_id) do
          @delegatable[schema.object_id] = plain_configuration? && !unsafe_schema?(schema.value)
        end
      end

      def plain_configuration?
        return @plain_configuration if defined?(@plain_configuration)

        configuration = @schema.configuration
        @plain_configuration =
          @schema.root.custom_keywords.empty? &&
          configuration.before_property_validation.empty? &&
          configuration.after_property_validation.empty? &&
          !configuration.insert_property_defaults
      end

      def unsafe_schema?(value)
        case value
        when Hash
          value.any? { |key, nested| UNSAFE_DELEGATION_KEYWORDS.include?(key) || unsafe_schema?(nested) }
        when Array
          value.any? { |nested| unsafe_schema?(nested) }
        else
          false
        end
      end

      def deep_stringify(obj)
        case obj
        when Hash
          obj.each_with_object({}) { |(key, value), out| out[key.to_s] = deep_stringify(value) }
        when Array
          obj.map { |item| deep_stringify(item) }
        else
          obj
        end
      end

      def join_instance_location(location, token)
        "#{location}/#{Location.escape_json_pointer_token(token)}"
      end

      def join_schema_location(location, token)
        "#{location}/#{Location.escape_json_pointer_token(token)}"
      end
    end

    def self.evaluate(schema, instance, unknown: UNKNOWN)
      Evaluator.new(schema, :unknown => unknown).evaluate(instance)
    end
  end

  class Schema
    # Validates a partially-known instance. Unknown values are marked with
    # JSONSchemer::Partial::UNKNOWN (or a custom +:unknown+ placeholder).
    # Returns a JSONSchemer::Partial::Result.
    def partial_validate(instance, unknown: Partial::UNKNOWN)
      Partial.evaluate(self, instance, :unknown => unknown)
    end

    # Three-valued convenience wrapper around #partial_validate:
    # true (definitely valid), false (definitely invalid), or nil (pending).
    def partial_valid?(instance, unknown: Partial::UNKNOWN)
      result = partial_validate(instance, :unknown => unknown)
      result.status == :unknown ? nil : result.valid?
    end
  end
end
