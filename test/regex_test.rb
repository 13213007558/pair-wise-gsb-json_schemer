require 'test_helper'

class RegexTest < Minitest::Test
  def test_it_handles_regex_anchors
    schema = JSONSchemer.schema({ 'pattern' => '^foo$' }, :regexp_resolver => 'ecma')
    assert(schema.valid?('foo'))
    refute(schema.valid?(' foo'))
    refute(schema.valid?('foo '))
    refute(schema.valid?("bar\nfoo\nbar"))

    schema = JSONSchemer.schema({ 'pattern' => '^foo$' })
    assert(schema.valid?('foo'))
    refute(schema.valid?(' foo'))
    refute(schema.valid?('foo '))
    assert(schema.valid?("bar\nfoo\nbar"))

    assert_raises(JSONSchemer::InvalidEcmaRegexp) do
      JSONSchemer.schema({ 'pattern' => '\Afoo\z' }, :regexp_resolver => 'ecma').valid?('foo')
    end

    schema = JSONSchemer.schema({ 'pattern' => '\Afoo\z' })
    assert(schema.valid?('foo'))
    refute(schema.valid?(' foo'))
    refute(schema.valid?('foo '))
    refute(schema.valid?("bar\nfoo\nbar"))
  end

  def test_it_handles_regexp_resolver
    new_regexp_class = Class.new do
      def self.counts
        @@counts ||= 0
      end

      def self.counts=(value)
        @@counts = value
      end

      def initialize(pattern)
        @regexp = Regexp.new(pattern)
        self.class.counts += 1
      end

      def match?(string)
        @regexp.match?(string)
      end
    end

    schema = JSONSchemer.schema({ 'pattern' => '^foo$' }, regexp_resolver: -> (pattern) { new_regexp_class.new(pattern) })
    assert(schema.valid?('foo'))
    assert_equal(1, new_regexp_class.counts)
  end

  def test_it_allows_named_regexp_resolvers
    schema = JSONSchemer.schema({ 'pattern' => '^test$' })
    assert(schema.valid?("test"))
    assert(schema.valid?("\ntest\n"))
    schema = JSONSchemer.schema({ 'pattern' => '^test$' }, :regexp_resolver => 'ecma')
    assert(schema.valid?("test"))
    refute(schema.valid?("\ntest\n"))
    schema = JSONSchemer.schema({ 'pattern' => '^test$' }, :regexp_resolver => 'ruby')
    assert(schema.valid?("test"))
    assert(schema.valid?("\ntest\n"))
  end

  def test_it_raises_for_invalid_regexp_resolution
    assert_raises(JSONSchemer::InvalidRegexpResolution) do
      JSONSchemer.schema(
        { 'pattern' => 'whatever' },
        :regexp_resolver => proc { |pattern| nil }
      )
    end
  end

  def test_cached_regexp_resolver
    schema = {
      'properties' => {
        'x' => { 'pattern' => '^1$' },
        'y' => { 'pattern' => '^1$' },
        'z' => { 'pattern' => '^2$' }
      }
    }
    data = { 'x' => '1', 'y' => '1', 'z' => '2' }
    counts = Hash.new(0)
    regexp_resolver = proc do |pattern|
      counts[pattern] += 1
      Regexp.new(pattern)
    end
    assert(JSONSchemer.schema(schema, :regexp_resolver => regexp_resolver).valid?(data))
    assert_equal(2, counts['^1$'])
    assert_equal(1, counts['^2$'])
    counts.clear
    assert(JSONSchemer.schema(schema, :regexp_resolver => JSONSchemer::CachedResolver.new(&regexp_resolver)).valid?(data))
    assert_equal(1, counts['^1$'])
    assert_equal(1, counts['^2$'])
  end

  def test_nul_regex_escape
    schema = JSONSchemer.schema({ 'format' => 'regex' })
    assert(schema.valid?('\0'))
  end

  def test_ecma_2024_u_resolver
    schema = JSONSchemer.schema(
      { 'pattern' => '^\u{1F600}$' },
      :regexp_resolver => 'ecma_2024_u'
    )
    assert(schema.valid?("\u{1F600}"))
    refute(schema.valid?('x'))

    schema = JSONSchemer.schema(
      { 'pattern' => '^.$' },
      :regexp_resolver => 'ecma_2024_u'
    )
    assert(schema.valid?('a'))
    refute(schema.valid?("\r"))
  end

  def test_ecma_2024_u_keeps_legacy_resolvers_optional
    ecma = JSONSchemer.schema({ 'pattern' => '^a$' }, :regexp_resolver => 'ecma')
    modern = JSONSchemer.schema({ 'pattern' => '^a$' }, :regexp_resolver => 'ecma_2024_u')
    refute(ecma.valid?("a\n"))
    assert(modern.valid?("a\n"))

    assert_raises(JSONSchemer::InvalidEcmaRegexp) do
      JSONSchemer.schema({ 'pattern' => '\\A' }, :regexp_resolver => 'ecma').valid?('a')
    end
    assert_raises(JSONSchemer::Ecma2024URegexpError) do
      JSONSchemer.schema({ 'pattern' => '\\A' }, :regexp_resolver => 'ecma_2024_u').valid?('a')
    end
  end

  def test_ecma_2024_u_test262_subset
    vectors = JSON.parse(File.read(File.expand_path('fixtures/ecma2024_u_test262_subset.json', __dir__)))
    assert_equal('es2024', vectors.fetch('revision'))

    vectors.fetch('valid').each do |vector|
      pattern = vector.fetch('pattern')
      matcher = JSONSchemer::Ecma2024URegexp.resolver.call(pattern)
      vector.fetch('matches').each { |value| assert(matcher.match?(value), "#{pattern.inspect} should match #{value.inspect}") }
      vector.fetch('non_matches').each { |value| refute(matcher.match?(value), "#{pattern.inspect} should not match #{value.inspect}") }
    end

    vectors.fetch('invalid').each do |vector|
      error = assert_raises(JSONSchemer::Ecma2024URegexpError, vector.inspect) do
        JSONSchemer::Ecma2024URegexp.ruby_equivalent(vector.fetch('pattern'))
      end
      refute_kind_of(JSONSchemer::UnsupportedEcma2024URegexp, error, vector.inspect)
      assert_equal(vector.fetch('position'), error.position, vector.inspect)
    end

    vectors.fetch('unsupported').each do |vector|
      error = assert_raises(JSONSchemer::UnsupportedEcma2024URegexp, vector.inspect) do
        JSONSchemer::Ecma2024URegexp.ruby_equivalent(vector.fetch('pattern'))
      end
      assert_equal(vector.fetch('position'), error.position, vector.inspect)
      assert_includes(error.message, vector.fetch('message'), vector.inspect)
    end
  end
end
