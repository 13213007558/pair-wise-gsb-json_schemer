require 'test_helper'

class PartialValidationTest < Minitest::Test
  UNKNOWN = JSONSchemer::PartialValidation::UNKNOWN

  def test_explicit_unknown_is_distinct_from_missing_and_null
    schema = JSONSchemer.schema({
      'type' => 'object',
      'required' => ['name'],
      'properties' => { 'name' => { 'type' => ['string', 'null'] } }
    })

    pending = schema.partial_validate(UNKNOWN)
    assert_equal('pending', pending.fetch('status'))
    assert_nil(pending.fetch('valid'))
    keywords = pending.fetch('unresolved').map { |item| item.fetch('keyword') }.uniq.sort
    assert_equal(%w[properties required type], keywords)

    assert_equal('invalid', schema.partial_validate({}).fetch('status'))
    assert_equal('valid', schema.partial_validate({ 'name' => nil }).fetch('status'))
    assert_equal('invalid', schema.partial_validate({ 'name' => 1 }).fetch('status'))
  end

  def test_type_enum_and_const_report_pending_only_for_applicable_unknowns
    schema = JSONSchemer.schema({
      'type' => ['string', 'null'],
      'enum' => ['x', nil],
      'const' => 'x'
    })

    pending = schema.partial_validate(UNKNOWN)
    assert_equal('pending', pending.fetch('status'))
    assert_equal(%w[const enum type], pending.fetch('unresolved').map { |item| item.fetch('keyword') }.sort)
    assert_equal('valid', schema.partial_validate('x').fetch('status'))
    assert_equal('invalid', schema.partial_validate(nil).fetch('status'))

    nested = JSONSchemer.schema({
      'type' => 'object',
      'properties' => {
        'known' => { 'type' => 'integer' },
        'choice' => { 'enum' => %w[a b] }
      }
    })
    assert_equal('invalid', nested.partial_validate({ 'known' => 'x', 'marker' => UNKNOWN }).fetch('status'))
    assert_equal('pending', nested.partial_validate({ 'known' => 1, 'choice' => UNKNOWN }).fetch('status'))
  end

  def test_object_properties_locate_each_unresolved_value
    schema = JSONSchemer.schema({
      'type' => 'object',
      'properties' => {
        'name' => { 'type' => 'string' },
        'address' => {
          'required' => ['city'],
          'properties' => { 'city' => { 'type' => 'string' } }
        }
      },
      'patternProperties' => {
        '^tag-' => { 'type' => 'string' }
      },
      'additionalProperties' => false
    })
    instance = {
      'name' => UNKNOWN,
      'address' => { 'city' => UNKNOWN },
      'tag-a' => UNKNOWN
    }

    result = schema.partial_validate(instance)
    assert_equal('pending', result.fetch('status'))
    locations = result.fetch('unresolved').map { |item| item.fetch('instanceLocation') }.sort
    assert_equal(['/address/city', '/name', '/tag-a'], locations)
    assert_equal('invalid', schema.partial_validate(instance.merge('extra' => 1)).fetch('status'))
  end

  def test_array_positions_are_validated_independently
    schema = JSONSchemer.schema({
      'prefixItems' => [{ 'type' => 'string' }, { 'type' => 'integer' }],
      'items' => false
    })

    pending = schema.partial_validate(['x', UNKNOWN])
    assert_equal('/1', pending.fetch('unresolved').first.fetch('instanceLocation'))
    assert_equal('valid', schema.partial_validate(['x', 1]).fetch('status'))
    assert_equal('invalid', schema.partial_validate(['x', 1, true]).fetch('status'))

    draft4 = JSONSchemer.schema(
      {
        'items' => [{ 'type' => 'string' }, { 'type' => 'integer' }],
        'additionalItems' => false
      },
      :meta_schema => JSONSchemer::Draft4::BASE_URI.to_s
    )
    assert_equal('pending', draft4.partial_validate(['x', UNKNOWN]).fetch('status'))
    assert_equal('invalid', draft4.partial_validate(['x', 1, true]).fetch('status'))
  end

  def test_applicator_keywords_have_reliable_definite_results
    schema = JSONSchemer.schema({
      'allOf' => [{ 'type' => 'string' }, { 'maxLength' => 3 }],
      'anyOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }],
      'oneOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }],
      'not' => { 'type' => 'boolean' }
    })

    assert_equal('pending', schema.partial_validate(UNKNOWN).fetch('status'))
    assert_equal('invalid', schema.partial_validate(true).fetch('status'))
    assert_equal('valid', schema.partial_validate('x').fetch('status'))
    assert_equal('invalid', schema.partial_validate('toolong').fetch('status'))

    duplicate = JSONSchemer.schema({
      'oneOf' => [{ 'type' => 'string' }, { 'enum' => ['x'] }]
    })
    assert_equal('invalid', duplicate.partial_validate('x').fetch('status'))

    none_match = JSONSchemer.schema({
      'anyOf' => [{ 'type' => 'integer' }, { 'type' => 'boolean' }]
    })
    assert_equal('invalid', none_match.partial_validate('x').fetch('status'))
  end

  def test_references_are_followed_and_dynamic_references_are_unsupported
    schema = JSONSchemer.schema({
      '$defs' => { 'name' => { 'type' => 'string' } },
      'properties' => { 'name' => { '$ref' => '#/$defs/name' } }
    })
    result = schema.partial_validate({ 'name' => UNKNOWN })
    assert_equal('pending', result.fetch('status'))
    assert_equal('type', result.fetch('unresolved').first.fetch('keyword'))

    dynamic = JSONSchemer.schema({ '$dynamicRef' => '#item' })
    result = dynamic.partial_validate(UNKNOWN)
    assert_equal('unsupported dynamic reference', result.fetch('unresolved').first.fetch('reason'))
  end

  def test_unsupported_built_in_and_custom_rules_are_conservative
    schema = JSONSchemer.schema({ 'type' => 'string', 'minLength' => 2 })
    pending = schema.partial_validate(UNKNOWN)
    assert_equal('pending', pending.fetch('status'))
    assert_equal(%w[minLength type], pending.fetch('unresolved').map { |item| item.fetch('keyword') }.sort)

    assert_equal('valid', schema.partial_validate('ok').fetch('status'))
    assert_equal('invalid', schema.partial_validate('x').fetch('status'))

    custom = JSONSchemer.schema(
      { 'even' => true },
      :keywords => { 'even' => proc { |value| value.to_i.even? } }
    )
    result = custom.partial_validate(UNKNOWN)
    assert_equal('even', result.fetch('unresolved').first.fetch('keyword'))
    assert_equal('unsupported keyword', result.fetch('unresolved').first.fetch('reason'))
  end

  def test_no_unknowns_returns_the_same_result_as_the_regular_validator
    schemas = [
      { 'type' => 'string' },
      { 'enum' => ['x', 1, nil, [1], { 'a' => 1 }] },
      { 'type' => 'object', 'required' => ['a'] },
      { 'properties' => { 'a' => { 'type' => 'string' } }, 'additionalProperties' => false },
      { 'prefixItems' => [{ 'type' => 'string' }], 'items' => { 'type' => 'integer' } },
      { 'allOf' => [{ 'type' => 'string' }, { 'maxLength' => 3 }] },
      { 'anyOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }] },
      { 'oneOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }] },
      { 'not' => { 'type' => 'boolean' } }
    ].map { |schema| JSONSchemer.schema(schema) }
    values = [nil, true, 1, 'x', [], [1], {}, { 'a' => 1 }]

    schemas.product(values).each do |schema, value|
      result = schema.partial_validate(value)
      assert_equal(schema.valid?(value), result.fetch('valid'))
    end
  end

  def test_replacing_every_unknown_converges_exhaustively
    schema = JSONSchemer.schema({
      'type' => 'object',
      'required' => %w[kind count],
      'properties' => {
        'kind' => { 'enum' => %w[small large] },
        'count' => { 'type' => 'integer' },
        'tags' => {
          'prefixItems' => [{ 'type' => 'string' }],
          'items' => { 'type' => 'integer' }
        }
      },
      'allOf' => [
        { 'anyOf' => [
          { 'properties' => { 'kind' => { 'const' => 'small' } } },
          { 'properties' => { 'kind' => { 'const' => 'large' } }, 'not' => { 'type' => 'array' } }
        ] }
      ]
    })
    candidates = [nil, 1, 'small', 'large', [], [1]]
    partial = { 'kind' => UNKNOWN, 'count' => UNKNOWN, 'tags' => [UNKNOWN] }

    expand = lambda do |value|
      case value
      when UNKNOWN
        candidates
      when Hash
        value.keys.reduce([{}]) do |instances, key|
          instances.product(expand.call(value.fetch(key))).map { |instance, child| instance.merge(key => child) }
        end
      when Array
        value.reduce([[]]) do |instances, child|
          instances.product(expand.call(child)).map { |instance, item| instance + [item] }
        end
      else
        [value]
      end
    end

    assert_equal('pending', schema.partial_validate(partial).fetch('status'))
    expand.call(partial).each do |instance|
      result = schema.partial_validate(instance)
      refute_equal('pending', result.fetch('status'))
      assert_equal(schema.valid?(instance), result.fetch('valid'), instance.inspect)
    end
  end

  def test_top_level_api_and_placeholder_inspection
    result = JSONSchemer.partial_validate({ 'type' => 'string' }, UNKNOWN)
    assert_equal('pending', result.fetch('status'))
    assert_nil(result.fetch('valid'))
    assert_equal('JSONSchemer::PartialValidation::UNKNOWN', UNKNOWN.inspect)
    assert_equal(UNKNOWN.to_s, UNKNOWN.inspect)
  end
end
