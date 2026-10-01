# frozen_string_literal: true
module JSONSchemer
  class DefaultsPlan
    Change = Struct.new(:instance_location, :property, :value, :keyword_location, :absolute_keyword_location, keyword_init: true)
    Candidate = Struct.new(:value, :keyword_location, :absolute_keyword_location, keyword_init: true)
    Conflict = Struct.new(:instance_location, :property, :candidates, keyword_init: true)

    attr_reader :schema, :changes, :conflicts

    def initialize(schema, changes = [], conflicts = [])
      @schema = schema
      @changes = changes
      @conflicts = conflicts
    end

    def empty?
      changes.empty? && conflicts.empty?
    end

    # Applies the planned defaults to `instance` in place.
    #
    # Returns `true` when the instance was updated and still validates against the schema,
    # `false` (without modifying the instance) otherwise.
    def apply(instance)
      return true if empty?
      return false unless satisfies_preconditions?(instance)

      applied = []
      changes.each do |change|
        parent = navigate(instance, change.instance_location)
        property = change.property
        parent[property] = deep_dup(change.value)
        applied << [parent, property]
      end

      if schema.validate_without_property_defaults(instance).fetch('valid')
        true
      else
        rollback!(applied)
        false
      end
    end

    def to_h
      {
        'changes' => changes.map { |change| change_to_h(change) },
        'conflicts' => conflicts.map { |conflict| conflict_to_h(conflict) }
      }
    end

  private

    def satisfies_preconditions?(instance)
      changes.all? do |change|
        parent = navigate(instance, change.instance_location)
        parent.is_a?(Hash) && !parent.key?(change.property) && !parent.key?(change.property.to_sym)
      end
    end

    def navigate(instance, instance_location)
      Hana::Pointer.parse(instance_location).reduce(instance) do |object, token|
        return nil unless object
        if object.is_a?(Array)
          object[token.to_i]
        else
          object.fetch(token, object[token.to_sym])
        end
      end
    end

    def rollback!(applied)
      applied.reverse_each { |parent, property| parent.delete(property) }
    end

    def deep_dup(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), out| out[key] = deep_dup(item) }
      when Array
        value.map { |item| deep_dup(item) }
      else
        value
      end
    end

    def change_to_h(change)
      {
        'instanceLocation' => change.instance_location,
        'property' => change.property,
        'value' => change.value,
        'keywordLocation' => change.keyword_location,
        'absoluteKeywordLocation' => change.absolute_keyword_location
      }
    end

    def conflict_to_h(conflict)
      {
        'instanceLocation' => conflict.instance_location,
        'property' => conflict.property,
        'candidates' => conflict.candidates.map do |candidate|
          {
            'value' => candidate.value,
            'keywordLocation' => candidate.keyword_location,
            'absoluteKeywordLocation' => candidate.absolute_keyword_location
          }
        end
      }
    end
  end
end
