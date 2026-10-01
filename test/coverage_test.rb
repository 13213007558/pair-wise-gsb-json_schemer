require 'test_helper'

class CoverageTest < Minitest::Test
  def test_observer_records_keyword_attempts_successes_and_failures
    schema = JSONSchemer.schema({
      '$comment' => 'annotations are not observed',
      'type' => 'object',
      'properties' => {
        'name' => { 'type' => 'string' }
      }
    })
    observer = JSONSchemer::Coverage::Observer.new

    schema.validate({ 'name' => 'joe' }, :observer => observer)
    schema.validate({ 'name' => 1 }, :observer => observer)

    types = observer.events.map(&:type)
    assert_includes types, :attempt
    assert_includes types, :success
    assert_includes types, :failure

    attempt = observer.events.find { |event| event.type == :attempt && event.keyword == 'properties' }
    assert_equal 'json-schemer://schema#/properties', attempt.location
    assert_equal '', attempt.instance_location

    success = observer.events.find { |event| event.type == :success && event.location == 'json-schemer://schema#/properties/name' }
    assert_equal '/name', success.instance_location

    failure = observer.events.find { |event| event.type == :failure && event.location == 'json-schemer://schema#/properties/name/type' }
    assert_equal '/name', failure.instance_location

    assert observer.events.none? { |event| event.location.include?('$comment') }

    report = observer.report
    assert report.covered?('json-schemer://schema#')
    assert report.covered?('json-schemer://schema#/properties/name')
    type_stats = report.locations.fetch('json-schemer://schema#/properties/name/type')
    assert_equal 1, type_stats.successes
    assert_equal 1, type_stats.failures
    refute report.covered?('json-schemer://schema#/missing')
  end

  def test_short_circuit_skips_are_recorded_in_flag_mode
    schema = JSONSchemer.schema({
      '$ref' => '#/$defs/failing',
      '$comment' => 'not an assertion',
      'minLength' => 2,
      '$defs' => {
        'failing' => { 'type' => 'integer' }
      }
    })
    observer = JSONSchemer::Coverage::Observer.new

    refute schema.valid?('abc', :observer => observer)

    skips = observer.events.select { |event| event.type == :skip && event.reason == :short_circuit }
    assert_equal ['json-schemer://schema#/minLength'], skips.map(&:location)
    assert observer.events.none? { |event| event.location.include?('$comment') }
  end

  def test_conditional_skips_are_recorded_when_branch_is_not_applicable
    schema = JSONSchemer.schema({
      'if' => { 'const' => 'a' },
      'then' => true,
      'else' => { 'maxLength' => 1 }
    })
    observer = JSONSchemer::Coverage::Observer.new

    assert schema.valid?('a', :observer => observer)

    skips = observer.events.select { |event| event.type == :skip && event.reason == :not_applicable }
    assert_equal ['json-schemer://schema#/else'], skips.map(&:location)
  end

  def test_report_points_out_branches_missed_by_passing_tests
    schema = JSONSchemer.schema({
      'type' => 'object',
      'properties' => {
        'kind' => { 'type' => 'string' },
        'value' => {
          'oneOf' => [
            { 'type' => 'integer' },
            { 'type' => 'string' }
          ]
        }
      },
      'if' => { 'properties' => { 'kind' => { 'const' => 'special' } } },
      'then' => { 'required' => ['extra'] },
      'else' => { 'required' => ['other'] }
    })
    observer = JSONSchemer::Coverage::Observer.new

    # all instances pass validation, but the string oneOf branch and the
    # else branch are never taken
    assert schema.valid?({ 'kind' => 'special', 'value' => 1, 'extra' => true }, :observer => observer)
    assert schema.valid?({ 'kind' => 'special', 'value' => 2, 'extra' => true }, :observer => observer)

    report = observer.report
    refute report.fully_covered?

    uncovered = report.uncovered
    assert uncovered.key?('json-schemer://schema#/properties/value/oneOf/1')
    assert uncovered.key?('json-schemer://schema#/else')
    refute uncovered.key?('json-schemer://schema#/properties/value/oneOf/0')
    refute uncovered.key?('json-schemer://schema#/then')

    missed_branch = report.locations.fetch('json-schemer://schema#/properties/value/oneOf/1')
    assert_equal 0, missed_branch.successes
    assert missed_branch.attempts.positive?

    missed_conditional = report.locations.fetch('json-schemer://schema#/else')
    assert_equal 0, missed_conditional.successes
    assert missed_conditional.skips.positive?

    assert_equal %w[
      json-schemer://schema#/if
      json-schemer://schema#/then
      json-schemer://schema#/else
    ], report.conditionals.keys

    assert_equal %w[
      json-schemer://schema#/properties/value/oneOf/0
      json-schemer://schema#/properties/value/oneOf/1
    ], report.branches.keys

    assert_equal 2, report.summary.fetch('instances')
    assert_equal report.locations.size, report.summary.fetch('total')
    assert_equal uncovered.size, report.summary.fetch('uncovered')
    assert_operator report.coverage, :<, 1.0
    assert_operator report.coverage, :>, 0.0
  end

  def test_ref_call_sites_are_tracked_separately
    schema = JSONSchemer.schema({
      'properties' => {
        'a' => { '$ref' => '#/$defs/positive' },
        'b' => { '$ref' => '#/$defs/positive' }
      },
      '$defs' => {
        'positive' => { 'type' => 'integer', 'minimum' => 0 }
      }
    })
    observer = JSONSchemer::Coverage::Observer.new

    assert schema.valid?({ 'a' => 1 }, :observer => observer)

    report = observer.report
    refs = report.refs
    assert_equal 2, refs.size
    assert_equal 'json-schemer://schema#/$defs/positive', refs.fetch('json-schemer://schema#/properties/a/$ref').target
    assert_equal 'json-schemer://schema#/$defs/positive', refs.fetch('json-schemer://schema#/properties/b/$ref').target

    assert report.covered?('json-schemer://schema#/properties/a/$ref')
    refute report.covered?('json-schemer://schema#/properties/b/$ref')
  end

  def test_recursive_refs_do_not_expand_infinitely
    schema = JSONSchemer.schema({
      '$defs' => {
        'node' => {
          'type' => 'object',
          'properties' => {
            'value' => { 'type' => 'integer' },
            'next' => { '$ref' => '#/$defs/node' }
          }
        }
      },
      '$ref' => '#/$defs/node'
    })
    observer = JSONSchemer::Coverage::Observer.new

    assert schema.valid?({ 'value' => 1, 'next' => { 'value' => 2, 'next' => { 'value' => 3 } } }, :observer => observer)

    report = observer.report
    assert report.covered?('json-schemer://schema#/$defs/node/properties/next/$ref')
    assert_equal 'json-schemer://schema#/$defs/node', report.refs.fetch('json-schemer://schema#/$defs/node/properties/next/$ref').target
    assert report.fully_covered?
  end

  def test_dynamic_ref_call_sites
    schema = JSONSchemer.schema({
      '$id' => 'https://example.com/strict-tree',
      '$dynamicAnchor' => 'node',
      'type' => 'object',
      'properties' => {
        'children' => {
          'type' => 'array',
          'items' => { '$dynamicRef' => '#node' }
        }
      }
    })
    observer = JSONSchemer::Coverage::Observer.new

    assert schema.valid?({ 'children' => [{ 'children' => [] }] }, :observer => observer)

    report = observer.report
    ref = report.refs.fetch('https://example.com/strict-tree#/properties/children/items/$dynamicRef')
    assert_equal 'https://example.com/strict-tree#', ref.target
    assert report.covered?('https://example.com/strict-tree#/properties/children/items/$dynamicRef')
  end

  def test_recursive_ref_call_sites_draft201909
    schema = JSONSchemer.schema({
      '$schema' => 'https://json-schema.org/draft/2019-09/schema',
      '$recursiveAnchor' => true,
      'type' => 'object',
      'properties' => {
        'child' => { '$recursiveRef' => '#' }
      }
    })
    observer = JSONSchemer::Coverage::Observer.new

    assert schema.valid?({ 'child' => { 'child' => {} } }, :observer => observer)

    report = observer.report
    ref = report.refs.fetch('json-schemer://schema#/properties/child/$recursiveRef')
    assert_equal 'json-schemer://schema#', ref.target
    assert report.covered?('json-schemer://schema#/properties/child/$recursiveRef')
  end

  def test_unresolvable_ref_target_is_reported_without_one
    schema = JSONSchemer.schema({
      'if' => { 'const' => 'a' },
      'then' => { '$ref' => 'https://unknown.example.com/missing.json' }
    })
    observer = JSONSchemer::Coverage::Observer.new

    assert schema.valid?('b', :observer => observer)

    report = observer.report
    ref = report.refs.fetch('json-schemer://schema#/then/$ref')
    assert_nil ref.target
    refute report.covered?('json-schemer://schema#/then/$ref')
  end

  def test_invalid_ref_pointer_is_reported_without_target
    schema = JSONSchemer.schema({
      'if' => { 'const' => 'a' },
      'then' => { '$ref' => '#/nope' }
    })
    observer = JSONSchemer::Coverage::Observer.new

    assert schema.valid?('b', :observer => observer)

    report = observer.report
    assert_nil report.refs.fetch('json-schemer://schema#/then/$ref').target
  end

  def test_observer_does_not_change_results_or_repeat_format_checks
    calls = 0
    formats = {
      'even' => proc { |instance, _format| calls += 1; instance.is_a?(Integer) && instance.even? }
    }
    schema = JSONSchemer.schema({ 'format' => 'even' }, :formats => formats)

    observer = JSONSchemer::Coverage::Observer.new
    assert schema.valid?(2, :observer => observer)
    refute schema.valid?(3, :observer => observer)
    assert_equal 2, calls

    calls = 0
    assert schema.valid?(2)
    refute schema.valid?(3)
    assert_equal 2, calls

    data = { 'name' => 1 }
    object_schema = JSONSchemer.schema({ 'properties' => { 'name' => { 'type' => 'string' } } })
    assert_equal object_schema.validate(data).to_a, object_schema.validate(data, :observer => JSONSchemer::Coverage::Observer.new).to_a
  end

  def test_observer_can_be_shared_across_schemas
    observer = JSONSchemer::Coverage::Observer.new
    integer_schema = JSONSchemer.schema({ 'type' => 'integer' })
    string_schema = JSONSchemer.schema({ 'type' => 'string' })

    assert integer_schema.valid?(1, :observer => observer)
    assert string_schema.valid?('a', :observer => observer)

    report = observer.report
    assert_equal 2, report.validations
    assert_equal 2, observer.roots.size
    assert report.fully_covered?
    assert_equal 1.0, report.coverage
  end

  def test_empty_report
    report = JSONSchemer::Coverage::Observer.new.report
    assert_equal 0, report.validations
    assert_empty report.events
    assert_empty report.locations
    assert_empty report.uncovered
    assert report.fully_covered?
    assert_equal 1.0, report.coverage
    assert_equal({ 'instances' => 0, 'total' => 0, 'covered' => 0, 'uncovered' => 0, 'coverage' => 1.0 }, report.summary)
  end

  def test_report_to_h_is_serializable
    schema = JSONSchemer.schema({
      'anyOf' => [
        { 'type' => 'integer' },
        { 'type' => 'string' }
      ]
    })
    observer = JSONSchemer::Coverage::Observer.new
    schema.valid?(1, :observer => observer)

    report = observer.report
    hash = report.to_h
    assert_equal report.summary, hash.fetch('summary')
    stats = hash.fetch('locations').fetch('json-schemer://schema#/anyOf/1')
    assert_equal 'anyOf', hash.fetch('locations').fetch('json-schemer://schema#/anyOf').fetch('keyword')
    assert_equal false, stats.fetch('covered')
    assert_equal 0, stats.fetch('successes')
    assert_equal 1, stats.fetch('failures')
    JSON.parse(JSON.generate(hash))
  end

  def test_draft7_dependencies_with_non_schema_values
    schema = JSONSchemer.schema({
      '$schema' => 'http://json-schema.org/draft-07/schema#',
      'dependencies' => {
        'credit_card' => ['billing_address'],
        'name' => { 'properties' => { 'age' => { 'type' => 'integer' } } }
      }
    })
    observer = JSONSchemer::Coverage::Observer.new

    assert schema.valid?({ 'credit_card' => 1, 'billing_address' => 'x', 'name' => 'a', 'age' => 1 }, :observer => observer)

    report = observer.report
    assert report.covered?('json-schemer://schema#/dependencies/name/properties/age')
    assert report.fully_covered?
  end
end
