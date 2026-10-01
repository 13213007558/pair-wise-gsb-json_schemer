# frozen_string_literal: true
module JSONSchemer
  # Strict ECMAScript 2024 `u` (Unicode) mode pattern resolver.
  #
  # The pattern is first parsed with ECMAScript `u`-mode semantics—so illegal
  # identity escapes, lone surrogates, Annex B syntax and Ruby-only syntax are
  # rejected instead of silently reinterpreted—and then translated into an
  # equivalent Ruby Regexp source.
  #
  # Supported subset: literals, character classes, quantifiers, groups,
  # alternation, anchors, Unicode escapes/properties and named backreferences.
  # Anything outside the subset raises {UnsupportedEcmaUnicodePattern} with the
  # UTF-16 source index of the offending construct.
  class EcmaUnicodePattern
    DOT = '[^\n\r\u2028\u2029]'.freeze
    WORD_CHARS = '0-9A-Za-z_'
    WORD = "[#{WORD_CHARS}]".freeze
    NON_WORD = "[^#{WORD_CHARS}]".freeze
    SPACE_CHARS = '\t\r\n\f\v\uFEFF\u2028\u2029\p{Zs}'
    SPACE = "[#{SPACE_CHARS}]".freeze
    NON_SPACE = "[^#{SPACE_CHARS}]".freeze
    DIGIT = '[0-9]'.freeze
    NON_DIGIT = '[^0-9]'.freeze
    BOUNDARY = "(?:^|(?<!#{WORD}))(?=#{WORD})|(?<=#{WORD})(?!#{WORD})".freeze
    NON_BOUNDARY = "(?<=#{WORD})(?=#{WORD})|(?<!#{WORD})(?!#{WORD})".freeze

    SYNTAX_CHARS = "^$\\.*+?()[]{}|/".freeze
    CONTROL_ESCAPES = { 'f' => 0x0C, 'n' => 0x0A, 'r' => 0x0D, 't' => 0x09, 'v' => 0x0B }.freeze

    # ES binary Unicode properties (loose-matching keys: no space/_/- , lowercase)
    # mapped to the Ruby/Onigmo property to emit. `nil` means a valid ES property
    # that the Ruby matcher cannot express; it raises UnsupportedEcmaUnicodePattern.
    BINARY_PROPERTIES = {
      'ascii' => 'ASCII',
      'ahex' => 'AHex', 'asciihexdigit' => 'AHex',
      'alpha' => 'Alpha', 'alphabetic' => 'Alphabetic',
      'bidic' => nil, 'bidicontrol' => nil,
      'bidim' => 'Bidi_M', 'bidimirrored' => 'Bidi_M',
      'cased' => 'Cased', 'ci' => nil,
      'changeswhencasefolded' => nil, 'cwcf' => nil,
      'changeswhencasemapped' => nil, 'cwcm' => nil,
      'changeswhennfkccasefolded' => nil, 'cwkcf' => nil,
      'changeswhenlowercased' => 'Changes_When_Lowercased', 'cwl' => 'Changes_When_Lowercased',
      'changeswhentitlecased' => 'Changes_When_Titlecased', 'cwt' => 'Changes_When_Titlecased',
      'changeswhenuppercased' => 'Changes_When_Uppercased', 'cwu' => 'Changes_When_Uppercased',
      'dash' => 'Dash', 'dep' => nil, 'deprecated' => nil, 'di' => nil,
      'dia' => 'Diacritic', 'diacritic' => 'Diacritic',
      'ext' => 'Extender', 'extender' => 'Extender',
      'grbase' => 'Grapheme_Base', 'graphemebase' => 'Grapheme_Base',
      'grext' => 'Grapheme_Extend', 'graphemeext' => 'Grapheme_Extend',
      'grlink' => nil, 'graphemelink' => nil,
      'hex' => 'Hex_Digit', 'hexdigit' => 'Hex_Digit',
      'idc' => 'ID_Continue', 'idcontinue' => 'ID_Continue',
      'ids' => 'ID_Start', 'idstart' => 'ID_Start',
      'ideo' => 'Ideographic', 'ideographic' => 'Ideographic',
      'idsb' => 'IDS_Binary_Operator', 'idsbinaryoperator' => 'IDS_Binary_Operator',
      'idst' => 'IDS_Trinary_Operator', 'idstrinaryoperator' => 'IDS_Trinary_Operator',
      'joinc' => 'Join_Control', 'joincontrol' => 'Join_Control',
      'loe' => 'Logical_Order_Exception', 'logicalorderexception' => 'Logical_Order_Exception',
      'lower' => 'Lowercase', 'lowercase' => 'Lowercase',
      'math' => 'Math',
      'nchar' => 'Noncharacter_Code_Point', 'noncharactercodepoint' => 'Noncharacter_Code_Point',
      'patsyn' => 'Pattern_Syntax', 'patternsyntax' => 'Pattern_Syntax',
      'patws' => 'Pattern_White_Space', 'patternwhitespace' => 'Pattern_White_Space',
      'qmark' => 'Quotation_Mark', 'quotationmark' => 'Quotation_Mark',
      'radical' => 'Radical',
      'ri' => 'Regional_Indicator', 'regionalindicator' => 'Regional_Indicator',
      'sd' => nil, 'sterm' => 'Sentence_Terminal', 'sentenceterminal' => 'Sentence_Terminal',
      'softdotted' => 'Soft_Dotted',
      'term' => 'Terminal_Punctuation', 'terminalpunctuation' => 'Terminal_Punctuation',
      'uideo' => 'Unified_Ideograph', 'unifiedideograph' => 'Unified_Ideograph',
      'upper' => 'Uppercase', 'uppercase' => 'Uppercase',
      'vs' => nil, 'space' => 'White_Space', 'whitespace' => 'White_Space',
      'emoji' => 'Emoji',
      'ecomp' => 'Emoji_Component', 'emojicomponent' => 'Emoji_Component',
      'ebase' => 'Emoji_Modifier_Base', 'emojimodifierbase' => 'Emoji_Modifier_Base',
      'emod' => 'Emoji_Modifier', 'emojimodifier' => 'Emoji_Modifier',
      'epres' => 'Emoji_Presentation', 'emojipresentation' => 'Emoji_Presentation',
      'extpict' => 'Extended_Pictographic', 'extendedpictographic' => 'Extended_Pictographic'
    }.freeze

    GENERAL_CATEGORY_NAMES = %w[generalcategory gc].to_set.freeze
    SCRIPT_NAMES = %w[script sc].to_set.freeze
    # Valid ES non-binary properties this implementation cannot translate to Ruby.
    UNSUPPORTED_PROPERTY_NAMES = %w[
      scriptextensions scx age block blk
      simplelowercasemapping slc simpleuppercasemapping suc simpletitlecasemapping stc
      lowercasemapping lc uppercasemapping uc titlecasemapping tc casefolding cf
    ].to_set.freeze

    # General_Category aliases (long names + grouped single letters) keyed by
    # UAX44 loose matching; values are the canonical Ruby/Onigmo spellings.
    CATEGORY_ALIASES = {
      'lc' => 'LC', 'casedletter' => 'LC',
      'lu' => 'Lu', 'uppercaseletter' => 'Lu',
      'll' => 'Ll', 'lowercaseletter' => 'Ll',
      'lt' => 'Lt', 'titlecaseletter' => 'Lt',
      'lm' => 'Lm', 'modifierletter' => 'Lm',
      'lo' => 'Lo', 'otherletter' => 'Lo',
      'l' => 'L', 'letter' => 'L',
      'mn' => 'Mn', 'nonspacingmark' => 'Mn',
      'mc' => 'Mc', 'spacingmark' => 'Mc',
      'me' => 'Me', 'enclosingmark' => 'Me',
      'm' => 'M', 'mark' => 'M',
      'nd' => 'Nd', 'decimalnumber' => 'Nd',
      'nl' => 'Nl', 'letternumber' => 'Nl',
      'no' => 'No', 'othernumber' => 'No',
      'n' => 'N', 'number' => 'N',
      'pc' => 'Pc', 'connectorpunctuation' => 'Pc',
      'pd' => 'Pd', 'dashpunctuation' => 'Pd',
      'ps' => 'Ps', 'openpunctuation' => 'Ps',
      'pe' => 'Pe', 'closepunctuation' => 'Pe',
      'pi' => 'Pi', 'initialpunctuation' => 'Pi',
      'pf' => 'Pf', 'finalpunctuation' => 'Pf',
      'po' => 'Po', 'otherpunctuation' => 'Po',
      'p' => 'P', 'punctuation' => 'P',
      'sm' => 'Sm', 'mathsymbol' => 'Sm',
      'sk' => 'Sk', 'modifiersymbol' => 'Sk',
      'so' => 'So', 'othersymbol' => 'So',
      'sc' => 'Sc', 'currencysymbol' => 'Sc',
      's' => 'S', 'symbol' => 'S',
      'zs' => 'Zs', 'spaceseparator' => 'Zs',
      'zl' => 'Zl', 'lineseparator' => 'Zl',
      'zp' => 'Zp', 'paragraphseparator' => 'Zp',
      'z' => 'Z', 'separator' => 'Z',
      'cc' => 'Cc', 'control' => 'Cc',
      'cf' => 'Cf', 'format' => 'Cf',
      'cs' => 'Cs', 'surrogate' => 'Cs',
      'co' => 'Co', 'privateuse' => 'Co',
      'cn' => 'Cn', 'unassigned' => 'Cn',
      'c' => 'C', 'other' => 'C'
    }.freeze

    Node = Struct.new(:kind, :children, :text, :code_point, keyword_init: true)

    class ParseError < StandardError
      attr_reader :index
      def initialize(message, index)
        @index = index
        super("#{message} at index #{index}")
      end
    end

    class << self
      def ruby_equivalent(pattern)
        Regexp.new(ruby_source(pattern))
      end

      def ruby_source(pattern)
        new(pattern).ruby_source
      end
    end

    attr_reader :ruby_source

    def initialize(pattern)
      unless pattern.is_a?(String)
        raise ParseError.new('pattern must be a String', 0)
      end
      @bytes = pattern.b
      @pos = 0
      @group_names = Set.new
      @ruby_property_cache = {}
      root = parse_disjunction(terminator: nil)
      raise ParseError.new('unexpected end of pattern', utf16_index) unless eof?
      @ruby_source = emit(root)
    end

  private

    def unsupported(message, index)
      UnsupportedEcmaUnicodePattern.new("#{message} at index #{index}")
    end

    # ---------- scanning (byte-based; tolerates raw surrogate bytes) ----------

    def eof?
      @pos >= @bytes.bytesize
    end

    def peek
      byte = @bytes.getbyte(@pos)
      byte&.chr
    end

    def advance
      start = @pos
      byte = @bytes.getbyte(start)
      raise ParseError.new('unexpected end of pattern', utf16_index(start)) if byte.nil?
      if byte < 0x80
        @pos += 1
        return byte
      end
      length = byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
      cp = (byte & ((1 << (7 - length)) - 1))
      (1...length).each do |i|
        continuation = @bytes.getbyte(start + i)
        unless continuation && (continuation & 0xC0) == 0x80
          raise ParseError.new('invalid UTF-8 byte sequence in pattern', utf16_index(start))
        end
        cp = (cp << 6) | (continuation & 0x3F)
      end
      @pos += length
      if (0xD800..0xDFFF).include?(cp)
        raise ParseError.new('lone surrogate code point in Unicode mode', utf16_index(start))
      end
      cp
    end

    # Source positions are reported in UTF-16 code units, matching ECMAScript.
    def utf16_index(byte_pos = @pos)
      units = 0
      i = 0
      while i < byte_pos
        byte = @bytes.getbyte(i)
        raise ParseError.new('invalid UTF-8 byte sequence in pattern', 0) if byte.nil?
        if byte < 0x80
          i += 1
          units += 1
        elsif byte < 0xE0
          i += 2
          units += 1
        elsif byte < 0xF0
          i += 3
          units += 1
        else
          i += 4
          units += 2
        end
      end
      units
    end

    def expect(char)
      raise ParseError.new("expected #{char.inspect}", utf16_index) unless peek == char
      advance
    end

    # ---------- pattern parsing ----------

    def parse_disjunction(terminator)
      alternatives = [parse_alternative(terminator)]
      while peek == '|'
        advance
        alternatives << parse_alternative(terminator)
      end
      Node.new(kind: :disjunction, children: alternatives)
    end

    def parse_alternative(terminator)
      terms = []
      until eof? || peek == '|' || (terminator && peek == terminator)
        terms << parse_term
      end
      Node.new(kind: :alternative, children: terms)
    end

    def parse_term
      case peek
      when nil
        raise ParseError.new('unexpected end of pattern', utf16_index)
      when '^'
        advance
        Node.new(kind: :anchor, text: '\A')
      when '$'
        advance
        Node.new(kind: :anchor, text: '\z')
      when '('
        parse_group
      when '['
        parse_class
      when '.'
        advance
        parse_quantifier(Node.new(kind: :dot))
      when '*', '+', '?'
        raise ParseError.new('nothing to repeat', utf16_index)
      when '}'
        raise ParseError.new('lone "}" in Unicode mode', utf16_index)
      when ']', ')'
        raise ParseError.new("lone #{peek.inspect} in pattern", utf16_index)
      when '\\'
        parse_atom_escape(in_class: false)
      when '{'
        if brace_quantifier?
          raise ParseError.new('nothing to repeat', utf16_index)
        end
        raise ParseError.new('lone "{" in Unicode mode', utf16_index)
      else
        cp = advance
        parse_quantifier(Node.new(kind: :literal, code_point: cp))
      end
    end

    def parse_quantifier(atom)
      return atom unless quantifier_token?
      start = utf16_index
      raw =
        case peek
        when '*', '+', '?'
          char = peek
          advance
          char
        when '{'
          parse_interval_quantifier(start)
        end
      if peek == '+'
        raise ParseError.new('possessive quantifier is not valid ECMAScript', utf16_index)
      end
      lazy = false
      if peek == '?'
        lazy = true
        advance
      end
      node = Node.new(kind: :quantifier, children: [atom], text: raw, code_point: (lazy ? 1 : 0))
      # A quantifier cannot directly follow another quantifier in Unicode mode.
      if quantifier_token?
        raise ParseError.new('nothing to repeat (quantifier on quantifier)', utf16_index)
      end
      node
    end

    def quantifier_token?
      return true if peek && '*+?'.include?(peek)
      peek == '{' && brace_quantifier?
    end

    def parse_interval_quantifier(start)
      source_start = @pos
      advance # '{'
      minimum = read_digits
      maximum = minimum
      if peek == ','
        advance
        maximum = peek == '}' ? nil : read_digits
      end
      raise ParseError.new('unterminated quantifier', utf16_index) unless peek == '}'
      advance
      if maximum && minimum.to_i > maximum.to_i
        raise ParseError.new('quantifier range out of order', start)
      end
      @bytes.byteslice(source_start, @pos - source_start)
    end

    def read_digits
      start = utf16_index
      digits = +''
      while peek && peek =~ /[0-9]/
        digits << peek
        advance
      end
      raise ParseError.new('expected decimal digits', start) if digits.empty?
      digits
    end

    def brace_quantifier?
      saved = @pos
      @pos += 1
      valid = false
      if peek && peek =~ /[0-9]/
        @pos += 1 while peek && peek =~ /[0-9]/
        if peek == ','
          @pos += 1
          @pos += 1 while peek && peek =~ /[0-9]/
        end
        valid = peek == '}'
      end
      @pos = saved
      valid
    end

    def parse_group
      start = utf16_index
      advance # '('
      if peek != '?'
        body = parse_disjunction(')')
        expect(')')
        return parse_quantifier(Node.new(kind: :capture_group, children: [body]))
      end
      marker_pos = @pos
      advance # '?'
      marker = peek
      case marker
      when ':'
        advance
        body = parse_disjunction(')')
        expect(')')
        parse_quantifier(Node.new(kind: :passive_group, children: [body]))
      when '='
        raise unsupported('lookahead assertions (?=) are outside the supported subset', start)
      when '!'
        raise unsupported('negative lookahead (?!) is outside the supported subset', start)
      when '<'
        next_byte = @bytes.getbyte(marker_pos + 2)&.chr
        if next_byte == '=' || next_byte == '!'
          raise unsupported('lookbehind assertions are outside the supported subset', start)
        end
        parse_named_group(start, marker_pos)
      else
        raise ParseError.new('invalid group', start)
      end
    end

    def parse_named_group(start, less_than_pos)
      @pos = less_than_pos + 1
      advance # '<'
      name = read_group_name
      expect('>')
      if @group_names.include?(name)
        raise ParseError.new("duplicate capture group name #{name.inspect}", start)
      end
      @group_names << name
      body = parse_disjunction(')')
      expect(')')
      parse_quantifier(Node.new(kind: :named_group, children: [body], text: name))
    end

    def read_group_name
      start = utf16_index
      name = +''
      while peek && peek != '>' && peek != ')'
        char = peek
        unless char =~ /[A-Za-z0-9_]/
          raise ParseError.new('invalid capture group name (ASCII identifiers only)', start)
        end
        name << char
        advance
      end
      raise ParseError.new('unterminated capture group name', start) if name.empty? || peek != '>'
      name
    end

    # ---------- escapes ----------

    def parse_atom_escape(in_class:)
      start = utf16_index
      advance # backslash
      char = peek
      raise ParseError.new('trailing backslash', start) if char.nil?
      if char =~ /[0-9]/
        return finish_atom(parse_decimal_escape(start, in_class: in_class), in_class)
      end
      node =
        case char
        when 'b', 'B'
          advance
          if in_class
            if char == 'b'
              Node.new(kind: :literal, code_point: 0x08)
            else
              raise ParseError.new('invalid identity escape \\B inside character class in Unicode mode', start)
            end
          else
            Node.new(kind: :boundary, text: (char == 'b' ? BOUNDARY : NON_BOUNDARY))
          end
        when 'd', 'D', 's', 'S', 'w', 'W'
          advance
          Node.new(kind: :char_class_escape, text: char)
        when 'f', 'n', 'r', 't', 'v'
          advance
          Node.new(kind: :literal, code_point: CONTROL_ESCAPES[char])
        when 'x'
          parse_x_escape(start)
        when 'u'
          parse_u_escape(start)
        when 'c'
          parse_c_escape(start)
        when 'p', 'P'
          parse_property_escape(start, negated: char == 'P')
        when 'k'
          if in_class
            raise ParseError.new('named backreference is not valid inside a character class', start)
          end
          parse_named_backreference(start)
        when 'g', 'h', 'H', 'R', 'X', 'K', 'A', 'z', 'Z', 'G'
          raise unsupported("Ruby/Perl-only escape \\#{char} is not valid ECMAScript", start)
        else
          cp = advance
          validate_identity_escape(char, start, in_class)
          Node.new(kind: :literal, code_point: cp)
        end
      finish_atom(node, in_class)
    end

    def finish_atom(node, in_class)
      return node if in_class
      parse_quantifier(node)
    end

    def validate_identity_escape(char, index, in_class)
      allowed = in_class ? "]^\\-/" : SYNTAX_CHARS
      unless allowed.include?(char)
        raise ParseError.new("invalid identity escape \\#{char} in Unicode mode", index)
      end
    end

    def parse_decimal_escape(start, in_class:)
      digits = +''
      while peek && peek =~ /[0-9]/
        digits << peek
        advance
      end
      if in_class
        raise ParseError.new('decimal escape is not valid inside a character class in Unicode mode', start)
      end
      if digits == '0'
        Node.new(kind: :literal, code_point: 0x00)
      elsif digits.start_with?('0')
        raise ParseError.new('NUL character escape followed by a decimal digit', start)
      else
        raise unsupported("numbered backreference \\#{digits} is outside the supported subset; use named groups", start)
      end
    end

    def parse_x_escape(start)
      advance
      Node.new(kind: :literal, code_point: read_fixed_hex(2, start, '\\x'))
    end

    def parse_c_escape(start)
      advance
      char = peek
      if char.nil?
        raise ParseError.new('invalid control escape', start)
      end
      if char =~ /[A-Za-z]/
        advance
        Node.new(kind: :literal, code_point: (char.upcase.ord - 'A'.ord + 1))
      else
        # In Unicode mode (as opposed to the v-mode character class grammar),
        # the control escape's letter must be an ASCII letter.
        raise ParseError.new('invalid control escape', start)
      end
    end

    def parse_named_backreference(start)
      advance # k
      raise ParseError.new("expected '<' after \\k", start) unless peek == '<'
      advance
      name_start = utf16_index
      name = +''
      while peek && peek != '>'
        if eof? || peek == '\\' || peek !~ /[A-Za-z0-9_]/
          raise ParseError.new('invalid named backreference', name_start)
        end
        name << peek
        advance
      end
      raise ParseError.new('empty named backreference', start) if name.empty?
      raise ParseError.new('unterminated named backreference', start) unless peek == '>'
      advance
      unless @group_names.include?(name)
        raise ParseError.new("named backreference #{name.inspect} does not reference a group", start)
      end
      Node.new(kind: :named_backreference, text: name)
    end

    def read_fixed_hex(count, error_index, prefix)
      digits = +''
      count.times do
        char = peek
        unless char && char =~ /[0-9A-Fa-f]/
          raise ParseError.new("invalid #{prefix} escape (expected #{count} hex digits)", error_index)
        end
        digits << char
        advance
      end
      digits.to_i(16)
    end

    def parse_u_escape(start)
      advance # u
      if peek != '{'
        value = read_fixed_hex(4, start, '\\u')
        return Node.new(kind: :literal, code_point: value) unless (0xD800..0xDFFF).include?(value)
        if (0xDC00..0xDFFF).include?(value)
          raise ParseError.new('lone low surrogate Unicode escape in Unicode mode', start)
        end
        return consume_surrogate_pair(value, start)
      end
      brace_start = utf16_index
      advance
      digits = +''
      while peek && peek != '}'
        char = peek
        unless char =~ /[0-9A-Fa-f]/
          raise ParseError.new('invalid Unicode brace escape', brace_start)
        end
        digits << char
        advance
      end
      raise ParseError.new('unterminated Unicode brace escape', brace_start) if peek != '}'
      raise ParseError.new('empty Unicode brace escape', brace_start) if digits.empty?
      raise ParseError.new('Unicode brace escape too long', brace_start) if digits.size > 6
      advance
      value = digits.to_i(16)
      raise ParseError.new('Unicode code point out of range', start) if value > 0x10FFFF
      if (0xD800..0xDFFF).include?(value)
        raise ParseError.new('lone surrogate Unicode escape in Unicode mode', start)
      end
      Node.new(kind: :literal, code_point: value)
    end

    def consume_surrogate_pair(high, start)
      saved = @pos
      low =
        if peek == '\\' && @bytes.getbyte(@pos + 1)&.chr == 'u' && @bytes.getbyte(@pos + 2)&.chr != '{'
          @pos += 2
          begin
            value = read_fixed_hex(4, start, '\\u')
            (0xDC00..0xDFFF).include?(value) ? value : nil
          rescue ParseError
            nil
          end
        end
      if low
        value = 0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)
        Node.new(kind: :literal, code_point: value)
      else
        @pos = saved
        raise ParseError.new('lone high surrogate Unicode escape in Unicode mode', start)
      end
    end

    # ---------- Unicode property escapes ----------

    def parse_property_escape(start, negated:)
      advance # p/P
      raise ParseError.new("expected '{' after property escape", start) unless peek == '{'
      advance
      raw = +''
      while peek && peek != '}'
        raise ParseError.new('unterminated property escape', start) if eof?
        cp = advance
        raise ParseError.new('surrogate in property escape', start) if (0xD800..0xDFFF).include?(cp)
        raw << cp.chr
      end
      raise ParseError.new('unterminated property escape', start) unless peek == '}'
      advance
      raise ParseError.new('empty property escape', start) if raw.empty?
      name, separator, value = raw.partition('=')
      raise ParseError.new("invalid Unicode property escape #{raw.inspect}", start) if name.empty?
      unless separator.empty?
        if value.empty? || value.include?('=')
          raise ParseError.new("invalid Unicode property escape #{raw.inspect}", start)
        end
      end
      ruby_property =
        if separator.empty?
          resolve_standalone_property(loose(name), raw, start)
        else
          resolve_valued_property(loose(name), loose(value), raw, start)
        end
      Node.new(kind: :property, text: ruby_property, code_point: (negated ? 1 : 0))
    end

    def resolve_standalone_property(normalized, raw, index)
      if BINARY_PROPERTIES.key?(normalized)
        mapped = BINARY_PROPERTIES[normalized]
        return mapped if mapped && probe_ruby_property?(mapped)
        raise unsupported("Unicode property #{raw.inspect} is valid ECMAScript but not supported by the Ruby matcher", index)
      end
      # \p{L} (general category) and \p{Hiragana} (script).
      if CATEGORY_ALIASES.key?(normalized)
        value = CATEGORY_ALIASES[normalized]
        return value if probe_ruby_property?(value)
      end
      script = resolve_script_value(normalized)
      return script if script
      raise ParseError.new("unknown Unicode property #{raw.inspect}", index)
    end

    def resolve_valued_property(name, value, raw, index)
      if GENERAL_CATEGORY_NAMES.include?(name)
        resolved = CATEGORY_ALIASES[value]
        if resolved && probe_ruby_property?(resolved)
          return resolved
        end
        raise ParseError.new("unknown Unicode general category value #{raw.inspect}", index)
      end
      if SCRIPT_NAMES.include?(name)
        script = resolve_script_value(value)
        return script if script
        raise ParseError.new("unknown Unicode script value #{raw.inspect}", index)
      end
      if UNSUPPORTED_PROPERTY_NAMES.include?(name)
        raise unsupported("Unicode property #{raw.inspect} (Age/Block/Script_Extensions/case mappings) is valid ECMAScript but not supported by the Ruby matcher", index)
      end
      if BINARY_PROPERTIES.key?(name)
        raise ParseError.new("binary Unicode property cannot take a value: #{raw.inspect}", index)
      end
      raise ParseError.new("unknown Unicode property #{raw.inspect}", index)
    end

    def resolve_script_value(normalized)
      candidates(normalized).each do |candidate|
        return candidate if probe_ruby_property?(candidate)
      end
      nil
    end

    def candidates(normalized)
      # UAX44 canonical script names are Title_Cased_With_Underscores; Onigmo
      # accepts those, 4-letter codes, and many aliases.
      titleized = normalized.split('_').map(&:capitalize).join('_')
      hyphenated_title = normalized.split('_').map(&:capitalize).join('-')
      [normalized, normalized.upcase, normalized.capitalize, titleized, hyphenated_title].uniq
    end

    def probe_ruby_property?(name)
      @ruby_property_cache.fetch(name) do
        @ruby_property_cache[name] =
          begin
            Regexp.new("\\p{#{name}}")
            true
          rescue RegexpError
            false
          end
      end
    end

    def loose(name)
      name.delete(' _-').downcase
    end

    # ---------- character classes ----------

    def parse_class
      start = utf16_index
      advance # '['
      negated = peek == '^'
      advance if negated
      if peek == ']'
        raise ParseError.new('empty character class in Unicode mode', start)
      end
      items = []
      until peek == ']'
        raise ParseError.new('unterminated character class', start) if eof?
        items << parse_class_atom(start)
        next unless peek == '-'
        hyphen_index = utf16_index
        advance
        if peek == ']' || eof?
          items << Node.new(kind: :literal, code_point: 0x2D)
        else
          right = parse_class_atom(start)
          left = items.pop
          items << make_range(left, right, hyphen_index)
        end
      end
      advance # ']'
      parse_quantifier(Node.new(kind: :class, children: items, code_point: (negated ? 1 : 0)))
    end

    def parse_class_atom(class_start)
      case peek
      when '\\'
        parse_atom_escape(in_class: true)
      when '['
        raise ParseError.new('nested character class is not valid in Unicode mode', utf16_index)
      when ']'
        raise ParseError.new('lone "]" in character class', utf16_index)
      when '&'
        if @bytes.getbyte(@pos + 1)&.chr == '&'
          raise unsupported('character class set operations (&&) are not valid in ECMAScript u mode', utf16_index)
        end
        cp = advance
        Node.new(kind: :literal, code_point: cp)
      when nil
        raise ParseError.new('unterminated character class', class_start)
      else
        cp = advance
        Node.new(kind: :literal, code_point: cp)
      end
    end

    def make_range(left, right, index)
      unless left&.kind == :literal && right.kind == :literal
        raise ParseError.new('character class range endpoint must be a single character', index)
      end
      if left.code_point > right.code_point
        raise ParseError.new('character class range out of order', index)
      end
      Node.new(kind: :range, children: [left, right])
    end

    # ---------- Ruby source generation ----------

    def emit(node)
      case node.kind
      when :disjunction
        node.children.map { |child| emit(child) }.join('|')
      when :alternative
        node.children.map { |child| emit(child) }.join
      when :literal
        emit_code_point(node.code_point)
      when :dot
        DOT
      when :anchor
        node.text
      when :boundary
        "(?:#{node.text})"
      when :named_backreference
        "\\k<#{node.text}>"
      when :named_group
        "(?<#{node.text}>#{emit(node.children.first)})"
      when :capture_group
        "(#{emit(node.children.first)})"
      when :passive_group
        "(?:#{emit(node.children.first)})"
      when :quantifier
        emitted = emit(node.children.first)
        emitted = "(?:#{emitted})" if node.children.first.kind == :boundary
        "#{emitted}#{node.text}#{node.code_point == 1 ? '?' : ''}"
      when :class
        body = node.children.map { |child| emit_class_item(child) }.join
        "[#{node.code_point == 1 ? '^' : ''}#{body}]"
      when :range
        "#{emit_class_code_point(node.children.first.code_point)}-#{emit_class_code_point(node.children.last.code_point)}"
      when :char_class_escape
        CHAR_CLASS_EMIT.fetch(node.text)
      when :property
        "#{node.code_point == 1 ? '\\P{' : '\\p{'}#{node.text}}"
      else
        raise unsupported("internal: cannot emit #{node.kind}", 0)
      end
    end

    def emit_class_item(node)
      case node.kind
      when :char_class_escape
        # Shorthands are expanded to nested classes so negated forms keep their
        # meaning (e.g. [\W] => [[^word]], not a bare word set).
        CHAR_CLASS_EMIT.fetch(node.text)
      when :property
        "#{node.code_point == 1 ? '\\P{' : '\\p{'}#{node.text}}"
      when :literal
        emit_class_code_point(node.code_point)
      else
        emit(node)
      end
    end

    CHAR_CLASS_EMIT = {
      'd' => DIGIT,
      'D' => NON_DIGIT,
      's' => SPACE,
      'S' => NON_SPACE,
      'w' => WORD,
      'W' => NON_WORD
    }.freeze

    def emit_code_point(cp)
      case cp
      when 0x0A then '\\n'
      when 0x0D then '\\r'
      when 0x09 then '\\t'
      when 0x0C then '\\f'
      when 0x0B then '\\v'
      when (0x00..0x7F)
        char = cp.chr
        SYNTAX_CHARS.include?(char) ? "\\#{char}" : char
      else
        "\\u{#{cp.to_s(16).upcase}}"
      end
    end

    def emit_class_code_point(cp)
      case cp
      when 0x08 then '\\b'
      when 0x09 then '\\t'
      when 0x0A then '\\n'
      when 0x0D then '\\r'
      when 0x0C then '\\f'
      when 0x0B then '\\v'
      when 0x5D, 0x5C, 0x2D, 0x5E then "\\#{cp.chr}"
      when (0x00..0x7F) then cp.chr
      else
        "\\u{#{cp.to_s(16).upcase}}"
      end
    end
  end
end
