require 'test_helper'

class SchemaMigrationTest < Minitest::Test
  def test_converts_draft4_equivalent_rules_and_preserves_annotations
    schema = {
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'title' => 'Draft 4 schema',
      'minimum' => 10,
      'exclusiveMinimum' => true,
      'maximum' => 20,
      'exclusiveMaximum' => false,
      'items' => [
        { 'type' => 'integer' }
      ],
      'additionalItems' => false,
      'dependencies' => {
        'a' => ['b'],
        'c' => { 'minProperties' => 2 }
      },
      'definitions' => {
        'number' => { 'type' => 'number' }
      },
      'properties' => {
        'value' => { '$ref' => '#/definitions/number' },
        'guarded' => { '$ref' => '#/definitions/number', 'minimum' => 5, '$id' => '#ignored', 'title' => 'Ref' }
      },
      'x-custom' => { 'keep' => true }
    }

    instances = [
      10,
      11,
      20,
      [1],
      [1, 2],
      ['x'],
      { 'value' => 1, 'guarded' => 1 },
      { 'value' => 1, 'guarded' => 4 },
      { 'a' => 1 },
      { 'a' => 1, 'b' => 2 },
      { 'c' => 1 },
      { 'c' => 1, 'd' => 2 }
    ]

    result = JSONSchemer.migrate_schema_to_202012(schema)
    assert(original_draft4_schema(schema).valid?([11]))
    assert_same_validity(instances, original_draft4_schema(schema), JSONSchemer.schema(result.schema))
    assert(result.equivalent?)
    assert(JSONSchemer.valid_schema?(result.schema))

    assert_equal('https://json-schema.org/draft/2020-12/schema', result.schema.fetch('$schema'))
    assert_equal(10, result.schema.fetch('exclusiveMinimum'))
    refute(result.schema.key?('minimum'))
    refute(result.schema.key?('exclusiveMaximum'))
    assert_equal([{ 'type' => 'integer' }], result.schema.fetch('prefixItems'))
    assert_equal(false, result.schema.fetch('items'))
    assert_equal({ 'a' => ['b'] }, result.schema.fetch('dependentRequired'))
    assert_equal({ 'c' => { 'minProperties' => 2 } }, result.schema.fetch('dependentSchemas'))
    assert_equal({ 'type' => 'number' }, result.schema.fetch('$defs').fetch('number'))
    assert_equal('#/$defs/number', result.schema.fetch('properties').fetch('value').fetch('$ref'))
    assert_equal('Draft 4 schema', result.schema.fetch('title'))
    assert_equal({ 'keep' => true }, result.schema.fetch('x-custom'))

    guarded = result.schema.fetch('properties').fetch('guarded')
    assert_equal('#/$defs/number', guarded.fetch('$ref'))
    assert_equal('Ref', guarded.fetch('title'))
    assert_equal(5, guarded.fetch('x-json-schemer-migration').fetch('ignored-ref-siblings').fetch('minimum'))
    assert_equal('#ignored', guarded.fetch('x-json-schemer-migration').fetch('ignored-ref-sibling-$id'))
    refute(guarded.key?('$id'))
    assert_includes(result.diagnostics.map { |diagnostic| diagnostic.fetch('pointer') }, '/properties/guarded/minimum')
    assert_includes(result.transforms.map { |transform| transform.fetch('from') }, '/items')
    assert_includes(result.transforms.map { |transform| transform.fetch('to') }, '/prefixItems')
  end

  def test_converts_draft7_tuples_dependencies_and_anchor
    schema = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'type' => 'array',
      'additionalItems' => { 'type' => 'number' },
      'dependencies' => {
        'a' => ['b'],
        'c' => { 'required' => ['d'] }
      },
      'definitions' => {
        'choice' => { '$id' => '#item', 'const' => 'ok' }
      },
      'items' => [{ '$ref' => '#item' }]
    }
    instances = [
      ['ok'],
      ['ok', 1],
      ['ok', 'bad'],
      [1],
      { 'a' => 1 },
      { 'a' => 1, 'b' => 2 },
      { 'c' => 1 },
      { 'c' => 1, 'd' => 2 }
    ]

    result = JSONSchemer.migrate_schema_to_202012(schema)
    assert_same_validity(instances, original_draft7_schema(schema), JSONSchemer.schema(result.schema))
    assert(result.equivalent?)
    assert(JSONSchemer.valid_schema?(result.schema))
    assert_equal('item', result.schema.fetch('$defs').fetch('choice').fetch('$anchor'))
    refute(result.schema.fetch('$defs').fetch('choice').key?('$id'))
    assert_equal('#item', result.schema.fetch('prefixItems').first.fetch('$ref'))
    assert_equal({ 'type' => 'number' }, result.schema.fetch('items'))
    assert_equal('ok', result.schema.fetch('$defs').fetch('choice').fetch('const'))
  end

  def test_reports_external_references_without_pretending_equivalence
    schema = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      '$ref' => 'https://example.com/schema#item'
    }

    result = JSONSchemer.migrate_schema_to_202012(schema)
    refute(result.equivalent?)
    assert_equal('https://example.com/schema#item', result.schema.fetch('$ref'))
    diagnostic = result.diagnostics.find { |item| item.fetch('pointer') == '/$ref' }
    assert_includes(diagnostic.fetch('message'), 'external reference')
  end

  def test_converts_local_plain_name_anchor_and_keeps_instance_results_equal
    schema = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'allOf' => [{ '$ref' => '#foo' }],
      'definitions' => {
        'A' => { '$id' => '#foo', 'type' => 'integer' }
      }
    }

    result = JSONSchemer.migrate_schema_to_202012(schema)
    assert_same_validity([1, 'a'], original_draft7_schema(schema), JSONSchemer.schema(result.schema))
    assert(result.equivalent?)
    assert_equal('foo', result.schema.fetch('$defs').fetch('A').fetch('$anchor'))
    assert_equal('#foo', result.schema.fetch('allOf').first.fetch('$ref'))
  end

  def test_reports_nested_embedded_reference_environment
    schema = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      '$id' => 'http://localhost:1234/root',
      'allOf' => [{ '$ref' => 'http://localhost:1234/nested.json#foo' }],
      'definitions' => {
        'A' => {
          '$id' => 'nested.json',
          'definitions' => {
            'B' => { '$id' => '#foo', 'type' => 'integer' }
          }
        }
      }
    }

    result = JSONSchemer.migrate_schema_to_202012(schema)
    refute(result.equivalent?)
    assert_equal('/allOf/0/$ref', result.diagnostics.first.fetch('pointer'))
    assert_equal('http://localhost:1234/nested.json', result.schema.fetch('$defs').fetch('A').fetch('$id'))
    assert_equal('foo', result.schema.fetch('$defs').fetch('A').fetch('$defs').fetch('B').fetch('$anchor'))
  end

  def test_preserves_unsupported_future_rules_as_data
    schema = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'type' => 'object',
      'unevaluatedProperties' => false
    }

    result = JSONSchemer.migrate_schema_to_202012(schema, source: 'draft7')
    assert(JSONSchemer.valid_schema?(result.schema))
    refute(result.schema.key?('unevaluatedProperties'))
    assert_equal(false, result.schema.fetch('x-json-schemer-migration').fetch('unevaluatedProperties'))
    assert_equal('/unevaluatedProperties', result.diagnostics.first.fetch('pointer'))
    assert_equal('warning', result.diagnostics.first.fetch('severity'))
  end

  def test_does_not_mutate_input
    schema = {
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'minimum' => 1,
      'exclusiveMinimum' => true,
      'items' => [{ 'type' => 'integer' }],
      'definitions' => { 'x' => { 'type' => 'string' } },
      'properties' => { 'x' => { '$ref' => '#/definitions/x' } }
    }

    JSONSchemer.migrate_schema_to_202012(schema)
    assert_equal('http://json-schema.org/draft-04/schema#', schema.fetch('$schema'))
    assert_equal(true, schema.fetch('exclusiveMinimum'))
    assert_equal(1, schema.fetch('minimum'))
    assert_equal([{ 'type' => 'integer' }], schema.fetch('items'))
    assert_equal('#/definitions/x', schema.fetch('properties').fetch('x').fetch('$ref'))
  end

  private

  def original_draft4_schema(schema)
    JSONSchemer.schema(schema, :meta_schema => JSONSchemer.draft4)
  end

  def original_draft7_schema(schema)
    JSONSchemer.schema(schema, :meta_schema => JSONSchemer.draft7)
  end

  def assert_same_validity(instances, original_schema, converted_schema)
    instances.each do |instance|
      original_valid = original_schema.valid?(instance)
      converted_valid = converted_schema.valid?(instance)
      assert_equal(
        original_valid,
        converted_valid,
        "expected #{instance.inspect} to be #{original_valid ? 'accepted' : 'rejected'} by both schemas"
      )
    end
  end
end
