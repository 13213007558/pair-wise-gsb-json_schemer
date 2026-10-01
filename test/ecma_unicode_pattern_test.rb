require 'test_helper'

class EcmaUnicodePatternTest < Minitest::Test
  FIXTURE = File.join(__dir__, 'fixtures', 'test262_regex', 'vectors.json')
  VECTORS = JSON.parse(File.read(FIXTURE))['vectors']

  def cp(value)
    Array(value).pack('U*')
  end

  def resolve(pattern)
    JSONSchemer::EcmaUnicodePattern.ruby_equivalent(pattern)
  end

  def classify(pattern)
    resolve(pattern)
    'accept'
  rescue JSONSchemer::EcmaUnicodePattern::ParseError
    'syntax_error'
  rescue JSONSchemer::UnsupportedEcmaUnicodePattern
    'unsupported'
  end

  VECTORS.each_with_index do |vector, index|
    define_method("test_test262_vector_#{index}") do
      pattern = vector['pattern']
      case vector['expected']
      when 'accept'
        regexp = resolve(pattern)
        (vector['tests'] || []).each do |test|
          assert_equal(
            test['match'],
            regexp.match?(test['input']),
            "#{pattern.inspect} matching #{test['input'].inspect}"
          )
        end
      when 'syntax_error'
        error = assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError, pattern.inspect) do
          resolve(pattern)
        end
        assert_kind_of(Integer, error.index)
        assert_match(/at index \d+/, error.message)
      when 'unsupported'
        assert_raises(JSONSchemer::UnsupportedEcmaUnicodePattern, pattern.inspect) do
          resolve(pattern)
        end
      end
    end
  end

  def test_semantics_dot_excludes_all_four_line_terminators
    regexp = resolve('a.c')
    refute_match(regexp, "a\nc")
    refute_match(regexp, "a\rc")
    refute_match(regexp, 'a' + cp(0x2028) + 'c')
    refute_match(regexp, 'a' + cp(0x2029) + 'c')
    assert_match(regexp, 'a' + cp(0x2027) + 'c')
  end

  def test_semantics_digit_and_word_are_ascii_only
    assert(resolve('\d').match?('9'))
    refute(resolve('\d').match?(cp(0x0661)))
    assert(resolve('\w').match?('z'))
    refute(resolve('\w').match?(cp(0x00E9)))
    refute(resolve('[\d]').match?(cp(0x0661)))
    refute(resolve('[\w]').match?(cp(0x00E9)))
  end

  def test_negated_class_shorthands_keep_meaning_inside_classes
    assert(resolve('[\W]').match?('!'))
    refute(resolve('[\W]').match?('a'))
    assert(resolve('[\D]').match?('x'))
    refute(resolve('[\D]').match?('5'))
    assert(resolve('[\S]').match?('x'))
    refute(resolve('[\S]').match?(' '))
    assert(resolve('[\W\d]').match?('!'))
    assert(resolve('[\W\d]').match?('5'))
    refute(resolve('[\W\d]').match?('a'))
  end

  def test_quantifiers_cannot_be_chained
    ['a**', 'a{1}{2}', 'a{1}*', 'a+*', 'a?+'].each do |pattern|
      assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError, pattern.inspect) do
        resolve(pattern)
      end
    end
    assert_equal('accept', classify('a*?'))
    assert_equal('accept', classify('a{2}?'))
  end

  def test_semantics_space_uses_white_space_list
    assert(resolve('\s').match?("\t"))
    assert(resolve('\s').match?(cp(0x2028)))
    assert(resolve('\s').match?(cp(0x2029)))
    assert(resolve('\s').match?(cp(0xFEFF)))
    assert(resolve('\s').match?(cp(0x00A0)))
    refute(resolve('\s').match?('a'))
  end

  def test_semantics_anchors
    assert(resolve('^x$').match?('x'))
    refute(resolve('^x$').match?("\nx\n"))
    refute(resolve('^x$').match?('xx'))
  end

  def test_semantics_astral_code_points_are_single_symbols
    emoji = cp(0x1F600)
    assert(resolve('\u{1F600}').match?(emoji))
    assert(resolve('\uD83D\uDE00').match?(emoji))
    refute(resolve('..').match?(emoji))
    assert(resolve('..').match?(emoji + emoji))
    assert(resolve('\u{1F600}{2}').match?(emoji + emoji))
    refute(resolve('\u{1F600}{2}').match?(emoji))
  end

  def test_lone_surrogates_rejected_for_raw_source_characters
    raw = [0x2F, 0xED, 0xA0, 0x80, 0x2F].pack('C*').force_encoding(Encoding::UTF_8)
    error = assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError) do
      resolve(raw)
    end
    assert_equal(1, error.index)
  end

  def test_source_positions_are_utf16_code_units
    error = assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError) do
      resolve(cp(0x1F600) + '\a')
    end
    assert_equal(2, error.index)
  end

  def test_illegal_identity_escapes
    ['\a', '\e', '\_', '\q', '\01'].each do |pattern|
      assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError, pattern.inspect) do
        resolve(pattern)
      end
    end
    ['\$', '\^', '\.', '\*', '\/', '\(', '\)', '\[', '\]', '\{', '\}', '\|', '\?', '\+'].each do |pattern|
      assert_equal('accept', classify(pattern), pattern.inspect)
    end
  end

  def test_numbered_backreferences_are_unsupported_not_silently_accepted
    ['\1', '\10', '(a)\1'].each do |pattern|
      assert_raises(JSONSchemer::UnsupportedEcmaUnicodePattern, pattern.inspect) do
        resolve(pattern)
      end
    end
  end

  def test_class_identity_escape_rules
    assert_equal('accept', classify('[\-]'))
    assert_equal('accept', classify('[\]]'))
    assert_equal('accept', classify('[\^]'))
    assert_equal('accept', classify('[\/]'))
    assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError) { resolve('[\_]') }
    assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError) { resolve('[\B]') }
  end

  def test_no_ruby_only_syntax_is_accepted
    patterns = ['\A', '\z', '\Z', '\G', '\K', '\R', '\X', '\h', 'a++', '(?>x)']
    patterns.each do |pattern|
      refute_equal('accept', classify(pattern), pattern.inspect)
    end
  end

  def test_control_escape_requires_ascii_letter_in_u_mode
    assert_equal(1, resolve('\cA').match?(cp(0x01)) ? 1 : 0)
    assert(resolve('\cZ').match?(cp(0x1A)))
    ['\c0', '\c_', '\c', '\c9'].each do |pattern|
      assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError, pattern.inspect) do
        resolve(pattern)
      end
    end
  end

  def test_possessive_and_quantifier_errors
    patterns = ['a++', 'a*+', 'a?+', 'a{1}+', 'a{2,1}', 'a{', 'a{}', '*', '+', '?', '}', ']']
    patterns.each do |pattern|
      assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError, pattern.inspect) do
        resolve(pattern)
      end
    end
  end

  def test_named_groups_and_backreferences
    regexp = resolve('(?<word>ab)\k<word>')
    assert(regexp.match?('abab'))
    refute(regexp.match?('ab'))
    assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError) do
      resolve('(?<x>a)(?<x>b)')
    end
    assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError) do
      resolve('\k<missing>')
    end
    assert_raises(JSONSchemer::UnsupportedEcmaUnicodePattern) do
      resolve('(a)\1')
    end
  end

  def test_unicode_properties
    hiragana = cp(0x3042)
    assert(resolve('\p{L}').match?('K'))
    assert(resolve('\p{Letter}').match?('K'))
    assert(resolve('\p{gc=L}').match?('K'))
    assert(resolve('\p{General_Category=Uppercase_Letter}').match?('K'))
    assert(resolve('\p{Lu}').match?('K'))
    assert(resolve('\p{sc=Hira}').match?(hiragana))
    assert(resolve('\p{Script=Hiragana}').match?(hiragana))
    assert(resolve('\p{Emoji}').match?(cp(0x1F600)))
    refute(resolve('\P{L}').match?('K'))
    assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError) do
      resolve('\p{Nope}')
    end
    assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError) do
      resolve('\p{=L}')
    end
    assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError) do
      resolve('\p{L=}')
    end
    assert_raises(JSONSchemer::EcmaUnicodePattern::ParseError) do
      resolve('\p{L=L}')
    end
    [
      '\p{Script_Extensions=Hani}',
      '\p{scx=Hani}',
      '\p{Age=7.0}',
      '\p{Block=Basic_Latin}'
    ].each do |pattern|
      assert_raises(JSONSchemer::UnsupportedEcmaUnicodePattern, pattern.inspect) do
        resolve(pattern)
      end
    end
  end

  def test_named_resolver_is_opt_in_and_coexists_with_others
    schema_pattern = { 'pattern' => '^x$' }
    # The built-in default resolver is 'ruby', whose ^/$ are line-oriented.
    assert(JSONSchemer.schema(schema_pattern).valid?("\nx\n"))
    assert(JSONSchemer.schema(schema_pattern, regexp_resolver: 'ruby').valid?("\nx\n"))
    refute(JSONSchemer.schema(schema_pattern, regexp_resolver: 'ecma').valid?("\nx\n"))
    refute(JSONSchemer.schema(schema_pattern, regexp_resolver: 'ecma_2024_u').valid?("\nx\n"))
    assert(JSONSchemer.schema(schema_pattern, regexp_resolver: 'ecma_2024_u').valid?('x'))
  end

  def test_named_resolver_rejects_invalid_ecma_patterns
    ['\a', '(?=x)', '\uD800'].each do |pattern|
      assert_raises(
        JSONSchemer::EcmaUnicodePattern::ParseError,
        JSONSchemer::UnsupportedEcmaUnicodePattern
      ) do
        JSONSchemer.schema({ 'pattern' => pattern }, regexp_resolver: 'ecma_2024_u')
      end
    end
  end

  def test_unsupported_errors_carry_source_location
    error = assert_raises(JSONSchemer::UnsupportedEcmaUnicodePattern) do
      resolve('ab(?=later)')
    end
    assert_match(/at index 2/, error.message)
  end

  def test_existing_ecma_resolver_behavior_is_unchanged
    schema = JSONSchemer.schema({ 'pattern' => '^x$' }, regexp_resolver: 'ecma')
    assert(schema.valid?('x'))
    refute(schema.valid?("\nx\n"))
    assert_raises(JSONSchemer::InvalidEcmaRegexp) do
      JSONSchemer.schema({ 'pattern' => '\A' }, regexp_resolver: 'ecma')
    end
  end
end
