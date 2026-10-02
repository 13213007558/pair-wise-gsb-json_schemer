require 'test_helper'

class SchemaMigratorTest < Minitest::Test
  def test_migrates_draft4_boundaries_tuples_and_dependencies
    source = {
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'maximum' => 3,
      'exclusiveMaximum' => true,
      'minimum' => 1,
      'exclusiveMinimum' => true,
      'items' => [
        { 'type' => 'integer' },
        { 'type' => 'string' }
      ],
      'additionalItems' => false,
      'dependencies' => {
        'a' => ['b'],
        'c' => { 'required' => ['d'] }
      },
      'title' => 'kept'
    }

    migration = JSONSchemer.migrate_to_202012(source)

    assert_equal(
      {
        'maximum' => 3,
        'exclusiveMaximum' => 3,
        'minimum' => 1,
        'exclusiveMinimum' => 1,
        'prefixItems' => [
          { 'type' => 'integer' },
          { 'type' => 'string' }
        ],
        'items' => false,
        'dependentRequired' => { 'a' => ['b'] },
        'dependentSchemas' => { 'c' => { 'required' => ['d'] } },
        'title' => 'kept',
        '$schema' => JSONSchemer::Draft202012::BASE_URI.to_s
      },
      migration.schema
    )
    assert(JSONSchemer.valid_schema?(migration.schema))
    assert_equal(7, migration.changes.length)

    instances = [
      0, 1, 2, 3, 4,
      [1, 'x'],
      [1, 'x', true],
      [1, 1],
      { 'a' => 1 },
      { 'a' => 1, 'b' => 2 },
      { 'c' => 1 },
      { 'c' => 1, 'd' => 2 }
    ]
    assert_equal(acceptance_results(source, instances, JSONSchemer.draft4), acceptance_results(migration.schema, instances))
  end

  def test_rewrites_definitions_refs_and_returns_positions
    source = {
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'definitions' => {
        'name' => { 'type' => 'string' }
      },
      'allOf' => [{ '$ref' => '#/definitions/name' }]
    }

    migration = JSONSchemer.migrate_to_202012(source)

    assert_equal('#/$defs/name', migration.schema.dig('allOf', 0, '$ref'))
    assert_equal('/definitions', migration.changes.find { |change| change['source_keyword'] == 'definitions' }['location'])
    assert_equal('/$defs', migration.changes.find { |change| change['source_keyword'] == 'definitions' }['destination_location'])
    assert_equal('/allOf/0/$ref', migration.changes.find { |change| change['source_keyword'] == '$ref' }['location'])

    instances = ['Ada', 42]
    assert_equal(acceptance_results(source, instances, JSONSchemer.draft4), acceptance_results(migration.schema, instances))
  end

  def test_preserves_ref_sibling_constraints_without_enforcing_them
    source = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'definitions' => {
        'name' => { 'type' => 'string' }
      },
      'properties' => {
        'name' => {
          '$ref' => '#/definitions/name',
          'maxItems' => 1,
          'description' => 'kept annotation',
          'x-tenant' => 'kept data'
        }
      }
    }

    migration = JSONSchemer.migrate_to_202012(source)
    ref_node = migration.schema.dig('properties', 'name')

    assert_equal('#/$defs/name', ref_node['$ref'])
    assert_equal('kept annotation', ref_node['description'])
    assert_equal('kept data', ref_node['x-tenant'])
    assert_equal(
      { 'maxItems' => 1 },
      ref_node['x-json-schemer-ignored-keywords']
    )
    assert(JSONSchemer.valid_schema?(migration.schema))

    diagnostic = migration.diagnostics.find { |item| item['location'] == '/properties/name/maxItems' }
    assert_equal('non-equivalent-rule', diagnostic['code'])
    assert_equal('warning', diagnostic['severity'])

    instances = [{ 'name' => ['a', 'b', 'c'] }, { 'name' => 1 }]
    assert_equal(acceptance_results(source, instances, JSONSchemer.draft7), acceptance_results(migration.schema, instances))
  end

  def test_preserves_unknown_fields_annotations_and_input
    source = {
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'description' => 'user note',
      'x-unknown' => { 'arbitrary' => ['data'] },
      'minimum' => 2
    }
    original = deep_dup(source)

    migration = JSONSchemer.migrate_to_202012(source)

    assert_equal(original, source)
    assert_equal('user note', migration.schema['description'])
    assert_equal({ 'arbitrary' => ['data'] }, migration.schema['x-unknown'])
    assert(JSONSchemer.valid_schema?(migration.schema))
  end

  def test_diagnoses_external_reference_environment
    source = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      '$ref' => 'https://example.com/schema#/definitions/thing'
    }

    migration = JSONSchemer.migrate_to_202012(source)

    assert_equal(source['$ref'], migration.schema['$ref'])
    assert_equal('external-reference', migration.diagnostics.first['code'])
    assert_equal('/$ref', migration.diagnostics.first['location'])
    refute(migration.equivalent?)
  end

  def test_migrates_anchors_and_escaped_definition_pointers
    source = {
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'definitions' => {
        'a/b' => { 'id' => '#thing', 'type' => 'string' }
      },
      'allOf' => [{ '$ref' => '#/definitions/a~1b' }]
    }

    migration = JSONSchemer.migrate_to_202012(source)

    assert_equal({ 'type' => 'string', '$anchor' => 'thing' }, migration.schema.dig('$defs', 'a/b'))
    assert_equal('#/$defs/a~1b', migration.schema.dig('allOf', 0, '$ref'))
    assert_equal('string', JSONSchemer.schema(migration.schema).ref('#thing').value['type'])
  end

  def test_preserves_rules_that_have_no_target_equivalent
    source = {
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'prefixItems' => [{ 'type' => 'string' }],
      'dependencies' => { 'bad' => 12 }
    }

    migration = JSONSchemer.migrate_to_202012(source)

    refute(migration.equivalent?)
    assert_equal(12, migration.schema.dig('x-json-schemer-ignored-keywords', 'dependencies/bad'))
    assert_equal(
      [{ 'type' => 'string' }],
      migration.schema.dig('x-json-schemer-ignored-keywords', 'prefixItems')
    )
    assert(JSONSchemer.valid_schema?(migration.schema))
  end

  def test_does_not_rewrite_pointer_inside_non_schema_data
    source = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'definitions' => { 'value' => { 'type' => 'string' } },
      'enum' => [{ '$ref' => '#/definitions/value' }]
    }

    migration = JSONSchemer.migrate_to_202012(source)

    assert_equal('#/definitions/value', migration.schema.dig('enum', 0, '$ref'))
    assert_equal('string', migration.schema.dig('$defs', 'value', 'type'))
  end

  def test_reports_diagnostics_for_unportable_reference_and_structures
    source = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      '$ref' => '#/missing',
      'contentEncoding' => 'base64',
      'allOf' => [42],
      'items' => [42],
      'definitions' => { 'bad' => 42 },
      '$id' => 'urn:x#/pointer'
    }

    migration = JSONSchemer.migrate_to_202012(source)
    locations = migration.diagnostics.map { |diagnostic| diagnostic['location'] }

    assert_includes(locations, '/contentEncoding')
    assert_includes(locations, '/allOf')
    assert_includes(locations, '/items')
    assert_includes(locations, '/definitions/bad')
    assert_includes(locations, '/$id')
    refute(migration.equivalent?)
    assert(JSONSchemer.valid_schema?(migration.schema))
  end

  def test_invalid_ref_values_and_local_pointer_diagnostics
    source = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'allOf' => [
        { '$ref' => 12 },
        { '$ref' => 'https://example.com/schema#/definitions/a' },
        { '$ref' => '#/%2' }
      ]
    }

    migration = JSONSchemer.migrate_to_202012(source)
    codes = migration.diagnostics.map { |diagnostic| diagnostic['code'] }

    assert_equal(%w[invalid-ref external-reference invalid-ref], codes)
    assert_equal(12, migration.schema.dig('allOf', 0, '$ref'))
    assert_equal('#/%2', migration.schema.dig('allOf', 2, '$ref'))
  end

  def test_handles_identifiers_content_and_unsupported_dialects
    draft6 = JSONSchemer.migrate_to_202012({
      '$schema' => 'http://json-schema.org/draft-06/schema#',
      '$id' => 'https://example.com/a#thing',
      'contentEncoding' => 'base64'
    })
    assert_equal('https://example.com/a', draft6.schema['$id'])
    assert_equal('thing', draft6.schema['$anchor'])
    assert_equal('base64', draft6.schema['contentEncoding'])

    invalid_id = JSONSchemer.migrate_to_202012({
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'id' => 'bad anchor'
    })
    refute(invalid_id.equivalent?)
    assert(JSONSchemer.valid_schema?(invalid_id.schema))

    unsupported = JSONSchemer.migrate_to_202012({ '$schema' => 'https://x.test/custom' }, from: '2019-09')
    refute(unsupported.equivalent?)
    assert_equal('2019-09', unsupported.source)
  end

  def test_migration_result_hash_and_string_input
    migration = JSONSchemer.migrate_to_202012('{"$schema":"http://json-schema.org/draft-07/schema#","minimum":1}')

    assert_equal(1, migration.to_h['schema']['minimum'])
    assert_equal('draft7', migration.to_h['source'])
  end

  def test_nested_target_schema_is_not_recursively_rewritten
    source = {
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'definitions' => { 'outer' => { 'type' => 'integer' } },
      'properties' => {
        'mixed' => {
          '$schema' => 'https://json-schema.org/draft/2020-12/schema',
          '$ref' => '#/definitions/outer'
        }
      }
    }

    migration = JSONSchemer.migrate_to_202012(source)

    assert_equal('#/definitions/outer', migration.schema.dig('properties', 'mixed', '$ref'))
    assert_equal('https://json-schema.org/draft/2020-12/schema', migration.schema.dig('properties', 'mixed', '$schema'))
  end

  def test_remaining_diagnostic_and_transform_branches
    assert_equal(
      '2020-12',
      JSONSchemer::SchemaMigrator.migrate({ '$schema' => JSONSchemer::Draft202012::BASE_URI.to_s }).source
    )
    assert(JSONSchemer::SchemaMigrator.migrate(true, from: 'draft7').equivalent?)

    root_boolean = JSONSchemer.migrate_to_202012(true, from: 'draft4')
    refute(root_boolean.equivalent?)
    assert_equal(true, root_boolean.schema)

    invalid_source = JSONSchemer.migrate_to_202012(12, from: 'draft7')
    refute(invalid_source.equivalent?)

    draft4 = JSONSchemer.migrate_to_202012({
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'maximum' => 3,
      'exclusiveMaximum' => false,
      'minimum' => 1,
      'exclusiveMinimum' => true,
      'id' => 5,
      'items' => [],
      'additionalItems' => 42,
      'dependencies' => { 'dup' => ['a', 'a'], 'bad' => 5 },
      'not' => 42,
      'properties' => 'no',
      'allOf' => [42]
    })
    assert(draft4.schema.key?('maximum'))
    refute(draft4.schema.key?('exclusiveMaximum'))
    assert_equal(1, draft4.schema['exclusiveMinimum'])
    assert_equal(['a'], draft4.schema.dig('dependentRequired', 'dup'))
    refute(draft4.equivalent?)
    assert(JSONSchemer.valid_schema?(draft4.schema))

    dependency_ref = JSONSchemer.migrate_to_202012({
      '$schema' => 'http://json-schema.org/draft-04/schema#',
      'dependencies' => { 'a' => ['b'], 'c' => { 'type' => 'object' } },
      'oneOf' => [
        { '$ref' => '#/dependencies/a' },
        { '$ref' => '#/dependencies/c' }
      ]
    })
    assert_equal('#/dependentRequired/a', dependency_ref.schema.dig('oneOf', 0, '$ref'))
    assert_equal('#/dependentSchemas/c', dependency_ref.schema.dig('oneOf', 1, '$ref'))

    tuple_ref = JSONSchemer.migrate_to_202012({
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'items' => [{ 'type' => 'integer' }],
      'additionalItems' => { 'type' => 'string' },
      'allOf' => [{ '$ref' => '#/items/0' }]
    })
    assert_equal('#/prefixItems/0', tuple_ref.schema.dig('allOf', 0, '$ref'))
    assert_equal({ 'type' => 'string' }, tuple_ref.schema['items'])

    collision = JSONSchemer.migrate_to_202012({
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'definitions' => { 'a' => { 'type' => 'string' } },
      '$defs' => { 'a' => { 'type' => 'integer' } }
    })
    assert_equal('string', collision.schema.dig('$defs', 'a', 'type'))
    assert_equal(
      { 'a' => { 'type' => 'integer' } },
      collision.schema.dig('x-json-schemer-ignored-keywords', '$defs')
    )
  end

  def test_invalid_source_shapes_are_retained_and_diagnosed
    string = JSONSchemer.migrate_to_202012('{"minimum":1}')
    assert_equal(1, string.schema['minimum'])

    inferred_false = JSONSchemer.migrate_to_202012({ 'maximum' => 3, 'exclusiveMaximum' => false })
    assert_equal('draft4', inferred_false.source)

    inferred_true = JSONSchemer.migrate_to_202012({})
    assert_equal('draft7', inferred_true.source)

    draft6_alias = JSONSchemer.migrate_to_202012({}, from: 6)
    assert_equal('draft6', draft6_alias.source)

    invalid_root = JSONSchemer.migrate_to_202012(12, from: 'draft7')
    refute(invalid_root.equivalent?)

    nested = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        'properties' => {
          'nested' => { '$schema' => 'http://json-schema.org/draft-06/schema#', 'contains' => { 'type' => 'integer' } },
          'foreign' => { '$schema' => 'custom-dialect' }
        }
      }
    )
    refute(nested.equivalent?)

    shape_migration = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-04/schema#',
        'minimum' => 1,
        'exclusiveMinimum' => true,
        'maximum' => 3,
        'exclusiveMaximum' => 'nope',
        'id' => '',
        'additionalItems' => 42,
        'items' => [{ 'type' => 'string' }],
        'dependencies' => [],
        'definitions' => [],
        'properties' => { 'bad' => 42 }
      }
    )
    refute(shape_migration.equivalent?)
    assert(JSONSchemer.valid_schema?(shape_migration.schema))

    d7_content = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        'contentEncoding' => 'base64'
      }
    )
    assert_equal('base64', d7_content.schema.dig('x-json-schemer-ignored-keywords', 'contentEncoding'))

    escaped_pointer = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        'definitions' => { 'a' => { 'type' => 'string' } },
        'allOf' => [{ '$ref' => '#/definitions/a%22' }]
      }
    )
    assert_equal('#/$defs/a%22', escaped_pointer.schema.dig('allOf', 0, '$ref'))

    array_pointer = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        'definitions' => { 'a' => { 'type' => 'string' } },
        'items' => [{ '$ref' => '#/definitions/a' }],
        'oneOf' => [{ '$ref' => '#/definitions/a' }]
      }
    )
    assert_equal('#/$defs/a', array_pointer.schema.dig('oneOf', 0, '$ref'))
    assert_equal('#/$defs/a', array_pointer.schema.dig('prefixItems', 0, '$ref'))

    missing_boundary = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-04/schema#',
        'exclusiveMaximum' => true,
        'id' => 'https://example.com/base#bad-anchor!'
      }
    )
    refute(missing_boundary.equivalent?)
    assert_equal('https://example.com/base', missing_boundary.schema['$id'])

    invalid_nested = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        '$ref' => 12
      }
    )
    refute(invalid_nested.equivalent?)

    pointer_id = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-04/schema#',
        'id' => 'https://example.com/base#/definitions/x'
      }
    )
    assert_equal('https://example.com/base', pointer_id.schema['$id'])
    refute(pointer_id.equivalent?)

    empty_id = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-04/schema#',
        'id' => '#bad-anchor!'
      }
    )
    assert_equal('#bad-anchor!', empty_id.schema.dig('x-json-schemer-ignored-keywords', 'id'))

    plain_empty_id = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-04/schema#',
        'id' => ''
      }
    )
    refute(plain_empty_id.schema.key?('$id'))

    invalid_definition_ref = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        '$ref' => '#/definitions/ok',
        'definitions' => { 'ok' => { 'type' => 'string' }, 'bad' => 42 }
      }
    )
    refute(invalid_definition_ref.equivalent?)

    final_edge = JSONSchemer.migrate_to_202012(
      {
        '$schema' => 'http://json-schema.org/draft-07/schema#',
        'definitions' => { 'bad' => 42, 'nested' => { '$defs' => { 'x' => true } } },
        'allOf' => [{ '$ref' => '#' }, { '$ref' => 'foo' }, { '$ref' => '#/%%' }, { '$ref' => '#/%FF' }],
        'x-json-schemer-ignored-keywords' => { 'definitions/bad' => 'old' }
      }
    )
    refute(final_edge.equivalent?)
    assert(final_edge.schema.key?('x-json-schemer-ignored-keywords'))
  end

  private

  def acceptance_results(schema, instances, meta_schema = nil)
    schemer = meta_schema ? JSONSchemer.schema(schema, meta_schema: meta_schema) : JSONSchemer.schema(schema)
    instances.map { |instance| schemer.valid?(instance) }
  end

  def deep_dup(value)
    case value
    when Hash
      value.each_with_object({}) { |(key, item), result| result[key] = deep_dup(item) }
    when Array
      value.map { |item| deep_dup(item) }
    else
      value
    end
  end
end
