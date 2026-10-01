# frozen_string_literal: true
module JSONSchemer
  # Optional evaluation observer that records keyword/schema evaluation events
  # during validation and aggregates them into a schema coverage report.
  #
  #   observer = JSONSchemer::Coverage::Observer.new
  #   schema.valid?(instance, :observer => observer)
  #   schema.validate(other_instance, :observer => observer)
  #
  #   report = observer.report
  #   report.fully_covered? # => false
  #   report.uncovered      # => { "json-schemer://schema#/oneOf/1" => #<Stats ...>, ... }
  #
  # Locations are stable absolute keyword location URIs. A location is
  # considered covered once at least one instance evaluated successfully
  # (valid) at that location. Observing is opt-in: validation without an
  # observer records nothing and evaluation runs exactly once either way.
  module Coverage
    COMBINATOR_KEYWORDS = %w[allOf anyOf oneOf].freeze

    COUNTER_TYPES = {
      :attempt => :attempts,
      :success => :successes,
      :failure => :failures,
      :skip => :skips
    }.freeze

    Event = Struct.new(:type, :source, :keyword, :location, :instance_location, :target, :reason, :keyword_init => true)

    Stats = Struct.new(:location, :keyword, :kind, :target, :attempts, :successes, :failures, :skips) do
      def covered?
        successes.positive?
      end

      def to_h
        {
          'keyword' => keyword,
          'kind' => kind,
          'target' => target,
          'attempts' => attempts,
          'successes' => successes,
          'failures' => failures,
          'skips' => skips,
          'covered' => covered?
        }
      end
    end

    # Keywords that only produce annotations (eg $comment, $defs, title)
    # inherit Keyword#validate and are not coverage points.
    def self.assertion_keyword?(keyword)
      keyword.method(:validate).owner != Keyword
    end

    class Observer
      attr_reader :events, :roots, :locations, :validations

      def initialize
        @events = []
        @roots = []
        @locations = {}
        @validations = 0
      end

      def observe(root)
        @roots << root unless @roots.any? { |observed| observed.equal?(root) }
        @validations += 1
      end

      def record(type, source, instance_location, target: nil, reason: nil)
        location = source.absolute_keyword_location
        target_location = target&.absolute_keyword_location
        @events << Event.new(
          :type => type,
          :source => source,
          :keyword => source.keyword,
          :location => location,
          :instance_location => Location.resolve(instance_location),
          :target => target_location,
          :reason => reason
        )
        stats = (@locations[location] ||= Stats.new(location, source.keyword, nil, nil, 0, 0, 0, 0))
        if type == :ref
          stats.target ||= target_location
        else
          counter = COUNTER_TYPES.fetch(type)
          stats[counter] += 1
        end
        stats
      end

      def report
        Report.new(self)
      end
    end

    class Report
      attr_reader :events, :locations, :validations

      def initialize(observer)
        @events = observer.events
        @validations = observer.validations
        @locations = observer.locations.transform_values(&:dup)
        visited = {}
        observer.roots.each { |root| walk_schema(root, :schema, visited) }
      end

      def covered?(location)
        (stats = @locations[location]) ? stats.covered? : false
      end

      def fully_covered?
        uncovered.empty?
      end

      def uncovered
        @locations.reject { |_location, stats| stats.covered? }
      end

      def coverage
        return 1.0 if @locations.empty?
        @locations.count { |_location, stats| stats.covered? }.fdiv(@locations.size)
      end

      def conditionals
        select_kind(:conditional)
      end

      def branches
        select_kind(:branch)
      end

      def refs
        select_kind(:ref)
      end

      def summary
        {
          'instances' => validations,
          'total' => @locations.size,
          'covered' => @locations.size - uncovered.size,
          'uncovered' => uncovered.size,
          'coverage' => coverage
        }
      end

      def to_h
        {
          'summary' => summary,
          'locations' => @locations.transform_values(&:to_h)
        }
      end

    private

      def select_kind(kind)
        @locations.select { |_location, stats| stats.kind == kind }
      end

      def register(location, keyword, kind, target = nil)
        stats = (@locations[location] ||= Stats.new(location, keyword, nil, nil, 0, 0, 0, 0))
        stats.kind ||= kind
        stats.keyword ||= keyword
        stats.target ||= target
        stats
      end

      def walk_schema(schema, kind, visited)
        return if visited[schema.object_id]
        visited[schema.object_id] = true
        register(schema.absolute_keyword_location, schema.keyword, kind)
        schema.parsed.each_value { |keyword| walk_keyword(keyword, visited) }
      end

      def walk_keyword(keyword, visited)
        if ref_keyword?(keyword)
          target = resolve_ref_target(keyword)
          register(keyword.absolute_keyword_location, keyword.keyword, :ref, target&.absolute_keyword_location)
          walk_schema(target, :schema, visited) if target
        else
          register(keyword.absolute_keyword_location, keyword.keyword, keyword_kind(keyword)) if Coverage.assertion_keyword?(keyword)
          walk_subschemas(keyword, visited)
        end
      end

      def walk_subschemas(keyword, visited)
        branch_kind = COMBINATOR_KEYWORDS.include?(keyword.keyword) ? :branch : :schema
        case (parsed = keyword.parsed)
        when Schema
          walk_schema(parsed, branch_kind, visited)
        when Array
          parsed.each { |value| walk_schema(value, branch_kind, visited) if value.is_a?(Schema) }
        when Hash
          parsed.each_value { |value| walk_schema(value, :schema, visited) if value.is_a?(Schema) }
        end
      end

      def ref_keyword?(keyword)
        keyword.respond_to?(:ref_uri) && keyword.respond_to?(:ref_schema)
      end

      def resolve_ref_target(keyword)
        keyword.ref_schema
      rescue UnknownRef, InvalidRefResolution, InvalidRefPointer, KeyError
        nil
      end

      def keyword_kind(keyword)
        case keyword.keyword
        when 'if', 'then', 'else'
          :conditional
        when 'allOf', 'anyOf', 'oneOf'
          :combinator
        else
          :keyword
        end
      end
    end
  end
end
