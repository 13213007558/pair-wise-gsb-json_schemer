require "test_helper"

class CoverageTest < Minitest::Test
  def report(schema, instances, observer = JSONSchemer::Coverage::Observer.new, **options)
    schemer = schema.is_a?(JSONSchemer::Schema) ? schema : JSONSchemer.schema(schema, **options)
    instances.each { |instance| schemer.valid?(instance, :coverage_observer => observer) }
    [schemer, observer.report(schemer)]
  end

  def entry(entries, pointer)
    entries.find { |entry| entry[:pointer] == pointer }
  end

  def test_dataset_that_misses_a_branch_points_to_the_uncovered_location
    schema = {
      'oneOf' => [
        { 'type' => 'integer' },
        { 'type' => 'string' },
        { 'const' => true }
      ]
    }
    _schemer, report = report(schema, [1, 'a', 2, 'b'])

    missed = report[:uncovered]
    assert_equal(['#/oneOf/2'], missed.map { |entry| entry[:pointer] })
    assert_equal('oneOf', missed.first[:keyword])
    assert_equal(2, missed.first[:branch])
    assert_equal('never matched', missed.first[:reason])
    assert_in_delta(2.0 / 3.0, report[:coverage])

    branches = report[:branches].map { |entry| [entry[:pointer], entry[:attempts], entry[:passed], entry[:failed]] }
    assert_includes(branches, ['#/oneOf/0', 4, 2, 2])
    assert_includes(branches, ['#/oneOf/1', 4, 2, 2])
    assert_includes(branches, ['#/oneOf/2', 4, 0, 4])
  end

  def test_keyword_attempts_pass_and_fail
    schema = { 'oneOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }] }
    _schemer, report = report(schema, [1, 'a', true])

    keyword = entry(report[:keywords], '#/oneOf/0/type')
    assert_equal(3, keyword[:attempts])
    assert_equal(1, keyword[:passed])
    assert_equal(2, keyword[:failed])
    assert_equal(0, keyword[:skipped])
  end

  def test_if_then_else_coverage_and_skips
    schema = {
      'if' => { 'type' => 'object' },
      'then' => { 'required' => ['a'] },
      'else' => { 'type' => 'string' }
    }
    _schemer, report = report(schema, [{ 'a' => 1 }, { 'a' => 2 }, 'str'])

    assert_equal(3, report[:branches].size)
    assert_equal(3, entry(report[:branches], '#/if')[:attempts])
    assert_equal(2, entry(report[:branches], '#/then')[:attempts])
    assert_equal(1, entry(report[:branches], '#/else')[:attempts])

    then_keyword = entry(report[:keywords], '#/then')
    else_keyword = entry(report[:keywords], '#/else')
    assert_equal(2, then_keyword[:attempts])
    assert_equal(1, then_keyword[:skipped])
    assert_equal(['if was false'], then_keyword[:skip_reasons])
    assert_equal(1, else_keyword[:attempts])
    assert_equal(2, else_keyword[:skipped])
    assert_equal(['if was true'], else_keyword[:skip_reasons])
    assert_empty(report[:uncovered])
    assert_equal(1.0, report[:coverage])
  end

  def test_else_without_if_is_skipped_and_uncovered
    schema = { 'else' => { 'type' => 'string' } }
    _schemer, report = report(schema, [1, 's'])

    assert_equal(['#/else'], report[:uncovered].map { |entry| entry[:pointer] })
    else_keyword = entry(report[:keywords], '#/else')
    assert_nil(else_keyword)
    skip_event = observer_skip_events(schema, [1]).first
    assert_equal('no if keyword', skip_event[:reason])
  end

  def test_short_circuit_records_remaining_keywords_as_skipped
    schema = { 'type' => 'integer', 'required' => ['a'] }
    schemer = JSONSchemer.schema(schema)
    observer = JSONSchemer::Coverage::Observer.new
    refute(schemer.valid?('x', :coverage_observer => observer))
    report = observer.report(schemer)

    required = entry(report[:keywords], '#/required')
    assert_nil(required)
    skip = observer.events.find { |event| event[:type] == :skip && event[:schema_pointer] == '/required' }
    assert_equal('short circuit', skip[:reason])
  end

  def test_recursive_ref_does_not_expand_infinitely
    schema = {
      'type' => 'object',
      'properties' => {
        'children' => { 'type' => 'array', 'items' => { '$ref' => '#' } }
      }
    }
    schemer = JSONSchemer.schema(schema)
    observer = JSONSchemer::Coverage::Observer.new
    instance = { 'children' => [{ 'children' => [{}] }] }
    assert(schemer.valid?(instance, :coverage_observer => observer))
    report = observer.report(schemer)

    ref_entry = entry(report[:refs], '#/properties/children/items/$ref')
    assert_equal(2, ref_entry[:calls])
    assert_equal([{ :pointer => '#', :calls => 2 }], ref_entry[:targets])
    assert_empty(report[:uncovered])
  end

  def test_same_target_from_two_call_sites_is_separate
    schema = {
      'allOf' => [{ '$ref' => '#/$defs/num' }],
      'oneOf' => [{ '$ref' => '#/$defs/num' }, { 'type' => 'integer' }],
      '$defs' => { 'num' => { 'type' => 'number' } }
    }
    _schemer, report = report(schema, [1.5, 1])

    refs = report[:refs].map { |ref_entry| [ref_entry[:pointer], ref_entry[:calls], ref_entry[:targets]] }
    assert_includes(refs, ['#/allOf/0/$ref', 2, [{ :pointer => '#/$defs/num', :calls => 2 }]])
    assert_includes(refs, ['#/oneOf/0/$ref', 2, [{ :pointer => '#/$defs/num', :calls => 2 }]])
  end

  def test_unreached_ref_call_site_is_uncovered
    schema = {
      'properties' => {
        'a' => { '$ref' => '#/$defs/num' },
        'b' => { '$ref' => '#/$defs/num' }
      },
      '$defs' => { 'num' => { 'type' => 'number' } }
    }
    _schemer, report = report(schema, [{ 'a' => 1 }])

    assert_equal(
      [{ :pointer => '#/properties/b/$ref', :keyword => '$ref', :reason => 'reference call site never reached' }],
      report[:uncovered]
    )
  end

  def test_format_checker_called_once_per_validation
    calls = 0
    format_proc = proc { |instance, _value| calls += 1; instance.is_a?(String) }
    schema = { 'format' => 'x' }
    schemer = JSONSchemer.schema(schema, :formats => { 'x' => format_proc })
    observer = JSONSchemer::Coverage::Observer.new

    assert(schemer.valid?('hi', :coverage_observer => observer))
    refute(schemer.valid?(42, :coverage_observer => observer))
    assert_equal(2, calls)

    report = observer.report
    keyword = entry(report[:keywords], '#/format')
    assert_equal(2, keyword[:attempts])
    assert_equal(1, keyword[:passed])
    assert_equal(1, keyword[:failed])
  end

  def test_default_validation_records_nothing
    schema = { 'oneOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }] }
    schemer = JSONSchemer.schema(schema)
    observer = JSONSchemer::Coverage::Observer.new

    assert(schemer.valid?(1))
    assert(schemer.valid?('a'))
    assert_empty(observer.events)
    assert_equal({ :keywords => [], :branches => [], :refs => [], :uncovered => [], :coverage => 1.0 }, observer.report)
    schemer = JSONSchemer.schema({ 'type' => 'integer' })
    assert_equal(1.0, observer.report(schemer)[:coverage])
    assert_equal(1.0, observer.report(JSONSchemer.schema({ 'type' => 'string' }))[:coverage])
  end

  def test_stable_locations_across_observers
    schema = { 'oneOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }] }
    first = JSONSchemer::Coverage::Observer.new
    second = JSONSchemer::Coverage::Observer.new
    schemer = JSONSchemer.schema(schema)

    schemer.valid?(1, :coverage_observer => first)
    schemer.valid?(1, :coverage_observer => second)

    assert_equal(first.report(schemer)[:branches], second.report(schemer)[:branches])
  end

  def test_report_with_multiple_schemas_requires_argument
    first = JSONSchemer.schema({ 'type' => 'integer' })
    second = JSONSchemer.schema({ 'type' => 'string' })
    observer = JSONSchemer::Coverage::Observer.new
    first.valid?(1, :coverage_observer => observer)
    second.valid?('a', :coverage_observer => observer)

    error = assert_raises(ArgumentError) { observer.report }
    assert_match(/multiple schemas/, error.message)
    assert_equal(1.0, observer.report(first)[:coverage])
  end

  def test_boolean_schema_branches
    schema = {
      'oneOf' => [true, false]
    }
    _schemer, report = report(schema, [42])

    assert_equal(['#/oneOf/1'], report[:uncovered].map { |entry| entry[:pointer] })
    assert_equal('never matched', report[:uncovered].first[:reason])
  end

  def test_draft4_exclusive_ref_walks_definitions_only
    schema = {
      '$ref' => '#/definitions/num',
      'definitions' => { 'num' => { 'type' => 'number' } }
    }
    _schemer, report = report(schema, [1], JSONSchemer::Coverage::Observer.new, :meta_schema => JSONSchemer::Draft4::BASE_URI.to_s)

    assert_equal(['#/$ref'], report[:refs].map { |entry| entry[:pointer] })
    assert_empty(report[:uncovered])
  end

  def test_draft4_exclusive_ref_to_definition_with_nested_branch
    schema = {
      '$ref' => '#/definitions/pair',
      'definitions' => {
        'pair' => { 'oneOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }] }
      }
    }
    _schemer, report = report(schema, [1], JSONSchemer::Coverage::Observer.new, :meta_schema => JSONSchemer::Draft4::BASE_URI.to_s)
    assert_equal(['#/definitions/pair/oneOf/1'], report[:uncovered].map { |entry| entry[:pointer] })
  end

  def test_draft4_dependencies_mixed_values
    schema = {
      'dependencies' => {
        'a' => ['b'],
        'c' => { 'required' => ['d'] }
      }
    }
    _schemer, report = report(schema, [{ 'a' => 1 }, { 'c' => 1, 'd' => 2 }])
    assert_empty(report[:uncovered])
  end

  def test_non_combination_array_items_walked
    schema = { 'prefixItems' => [{ 'type' => 'integer' }, { 'type' => 'string' }] }
    _schemer, report = report(schema, [[1, 'a']])
    assert_empty(report[:uncovered])
  end

  def test_draft7_array_items_walked
    schema = { 'items' => [{ 'oneOf' => [{ 'type' => 'integer' }, { 'type' => 'string' }] }] }
    _schemer, report = report(schema, [[1], [2]], JSONSchemer::Coverage::Observer.new, :meta_schema => JSONSchemer::Draft7::BASE_URI.to_s)
    assert_equal(['#/items/0/oneOf/1'], report[:uncovered].map { |entry| entry[:pointer] })
  end

  def test_coverage_does_not_change_errors_for_covered_keywords
    schema = {
      'if' => { 'type' => 'object' },
      'then' => { 'required' => ['a'] },
      'else' => { 'type' => 'string' },
      'dependentSchemas' => { 'a' => { 'required' => ['b'] } },
      'patternProperties' => { 'x' => { 'type' => 'integer' } },
      'propertyNames' => { 'maxLength' => 2 },
      'properties' => { 'list' => { 'prefixItems' => [{ 'type' => 'integer' }] } }
    }
    schemer = JSONSchemer.schema(schema)
    observer = JSONSchemer::Coverage::Observer.new
    instances = [
      { 'x' => 'nope', 'long' => 1, 'list' => ['nope'] },
      { 'a' => 1 }, # triggers dependentSchemas a->b failure
      {} # object so `if` applies, but missing required `a` so `then` fails
    ]
    instances.each do |instance|
      refute(schemer.validate(instance, :output_format => 'basic', :coverage_observer => observer)['valid'])
    end
    report = observer.report(schemer)
    assert(entry(report[:keywords], '#/then/required')[:failed] >= 1)
    assert(entry(report[:keywords], '#/dependentSchemas/a/required')[:failed] >= 1)
    assert_equal(1, entry(report[:keywords], '#/properties/list/prefixItems/0/type')[:failed])
    pattern_keyword = report[:keywords].find { |keyword| keyword[:pointer].start_with?('#/patternProperties/') && keyword[:keyword] == 'type' }
    assert_equal(1, pattern_keyword[:failed])
    assert(entry(report[:keywords], '#/propertyNames/maxLength')[:failed] >= 1)
  end

  def test_error_messages_unchanged_while_observing
    schema = {
      'if' => { 'type' => 'object' },
      'then' => { 'required' => ['a'] },
      'else' => { 'type' => 'string' },
      'dependentSchemas' => { 'a' => { 'required' => ['b'] } },
      'patternProperties' => { 'x' => { 'type' => 'integer' } },
      'propertyNames' => { 'maxLength' => 2 },
      'properties' => { 'list' => { 'prefixItems' => [{ 'type' => 'integer' }] } }
    }
    schemer = JSONSchemer.schema(schema)
    observer = JSONSchemer::Coverage::Observer.new
    messages = []
    [
      { 'x' => 'nope', 'long' => 1, 'list' => ['nope'] },
      { 'a' => 1 },
      {},
      1
    ].each do |invalid|
      verbose = schemer.validate(invalid, :output_format => 'verbose', :coverage_observer => observer)
      collect_errors(verbose, messages)
    end
    assert(messages.any? { |message| message.include?('conditional `then` schema') })
    assert(messages.any? { |message| message.include?('conditional `else` schema') })
    assert(messages.any? { |message| message.include?('applicable `dependentSchemas` schemas') })
    assert(messages.any? { |message| message.include?('corresponding `prefixItems` schemas') })
    assert(messages.any? { |message| message.include?('corresponding `patternProperties` schemas') })
    assert(messages.any? { |message| message.include?('do not match `propertyNames` schema') })
  end

  def test_dynamic_ref_records_resolved_target
    schema = {
      'properties' => {
        'v' => { '$dynamicRef' => '#other' }
      },
      '$defs' => {
        'inner' => { '$dynamicAnchor' => 'meta', 'type' => 'integer' },
        'other' => { '$anchor' => 'other', 'type' => 'string' }
      }
    }
    schemer = JSONSchemer.schema(schema)
    observer = JSONSchemer::Coverage::Observer.new
    assert(schemer.valid?({ 'v' => 'a' }, :coverage_observer => observer))
    ref_entry = entry(observer.report(schemer)[:refs], '#/properties/v/$dynamicRef')
    assert_equal(1, ref_entry[:calls])
    assert_equal('#/$defs/other', ref_entry[:targets].first[:pointer])
  end

  def test_dynamic_ref_without_anchor_records_target
    schema = {
      '$defs' => { 'num' => { 'type' => 'integer' } },
      'properties' => { 'v' => { '$dynamicRef' => '#/$defs/num' } }
    }
    schemer = JSONSchemer.schema(schema)
    observer = JSONSchemer::Coverage::Observer.new
    assert(schemer.valid?({ 'v' => 1 }, :coverage_observer => observer))
    ref_entry = entry(observer.report(schemer)[:refs], '#/properties/v/$dynamicRef')
    assert_equal(1, ref_entry[:calls])
    assert_equal('#/$defs/num', ref_entry[:targets].first[:pointer])
  end

  def test_recursive_ref_records_target
    schema = {
      '$id' => 'https://example.com/tree',
      'type' => 'object',
      'properties' => {
        'child' => { '$recursiveRef' => '#' }
      }
    }
    schemer = JSONSchemer.schema(schema, :meta_schema => JSONSchemer::Draft201909::BASE_URI.to_s)
    observer = JSONSchemer::Coverage::Observer.new
    assert(schemer.valid?({ 'child' => {} }, :coverage_observer => observer))
    ref_entry = entry(observer.report(schemer)[:refs], '#/properties/child/$recursiveRef')
    assert_equal(1, ref_entry[:calls])
  end

  def test_refs_work_without_observer
    schema = {
      'type' => 'object',
      'properties' => { 'v' => { '$ref' => '#/$defs/num' } },
      '$defs' => { 'num' => { 'type' => 'integer' } }
    }
    schemer = JSONSchemer.schema(schema)
    assert(schemer.valid?({ 'v' => 1 }))
    refute(schemer.valid?({ 'v' => 'x' }))
  end

  def test_non_array_guards_for_prefix_items_and_contains
    schema = {
      'prefixItems' => [{ 'type' => 'integer' }],
      'contains' => { 'type' => 'integer' },
      'minContains' => 2
    }
    schemer = JSONSchemer.schema(schema)
    observer = JSONSchemer::Coverage::Observer.new
    assert(schemer.valid?('not-an-array', :coverage_observer => observer))
    refute(schemer.valid?([true, true, true], :coverage_observer => observer))
    assert(observer.report(schemer)[:keywords].any? { |keyword| keyword[:keyword] == 'contains' })
  end

  def test_contains_with_min_contains_failure
    schemer = JSONSchemer.schema({ 'contains' => { 'type' => 'integer' }, 'minContains' => 2 })
    observer = JSONSchemer::Coverage::Observer.new
    refute(schemer.valid?([1, 'a', 'b'], :coverage_observer => observer))
  end

  def test_unknown_required_vocabulary_raises
    schema = {
      '$schema' => JSONSchemer::Draft202012::BASE_URI.to_s,
      '$vocabulary' => { 'https://example.com/unknown' => true }
    }
    assert_raises(JSONSchemer::UnknownVocabulary) { JSONSchemer.schema(schema) }
  end

  def test_unknown_optional_vocabulary_is_ignored
    schema = {
      '$schema' => JSONSchemer::Draft202012::BASE_URI.to_s,
      '$vocabulary' => { 'https://example.com/unknown' => false }
    }
    assert(JSONSchemer.schema(schema).valid?(1))
  end

  def test_recursive_anchor_true_followed
    schema = {
      '$id' => 'https://example.com/tree',
      '$recursiveAnchor' => true,
      'type' => 'object',
      'properties' => { 'child' => { '$recursiveRef' => '#' } }
    }
    schemer = JSONSchemer.schema(schema, :meta_schema => JSONSchemer::Draft201909::BASE_URI.to_s)
    observer = JSONSchemer::Coverage::Observer.new
    assert(schemer.valid?({ 'child' => { 'child' => {} } }, :coverage_observer => observer))
    ref_entry = entry(observer.report(schemer)[:refs], '#/properties/child/$recursiveRef')
    assert_equal(2, ref_entry[:calls])
  end

  def test_recursive_anchor_false_is_parsed
    schema = {
      '$id' => 'https://example.com/tree',
      '$recursiveAnchor' => false,
      'type' => 'object'
    }
    schemer = JSONSchemer.schema(schema, :meta_schema => JSONSchemer::Draft201909::BASE_URI.to_s)
    assert(schemer.valid?({}))
    refute(schemer.valid?('x'))
  end

  def test_recursive_ref_resolution_without_dynamic_match
    schema = {
      '$id' => 'https://example.com/root',
      'type' => 'object',
      '$defs' => {
        'leaf' => {
          '$recursiveAnchor' => false,
          'type' => 'object',
          'properties' => { 'next' => { '$recursiveRef' => '#' } }
        }
      },
      'properties' => { 'entry' => { '$ref' => '#/$defs/leaf' } }
    }
    schemer = JSONSchemer.schema(schema, :meta_schema => JSONSchemer::Draft201909::BASE_URI.to_s)
    observer = JSONSchemer::Coverage::Observer.new
    assert(schemer.valid?({ 'entry' => { 'next' => { 'next' => {} } } }, :coverage_observer => observer))
    assert(observer.report(schemer)[:refs].any? { |entry| entry[:pointer] == '#/$defs/leaf/properties/next/$recursiveRef' })
  end

  def test_recursive_anchor_true_but_no_dynamic_ancestor_match
    schema = {
      '$id' => 'https://example.com/root',
      'type' => 'object',
      '$defs' => {
        'anchor' => {
          '$id' => 'https://example.com/anchor',
          '$recursiveAnchor' => true,
          'properties' => { 'v' => { '$recursiveRef' => '#' } }
        }
      },
      'properties' => { 'entry' => { '$ref' => '#/$defs/anchor' } }
    }
    schemer = JSONSchemer.schema(schema, :meta_schema => JSONSchemer::Draft201909::BASE_URI.to_s)
    observer = JSONSchemer::Coverage::Observer.new
    schemer.valid?({ 'entry' => { 'v' => {} } }, :coverage_observer => observer)
    assert(observer.events.any? { |event| event[:type] == :ref && event[:call_site_pointer] == '/$defs/anchor/properties/v/$recursiveRef' })
  end

  def test_walker_tolerates_nonstandard_keyword_shapes
    observer = JSONSchemer::Coverage::Observer.new
    branches = []
    refs = []
    value = {
      'oneOf' => 'not-an-array',
      'prefixItems' => 'not-an-array',
      'properties' => 'not-an-object',
      '$defs' => 'not-an-object',
      'dependencies' => 'not-an-object'
    }
    observer.send(:walk, value, '', false, '$defs', branches, refs)
    assert_empty(branches)
    assert_empty(refs)
  end

  def test_walker_handles_definitions_variants
    observer = JSONSchemer::Coverage::Observer.new

    branches = []
    refs = []
    observer.send(:walk, { '$ref' => '#/x' }, '', true, 'definitions', branches, refs)
    assert_equal(['/$ref'], refs.map { |entry| entry[:pointer] })

    branches = []
    refs = []
    observer.send(:walk, { '$defs' => [] }, '', false, '$defs', branches, refs)
    observer.send(:walk, { 'properties' => [] }, '', false, '$defs', branches, refs)
    observer.send(:walk, { 'dependencies' => [] }, '', false, '$defs', branches, refs)
    observer.send(:walk, { 'allOf' => 'x' }, '', false, '$defs', branches, refs)
    observer.send(:walk, { 'prefixItems' => 'x' }, '', false, '$defs', branches, refs)
    assert_empty(branches)
  end

  def test_walker_skips_non_object_roots_and_non_hash_dependencies
    observer = JSONSchemer::Coverage::Observer.new
    branches = []
    refs = []
    observer.send(:walk, true, '', false, '$defs', branches, refs)
    observer.send(:walk, { 'dependencies' => { 'a' => ['b'] } }, '', false, '$defs', branches, refs)
    assert_empty(branches)
    assert_empty(refs)
  end

  def test_bundle_with_draft4_exclusive_ref
    schema = {
      '$ref' => '#/definitions/num',
      'definitions' => { 'num' => { 'type' => 'number' } }
    }
    schemer = JSONSchemer.schema(schema, :meta_schema => JSONSchemer::Draft4::BASE_URI.to_s)
    bundled = schemer.bundle
    assert(bundled.key?('allOf'))
  end

  private

  def observer_skip_events(schema, instances)
    observer = JSONSchemer::Coverage::Observer.new
    report(schema, instances, observer)
    observer.events.select { |event| event[:type] == :skip }
  end

  def collect_errors(node, messages = [])
    case node
    when Hash
      messages << node['error'] if node['error']
      (node['errors'] || []).each { |child| collect_errors(child, messages) }
      messages
    else
      messages
    end
  end

end
