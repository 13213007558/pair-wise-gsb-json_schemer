# frozen_string_literal: true
require 'json'
require 'json_schemer/streaming/array_reader'

module JSONSchemer
  # Raised when a schema uses rules whose result depends on the complete array
  # (the array as a whole, every item, or every property). Streaming cannot
  # produce the same errors in bounded memory in those cases unless the caller
  # supplies an explicit bounded cache for the keyword (currently
  # `uniqueItems`).
  class StreamingUnsupportedError < StandardError
    attr_reader :keywords

    def initialize(message, keywords)
      @keywords = keywords
      super(message)
    end
  end

    # Analyzes a schema for bounded-memory streamability against a top-level
    # array, then validates array items one at a time. Emitted errors use the
  # same `data_pointer`, `schema_pointer`, `type`, `details` and `error`
  # values as `Schema#validate` classic output.
  class StreamingValidator
    VACUOUS_ON_ARRAY_KEYWORDS = %w[
      properties patternProperties additionalProperties propertyNames
      maxProperties minProperties required dependentRequired dependencies
      maxLength minLength pattern format contentEncoding contentMediaType
      unevaluatedProperties
    ].freeze

    WHOLE_VALUE_KEYWORDS = %w[
      enum const unevaluatedItems
      allOf anyOf oneOf not if then else dependentSchemas
      $dynamicRef $recursiveRef
    ].freeze

    ItemApplicator = Struct.new(:subschema, :keyword, :offset, :limit)
    ContainsApplicator = Struct.new(
      :subschema, :keyword, :min_contains_keyword, :max_contains_keyword
    )
    Leaf = Struct.new(:source, :keyword_location)

    # Array placeholder with a length but no element storage. Count keywords
    # only test `is_a?(Array)` and read `size`, so this keeps root count
    # validation O(1) in memory while using the keyword's own code path.
    class ArraySize
      def initialize(size)
        @size = size
      end

      def is_a?(klass)
        klass == Array || super
      end

      def kind_of?(klass)
        klass == Array || super
      end

      attr_reader :size
      alias count size
      alias length size
    end

    Plan = Struct.new(
      :type_leaves,
      :false_leaves,
      :count_leaves,
      :item_applicators,
      :contains,
      :unique_items_keywords
    ) do
      def initialize
        super([], [], [], [], [], [])
      end
    end

    class << self
      def analyze(schema)
        plan = Plan.new
        walk(schema, plan, [])
        plan
      end

      def streamable?(schema)
        analyze(schema)
        true
      rescue StreamingUnsupportedError
        false
      end

    private

      def walk(schema, plan, path)
        # Only break actual reference cycles (a schema already on the current
        # walk path); a $ref reached from two branches is still followed, so
        # diamond-shaped schemas report the same errors as ordinary validation.
        return if path.include?(schema.object_id)
        path << schema.object_id

        case schema.value
        when true
          return
        when false
          plan.false_leaves << Leaf.new(schema, Location.root)
          return
        end

        schema.parsed.each do |keyword, keyword_instance|
          collect(keyword, keyword_instance, schema, plan, path)
        end
      ensure
        path.delete(schema.object_id)
      end

      def collect(keyword, keyword_instance, schema, plan, path)
        case keyword
        when 'type'
          plan.type_leaves << Leaf.new(keyword_instance, root_keyword_location(keyword_instance))
        when 'minItems', 'maxItems', 'minContains', 'maxContains'
          plan.count_leaves << Leaf.new(keyword_instance, root_keyword_location(keyword_instance))
        when 'uniqueItems'
          plan.unique_items_keywords << keyword_instance if keyword_instance.value
        when 'contains'
          plan.contains << ContainsApplicator.new(
            keyword_instance.parsed,
            keyword_instance,
            schema.parsed['minContains'],
            schema.parsed['maxContains']
          )
        when 'prefixItems'
          keyword_instance.parsed.each_with_index do |subschema, index|
            plan.item_applicators << ItemApplicator.new(
              subschema, keyword_instance, index, index
            )
          end
        when 'items'
          collect_items(keyword_instance, schema, plan)
        when 'additionalItems'
          # handled together with the draft 4 tuple form of `items`
        when '$ref'
          walk(keyword_instance.ref_schema, plan, path)
        when *VACUOUS_ON_ARRAY_KEYWORDS
          # never applies when the root instance is an array
        when *WHOLE_VALUE_KEYWORDS
          raise_unsupported(keyword)
        else
          # `$schema`, metadata and unknown/custom keywords do not constrain an
          # array root
        end
      end

      def collect_items(keyword_instance, schema, plan)
        parsed = keyword_instance.parsed
        if parsed.is_a?(Schema)
          prefix_count = schema.parsed['prefixItems']&.parsed&.size || 0
          plan.item_applicators << ItemApplicator.new(
            parsed, keyword_instance, prefix_count, nil
          )
        elsif parsed.is_a?(Array) # draft 4 tuple form
          parsed.each_with_index do |subschema, index|
            plan.item_applicators << ItemApplicator.new(
              subschema, keyword_instance, index, index
            )
          end
          additional_items = schema.parsed['additionalItems']
          if additional_items && additional_items.parsed.is_a?(Schema)
            plan.item_applicators << ItemApplicator.new(
              additional_items.parsed, additional_items, parsed.size, nil
            )
          end
        end
      end

      def root_keyword_location(keyword_instance)
        Location.join(Location.root, keyword_instance.send(:escaped_keyword))
      end

      def raise_unsupported(keyword)
        raise(
          StreamingUnsupportedError.new(
            "schema keyword `#{keyword}` requires the complete array value " \
            'and cannot be evaluated with bounded streaming memory; use ' \
            '`Schema#validate` or provide an explicit bounded cache where ' \
            'supported',
            [keyword]
          )
        )
      end
    end

    def initialize(schema, source, chunk_size:, unique_items_cache:, access_mode:)
      @schema = schema
      @plan = self.class.analyze(schema)
      @reader = StreamingArrayReader.new(source, :chunk_size => chunk_size)
      @unique_items_cache = unique_items_cache
      @access_mode = access_mode
      if @plan.unique_items_keywords.any? && !@unique_items_cache
        keyword_names = @plan.unique_items_keywords.map(&:keyword).uniq
        raise(
          StreamingUnsupportedError.new(
            '`uniqueItems` requires retaining every array item (or a bounded ' \
            'digest of them); pass an explicit bounded cache via ' \
            '`unique_items_cache:` to stream this schema',
            keyword_names
          )
        )
      end
    end

    def each
      raise(ArgumentError, 'a block is required') unless block_given?
      if (non_array = @reader.non_array_source)
        validate_non_array(non_array) { |error| yield(error) }
        return nil
      end
      context = Schema::Context.new(nil, [], nil, false, @access_mode)
      item_count = 0
      contains_matches = Array.new(@plan.contains.size, 0)
      @unique_items_failed = false

      # false-schema and type failures at the root are known before reading
      # items, and classic output orders them ahead of item errors.
      validate_root_leaf!(@plan.false_leaves, context) { |error| yield(error) }
      validate_root_leaf!(@plan.type_leaves, context) { |error| yield(error) }

      until (item = @reader.next_element).equal?(StreamingArrayReader::EOF_SENTINEL)
        validate_item(item, item_count, context, contains_matches) { |error| yield(error) }
        item_count += 1
      end

      validate_count_leaves(context, item_count) { |error| yield(error) }
      validate_contains_leaves(item_count, contains_matches) { |error| yield(error) }
      nil
    end

    def validate_non_array(source)
      instance = JSON.parse(source)
      output = @schema.validate(instance, :access_mode => @access_mode)
      output.each { |error| yield(error) }
    end

  private

    def validate_root_leaf!(leaves, context, &block)
      leaves.each do |leaf|
        result = validate_leaf(leaf, context)
        emit(result, &block)
      end
    end

    def validate_item(item, index, context, contains_matches, &block)
      instance_location = Location.join(Location.root, index.to_s)

      @plan.item_applicators.each do |applicator|
        next unless index >= applicator.offset
        next if applicator.limit && index > applicator.limit
        keyword_location = item_keyword_location(applicator, index)
        result = applicator.subschema.validate_instance(
          item, instance_location, keyword_location, context
        )
        emit(result, &block)
      end

      @plan.contains.each_with_index do |contains, contains_index|
        result = contains.subschema.validate_instance(
          item,
          instance_location,
          Location.join(Location.root, contains.keyword.send(:escaped_keyword)),
          context
        )
        contains_matches[contains_index] += 1 if result.valid
      end

      check_unique(item, index, &block) if @unique_items_cache
    end

    def item_keyword_location(applicator, index)
      keyword = applicator.keyword
      base = Location.join(Location.root, keyword.send(:escaped_keyword))
      return base unless applicator.limit && applicator.offset == applicator.limit
      Location.join(base, index.to_s)
    end

    def validate_count_leaves(context, item_count, &block)
      @plan.count_leaves.each do |leaf|
        case leaf.source.keyword
        when 'minContains', 'maxContains'
          next # evaluated together with its `contains` keyword
        end
        result = validate_leaf(leaf, context, ArraySize.new(item_count))
        emit(result, &block)
      end
    end

    def validate_leaf(leaf, context, instance = [])
      source = leaf.source
      if source.is_a?(Schema)
        source.validate_instance(instance, Location.root, leaf.keyword_location, context)
      else
        source.validate(instance, Location.root, leaf.keyword_location, context)
      end
    end

    def validate_contains_leaves(item_count, contains_matches, &block)
      @plan.contains.each_with_index do |contains, index|
        matched_count = contains_matches[index]
        min_keyword = contains.min_contains_keyword
        if min_keyword
          min_required = min_keyword.parsed
          if matched_count < min_required
            emit_synthetic_leaf(contains.keyword, ArraySize.new(item_count), &block)
            adjacent = { contains.keyword.class => contains_annotation_result(contains.keyword, matched_count) }
            leaf = Leaf.new(min_keyword, Location.join(Location.root, 'minContains'))
            emit(validate_leaf_with_adjacent(leaf, ArraySize.new(item_count), adjacent), &block)
          end
        elsif matched_count.zero?
          emit_synthetic_leaf(contains.keyword, ArraySize.new(item_count), &block)
        end
        max_keyword = contains.max_contains_keyword
        if max_keyword && matched_count > max_keyword.parsed
          adjacent = { contains.keyword.class => contains_annotation_result(contains.keyword, matched_count) }
          leaf = Leaf.new(max_keyword, Location.join(Location.root, 'maxContains'))
          emit(validate_leaf_with_adjacent(leaf, ArraySize.new(item_count), adjacent), &block)
        end
      end
    end

    def validate_leaf_with_adjacent(leaf, instance, adjacent)
      context = Schema::Context.new(nil, [], adjacent, false, @access_mode)
      validate_leaf(leaf, context, instance)
    end

    def contains_annotation_result(keyword, matched_count)
      keyword_location = Location.join(Location.root, keyword.send(:escaped_keyword))
      keyword.send(:result, ArraySize.new(0), Location.root, keyword_location,
        matched_count.positive?, nil, :annotation => Array.new(matched_count, 0))
    end

    def emit_synthetic_leaf(keyword, instance, &block)
      keyword_location = Location.join(Location.root, keyword.send(:escaped_keyword))
      result = keyword.send(:result, instance, Location.root, keyword_location, false)
      result.classic.each { |error| block.call(error) }
    end

    def check_unique(item, item_count, &block)
      canonical = JSON.generate(canonical_value(item))
      return if @unique_items_cache.add?(canonical)
      return if @unique_items_failed
      @unique_items_failed = true
      @plan.unique_items_keywords.each do |keyword|
        emit_synthetic_leaf(keyword, ArraySize.new(item_count), &block)
      end
    end

    def emit(result, &block)
      result.classic.each { |error| block.call(error) }
    end

    # Stable serialization matching Ruby Hash equality semantics used by
    # `Array#uniq`: hash keys are unordered, array order is significant.
    def canonical_value(value)
      case value
      when Hash
        value.keys.sort.each_with_object({}) { |key, out| out[key] = canonical_value(value.fetch(key)) }
      when Array
        value.map { |element| canonical_value(element) }
      else
        value
      end
    end
  end
end
