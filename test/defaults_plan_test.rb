require 'test_helper'

class DefaultsPlanTest < Minitest::Test
  def test_plan_defaults_returns_patches_without_modifying_instance
    schema = {
      'properties' => {
        'name' => { 'type' => 'string', 'default' => 'anon' },
        'age' => { 'type' => 'integer', 'default' => 0 },
        'address' => {
          'type' => 'object',
          'properties' => {
            'city' => { 'default' => 'Berlin' }
          }
        }
      }
    }
    schemer = JSONSchemer.schema(schema)
    data = { 'name' => 'bob', 'address' => {} }
    plan = schemer.plan_defaults(data)

    refute(plan.empty?)
    assert_equal(
      [
        {
          'instance_location' => '',
          'property' => 'age',
          'value' => 0,
          'keyword_location' => '/properties/age/default',
          'absolute_keyword_location' => 'json-schemer://schema#/properties/age/default'
        },
        {
          'instance_location' => '/address',
          'property' => 'city',
          'value' => 'Berlin',
          'keyword_location' => '/properties/address/properties/city/default',
          'absolute_keyword_location' => 'json-schemer://schema#/properties/address/properties/city/default'
        }
      ],
      plan.patches
    )
    assert_equal([], plan.conflicts)
    assert_equal({ 'name' => 'bob', 'address' => {} }, data)
    assert_equal({ 'patches' => plan.patches, 'conflicts' => plan.conflicts }, plan.to_h)
  end

  def test_plan_defaults_is_empty_when_nothing_is_missing
    schemer = JSONSchemer.schema({ 'properties' => { 'a' => { 'default' => 1 } } })
    assert(schemer.plan_defaults({ 'a' => 1 }).empty?)
    assert(schemer.plan_defaults({ 'a' => nil }).empty?)
    assert(schemer.plan_defaults({}).empty? == false)
    assert(JSONSchemer.schema({ 'properties' => { 'a' => { 'type' => 'string' } } }).plan_defaults({}).empty?)
    assert(JSONSchemer.schema({ 'type' => 'string' }).plan_defaults(1).empty?)
  end

  def test_plan_defaults_materializes_nested_objects
    schema = {
      'properties' => {
        'd' => {
          'default' => {},
          'properties' => {
            'x' => { 'default' => 1 },
            'y' => {
              'default' => {},
              'properties' => {
                'z' => { 'default' => 2 }
              }
            }
          }
        }
      }
    }
    schemer = JSONSchemer.schema(schema)
    data = {}
    plan = schemer.plan_defaults(data)

    assert_equal(
      [
        { 'instance_location' => '', 'property' => 'd', 'value' => {} },
        { 'instance_location' => '/d', 'property' => 'x', 'value' => 1 },
        { 'instance_location' => '/d', 'property' => 'y', 'value' => {} },
        { 'instance_location' => '/d/y', 'property' => 'z', 'value' => 2 }
      ],
      plan.patches.map { |patch| patch.slice('instance_location', 'property', 'value') }
    )

    schemer.apply_defaults_plan(data, plan)
    assert_equal({ 'd' => { 'x' => 1, 'y' => { 'z' => 2 } } }, data)
    assert(schemer.plan_defaults(data).empty?)
  end

  def test_plan_defaults_refs
    schema = {
      'properties' => {
        'inline' => { 'default' => 'a' },
        'ref-inline' => { '$ref' => '#/$defs/default-b' },
        'ref-inline-override' => { '$ref' => '#/$defs/default-b', 'default' => 'c' }
      },
      '$defs' => {
        'default-b' => { 'default' => 'b' }
      }
    }
    schemer = JSONSchemer.schema(schema)
    data = {}
    plan = schemer.plan_defaults(data)

    assert_equal(%w[a b c], plan.patches.map { |patch| patch.fetch('value') })
    ref_patch = plan.patches.find { |patch| patch.fetch('property') == 'ref-inline' }
    assert_equal('json-schemer://schema#/$defs/default-b/default', ref_patch.fetch('absolute_keyword_location'))

    schemer.apply_defaults_plan(data, plan)
    assert_equal({ 'inline' => 'a', 'ref-inline' => 'b', 'ref-inline-override' => 'c' }, data)
  end

  def test_plan_defaults_dynamic_refs
    schema = {
      'properties' => {
        'x' => { '$dynamicRef' => '#default-b' }
      },
      '$defs' => {
        'foo' => { '$dynamicAnchor' => 'default-b', 'default' => 'b' }
      }
    }
    schemer = JSONSchemer.schema(schema)
    plan = schemer.plan_defaults({})
    assert_equal(['b'], plan.patches.map { |patch| patch.fetch('value') })
  end

  def test_plan_defaults_agreeing_combinator_branches
    schema = {
      'allOf' => [
        { 'properties' => { 'x' => { 'default' => 'a' } } },
        { 'properties' => { 'x' => { 'default' => 'a' } } }
      ]
    }
    plan = JSONSchemer.schema(schema).plan_defaults({})
    assert_equal(1, plan.patches.size)
    assert_equal('a', plan.patches.first.fetch('value'))
    assert_equal([], plan.conflicts)
  end

  def test_plan_defaults_conflicting_combinator_branches_are_preserved
    schema = {
      'allOf' => [
        { 'properties' => { 'x' => { 'default' => 'a' } } },
        { 'properties' => { 'x' => { 'default' => 'b' } } }
      ],
      'properties' => {
        'd' => { 'default' => {}, 'properties' => { 'y' => { 'default' => 1 } } }
      }
    }
    schemer = JSONSchemer.schema(schema)
    data = {}
    plan = schemer.plan_defaults(data)

    assert_equal(%w[d y], plan.patches.map { |patch| patch.fetch('property') })
    assert_equal(1, plan.conflicts.size)
    conflict = plan.conflicts.first
    assert_equal('', conflict.fetch('instance_location'))
    assert_equal('x', conflict.fetch('property'))
    assert_equal(%w[a b], conflict.fetch('values').sort)
    assert_equal(
      [
        'json-schemer://schema#/allOf/0/properties/x/default',
        'json-schemer://schema#/allOf/1/properties/x/default'
      ],
      conflict.fetch('absolute_keyword_locations').sort
    )

    schemer.apply_defaults_plan(data, plan)
    assert_equal({ 'd' => { 'y' => 1 } }, data)
    refute(data.key?('x'))
  end

  def test_plan_defaults_any_of_and_one_of
    schema = {
      'anyOf' => [
        { 'properties' => { 'x' => { 'default' => 'a' } } },
        { 'properties' => { 'x' => { 'default' => 'a' } } }
      ],
      'oneOf' => [
        { 'properties' => { 'w' => { 'const' => 1 } }, 'required' => ['w'] },
        { 'properties' => { 'y' => { 'default' => 'b' } }, 'required' => ['q'] }
      ]
    }
    plan = JSONSchemer.schema(schema).plan_defaults({ 'w' => 1 })
    assert_equal([['x', 'a'], ['y', 'b']], plan.patches.map { |patch| [patch.fetch('property'), patch.fetch('value')] }.sort)
    assert_equal([], plan.conflicts)
  end

  def test_plan_defaults_single_candidate_from_invalid_branch
    schema = {
      'properties' => {
        'x' => { 'default' => 'a', 'type' => 'string' }
      },
      'required' => ['missing']
    }
    plan = JSONSchemer.schema(schema).plan_defaults({})
    assert_equal(['a'], plan.patches.map { |patch| patch.fetch('value') })
  end

  def test_plan_defaults_skips_candidates_without_valid_branch
    schema = {
      'anyOf' => [
        { 'properties' => { 'x' => { 'default' => 'a' } }, 'required' => ['a1'] },
        { 'properties' => { 'x' => { 'default' => 'b' } }, 'required' => ['a2'] }
      ]
    }
    plan = JSONSchemer.schema(schema).plan_defaults({})
    assert(plan.empty?)
    assert_equal([], plan.conflicts)
  end

  def test_plan_defaults_recursive_refs_terminate
    schema = {
      'properties' => {
        'child' => { '$ref' => '#', 'default' => {} }
      }
    }
    plan = JSONSchemer.schema(schema).plan_defaults({})
    assert_equal([{ 'instance_location' => '', 'property' => 'child', 'value' => {} }], plan.patches.map { |patch| patch.slice('instance_location', 'property', 'value') })
  end

  def test_plan_defaults_deep_copies_default_values
    schema = {
      'properties' => {
        'list' => { 'default' => [1, 2] },
        'config' => { 'default' => { 'a' => 1 } }
      }
    }
    schemer = JSONSchemer.schema(schema)
    plan = schemer.plan_defaults({})
    plan.patches.each { |patch| patch.fetch('value') << 3 rescue patch.fetch('value')['b'] = 2 }

    fresh_plan = schemer.plan_defaults({})
    assert_equal([1, 2], fresh_plan.patches.find { |patch| patch.fetch('property') == 'list' }.fetch('value'))
    assert_equal({ 'a' => 1 }, fresh_plan.patches.find { |patch| patch.fetch('property') == 'config' }.fetch('value'))

    first = {}
    second = {}
    schemer.apply_defaults_plan(first, fresh_plan)
    first.fetch('list') << 3
    first.fetch('config')['b'] = 2
    schemer.apply_defaults_plan(second, schemer.plan_defaults(second))
    assert_equal([1, 2], second.fetch('list'))
    assert_equal({ 'a' => 1 }, second.fetch('config'))
  end

  def test_plan_defaults_array_items
    schema = {
      'type' => 'array',
      'items' => {
        'type' => 'object',
        'properties' => {
          'x' => { 'default' => 1 }
        }
      }
    }
    schemer = JSONSchemer.schema(schema)
    data = [{}, { 'x' => 10 }, {}]
    plan = schemer.plan_defaults(data)
    assert_equal(['/0', '/2'], plan.patches.map { |patch| patch.fetch('instance_location') }.sort)
    schemer.apply_defaults_plan(data, plan)
    assert_equal([{ 'x' => 1 }, { 'x' => 10 }, { 'x' => 1 }], data)
  end

  def test_apply_defaults_plan_returns_instance_and_replans_empty
    schemer = JSONSchemer.schema({ 'properties' => { 'a' => { 'default' => 1 } } })
    data = {}
    plan = schemer.plan_defaults(data)
    assert_same(data, schemer.apply_defaults_plan(data, plan))
    assert_equal({ 'a' => 1 }, data)
    assert(schemer.plan_defaults(data).empty?)
  end

  def test_apply_defaults_plan_via_plan_apply
    schemer = JSONSchemer.schema({ 'properties' => { 'a' => { 'default' => 1 } } })
    data = {}
    plan = schemer.plan_defaults(data)
    assert_same(data, plan.apply(data))
    assert_equal({ 'a' => 1 }, data)
  end

  def test_apply_defaults_plan_empty_plan_is_a_no_op
    schemer = JSONSchemer.schema({ 'properties' => { 'a' => { 'default' => 1 } } })
    data = { 'a' => 1 }
    plan = schemer.plan_defaults(data)
    assert(plan.empty?)
    assert_same(data, schemer.apply_defaults_plan(data, plan))
    assert_equal({ 'a' => 1 }, data)
  end

  def test_apply_defaults_plan_raises_when_instance_changed
    schemer = JSONSchemer.schema({ 'properties' => { 'a' => { 'default' => 1 }, 'b' => { 'default' => 2 } } })
    data = {}
    plan = schemer.plan_defaults(data)
    data['a'] = 100
    error = assert_raises(JSONSchemer::StaleDefaultsPlan) { schemer.apply_defaults_plan(data, plan) }
    assert_equal('instance no longer satisfies defaults plan preconditions', error.message)
    assert_equal({ 'a' => 100 }, data)
  end

  def test_apply_defaults_plan_raises_when_applied_twice
    schemer = JSONSchemer.schema({ 'properties' => { 'a' => { 'default' => 1 } } })
    data = {}
    plan = schemer.plan_defaults(data)
    schemer.apply_defaults_plan(data, plan)
    assert_raises(JSONSchemer::StaleDefaultsPlan) { schemer.apply_defaults_plan(data, plan) }
    assert_equal({ 'a' => 1 }, data)
  end

  def test_apply_defaults_plan_is_atomic_when_result_is_invalid
    schema = {
      'properties' => {
        'a' => { 'default' => 'x', 'type' => 'integer' },
        'b' => { 'default' => 2 }
      }
    }
    schemer = JSONSchemer.schema(schema)
    data = {}
    plan = schemer.plan_defaults(data)
    error = assert_raises(JSONSchemer::InvalidDefaultsPlan) { schemer.apply_defaults_plan(data, plan) }
    assert_equal('instance is invalid after applying defaults plan', error.message)
    assert_equal({}, data)
  end

  def test_apply_defaults_plan_with_symbol_keys
    schemer = JSONSchemer.schema({
      'properties' => {
        'a' => {
          'properties' => {
            'b' => { 'default' => 1 }
          }
        }
      }
    })
    data = { :a => {} }
    plan = schemer.plan_defaults(data)
    assert_equal('/a', plan.patches.first.fetch('instance_location'))
    schemer.apply_defaults_plan(data, plan)
    assert_equal({ :a => { 'b' => 1 } }, data)
  end

  def test_plan_defaults_matches_insert_property_defaults
    schema = {
      'properties' => {
        'a' => { 'default' => 1 },
        'b' => { 'default' => 2 },
        'c' => {
          'properties' => {
            'x' => { 'default' => 3 },
            'y' => { 'default' => 4 }
          }
        }
      }
    }
    data = { 'a' => 10, 'c' => { 'x' => 30 } }
    inserted = Marshal.load(Marshal.dump(data))
    JSONSchemer.schema(schema, :insert_property_defaults => true).valid?(inserted)

    planned = Marshal.load(Marshal.dump(data))
    schemer = JSONSchemer.schema(schema)
    schemer.apply_defaults_plan(planned, schemer.plan_defaults(planned))

    assert_equal(inserted, planned)
  end
end
