# frozen_string_literal: true
module JSONSchemer
  module Coverage
    # Keywords whose value is a single subschema.
    SINGLE_SUBSCHEMA_KEYWORDS = %w[
      if then else not additionalProperties propertyNames contains items additionalItems
      unevaluatedProperties unevaluatedItems contentSchema
    ].freeze

    # Keywords whose value is an array of subschemas.
    ARRAY_SUBSCHEMA_KEYWORDS = %w[allOf anyOf oneOf prefixItems].freeze

    # Keywords whose value is an object mapping names to subschemas.
    MAP_SUBSCHEMA_KEYWORDS = %w[properties patternProperties dependentSchemas $defs definitions].freeze

    # Object keywords whose values are subschemas only when they are objects
    # (draft 4 `dependencies` mixes property-name arrays with subschemas).
    MIXED_MAP_SUBSCHEMA_KEYWORDS = %w[dependencies].freeze

    # Conditional branches reported individually when never evaluated.
    CONDITIONAL_BRANCH_KEYWORDS = %w[if then else].freeze

    # Combination keywords whose array entries are reported as branches.
    COMBINATION_BRANCH_KEYWORDS = %w[allOf anyOf oneOf].freeze

    # Reference keywords marking call sites that may never be reached.
    REF_KEYWORDS = %w[$ref $recursiveRef $dynamicRef].freeze

    def self.pointer(pointer)
      pointer.empty? ? '#' : "##{pointer}"
    end

    def self.escape_token(token)
      Location.escape_json_pointer_token(token)
    end

    # Opt-in evaluation observer. Pass an instance as the `coverage_observer`
    # option to {Schema#validate} or {Schema#valid?}, validate one or more
    # instances, then call {#report}. Default validation creates no observer
    # and records nothing.
    class Observer
      attr_reader :events

      def initialize
        @events = []
        @indexes = {}
        @indexes.compare_by_identity
      end

      def schema(schema, valid, instance_location)
        @events << {
          :type => :schema,
          :root => schema.root,
          :schema_pointer => schema.schema_pointer,
          :valid => valid,
          :instance_location => Location.resolve(instance_location)
        }
      end

      def keyword(keyword, valid, instance_location)
        @events << {
          :type => :keyword,
          :root => keyword.root,
          :schema_pointer => keyword.schema_pointer,
          :keyword => keyword.keyword,
          :valid => valid,
          :instance_location => Location.resolve(instance_location)
        }
      end

      def skip(keyword, reason, instance_location)
        @events << {
          :type => :skip,
          :root => keyword.root,
          :schema_pointer => keyword.schema_pointer,
          :keyword => keyword.keyword,
          :reason => reason,
          :instance_location => Location.resolve(instance_location)
        }
      end

      def ref(keyword, target_schema, instance_location)
        @events << {
          :type => :ref,
          :root => keyword.root,
          :call_site_pointer => keyword.schema_pointer,
          :target_pointer => target_schema.schema_pointer,
          :instance_location => Location.resolve(instance_location)
        }
      end

      def report(schema = nil)
        roots = @events.map { |event| event[:root] }.uniq
        root = schema ? schema.root : (roots.first if roots.size == 1)
        raise ArgumentError, 'report requires a schema argument when multiple schemas were observed' if !schema && roots.size > 1
        return empty_report unless root

        root_events = @events.select { |event| event[:root].equal?(root) }
        index = index(root)

        schema_counts = root_events.select { |event| event[:type] == :schema }.group_by { |event| event[:schema_pointer] }

        keywords = build_keywords(root_events)
        branches = build_branches(index[:branches], schema_counts)
        refs = build_refs(index[:refs], root_events)

        uncovered = branches.reject { |entry| entry[:passed] > 0 }.map do |entry|
          {
            :pointer => entry[:pointer],
            :parent_pointer => entry[:parent_pointer],
            :keyword => entry[:keyword],
            :branch => entry[:branch],
            :reason => 'never matched'
          }
        end
        uncovered.concat(refs.reject { |entry| entry[:calls] > 0 }.map do |entry|
          {
            :pointer => entry[:pointer],
            :keyword => '$ref',
            :reason => 'reference call site never reached'
          }
        end)

        coverable = branches.size + refs.size
        covered = branches.count { |entry| entry[:passed] > 0 } + refs.count { |entry| entry[:calls] > 0 }

        {
          :keywords => keywords,
          :branches => branches,
          :refs => refs,
          :uncovered => uncovered,
          :coverage => coverable.zero? ? 1.0 : covered.to_f / coverable
        }
      end

      private

      def empty_report
        { :keywords => [], :branches => [], :refs => [], :uncovered => [], :coverage => 1.0 }
      end

      def index(root)
        @indexes[root] ||= begin
          branches = []
          refs = []
          walk(root.value, '', root.meta_schema.keywords.fetch('$ref').exclusive?, root.meta_schema.defs_keyword, branches, refs)
          { :branches => branches, :refs => refs }
        end
      end

      def walk(value, pointer, exclusive_ref, defs_keyword, branches, refs)
        return unless value.is_a?(Hash)

        REF_KEYWORDS.each do |keyword|
          refs << { :pointer => "#{pointer}/#{Coverage.escape_token(keyword)}" } if value.key?(keyword)
        end

        if exclusive_ref && value.key?('$ref')
          if value.key?(defs_keyword)
            walk_map(value.fetch(defs_keyword), "#{pointer}/#{Coverage.escape_token(defs_keyword)}", exclusive_ref, defs_keyword, branches, refs)
          end
          return
        end

        CONDITIONAL_BRANCH_KEYWORDS.each do |keyword|
          next unless value.key?(keyword)
          branch_pointer = "#{pointer}/#{Coverage.escape_token(keyword)}"
          branches << { :pointer => branch_pointer, :parent_pointer => Coverage.pointer(pointer), :keyword => keyword, :branch => nil }
          walk(value.fetch(keyword), branch_pointer, exclusive_ref, defs_keyword, branches, refs)
        end

        COMBINATION_BRANCH_KEYWORDS.each do |keyword|
          next unless value.key?(keyword)
          entries = value.fetch(keyword)
          next unless entries.is_a?(Array)
          parent_pointer = "#{pointer}/#{Coverage.escape_token(keyword)}"
          entries.each_with_index do |subschema, index|
            branch_pointer = "#{parent_pointer}/#{index}"
            branches << { :pointer => branch_pointer, :parent_pointer => Coverage.pointer(pointer), :keyword => keyword, :branch => index }
            walk(subschema, branch_pointer, exclusive_ref, defs_keyword, branches, refs)
          end
        end

        (SINGLE_SUBSCHEMA_KEYWORDS - CONDITIONAL_BRANCH_KEYWORDS).each do |keyword|
          next unless value.key?(keyword)
          child = value.fetch(keyword)
          child_pointer = "#{pointer}/#{Coverage.escape_token(keyword)}"
          # pre-2020-12 `items` may be an array of subschemas
          if keyword == 'items' && child.is_a?(Array)
            child.each_with_index do |subschema, index|
              walk(subschema, "#{child_pointer}/#{index}", exclusive_ref, defs_keyword, branches, refs)
            end
          else
            walk(child, child_pointer, exclusive_ref, defs_keyword, branches, refs)
          end
        end

        (ARRAY_SUBSCHEMA_KEYWORDS - COMBINATION_BRANCH_KEYWORDS).each do |keyword|
          next unless value.key?(keyword)
          entries = value.fetch(keyword)
          next unless entries.is_a?(Array)
          parent_pointer = "#{pointer}/#{Coverage.escape_token(keyword)}"
          entries.each_with_index do |subschema, index|
            walk(subschema, "#{parent_pointer}/#{index}", exclusive_ref, defs_keyword, branches, refs)
          end
        end

        (MAP_SUBSCHEMA_KEYWORDS - [defs_keyword]).each do |keyword|
          next unless value.key?(keyword)
          entries = value.fetch(keyword)
          next unless entries.is_a?(Hash)
          walk_map(entries, "#{pointer}/#{Coverage.escape_token(keyword)}", exclusive_ref, defs_keyword, branches, refs)
        end

        if value.key?(defs_keyword)
          entries = value.fetch(defs_keyword)
          walk_map(entries, "#{pointer}/#{Coverage.escape_token(defs_keyword)}", exclusive_ref, defs_keyword, branches, refs) if entries.is_a?(Hash)
        end

        MIXED_MAP_SUBSCHEMA_KEYWORDS.each do |keyword|
          next unless value.key?(keyword)
          entries = value.fetch(keyword)
          next unless entries.is_a?(Hash)
          parent_pointer = "#{pointer}/#{Coverage.escape_token(keyword)}"
          entries.each do |name, child|
            next unless child.is_a?(Hash)
            walk(child, "#{parent_pointer}/#{Coverage.escape_token(name)}", exclusive_ref, defs_keyword, branches, refs)
          end
        end
      end

      def walk_map(entries, parent_pointer, exclusive_ref, defs_keyword, branches, refs)
        entries.each do |name, child|
          walk(child, "#{parent_pointer}/#{Coverage.escape_token(name)}", exclusive_ref, defs_keyword, branches, refs)
        end
      end

      def build_keywords(root_events)
        keyword_events = root_events.select { |event| event[:type] == :keyword }
        skip_events = root_events.select { |event| event[:type] == :skip }
        keyword_events.group_by { |event| [event[:schema_pointer], event[:keyword]] }.map do |(schema_pointer, _keyword), attempts|
          skips = skip_events.select { |event| event[:schema_pointer] == schema_pointer && event[:keyword] == attempts.first[:keyword] }
          {
            :pointer => Coverage.pointer(schema_pointer),
            :keyword => attempts.first[:keyword],
            :attempts => attempts.size,
            :passed => attempts.count { |event| event[:valid] },
            :failed => attempts.count { |event| !event[:valid] },
            :skipped => skips.size,
            :skip_reasons => skips.map { |event| event[:reason] }.uniq
          }
        end.compact.sort_by { |entry| [entry[:pointer], entry[:keyword]] }
      end

      def build_branches(index_branches, schema_counts)
        index_branches.map do |branch|
          events = schema_counts[branch[:pointer]] || []
          {
            :pointer => Coverage.pointer(branch[:pointer]),
            :parent_pointer => branch[:parent_pointer],
            :keyword => branch[:keyword],
            :branch => branch[:branch],
            :attempts => events.size,
            :passed => events.count { |event| event[:valid] },
            :failed => events.count { |event| !event[:valid] }
          }
        end
      end

      def build_refs(index_refs, root_events)
        grouped = root_events.select { |event| event[:type] == :ref }.group_by { |event| event[:call_site_pointer] }
        index_refs.map do |ref|
          events = grouped[ref[:pointer].sub(/\A#/, '')] || []
          {
            :pointer => Coverage.pointer(ref[:pointer]),
            :calls => events.size,
            :targets => events.group_by { |event| event[:target_pointer] }.map do |target_pointer, target_events|
              { :pointer => Coverage.pointer(target_pointer), :calls => target_events.size }
            end
          }
        end
      end
    end
  end
end
