# frozen_string_literal: true
#
# Selects the ECMAScript 2024 u-mode regular-expression subset vectors from a
# fixed tc39/test262 checkout and emits vectors.json.
#
# Usage:
#   git clone https://github.com/tc39/test262.git
#   cd test262 && git checkout es2024-candidate
#   bundle exec ruby test/fixtures/test262_regex/select_test262_vectors.rb /path/to/test262
#
# The runtime test suite never invokes this script and never depends on Node;
# it consumes the checked-in vectors.json fixture instead.
require 'json'

# test262 publishes per-spec snapshots as tags. Pin the exact revision used to
# generate the fixture and refuse to extract from anything else.
TEST262_REVISION = 'es2024-candidate'

SOURCE_GLOBS = %w[
  test/built-ins/RegExp/named-capture-groups/**/*.js
  test/built-ins/RegExp/unicode-property-escapes/**/*.js
  test/built-ins/RegExp/unicode-escape/**/*.js
  test/built-ins/RegExp/character-class-escape/**/*.js
  test/built-ins/RegExp/quantifiers/**/*.js
  test/built-ins/RegExp/assertions/**/*.js
].freeze

UNSUPPORTED_TOKENS = ['(?=', '(?!', '(?<=', '(?<!', '(?>', '(?#', '(?imsu', '\\g<', '\\R', '\\X', '\\K'].freeze

def revision_for(root)
  head_file = File.join(root, '.git', 'HEAD')
  return nil unless File.file?(head_file)
  ref = File.read(head_file).strip
  if ref.start_with?('ref: ')
    ref_path = File.join(root, '.git', ref.sub('ref: ', ''))
    File.file?(ref_path) ? File.read(ref_path).strip : File.basename(ref)
  else
    ref
  end
rescue SystemCallError
  nil
end

def eligible?(relative_path)
  SOURCE_GLOBS.any? do |glob|
    File.fnmatch?(glob, relative_path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
  end
end

# Extracts only the small, stable test262 shapes used by the supported subset.
# This is a deliberately narrow extraction helper, not a JavaScript parser.
def extract_vectors(source, relative_path)
  vectors = []
  source.each_line.with_index(1) do |line, line_number|
    next unless line.include?("'u'") || line.include?('"u"') || line =~ %r{/u[gimsuy]*[;,\s]}
    next if UNSUPPORTED_TOKENS.any? { |token| line.include?(token) }
    pattern = line[/new RegExp\(\s*["'](.*?)["']\s*,\s*["']u["']/, 1]
    pattern ||= line[%r{/(.+)/u[gimsuy]*[;,\s]}, 1]
    next unless pattern && !pattern.empty?
    expected = if line.include?('assert.throws') || line.include?('SyntaxError')
      'syntax_error'
    else
      'accept'
    end
    vectors << {
      'pattern' => pattern,
      'expected' => expected,
      'source' => relative_path,
      'line' => line_number
    }
  end
  vectors
end

def main(argv)
  root = argv.first
  abort('usage: select_test262_vectors.rb /path/to/test262') unless root
  revision = revision_for(root)
  unless revision == TEST262_REVISION
    abort "test262 checkout is #{revision.inspect}; expected #{TEST262_REVISION.inspect}"
  end
  vectors = []
  pattern = File.join(root, 'test/built-ins/RegExp/**/*.js')
  Dir.glob(pattern).sort.each do |path|
    relative = path.sub(root + File::SEPARATOR, '')
    next unless eligible?(relative)
    vectors.concat(extract_vectors(File.read(path, encoding: 'utf-8'), relative))
  end
  output = {
    'source' => 'https://github.com/tc39/test262',
    'revision' => revision,
    'generated_by' => 'test/fixtures/test262_regex/select_test262_vectors.rb',
    'vectors' => vectors
  }
  destination = File.expand_path('vectors.json', __dir__)
  File.write(destination, JSON.pretty_generate(output) + "\n")
  puts "wrote #{vectors.size} vectors to #{destination}"
end

main(ARGV) if __FILE__ == $PROGRAM_NAME
