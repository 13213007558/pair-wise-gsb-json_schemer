# frozen_string_literal: true
module JSONSchemer
  class DefaultsPlan
    attr_reader :patches, :conflicts

    def initialize(schema, patches, conflicts)
      @schema = schema
      @patches = patches
      @conflicts = conflicts
    end

    def empty?
      patches.empty?
    end

    def to_h
      {
        'patches' => patches,
        'conflicts' => conflicts
      }
    end

    def apply(instance)
      @schema.apply_defaults_plan(instance, self)
    end
  end
end
