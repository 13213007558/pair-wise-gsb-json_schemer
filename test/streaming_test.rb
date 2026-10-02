# frozen_string_literal: true
require 'test_helper'
require 'stringio'
require 'weakref'
require 'set'

class StreamingTest < Minitest::Test
  # Root (whole-array) errors do not carry the streamed array itself in the
  # `data` field; compare every other classic-error field including the full
  # error message and pointers.
  CLASSIC_KEYS = %w[data_pointer schema_pointer root_schema type details error].freeze

  def test_streaming_array_reader_parses_across_chunks
    json = '[1, "a\"b\\nc", {"k": "中文😀\\u0041"}, [], true, null, -1.5e2]'
    1.upto(40).each do |chunk_size|
      reader = JSONSchemer::StreamingArrayReader.new(StringIO.new(json), :chunk_size => chunk_size)
      values = []
      reader.each { |element| values << element }
      assert_equal(JSON.parse(json), values)
    end
  end

  def test_streaming_array_reader_multibyte_split_at_every_byte
    data = ['中文😀', 'a', '日本語x', ['中'], { '键' => '值' }]
    json = JSON.generate(data).b
    1.upto(60) do |chunk_size|
      values = []
      JSONSchemer::StreamingArrayReader
        .new(StringIO.new(json), :chunk_size => chunk_size).each { |element| values << element }
      assert_equal(data, values, "chunk_size=#{chunk_size}")
    end
  end

  def test_streaming_array_reader_rejects_mismatched_containers
    json = '[{"a": 1]'
    assert_raises(JSONSchemer::StreamingJSONParseError) do
      JSONSchemer::StreamingArrayReader
        .new(StringIO.new(json), :chunk_size => 1).each { }
    end
  end

  def test_streaming_array_reader_block_form
    json = '[1, "x", {"a": 2}]'
    [1, 2, 5].each do |chunk_size|
      values = []
      JSONSchemer::StreamingArrayReader
        .new(StringIO.new(json), :chunk_size => chunk_size)
        .each { |element| values << element }
      assert_equal(JSON.parse(json), values)
    end
  end

  def test_streaming_array_reader_handles_string_source
    values = []
    JSONSchemer::StreamingArrayReader.new('[1, 2, 3]', :chunk_size => 1).each do |element|
      values << element
    end
    assert_equal([1, 2, 3], values)
  end

  def test_streaming_array_reader_empty_array
    [1, 2, 10].each do |chunk_size|
      values = []
      JSONSchemer::StreamingArrayReader
        .new(StringIO.new('  [  ] '), :chunk_size => chunk_size)
        .each { |element| values << element }
      assert_empty(values)
    end
  end

  def test_streaming_array_reader_rejects_trailing_and_missing_syntax_errors
    invalid = ['[', '[1,,2]', '[1,]', '[,1]', '[1,2}', '5', '["ab', '[1]x']
    invalid << %q![1,"a\]!
    invalid.each do |json|
      [1, 2, 20].each do |chunk_size|
        assert_raises(JSONSchemer::StreamingJSONParseError) do
          JSONSchemer::StreamingArrayReader
            .new(StringIO.new(json), :chunk_size => chunk_size).each { }
        end
      end
    end
  end

  def test_streaming_array_reader_rejects_invalid_utf8_token
    json = "[\"\xff\"]".b
    assert_raises(JSONSchemer::StreamingJSONParseError) do
      JSONSchemer::StreamingArrayReader
        .new(StringIO.new(json), :chunk_size => 50).each { }
    end
  end

  def test_streaming_array_reader_does_not_retain_completed_items
    json = 200.times.map { |i| { 'i' => i, 'pad' => 'z' * 100 } }.to_json
    reader = JSONSchemer::StreamingArrayReader.new(StringIO.new(json), :chunk_size => 3)
    weak = WeakRef.new(reader.next_element)
    100.times { reader.next_element }
    GC.start
    refute(weak.weakref_alive?)
  end

  def test_streaming_validation_matches_classic_errors
    schema = {
      'type' => 'array',
      'minItems' => 3,
      'maxItems' => 4,
      'prefixItems' => [
        { 'type' => 'integer', 'minimum' => 0, 'multipleOf' => 2 },
        { 'type' => 'string', 'minLength' => 2, 'maxLength' => 4, 'pattern' => '^[a-z]+$' }
      ],
      'items' => {
        'type' => 'object',
        'required' => %w[id name],
        'properties' => {
          'id' => { 'type' => 'integer', 'maximum' => 100 },
          'name' => { 'type' => 'string', 'minLength' => 1 },
          'tags' => { 'type' => 'array', 'items' => { 'type' => 'string' } }
        },
        'additionalProperties' => false
      }
    }
    data = [2, 'A', { 'id' => 500 }, { 'id' => 1, 'name' => 'ok' }, 'extra', 6]
    schemer = JSONSchemer.schema(schema)
    [1, 2, 3, 7, 64].each do |chunk_size|
      errors = []
      schemer.validate_stream(StringIO.new(JSON.generate(data)), :chunk_size => chunk_size) do |error|
        errors << error.slice(*CLASSIC_KEYS)
      end
      assert_equal(
        classic_errors(schemer, data),
        errors.sort_by { |error| error_sort_key(error) },
        "chunk_size=#{chunk_size}"
      )
    end
  end

  def test_streaming_validation_error_order_matches_classic
    schemer = JSONSchemer.schema(
      {
        'type' => 'array',
        'minItems' => 5,
        'maxItems' => 2,
        'items' => { 'type' => 'integer' }
      }
    )
    data = ['x', 1, 'y']
    expected = schemer.validate(data).map { |error| [error['type'], error['data_pointer']] }
    actual = []
    schemer.validate_stream(StringIO.new(JSON.generate(data)), :chunk_size => 1) do |error|
      actual << [error['type'], error['data_pointer']]
    end
    assert_equal(expected, actual)
  end

  def test_streaming_validation_contains_count_limits
    schema = {
      'type' => 'array',
      'contains' => { 'type' => 'integer', 'minimum' => 10 },
      'minContains' => 2,
      'maxContains' => 3
    }
    data = [10, 20, 30, 40, 1]
    assert_stream_matches(schema, data)
    assert_stream_matches(schema, [10, 20, 'x'])
    assert_stream_matches(schema, ['a', 'b'])
  end

  def test_streaming_validation_prefix_items_and_items_offsets
    schema = {
      'type' => 'array',
      'prefixItems' => [{ 'const' => 'a' }, { 'const' => 'b' }],
      'items' => { 'const' => 'c' }
    }
    assert_stream_matches(schema, ['a', 'x', 'c', 'y'])
  end

  def test_streaming_validation_draft4_tuple_and_additional_items
    schema = {
      'type' => 'array',
      'items' => [{ 'type' => 'integer' }, { 'type' => 'string' }],
      'additionalItems' => false
    }
    schemer = JSONSchemer.schema(schema, :meta_schema => JSONSchemer.draft4)
    data = ['x', 1, 5]
    errors = []
    schemer.validate_stream(StringIO.new(JSON.generate(data)), :chunk_size => 1) do |error|
      errors << error.slice(*CLASSIC_KEYS)
    end
    assert_equal(classic_errors(schemer, data), errors.sort_by { |error| error_sort_key(error) })
  end

  def test_streaming_validation_multibyte_strings
    schema = { 'type' => 'array', 'items' => { 'type' => 'string', 'maxLength' => 2 } }
    assert_stream_matches(schema, ['中文', '😀😀', 'abc', '日本語'])
  end

  def test_streaming_validation_root_ref
    schema = {
      '$defs' => {
        'item' => { 'type' => 'array', 'prefixItems' => [{ 'type' => 'integer' }] }
      },
      '$ref' => '#/$defs/item'
    }
    assert_stream_matches(schema, [['x'], [1]])
  end

  def test_streaming_validation_ref_with_sibling_array_keywords
    schema = {
      '$defs' => { 'base' => { 'type' => 'array' } },
      '$ref' => '#/$defs/base',
      'prefixItems' => [{ 'type' => 'integer' }],
      'items' => { 'type' => 'string' }
    }
    assert_stream_matches(schema, ['x', 1, 2])
  end

  def test_streaming_validation_item_level_whole_value_keywords
    schema = {
      'type' => 'array',
      'items' => {
        'type' => 'object',
        'allOf' => [{ 'required' => ['a'] }],
        'anyOf' => [{ 'properties' => { 'a' => { 'type' => 'integer' } } }],
        'not' => { 'required' => ['z'] },
        'enum' => [{ 'a' => 1 }, { 'b' => 2 }]
      }
    }
    assert_stream_matches(schema, [{ 'a' => 1 }, { 'b' => 2 }, { 'c' => 3 }])
  end

  def test_streaming_validation_false_root_schema
    assert_stream_matches(false, [1, 2])
  end

  def test_streaming_validation_falls_back_for_non_array_instance
    schemer = JSONSchemer.schema(
      {
        'type' => 'object',
        'required' => %w[a b],
        'properties' => { 'a' => { 'type' => 'integer' } }
      }
    )
    data = { 'a' => 'x' }
    errors = []
    schemer.validate_stream(StringIO.new(JSON.generate(data)), :chunk_size => 1) do |error|
      errors << error.slice(*CLASSIC_KEYS)
    end
    assert_equal(classic_errors(schemer, data), errors.sort_by { |error| error_sort_key(error) })
  end

  def test_streamable_predicate
    assert(JSONSchemer.schema({ 'type' => 'array' }).streamable?)
    assert(JSONSchemer.schema(true).streamable?)
    refute(JSONSchemer.schema({ 'type' => 'array', 'oneOf' => [true] }).streamable?)
    refute(JSONSchemer.schema({ 'type' => 'array', 'enum' => [[1]] }).streamable?)
    refute(JSONSchemer.schema({ 'type' => 'array', 'unevaluatedItems' => false }).streamable?)
  end

  def test_streaming_validation_rejects_whole_value_keywords
    %w[enum const allOf anyOf oneOf not if unevaluatedItems $dynamicRef].each do |keyword|
      schema = case keyword
      when 'const'
        { 'type' => 'array', 'const' => [1] }
      when 'if'
        { 'type' => 'array', 'if' => true, 'then' => false }
      when '$dynamicRef'
        { 'type' => 'array', '$dynamicRef' => '#x' }
      else
        { 'type' => 'array', keyword => [] }
      end
      error = assert_raises(JSONSchemer::StreamingUnsupportedError) do
        JSONSchemer.schema(schema).validate_stream('[1]') { }
      end
      assert_includes(error.keywords, keyword == 'if' ? 'if' : keyword)
    end
  end

  def test_streaming_validation_unique_items_requires_explicit_bounded_cache
    schemer = JSONSchemer.schema(
      {
        'type' => 'array', 'uniqueItems' => true, 'items' => { 'type' => 'integer' }
      }
    )
    error = assert_raises(JSONSchemer::StreamingUnsupportedError) do
      schemer.validate_stream('[1, 1]') { }
    end
    assert_includes(error.keywords, 'uniqueItems')

    data = [1, 1, 2, 2, 3]
    errors = []
    schemer.validate_stream(
      StringIO.new(JSON.generate(data)), :chunk_size => 1, :unique_items_cache => Set.new
    ) { |stream_error| errors << stream_error.slice(*CLASSIC_KEYS) }
    assert_equal(classic_errors(schemer, data), errors)
  end

  def test_streaming_validation_unique_items_matches_ruby_key_equality
    schemer = JSONSchemer.schema(
      {
        'type' => 'array', 'uniqueItems' => true, 'items' => true
      }
    )
    data = [
      { 'a' => 1, 'b' => 2 }, { 'b' => 2, 'a' => 1 },
      [1, 2], [2, 1], 'x', 'x'
    ]
    errors = []
    schemer.validate_stream(
      StringIO.new(JSON.generate(data)),
      :chunk_size => 1,
      :unique_items_cache => Set.new
    ) { |stream_error| errors << stream_error.slice(*CLASSIC_KEYS) }
    assert_equal(classic_errors(schemer, data), errors)
  end

  def test_streaming_validation_rejects_insert_defaults_and_hooks
    schemer = JSONSchemer.schema({ 'type' => 'array' }, :insert_property_defaults => true)
    assert_raises(ArgumentError) { schemer.validate_stream('[]') { } }

    hook = proc { }
    schemer = JSONSchemer.schema({ 'type' => 'array' }, :before_property_validation => [hook])
    assert_raises(ArgumentError) { schemer.validate_stream('[]') { } }
  end

  def test_streaming_validation_does_not_retain_completed_items
    count = 5_000
    source = StringIO.new
    source << '['
    count.times do |index|
      source << ',' unless index.zero?
      source << JSON.generate('i' => index, 'pad' => 'z' * 300)
    end
    source << ']'
    source.rewind

    schemer = JSONSchemer.schema(
      {
        'type' => 'array',
        'items' => { 'type' => 'integer' }
      }
    )
    weak = nil
    seen = -1
    schemer.validate_stream(source, :chunk_size => 16) do |error|
      seen += 1
      assert_equal('integer', error['type'])
      weak = WeakRef.new(error['data']) if seen == 100
      if seen == 2_000
        GC.start
        refute(weak.weakref_alive?, 'completed array item was retained')
      end
    end
    assert_equal(count - 1, seen)
    GC.start
    refute(weak.weakref_alive?)
  end

  private

  def classic_errors(schemer, data)
    schemer.validate(data)
      .map { |error| error.slice(*CLASSIC_KEYS) }
      .sort_by { |error| error_sort_key(error) }
  end

  def assert_stream_matches(schema, data, **options)
    schemer = schema.is_a?(JSONSchemer::Schema) ? schema : JSONSchemer.schema(schema)
    [1, 2, 7, 1000].each do |chunk_size|
      errors = []
      schemer.validate_stream(StringIO.new(JSON.generate(data)), :chunk_size => chunk_size, **options) do |error|
        errors << error.slice(*CLASSIC_KEYS)
      end
      assert_equal(
        classic_errors(schemer, data),
        errors.sort_by { |error| error_sort_key(error) },
        "chunk_size=#{chunk_size}"
      )
    end
  end

  def error_sort_key(error)
    [error['data_pointer'], error['schema_pointer'], error['type'].to_s, error['details'].inspect]
  end
end
