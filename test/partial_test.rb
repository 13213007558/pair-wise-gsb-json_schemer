require 'test_helper'

class PartialTest < Minitest::Test
  UNKNOWN = JSONSchemer::Partial::UNKNOWN

  def partial(schema, instance, **options)
    JSONSchemer.schema(schema).partial_validate(instance, **options)
  end

  # Wraps a leaf schema so the evaluator's own keyword logic runs on a
  # concrete value (non-plain configuration disables delegation).
  def leaf_result(leaf_schema, value)
    schema = JSONSchemer.schema(
      { 'properties' => { 'x' => leaf_schema, 'y' => { 'type' => 'string' } } },
      :insert_property_defaults => true
    )
    schema.partial_validate({ 'x' => value, 'y' => UNKNOWN })
  end

  def leaf_errors(leaf_schema, value)
    leaf_result(leaf_schema, value).errors.select { |entry| entry['instance_location'].start_with?('/x') }
  end

  def leaf_unresolved(leaf_schema, value)
    leaf_result(leaf_schema, value).unresolved.select { |entry| entry['instance_location'].start_with?('/x') }
  end

  def test_unknown_placeholder_is_distinct_from_missing_and_null
    assert_equal('JSONSchemer::Partial::UNKNOWN', UNKNOWN.inspect)
    assert_equal('JSONSchemer::Partial::UNKNOWN', UNKNOWN.to_s)

    schema = { 'type' => 'object', 'required' => ['a'], 'properties' => { 'a' => { 'type' => 'string' } } }

    missing = partial(schema, {})
    assert_equal(:invalid, missing.status)

    null = partial(schema, { 'a' => nil })
    assert_equal(:invalid, null.status)

    unknown = partial(schema, { 'a' => UNKNOWN })
    assert_equal(:unknown, unknown.status)
    assert(unknown.unresolved.any? { |entry| entry['keyword'] == 'type' && entry['instance_location'] == '/a' })
    assert_empty(unknown.errors)
  end

  def test_concrete_instance_matches_regular_validator
    schema = {
      'type' => 'object',
      'required' => %w[name age],
      'properties' => {
        'name' => { 'type' => 'string', 'minLength' => 2 },
        'age' => { 'type' => 'integer', 'minimum' => 0 }
      }
    }

    valid = partial(schema, { 'name' => 'alice', 'age' => 30 })
    assert_equal(:valid, valid.status)
    assert(valid.valid?)
    refute(valid.invalid?)
    refute(valid.unknown?)
    refute(valid.pending?)
    assert_empty(valid.unresolved)
    assert_empty(valid.errors)

    invalid = partial(schema, { 'name' => 'a', 'age' => -1 })
    assert_equal(:invalid, invalid.status)
    refute_empty(invalid.errors)
  end

  def test_result_to_h
    result = partial({ 'type' => 'string' }, UNKNOWN)
    expected = {
      'status' => 'unknown',
      'valid' => false,
      'unresolved' => result.unresolved,
      'errors' => []
    }
    assert_equal(expected, result.to_h)
  end

  def test_partial_valid_convenience
    schema = JSONSchemer.schema({ 'type' => 'string' })
    assert_equal(true, schema.partial_valid?('a'))
    assert_equal(false, schema.partial_valid?(1))
    assert_nil(schema.partial_valid?(UNKNOWN))
  end

  def test_module_level_evaluate
    schema = JSONSchemer.schema({ 'type' => 'string' })
    assert_equal(:valid, JSONSchemer::Partial.evaluate(schema, 'a').status)
    assert_equal(:unknown, JSONSchemer::Partial.evaluate(schema, UNKNOWN).status)
  end

  def test_custom_placeholder
    schema = JSONSchemer.schema({ 'properties' => { 'a' => { 'type' => 'string' } } })
    result = schema.partial_validate({ :a => :todo }, :unknown => :todo)
    assert_equal(:unknown, result.status)
    assert_equal(['/a'], result.unresolved.map { |entry| entry['instance_location'] })
  end

  def test_symbol_keys_are_stringified
    result = partial({ 'properties' => { 'a' => { 'type' => 'string' } } }, { :a => UNKNOWN })
    assert_equal(:unknown, result.status)
    assert_equal(['/a'], result.unresolved.map { |entry| entry['instance_location'] })
  end

  def test_type_keyword
    assert_empty(leaf_errors({ 'type' => 'null' }, nil))
    refute_empty(leaf_errors({ 'type' => 'null' }, 1))

    assert_empty(leaf_errors({ 'type' => 'boolean' }, true))
    assert_empty(leaf_errors({ 'type' => 'boolean' }, false))
    refute_empty(leaf_errors({ 'type' => 'boolean' }, 1))

    assert_empty(leaf_errors({ 'type' => 'number' }, 1.5))
    refute_empty(leaf_errors({ 'type' => 'number' }, 'a'))

    assert_empty(leaf_errors({ 'type' => 'integer' }, 1))
    assert_empty(leaf_errors({ 'type' => 'integer' }, 1.0))
    refute_empty(leaf_errors({ 'type' => 'integer' }, 1.5))

    assert_empty(leaf_errors({ 'type' => 'string' }, 'a'))
    refute_empty(leaf_errors({ 'type' => 'string' }, 1))

    assert_empty(leaf_errors({ 'type' => 'array' }, []))
    refute_empty(leaf_errors({ 'type' => 'array' }, {}))

    assert_empty(leaf_errors({ 'type' => 'object' }, {}))
    refute_empty(leaf_errors({ 'type' => 'object' }, []))

    assert_empty(leaf_errors({ 'type' => 'unknown-type' }, 1))

    assert_empty(leaf_errors({ 'type' => %w[string null] }, nil))
    assert_empty(leaf_errors({ 'type' => %w[string null] }, 'a'))
    refute_empty(leaf_errors({ 'type' => %w[string null] }, 1))

    assert(leaf_unresolved({ 'type' => 'string' }, UNKNOWN).any? { |entry| entry['keyword'] == 'type' })
  end

  def test_enum_and_const_keywords
    assert_empty(leaf_errors({ 'enum' => [1, 2, 3] }, 2))
    refute_empty(leaf_errors({ 'enum' => [1, 2, 3] }, 4))
    refute_empty(leaf_unresolved({ 'enum' => [1, 2, 3] }, UNKNOWN))

    assert_empty(leaf_errors({ 'const' => 'a' }, 'a'))
    refute_empty(leaf_errors({ 'const' => 'a' }, 'b'))
    refute_empty(leaf_unresolved({ 'const' => 'a' }, UNKNOWN))
  end

  def test_enum_with_nested_unknown_is_pending
    result = leaf_result({ 'enum' => [{ 'a' => 1 }] }, { 'a' => UNKNOWN })
    assert(result.unresolved.any? { |entry| entry['keyword'] == 'enum' && entry['instance_location'] == '/x' })
    assert_empty(result.errors.select { |entry| entry['instance_location'] == '/x' })
  end

  def test_required_keyword
    assert_empty(leaf_errors({ 'required' => ['a'] }, { 'a' => 1 }))
    refute_empty(leaf_errors({ 'required' => ['a'] }, {}))
    assert_empty(leaf_errors({ 'required' => ['a'] }, 'not-an-object'))
    refute_empty(leaf_unresolved({ 'required' => ['a'] }, UNKNOWN))
  end

  def test_required_with_access_mode_is_unresolved
    schema = JSONSchemer.schema(
      { 'required' => ['a'], 'properties' => { 'a' => { 'readOnly' => true } } },
      :access_mode => 'write'
    )
    result = schema.partial_validate({ 'a' => UNKNOWN })
    assert_equal(:unknown, result.status)
    assert(result.unresolved.any? { |entry| entry['keyword'] == 'required' })
  end

  def test_properties_keyword
    assert_empty(leaf_errors({ 'properties' => { 'a' => { 'type' => 'string' } } }, { 'a' => 'x' }))
    refute_empty(leaf_errors({ 'properties' => { 'a' => { 'type' => 'string' } } }, { 'a' => 1 }))
    assert_empty(leaf_errors({ 'properties' => { 'a' => { 'type' => 'string' } } }, { 'b' => 1 }))
    assert_empty(leaf_errors({ 'properties' => { 'a' => { 'type' => 'string' } } }, 'not-an-object'))
    refute_empty(leaf_unresolved({ 'properties' => { 'a' => { 'type' => 'string' } } }, UNKNOWN))
  end

  def test_prefix_items_keyword
    assert_empty(leaf_errors({ 'prefixItems' => [{ 'type' => 'string' }] }, ['a']))
    refute_empty(leaf_errors({ 'prefixItems' => [{ 'type' => 'string' }] }, [1]))
    assert_empty(leaf_errors({ 'prefixItems' => [{ 'type' => 'string' }] }, ['a', 'extra', 'items']))
    assert_empty(leaf_errors({ 'prefixItems' => [{ 'type' => 'string' }] }, 'not-an-array'))
    refute_empty(leaf_unresolved({ 'prefixItems' => [{ 'type' => 'string' }] }, UNKNOWN))
  end

  def test_items_keyword
    assert_empty(leaf_errors({ 'items' => { 'type' => 'integer' } }, [1, 2]))
    refute_empty(leaf_errors({ 'items' => { 'type' => 'integer' } }, [1, 'a']))
    assert_empty(leaf_errors({ 'items' => { 'type' => 'integer' } }, 'not-an-array'))
    refute_empty(leaf_unresolved({ 'items' => { 'type' => 'integer' } }, UNKNOWN))
  end

  def test_items_offset_with_prefix_items
    schema = { 'prefixItems' => [{ 'type' => 'string' }], 'items' => { 'type' => 'integer' } }
    assert_empty(leaf_errors(schema, ['a', 1, 2]))
    refute_empty(leaf_errors(schema, ['a', 'b']))
    assert_empty(leaf_errors(schema, ['a']))
  end

  def test_items_tuple_form_in_older_drafts
    schema = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'items' => [{ 'type' => 'string' }]
    }
    assert_empty(leaf_errors(schema, ['a']))
    refute_empty(leaf_errors(schema, [1]))
  end
  def test_all_of
    assert_equal(:unknown, leaf_result({ 'allOf' => [{ 'type' => 'string' }, { 'minLength' => 2 }] }, UNKNOWN).status)
    assert_empty(leaf_errors({ 'allOf' => [{ 'type' => 'string' }, { 'const' => 'a' }] }, 'a'))
    refute_empty(leaf_errors({ 'allOf' => [{ 'type' => 'string' }, { 'const' => 'a' }] }, 'b'))
  end

  def test_any_of
    assert_empty(leaf_errors({ 'anyOf' => [{ 'type' => 'string' }, { 'type' => 'integer' }] }, 1))
    refute_empty(leaf_errors({ 'anyOf' => [{ 'type' => 'string' }, { 'type' => 'boolean' }] }, 1))
    result = leaf_result({ 'anyOf' => [{ 'type' => 'string' }, { 'type' => 'integer' }] }, UNKNOWN)
    assert_equal(:unknown, result.status)
    assert_equal(2, result.unresolved.count { |entry| entry['instance_location'] == '/x' && entry['keyword'] == 'type' })
  end

  def test_one_of
    assert_equal(:invalid, leaf_result({ 'oneOf' => [true, true] }, UNKNOWN).status)
    assert_equal(:unknown, leaf_result({ 'oneOf' => [{ 'type' => 'string' }, true] }, UNKNOWN).status)
    assert_equal(:unknown, leaf_result({ 'oneOf' => [{ 'type' => 'string' }, { 'type' => 'integer' }] }, UNKNOWN).status)
    assert_empty(leaf_errors({ 'oneOf' => [{ 'type' => 'string' }, { 'type' => 'integer' }] }, 'a'))
    assert_empty(leaf_errors({ 'oneOf' => [{ 'type' => 'string' }, { 'type' => 'integer' }] }, 1))
    refute_empty(leaf_errors({ 'oneOf' => [{ 'type' => 'string' }, { 'type' => 'boolean' }] }, 1))
    refute_empty(leaf_errors({ 'oneOf' => [{ 'type' => 'integer' }, { 'type' => 'number' }] }, 1))
  end

  def test_not
    assert_empty(leaf_errors({ 'not' => { 'type' => 'string' } }, 1))
    refute_empty(leaf_errors({ 'not' => { 'type' => 'string' } }, 'a'))
    assert_equal(:unknown, leaf_result({ 'not' => { 'type' => 'string' } }, UNKNOWN).status)
  end

  def test_ref
    schema = {
      '$defs' => { 'name' => { 'type' => 'string' } },
      'properties' => { 'a' => { '$ref' => '#/$defs/name' } }
    }
    result = partial(schema, { 'a' => UNKNOWN })
    assert_equal(:unknown, result.status)
    assert(result.unresolved.any? { |entry| entry['keyword'] == 'type' && entry['instance_location'] == '/a' })
    assert_equal(:valid, partial(schema, { 'a' => 'ok' }).status)
    assert_equal(:invalid, partial(schema, { 'a' => 1 }).status)
  end

  def test_recursive_ref_is_unresolved
    result = partial({ '$ref' => '#' }, UNKNOWN)
    assert_equal(:unknown, result.status)
    assert(result.unresolved.any? { |entry| entry['keyword'] == '$ref' && entry['reason'].include?('recursive') })
  end

  def test_unsupported_keywords_become_unresolved_constraints
    result = partial({ 'type' => 'string', 'minLength' => 3, 'pattern' => '^a' }, UNKNOWN)
    assert_equal(:unknown, result.status)
    keywords = result.unresolved.map { |entry| entry['keyword'] }
    assert_includes(keywords, 'type')
    assert_includes(keywords, 'minLength')
    assert_includes(keywords, 'pattern')
    assert(result.unresolved.any? { |entry| entry['keyword'] == 'minLength' && entry['reason'].include?('not supported') })
  end

  def test_unsupported_keywords_are_exact_for_concrete_values
    schema = { 'properties' => { 'x' => { 'minimum' => 10 }, 'y' => { 'type' => 'string' } } }
    assert_equal(:invalid, partial(schema, { 'x' => 5, 'y' => UNKNOWN }).status)
    result = partial(schema, { 'x' => 15, 'y' => UNKNOWN })
    assert_equal(:unknown, result.status)
    assert_equal(['/y'], result.unresolved.map { |entry| entry['instance_location'] })
  end

  def test_annotation_and_unknown_keywords_are_ignored
    schema = {
      'title' => 'title',
      'description' => 'description',
      'default' => 1,
      'examples' => [],
      'deprecated' => true,
      'readOnly' => true,
      'writeOnly' => false,
      '$comment' => 'comment',
      'x-custom' => 'whatever'
    }
    assert_equal(:valid, partial(schema, UNKNOWN).status)
  end

  def test_false_and_true_schemas
    schema = { 'properties' => { 'x' => false, 'y' => { 'type' => 'string' } } }
    assert_equal(:invalid, partial(schema, { 'x' => 1, 'y' => UNKNOWN }).status)

    forced = JSONSchemer.schema(schema, :insert_property_defaults => true)
    result = forced.partial_validate({ 'x' => 1, 'y' => UNKNOWN })
    assert_equal(:invalid, result.status)
    assert(result.errors.any? { |entry| entry['instance_location'] == '/x' })

    true_schema = { 'properties' => { 'x' => true, 'y' => { 'type' => 'string' } } }
    result = partial(true_schema, { 'x' => UNKNOWN, 'y' => UNKNOWN })
    assert_equal(:unknown, result.status)
    assert_equal(['/y'], result.unresolved.map { |entry| entry['instance_location'] })
  end

  def test_unevaluated_keywords_are_not_delegated
    schema = { 'unevaluatedProperties' => false, 'properties' => { 'a' => { 'type' => 'string' } } }
    result = partial(schema, { 'a' => UNKNOWN, 'b' => 1 })
    assert_equal(:unknown, result.status)
    assert(result.unresolved.any? { |entry| entry['keyword'] == 'unevaluatedProperties' })
    assert_equal(:invalid, partial(schema, { 'a' => 'x', 'b' => 1 }).status)
    assert_equal(:valid, partial(schema, { 'a' => 'x' }).status)
  end

  def test_unsafe_keyword_nested_in_array_is_not_delegated
    schema = {
      'properties' => {
        'x' => { 'allOf' => [{ 'unevaluatedProperties' => true }] },
        'y' => { 'type' => 'string' }
      }
    }
    result = partial(schema, { 'x' => { 'a' => 1 }, 'y' => UNKNOWN })
    assert_equal(:unknown, result.status)
    assert(result.unresolved.any? { |entry| entry['keyword'] == 'unevaluatedProperties' })
  end

  def test_additional_items_is_unresolved
    schema = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'items' => [{ 'type' => 'string' }],
      'additionalItems' => { 'type' => 'integer' }
    }
    result = partial(schema, ['a', UNKNOWN])
    assert_equal(:unknown, result.status)
    assert(result.unresolved.any? { |entry| entry['keyword'] == 'additionalItems' })
  end

  def test_custom_keywords_are_unresolved
    schema = JSONSchemer.schema(
      { 'x-even' => true, 'properties' => { 'a' => { 'type' => 'string' } } },
      :keywords => { 'x-even' => :itself.to_proc }
    )
    result = schema.partial_validate({ 'a' => UNKNOWN })
    assert_equal(:unknown, result.status)
    assert(result.unresolved.any? { |entry| entry['keyword'] == 'x-even' && entry['reason'].include?('custom keywords') })
  end

  def test_custom_keywords_not_present_in_schema_are_ignored
    schema = JSONSchemer.schema(
      { 'type' => 'string' },
      :keywords => { 'x-even' => :itself.to_proc }
    )
    result = schema.partial_validate(UNKNOWN)
    assert_equal(:unknown, result.status)
    assert_equal(%w[type], result.unresolved.map { |entry| entry['keyword'] })
  end

  def test_custom_keywords_with_boolean_schema
    schema = JSONSchemer.schema(true, :keywords => { 'x-even' => :itself.to_proc })
    assert_equal(:valid, schema.partial_validate(UNKNOWN).status)
  end

  def test_property_validation_hooks_disable_delegation
    hook = proc { |instance, property, property_schema, schema| }
    schema = JSONSchemer.schema(
      { 'properties' => { 'x' => { 'type' => 'string' }, 'y' => { 'type' => 'string' } } },
      :before_property_validation => hook
    )
    result = schema.partial_validate({ 'x' => 'a', 'y' => UNKNOWN })
    assert_equal(:unknown, result.status)
    assert_equal(['/y'], result.unresolved.map { |entry| entry['instance_location'] })

    schema = JSONSchemer.schema(
      { 'properties' => { 'x' => { 'type' => 'string' }, 'y' => { 'type' => 'string' } } },
      :after_property_validation => hook
    )
    result = schema.partial_validate({ 'x' => 'a', 'y' => UNKNOWN })
    assert_equal(:unknown, result.status)
    assert_equal(['/y'], result.unresolved.map { |entry| entry['instance_location'] })
  end

  def test_delegation_is_memoized_per_subschema
    schema = { 'items' => { 'type' => 'integer' } }
    result = partial(schema, [1, 2, UNKNOWN])
    assert_equal(:unknown, result.status)
    assert_equal(['/2'], result.unresolved.map { |entry| entry['instance_location'] })
  end

  def test_convergence_to_regular_validator
    schema = JSONSchemer.schema({
      'type' => 'object',
      'required' => %w[name age],
      'properties' => {
        'name' => { 'type' => 'string', 'enum' => %w[alice bob] },
        'age' => { 'type' => 'integer' },
        'tags' => { 'type' => 'array', 'prefixItems' => [{ 'type' => 'string' }], 'items' => { 'type' => 'integer' } },
        'role' => { 'anyOf' => [{ 'const' => 'admin' }, { 'const' => 'user' }] },
        'nickname' => { 'not' => { 'type' => 'integer' } }
      }
    })

    template = { 'name' => UNKNOWN, 'age' => UNKNOWN, 'tags' => [UNKNOWN, UNKNOWN], 'role' => UNKNOWN, 'nickname' => UNKNOWN }
    assert_equal(:unknown, schema.partial_validate(template).status)

    candidates = {
      'name' => ['alice', 'carol', 7],
      'age' => [30, 'x'],
      'role' => ['admin', 'nope'],
      'nickname' => ['nick', 9]
    }
    tag_candidates = [['a', 2], ['a', 'b'], [1, 2]]

    candidates['name'].each do |name|
      candidates['age'].each do |age|
        tag_candidates.each do |tags|
          candidates['role'].each do |role|
            candidates['nickname'].each do |nickname|
              instance = { 'name' => name, 'age' => age, 'tags' => tags, 'role' => role, 'nickname' => nickname }
              expected = schema.valid?(instance) ? :valid : :invalid
              assert_equal(expected, schema.partial_validate(instance).status, "instance: #{instance.inspect}")
            end
          end
        end
      end
    end
  end

  def test_definite_conclusions_hold_for_every_completion
    schema = JSONSchemer.schema({
      'required' => %w[name age],
      'properties' => {
        'name' => { 'enum' => %w[alice bob] },
        'age' => { 'type' => 'integer' }
      }
    })

    definitely_invalid = schema.partial_validate({ 'name' => 'carol', 'age' => UNKNOWN })
    assert_equal(:invalid, definitely_invalid.status)
    %w[alice bob carol].each do |name|
      [1, 'x', nil].each do |age|
        instance = { 'name' => name, 'age' => age }
        next if name == 'alice' || name == 'bob'
        refute(schema.valid?(instance))
      end
    end

    pending = schema.partial_validate({ 'name' => 'alice', 'age' => UNKNOWN })
    assert_equal(:unknown, pending.status)
    assert_equal(:valid, schema.partial_validate({ 'name' => 'alice', 'age' => 1 }).status)
    assert_equal(:invalid, schema.partial_validate({ 'name' => 'alice', 'age' => 'x' }).status)
  end

  def test_progressive_replacement_converges
    schema = JSONSchemer.schema({
      'required' => %w[a b c],
      'properties' => {
        'a' => { 'type' => 'string' },
        'b' => { 'type' => 'integer' },
        'c' => { 'type' => 'boolean' }
      }
    })

    instance = { 'a' => UNKNOWN, 'b' => UNKNOWN, 'c' => UNKNOWN }
    assert_equal(:unknown, schema.partial_validate(instance).status)

    instance['a'] = 'x'
    assert_equal(:unknown, schema.partial_validate(instance).status)

    instance['b'] = 1
    assert_equal(:unknown, schema.partial_validate(instance).status)

    instance['c'] = true
    assert_equal(:valid, schema.partial_validate(instance).status)
    assert(schema.valid?(instance))
  end

  def test_unresolved_entries_have_locations
    result = partial(
      { 'properties' => { 'a' => { 'type' => 'string' } } },
      { 'a' => UNKNOWN }
    )
    entry = result.unresolved.first
    assert_equal('type', entry['keyword'])
    assert_equal('/a', entry['instance_location'])
    assert_equal('/properties/a/type', entry['schema_location'])
    assert_equal('value is unknown', entry['reason'])
  end
end
