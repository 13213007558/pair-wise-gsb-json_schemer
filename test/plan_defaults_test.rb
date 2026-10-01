# frozen_string_literal: true
require 'test_helper'

class PlanDefaultsTest < Minitest::Test
  def test_plan_does_not_modify_instance
    schema = {
      'properties' => {
        'a' => { 'default' => 1 },
        'b' => {
          'properties' => {
            'x' => { 'default' => 2 }
          }
        }
      }
    }
    data = { 'b' => {} }
    plan = JSONSchemer.schema(schema).plan_defaults(data)
    refute(plan.empty?)
    assert_equal({ 'b' => {} }, data)
  end

  def test_plan_returns_patches_for_missing_nested_properties
    schema = {
      'type' => 'object',
      'properties' => {
        'a' => { 'default' => 1 },
        'b' => {
          'properties' => {
            'x' => { 'default' => 2 }
          }
        },
        'list' => {
          'type' => 'array',
          'items' => {
            'properties' => {
              'n' => { 'default' => 0 }
            }
          }
        }
      }
    }
    data = { 'b' => {}, 'list' => [{}, { 'n' => 5 }] }
    plan = JSONSchemer.schema(schema).plan_defaults(data)

    assert_empty(plan.conflicts)
    assert_equal(
      [
        { 'instanceLocation' => '', 'property' => 'a', 'value' => 1 },
        { 'instanceLocation' => '/b', 'property' => 'x', 'value' => 2 },
        { 'instanceLocation' => '/list/0', 'property' => 'n', 'value' => 0 }
      ],
      plan.to_h.fetch('changes').map { |change| change.slice('instanceLocation', 'property', 'value') }
    )
  end

  def test_plan_reports_source_schema_locations
    schema = {
      'properties' => {
        'inline' => { 'default' => 'a' },
        'ref-inline' => { '$ref' => '#/$defs/default-b' }
      },
      '$defs' => {
        'default-b' => { 'default' => 'b' }
      }
    }
    plan = JSONSchemer.schema(schema).plan_defaults({})
    changes = plan.to_h.fetch('changes').to_h { |change| [change.fetch('property'), change] }

    assert_equal('/properties/inline/default', changes.fetch('inline').fetch('keywordLocation'))
    assert_equal(
      'json-schemer://schema#/$defs/default-b/default',
      changes.fetch('ref-inline').fetch('absoluteKeywordLocation')
    )
  end

  def test_planning_twice_returns_empty_plan_after_apply
    schema = {
      'properties' => {
        'a' => { 'default' => 1 }
      }
    }
    schemer = JSONSchemer.schema(schema)
    data = {}

    plan = schemer.plan_defaults(data)
    refute(plan.empty?)
    assert(plan.apply(data))
    assert_equal({ 'a' => 1 }, data)

    replan = schemer.plan_defaults(data)
    assert(replan.empty?)
    assert_equal({ 'changes' => [], 'conflicts' => [] }, replan.to_h)
  end

  def test_apply_is_idempotent_and_does_not_clone_the_schema_default
    schema = {
      'properties' => {
        'a' => { 'default' => { 'x' => 1 } }
      }
    }
    schemer = JSONSchemer.schema(schema)
    data = {}

    assert(schemer.plan_defaults(data).apply(data))
    data.fetch('a')['x'] = 2

    other = {}
    assert(schemer.plan_defaults(other).apply(other))
    assert_equal(1, other.dig('a', 'x'))
  end

  def test_apply_deep_duplicates_array_and_nested_defaults
    schema = {
      'properties' => {
        'tags' => { 'default' => ['a', { 'k' => 'v' }] }
      }
    }
    schemer = JSONSchemer.schema(schema)

    first = {}
    assert(schemer.plan_defaults(first).apply(first))
    first.fetch('tags').last['k'] = 'changed'

    second = {}
    assert(schemer.plan_defaults(second).apply(second))
    assert_equal(['a', { 'k' => 'v' }], second.fetch('tags'))
  end

  def test_plan_inserts_defaults_inside_array_items
    schema = {
      'type' => 'array',
      'items' => {
        'properties' => {
          'n' => { 'default' => 0 }
        }
      }
    }
    plan = JSONSchemer.schema(schema).plan_defaults([{}])
    data = [{}]

    assert(plan.apply(data))
    assert_equal([{ 'n' => 0 }], data)
  end

  def test_agreement_between_multiple_valid_branches_inserts_default
    schema = {
      'allOf' => [
        { 'properties' => { 'a' => { 'default' => 1 } } }
      ],
      'anyOf' => [
        {
          'properties' => {
            'a' => { 'default' => 1 },
            'b' => { 'default' => 2 }
          }
        }
      ]
    }
    plan = JSONSchemer.schema(schema).plan_defaults({ 'b' => 2 })

    a_change = plan.changes.find { |change| change.property == 'a' }
    refute_nil(a_change)
    assert_equal(1, a_change.value)

    data = { 'b' => 2 }
    assert(plan.apply(data))
    assert_equal({ 'b' => 2, 'a' => 1 }, data)
  end

  def test_conflict_between_valid_branches_is_retained
    schema = {
      'anyOf' => [
        { 'properties' => { 'a' => { 'default' => 1 } } },
        { 'properties' => { 'a' => { 'default' => 2 } } }
      ]
    }
    plan = JSONSchemer.schema(schema).plan_defaults({ 'present' => true })

    assert_empty(plan.changes)
    refute(plan.empty?)

    conflict = plan.conflicts.first
    assert_equal('', conflict.instance_location)
    assert_equal('a', conflict.property)
    assert_equal([1, 2].to_set, conflict.candidates.map(&:value).to_set)
    assert_equal(
      ['/anyOf/0/properties/a/default', '/anyOf/1/properties/a/default'].to_set,
      conflict.candidates.map(&:keyword_location).to_set
    )

    hash = plan.to_h
    conflict_hash = hash.fetch('conflicts').first
    assert_equal(
      ['instanceLocation', 'property', 'candidates'],
      conflict_hash.keys
    )
    assert_equal(
      ['value', 'keywordLocation', 'absoluteKeywordLocation'],
      conflict_hash.fetch('candidates').first.keys
    )
  end

  def test_only_defaults_from_successful_branches_conflict
    schema = {
      'oneOf' => [
        {
          'properties' => {
            'foo' => { 'enum' => ['a'] },
            'bar' => { 'enum' => ['a'], 'default' => 'a' }
          }
        },
        {
          'properties' => {
            'foo' => { 'enum' => ['b'] },
            'bar' => { 'enum' => ['b'], 'default' => 'b' }
          }
        }
      ]
    }
    schemer = JSONSchemer.schema(schema)

    plan_a = schemer.plan_defaults({ 'foo' => 'a' })
    assert_equal(['a'], plan_a.changes.map(&:value))
    assert_empty(plan_a.conflicts)

    plan_b = schemer.plan_defaults({ 'foo' => 'b' })
    assert_equal(['b'], plan_b.changes.map(&:value))
  end

  def test_defaults_from_invalid_branches_are_not_planned
    schema = {
      'anyOf' => [
        {
          'properties' => {
            'foo' => { 'const' => 'a' },
            'bar' => { 'default' => 'a' }
          }
        },
        {
          'properties' => {
            'foo' => { 'const' => 'b' },
            'bar' => { 'default' => 'b' }
          }
        }
      ]
    }
    plan = JSONSchemer.schema(schema).plan_defaults({ 'foo' => 'c', 'keep' => true })

    assert_empty(plan.changes)
    assert_empty(plan.conflicts)
  end

  def test_apply_checks_preconditions_without_modifying
    schema = {
      'required' => ['a'],
      'properties' => {
        'a' => { 'default' => 1 }
      }
    }
    plan = JSONSchemer.schema(schema).plan_defaults({})
    data = { 'a' => 42 }

    refute(plan.apply(data))
    assert_equal({ 'a' => 42 }, data)
  end

  def test_apply_rolls_back_when_post_validation_fails
    schema = {
      'required' => %w[a b],
      'properties' => {
        'a' => { 'default' => 1 },
        'b' => {
          'anyOf' => [
            { 'default' => 2 },
            { 'default' => 3 }
          ]
        }
      }
    }
    plan = JSONSchemer.schema(schema).plan_defaults({})
    assert_equal(['a'], plan.changes.map(&:property))

    data = {}
    refute(plan.apply(data))
    assert_equal({}, data)
  end

  def test_apply_rolls_back_when_a_parent_disappears
    schema = {
      'properties' => {
        'a' => {
          'properties' => {
            'x' => { 'default' => 1 }
          }
        }
      }
    }
    plan = JSONSchemer.schema(schema).plan_defaults({ 'a' => {} })
    data = {}

    refute(plan.apply(data))
    assert_equal({}, data)
  end

  def test_apply_fails_when_parent_is_not_an_object
    schema = {
      'properties' => {
        'a' => {
          'properties' => {
            'x' => { 'default' => 1 }
          }
        }
      }
    }
    plan = JSONSchemer.schema(schema).plan_defaults({ 'a' => {} })
    data = { 'a' => 5 }

    refute(plan.apply(data))
    assert_equal({ 'a' => 5 }, data)

    nested_schema = {
      'properties' => {
        'a' => {
          'properties' => {
            'b' => {
              'properties' => {
                'x' => { 'default' => 1 }
              }
            }
          }
        }
      }
    }
    nested_plan = JSONSchemer.schema(nested_schema).plan_defaults({ 'a' => { 'b' => {} } })
    refute(nested_plan.apply({}))
    refute(nested_plan.apply({ 'a' => { 'b' => 'scalar' } }))
  end

  def test_plan_includes_defaults_behind_refs
    schema = {
      'properties' => {
        'ref-inline' => { '$ref' => '#/$defs/default-b' },
        'ref-inherit' => { '$ref' => '#/$defs/inherit-default-b' },
        'ref-inline-override' => { '$ref' => '#/$defs/default-b', 'default' => 'c' }
      },
      '$defs' => {
        'default-b' => { 'default' => 'b' },
        'inherit-default-b' => { '$ref' => '#/$defs/default-b' }
      }
    }
    plan = JSONSchemer.schema(schema).plan_defaults({})
    values = plan.changes.to_h { |change| [change.property, change.value] }

    assert_equal({ 'ref-inline' => 'b', 'ref-inherit' => 'b', 'ref-inline-override' => 'c' }, values)
  end

  def test_empty_plan_apply_is_a_noop
    schema = {
      'properties' => {
        'a' => { 'default' => 1 }
      }
    }
    schemer = JSONSchemer.schema(schema)
    data = { 'a' => 9 }
    plan = schemer.plan_defaults(data)

    assert(plan.empty?)
    assert(plan.apply(data))
    assert_equal({ 'a' => 9 }, data)
  end

  def test_apply_supports_symbol_keyed_instances
    schema = {
      'properties' => {
        'a' => {
          'properties' => {
            'b' => { 'default' => 1 }
          }
        }
      }
    }
    plan = JSONSchemer.schema(schema).plan_defaults({ :a => {} })
    data = { :a => {} }

    assert(plan.apply(data))
    assert_equal(1, data.dig(:a, 'b'))

    precondition = { :a => { :b => 2 } }
    refute(plan.apply(precondition))
    assert_equal({ :a => { :b => 2 } }, precondition)
  end
end
