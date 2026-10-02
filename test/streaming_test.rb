require 'test_helper'

class StreamingTest < Minitest::Test
  CONTAINER_ERROR_TYPES = %w[required dependentRequired minProperties maxProperties minItems maxItems].freeze

  def streaming_errors(schema, data, **options)
    json = data.is_a?(String) ? data : JSON.generate(data)
    JSONSchemer::Streaming.validate_each(schema, StringIO.new(json), **options).to_a
  end

  def normal_errors(schema, data)
    JSONSchemer.schema(schema).validate(JSON.parse(JSON.generate(data))).to_a
  end

  def assert_streaming_parity(schema, data, **options)
    expected = normal_errors(schema, data)
    actual = streaming_errors(schema, data, **options)
    # Streaming emits errors in document order while the in-memory validator
    # emits them in schema keyword order, so compare them as sets. Container
    # level errors intentionally carry nil data in streaming mode.
    normalize = lambda do |error|
      CONTAINER_ERROR_TYPES.include?(error.fetch('type')) ? error.merge('data' => nil) : error
    end
    actual.each do |error|
      assert_nil error.fetch('data'), 'container-level errors must not retain the container' if CONTAINER_ERROR_TYPES.include?(error.fetch('type'))
    end
    sort_by = ->(error) { error.values_at('data_pointer', 'type', 'schema_pointer', 'error').map(&:to_s) }
    assert_equal expected.map(&normalize).sort_by(&sort_by), actual.map(&normalize).sort_by(&sort_by)
  end

  def assert_buffered_parity(schema, data)
    # Buffered mode validates whole items with the regular validator, so
    # errors (including data) must match exactly, modulo emission order.
    expected = normal_errors(schema, data)
    actual = streaming_errors(schema, data, :buffer_items => true, :chunk_size => 3)
    sort_by = ->(error) { error.values_at('data_pointer', 'type', 'schema_pointer', 'error').map(&:to_s) }
    assert_equal expected.sort_by(&sort_by), actual.sort_by(&sort_by)
  end

  def comprehensive_schema
    {
      'type' => 'array',
      'items' => {
        'type' => 'object',
        'minProperties' => 1,
        'maxProperties' => 6,
        'required' => %w[name],
        'dependentRequired' => { 'credit_card' => %w[billing_address] },
        'propertyNames' => { 'maxLength' => 15 },
        'properties' => {
          'name' => { 'type' => 'string', 'minLength' => 2, 'maxLength' => 10, 'pattern' => '^[a-z]+$' },
          'age' => { 'type' => 'integer', 'minimum' => 0, 'maximum' => 150 },
          'score' => { 'type' => 'number', 'exclusiveMinimum' => 0.5, 'exclusiveMaximum' => 99.5, 'multipleOf' => 0.5 },
          'kind' => { 'const' => 'person' },
          'role' => { 'enum' => ['admin', 'user', nil, 1] },
          'tags' => {
            'type' => 'array',
            'prefixItems' => [{ 'type' => 'string' }],
            'items' => { 'type' => 'integer' },
            'minItems' => 1,
            'maxItems' => 3
          },
          'active' => { 'type' => 'boolean' },
          'misc' => { 'type' => %w[string null] }
        },
        'patternProperties' => { '^x-' => { 'type' => 'integer' } },
        'additionalProperties' => false
      }
    }
  end

  def comprehensive_data
    [
      { 'name' => 'ab', 'age' => 30, 'score' => 1.5, 'kind' => 'person', 'role' => 'admin', 'tags' => ['a', 1], 'active' => false, 'x-count' => 3 },
      { 'name' => 'A', 'age' => -1, 'score' => 0.5, 'kind' => 'robot', 'role' => 'other', 'tags' => [1, 'b'], 'active' => 'yes', 'x-count' => 'no', 'credit_card' => '123' },
      { 'age' => 200, 'name' => 'toolongname!!', 'score' => 1.3, 'misc' => 5 },
      { 'age' => 5 },
      {},
      { 'name' => 'ok', 'score' => 99.5 },
      'not an object',
      { 'name' => 'ok', 'a' => 1, 'b' => 2, 'c' => 3, 'd' => 4, 'e' => 5 }
    ]
  end

  def test_streaming_matches_normal_validation
    [1, 2, 3, 7, 64, 1024].each do |chunk_size|
      assert_streaming_parity(comprehensive_schema, comprehensive_data, :chunk_size => chunk_size)
    end
  end

  def test_scalar_error_data_matches_normal_validation
    schema = { 'items' => { 'properties' => { 'age' => { 'type' => 'integer', 'minimum' => 5 } } } }
    errors = streaming_errors(schema, [{ 'age' => 3 }])
    assert_equal 1, errors.size
    assert_equal 3, errors.first.fetch('data')
    assert_equal '/0/age', errors.first.fetch('data_pointer')
  end

  def test_root_type_mismatch
    errors = streaming_errors({ 'type' => 'array' }, { 'a' => 1 })
    assert_equal 1, errors.size
    assert_equal 'array', errors.first.fetch('type')
    assert_equal '', errors.first.fetch('data_pointer')
    assert_nil errors.first.fetch('data')
  end

  def test_root_min_max_items
    assert_streaming_parity({ 'type' => 'array', 'minItems' => 2 }, [1])
    assert_streaming_parity({ 'type' => 'array', 'maxItems' => 1 }, [1, 2, 3])
  end

  def test_prefix_items_and_items_false
    assert_streaming_parity({ 'prefixItems' => [{ 'type' => 'string' }], 'items' => false }, ['ok', 'extra'])
    assert_streaming_parity({ 'prefixItems' => [{ 'type' => 'string' }], 'items' => false }, [1])
  end

  def test_empty_containers
    assert_empty streaming_errors({ 'type' => 'array' }, [])
    assert_empty streaming_errors({ 'type' => 'object' }, {})
    assert_empty streaming_errors(true, [1, { 'a' => [2] }])
  end

  def test_false_root_schema
    errors = streaming_errors(false, [1])
    assert_equal 1, errors.size
    assert_equal 'schema', errors.first.fetch('type')
  end

  def test_tiny_chunks_with_multibyte_and_escapes
    schema = { 'type' => 'array', 'items' => { 'type' => 'string' } }
    data = ['héllo wörld', "emoji \u{1F600} end", '中文测试', "tab\tnewline\nform\ffeed\rreturn", 'quote"back\slash']
    json = JSON.generate(data)
    [1, 2, 3, 5].each do |chunk_size|
      assert_empty streaming_errors(schema, json, :chunk_size => chunk_size)
    end
  end

  def test_unicode_escape_split_across_chunks
    json = '["\\ud83d\\ude00 \\u0041 \\u00e9"]'
    schema = { 'items' => { 'const' => "\u{1F600} A é" } }
    [1, 2, 3].each do |chunk_size|
      assert_empty streaming_errors(schema, json, :chunk_size => chunk_size)
    end
  end

  def test_utf8_bom_is_skipped
    json = [0xEF, 0xBB, 0xBF].pack('C*') + '[1, 2]'
    assert_empty streaming_errors({ 'type' => 'array' }, json, :chunk_size => 2)
  end

  def test_deep_nesting_does_not_overflow_stack
    depth = 10_000
    json = ('[' * depth) + '1' + (']' * depth)
    assert_empty streaming_errors({ 'type' => 'array' }, json, :chunk_size => 128)
  end

  def test_truncated_input_raises_parse_error
    ['[', '[1,', '[1,2', '{"a"', '{"a":', '{"a":1', '[{"a":1},', '"abc', 'tru', '[1,2,', ''].each do |json|
      assert_raises(JSONSchemer::Streaming::ParseError, "expected ParseError for #{json.inspect}") do
        streaming_errors({ 'type' => 'array' }, json, :chunk_size => 2)
      end
    end
  end

  def test_trailing_data_raises_parse_error
    ['[1] x', '[1] [2]', '1 2', '{} x', 'null true'].each do |json|
      assert_raises(JSONSchemer::Streaming::ParseError, "expected ParseError for #{json.inspect}") do
        streaming_errors(true, json, :chunk_size => 3)
      end
    end
  end

  def test_invalid_tokens_raise_parse_error
    ['[01]', '[1.]', '[1e]', '[-]', '[nul]', '[True]', '[+1]', '[.5]', '[1,]', '[,]', '{,}', '{"a":1,}', "{'a':1}", '[1 2]', '{"a" 1}', '{"a":}', '{"a":1 "b":2}', 'x'].each do |json|
      assert_raises(JSONSchemer::Streaming::ParseError, "expected ParseError for #{json.inspect}") do
        streaming_errors(true, json, :chunk_size => 2)
      end
    end
  end

  def test_invalid_string_content_raises_parse_error
    invalid_escape = '["\\x"]'
    control_character = "[\"a\x01b\"]".b
    invalid_utf8 = "[\"\xc3\x28\"]".b
    lone_high_surrogate = '["\\ud800"]'
    lone_low_surrogate = '["\\udc00"]'
    bad_surrogate_pair = '["\\ud800\\u0041"]'
    bad_hex = '["\\u00zz"]'
    [invalid_escape, control_character, invalid_utf8, lone_high_surrogate, lone_low_surrogate, bad_surrogate_pair, bad_hex].each do |json|
      assert_raises(JSONSchemer::Streaming::ParseError, "expected ParseError for #{json.inspect}") do
        streaming_errors(true, json, :chunk_size => 2)
      end
    end
  end

  def test_parser_requires_positive_chunk_size
    assert_raises(ArgumentError) { JSONSchemer::Streaming::Parser.new(StringIO.new('[]'), :chunk_size => 0) }
  end

  def test_analyze_streamable_schema
    plan = JSONSchemer::Streaming.analyze(comprehensive_schema)
    assert plan.streamable?
    assert_empty plan.unsupported
    assert_empty plan.buffered
  end

  def test_analyze_whole_value_keywords_in_items_are_bufferable
    plan = JSONSchemer::Streaming.analyze({ 'type' => 'array', 'items' => { 'uniqueItems' => true } })
    refute plan.streamable?
    assert_equal [['items']], plan.buffered
    assert_empty plan.unsupported
  end

  def test_analyze_root_whole_value_keywords_are_unsupported
    plan = JSONSchemer::Streaming.analyze({ 'uniqueItems' => true, 'contains' => { 'const' => 1 } })
    assert_equal %w[uniqueItems contains], plan.unsupported.map { |entry| entry.fetch('keyword') }
    assert plan.unsupported.all? { |entry| entry.fetch('schema_pointer').empty? }
  end

  def test_analyze_references_are_unsupported
    plan = JSONSchemer::Streaming.analyze({ 'items' => { '$ref' => '#/$defs/thing' } })
    assert_equal %w[$ref], plan.unsupported.map { |entry| entry.fetch('keyword') }
    assert_equal ['/items'], plan.unsupported.map { |entry| entry.fetch('schema_pointer') }
  end

  def test_analyze_non_scalar_enum_and_const_are_bufferable
    assert_equal [['items']], JSONSchemer::Streaming.analyze({ 'items' => { 'enum' => [[1, 2]] } }).buffered
    assert_equal [['items']], JSONSchemer::Streaming.analyze({ 'items' => { 'const' => { 'a' => 1 } } }).buffered
  end

  def test_analyze_whole_value_keywords_in_property_names_are_unsupported
    plan = JSONSchemer::Streaming.analyze({ 'items' => { 'propertyNames' => { 'not' => {} } } })
    assert_equal %w[not], plan.unsupported.map { |entry| entry.fetch('keyword') }
  end

  def test_validate_each_rejects_whole_value_keywords_without_buffer_items
    schema = { 'items' => { 'uniqueItems' => true } }
    error = assert_raises(JSONSchemer::Streaming::UnsupportedKeywordError) do
      streaming_errors(schema, [[1, 1]])
    end
    assert_match(/buffer_items/, error.message)
  end

  def test_validate_each_rejects_unsupported_keywords_even_with_buffer_items
    error = assert_raises(JSONSchemer::Streaming::UnsupportedKeywordError) do
      streaming_errors({ 'uniqueItems' => true }, [1], :buffer_items => true)
    end
    assert_match(/uniqueItems/, error.message)
  end

  def test_buffer_items_mode_matches_normal_validation
    schema = {
      'type' => 'array',
      'items' => {
        'type' => 'object',
        'properties' => {
          'nums' => { 'type' => 'array', 'uniqueItems' => true },
          'name' => { 'type' => 'string', 'minLength' => 2 }
        }
      }
    }
    data = [
      { 'nums' => [1, 1], 'name' => 'ok' },
      { 'nums' => [1, 2], 'name' => 'x' },
      { 'nums' => 'nope' }
    ]
    assert_buffered_parity(schema, data)
  end

  def test_buffer_items_mode_with_conditional_keywords
    schema = {
      'items' => {
        'if' => { 'properties' => { 'kind' => { 'const' => 'a' } } },
        'then' => { 'required' => %w[a] },
        'else' => { 'required' => %w[b] }
      }
    }
    data = [{ 'kind' => 'a' }, { 'kind' => 'c' }, { 'kind' => 'a', 'a' => 1, 'b' => 2 }]
    assert_buffered_parity(schema, data)
  end

  def test_buffer_items_mode_enforces_max_item_bytes
    schema = { 'items' => { 'uniqueItems' => true } }
    json = JSON.generate([['a' * 100]])
    error = assert_raises(JSONSchemer::Streaming::ItemTooLargeError) do
      streaming_errors(schema, json, :buffer_items => true, :max_item_bytes => 10)
    end
    assert_match(/max_item_bytes/, error.message)
  end

  def test_buffer_items_with_sibling_schemas
    schema = {
      'items' => {
        'properties' => { 'ab' => false, 'ac' => true },
        'patternProperties' => { '^a' => { 'uniqueItems' => true } }
      }
    }
    data = [{ 'ab' => [1, 1] }, { 'ac' => [1, 1] }, { 'ab' => [1] }]
    assert_buffered_parity(schema, data)
  end

  def test_unknown_type_is_ignored
    assert_empty streaming_errors({ 'items' => { 'type' => 'notarealtype' } }, [1, 'x'])
  end

  def test_validate_each_with_block
    seen = []
    JSONSchemer::Streaming.validate_each({ 'items' => { 'type' => 'integer' } }, StringIO.new('[1,"a",2]')) do |error|
      seen << error
    end
    assert_equal 1, seen.size
    assert_equal '/1', seen.first.fetch('data_pointer')
  end

  def test_schema_validate_each
    schemer = JSONSchemer.schema({ 'items' => { 'type' => 'integer' } })
    errors = schemer.validate_each(StringIO.new('[1,"x"]')).to_a
    assert_equal %w[integer], errors.map { |error| error.fetch('type') }
    assert_equal ['/1'], errors.map { |error| error.fetch('data_pointer') }
  end

  def test_schema_given_as_json_string
    errors = streaming_errors(JSON.generate({ 'items' => { 'type' => 'integer' } }), [1, 'x'])
    assert_equal %w[integer], errors.map { |error| error.fetch('type') }
  end

  def test_validator_stack_returns_to_root_between_items
    schema = { 'type' => 'array', 'items' => { 'type' => 'object', 'properties' => { 'n' => { 'type' => 'integer' } } } }
    json = JSON.generate(Array.new(50) { |i| { 'n' => i } })
    parser = JSONSchemer::Streaming::Parser.new(StringIO.new(json), :chunk_size => 9)
    validator = JSONSchemer::Streaming::Validator.new(schema)
    depths = []
    parser.each_event do |type, payload|
      validator.handle_event(type, payload, parser.position) { |error| flunk "unexpected error: #{error.inspect}" }
      depths << validator.frames.size if type == :end_object
    end
    assert_equal [1] * 50, depths
    assert_equal 0, validator.frames.size
  end

  def test_completed_items_are_not_retained
    marker = 'streaming-retention-marker-'
    items = Array.new(2_000) { |i| { 'name' => "#{marker}#{i}" } }
    json = JSON.generate(items)
    items = nil
    schema = { 'type' => 'array', 'items' => { 'type' => 'object', 'properties' => { 'name' => { 'type' => 'string' } } } }

    GC.start
    before = ObjectSpace.each_object(String).count { |string| string.include?(marker) }
    errors = streaming_errors(schema, json, :chunk_size => 1024)
    assert_empty errors
    GC.start
    after = ObjectSpace.each_object(String).count { |string| string.include?(marker) }

    assert_operator after - before, :<, 20, "expected completed items to be garbage collected (before: #{before}, after: #{after})"
  end

  def test_fuzz_parity_with_normal_validation
    schema = {
      'type' => 'array',
      'items' => {
        'type' => 'object',
        'properties' => {
          'a' => { 'type' => %w[string null], 'minLength' => 2, 'pattern' => '^[a-z]+$' },
          'b' => { 'type' => 'number', 'minimum' => -10, 'maximum' => 10, 'multipleOf' => 0.5 },
          'c' => { 'type' => 'array', 'items' => { 'type' => 'integer' }, 'minItems' => 1 },
          'd' => { 'type' => 'boolean' },
          'e' => { 'enum' => ['x', 'y', nil, 3] }
        },
        'required' => %w[a],
        'minProperties' => 1,
        'maxProperties' => 5
      }
    }
    rng = Random.new(12345)
    strings = ['ab', 'abc', nil, 'A!', 'xy', 'ümläut', "e\u{1F600}moji", 'a']
    numbers = [-11, -10.5, 0, 0.5, 1.3, 9.5, 10, 10.5, 3]
    30.times do
      data = Array.new(rng.rand(0..8)) do
        item = {}
        rng.rand(0..6).times do
          case rng.rand(0..6)
          when 0 then item['a'] = strings[rng.rand(strings.size)]
          when 1 then item['b'] = numbers[rng.rand(numbers.size)]
          when 2 then item['c'] = Array.new(rng.rand(0..3)) { rng.rand(-2..2) }
          when 3 then item['d'] = rng.rand(2).zero?
          when 4 then item['e'] = ['x', 'y', 'z', nil, 3, 4][rng.rand(6)]
          when 5 then item['extra'] = rng.rand(2).zero?
          when 6 then item['c'] = 'not an array'
          end
        end
        item
      end
      json = JSON.generate(data)
      [1, 3, 16, 4096].each do |chunk_size|
        assert_streaming_parity(schema, data, :chunk_size => chunk_size)
      end
    end
  end
end
