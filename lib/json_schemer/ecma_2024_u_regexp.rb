# frozen_string_literal: true
require 'set'

module JSONSchemer
  class Ecma2024URegexpError < (defined?(InvalidEcmaRegexp) ? InvalidEcmaRegexp : StandardError)
    attr_reader :position, :length

    def initialize(message, position, length = 1)
      @position = position
      @length = length
      super("#{message} at position #{position}")
    end
  end

  class UnsupportedEcma2024URegexp < Ecma2024URegexpError; end

  class Ecma2024URegexp
    DIGIT_CLASS = '\x30-\x39'
    WORD_CLASS = 'A-Za-z0-9_'
    SPACE_CLASS = '\t\r\n\f\v\uFEFF\u2028\u2029\p{Zs}'
    LINE_TERMINATORS = '\n\r\u2028\u2029'

    GENERAL_CATEGORY_ALIASES = {
      'C' => 'C', 'OTHER' => 'C',
      'CC' => 'Cc', 'CONTROL' => 'Cc', 'CNTRL' => 'Cc',
      'CF' => 'Cf', 'FORMAT' => 'Cf',
      'CN' => 'Cn', 'UNASSIGNED' => 'Cn',
      'CO' => 'Co', 'PRIVATE_USE' => 'Co',
      'CS' => 'Cs', 'SURROGATE' => 'Cs',
      'LC' => 'LC', 'CASED_LETTER' => 'LC',
      'L' => 'L', 'LETTER' => 'L',
      'LL' => 'Ll', 'LOWERCASE_LETTER' => 'Ll',
      'LM' => 'Lm', 'MODIFIER_LETTER' => 'Lm',
      'LO' => 'Lo', 'OTHER_LETTER' => 'Lo',
      'LT' => 'Lt', 'TITLECASE_LETTER' => 'Lt',
      'LU' => 'Lu', 'UPPERCASE_LETTER' => 'Lu',
      'M' => 'M', 'MARK' => 'M', 'COMBINING_MARK' => 'M',
      'MC' => 'Mc', 'SPACING_MARK' => 'Mc', 'SPACING_COMBINING_MARK' => 'Mc',
      'ME' => 'Me', 'ENCLOSING_MARK' => 'Me',
      'MN' => 'Mn', 'NONSPACING_MARK' => 'Mn',
      'N' => 'N', 'NUMBER' => 'N',
      'ND' => 'Nd', 'DECIMAL_NUMBER' => 'Nd', 'DIGIT' => 'Nd',
      'NL' => 'Nl', 'LETTER_NUMBER' => 'Nl',
      'NO' => 'No', 'OTHER_NUMBER' => 'No',
      'P' => 'P', 'PUNCTUATION' => 'P',
      'PC' => 'Pc', 'CONNECTOR_PUNCTUATION' => 'Pc',
      'PD' => 'Pd', 'DASH_PUNCTUATION' => 'Pd',
      'PE' => 'Pe', 'CLOSE_PUNCTUATION' => 'Pe', 'END_PUNCTUATION' => 'Pe',
      'PF' => 'Pf', 'FINAL_PUNCTUATION' => 'Pf',
      'PI' => 'Pi', 'INITIAL_PUNCTUATION' => 'Pi', 'OPEN_PUNCTUATION' => 'Ps',
      'PO' => 'Po', 'OTHER_PUNCTUATION' => 'Po',
      'PS' => 'Ps', 'START_PUNCTUATION' => 'Ps',
      'S' => 'S', 'SYMBOL' => 'S',
      'SC' => 'Sc', 'CURRENCY_SYMBOL' => 'Sc',
      'SK' => 'Sk', 'MODIFIER_SYMBOL' => 'Sk',
      'SM' => 'Sm', 'MATH_SYMBOL' => 'Sm',
      'SO' => 'So', 'OTHER_SYMBOL' => 'So',
      'Z' => 'Z', 'SEPARATOR' => 'Z',
      'ZL' => 'Zl', 'LINE_SEPARATOR' => 'Zl',
      'ZP' => 'Zp', 'PARAGRAPH_SEPARATOR' => 'Zp',
      'ZS' => 'Zs', 'SPACE_SEPARATOR' => 'Zs'
    }.freeze

    GENERAL_CATEGORY_NORMALIZED_ALIASES = GENERAL_CATEGORY_ALIASES.each_with_object({}) do |(name, value), aliases|
      aliases[name.gsub(/[\s_-]/, '').upcase] = value
    end.freeze

    SCRIPT_ALIASES = {
      'ADLM' => 'Adlam', 'AGHB' => 'Caucasian_Albanian', 'ARMI' => 'Imperial_Aramaic',
      'BALI' => 'Balinese', 'BAMU' => 'Bamum', 'BASS' => 'Bassa_Vah', 'BATK' => 'Batak',
      'BENG' => 'Bengali', 'BHKS' => 'Bhaiksuki', 'BOPO' => 'Bopomofo', 'BRAH' => 'Brahmi',
      'BRAI' => 'Braille', 'BUGI' => 'Buginese', 'BUHD' => 'Buhid', 'CAKM' => 'Chakma',
      'CANS' => 'Canadian_Aboriginal', 'CARI' => 'Carian', 'CHAM' => 'Cham', 'CHER' => 'Cherokee',
      'CHRS' => 'Chorasmian', 'COPT' => 'Coptic', 'CPRT' => 'Cypriot', 'CPMN' => 'Cypro_Minoan',
      'CYRL' => 'Cyrillic', 'DEVA' => 'Devanagari', 'DIAK' => 'Dives_Akuru', 'DOGR' => 'Dogra',
      'DSRT' => 'Deseret', 'DUPL' => 'Duployan', 'EGYP' => 'Egyptian_Hieroglyphs',
      'ELBA' => 'Elbasan', 'ELYM' => 'Elymaic', 'ETHI' => 'Ethiopic', 'GEOR' => 'Georgian',
      'GLAG' => 'Glagolitic', 'GONG' => 'Gunjala_Gondi', 'GONM' => 'Masaram_Gondi',
      'GOTH' => 'Gothic', 'GRAN' => 'Grantha', 'GREK' => 'Greek', 'GUJR' => 'Gujarati',
      'GURU' => 'Gurmukhi', 'HANG' => 'Hangul', 'HANI' => 'Han', 'HANO' => 'Hanunoo',
      'HATR' => 'Hatran', 'HEBR' => 'Hebrew', 'HIRA' => 'Hiragana', 'HLUW' => 'Anatolian_Hieroglyphs',
      'HMNG' => 'Pahawh_Hmong', 'HUNG' => 'Old_Hungarian',
      'ITAL' => 'Old_Italic', 'JAVA' => 'Javanese', 'KALI' => 'Kayah_Li',
      'KANA' => 'Katakana', 'KAWI' => 'Kawi', 'KHAR' => 'Kharoshthi', 'KHMR' => 'Khmer',
      'KHOJ' => 'Khojki', 'KITL' => 'Khitan_Small_Script', 'KNDA' => 'Kannada', 'KTHI' => 'Kaithi',
      'LAOO' => 'Lao', 'LATN' => 'Latin', 'LEPC' => 'Lepcha', 'LIMB' => 'Limbu',
      'LINA' => 'Linear_A', 'LINB' => 'Linear_B', 'LISU' => 'Lisu', 'LYCI' => 'Lycian',
      'LYDI' => 'Lydian', 'MAHJ' => 'Mahajani', 'MAKA' => 'Makasar', 'MAND' => 'Mandaic',
      'MANI' => 'Manichaean', 'MARC' => 'Marchen', 'MEDF' => 'Medefaidrin', 'MEND' => 'Mende_Kikakui',
      'MERC' => 'Meroitic_Cursive', 'MERO' => 'Meroitic_Hieroglyphs', 'MLYM' => 'Malayalam',
      'MODI' => 'Modi', 'MONG' => 'Mongolian', 'MROO' => 'Mro', 'MTEI' => 'Meetei_Mayek',
      'MULT' => 'Multani', 'MYMR' => 'Myanmar', 'NAND' => 'Nandinagari', 'NARB' => 'Old_North_Arabian',
      'NBAT' => 'Nabataean', 'NEWA' => 'Newa', 'NKOO' => 'Nko', 'NSHU' => 'Nushu',
      'OGAM' => 'Ogham', 'OLCK' => 'Ol_Chiki', 'ORKH' => 'Old_Turkic', 'ORYA' => 'Oriya',
      'OSGE' => 'Osage', 'OSMA' => 'Osmanya', 'OUGR' => 'Old_Uyghur', 'PALM' => 'Palmyrene',
      'PAUC' => 'Pau_Cin_Hau', 'PERM' => 'Old_Permic', 'PHAG' => 'Phags_Pa', 'PHLI' => 'Inscriptional_Pahlavi',
      'PHLP' => 'Psalter_Pahlavi', 'PHNX' => 'Phoenician', 'PLRD' => 'Miao', 'PRTI' => 'Inscriptional_Parthian',
      'RJNG' => 'Rejang', 'ROHG' => 'Hanifi_Rohingya', 'RUNR' => 'Runic', 'SAMR' => 'Samaritan',
      'SARB' => 'Old_South_Arabian', 'SAUR' => 'Saurashtra', 'SGNW' => 'SignWriting', 'SHRD' => 'Sharada',
      'SHAW' => 'Shavian', 'SIDD' => 'Siddham', 'SIND' => 'Khudawadi',
      'SINH' => 'Sinhala', 'SOGD' => 'Sogdian', 'SOGO' => 'Old_Sogdian', 'SORA' => 'Sora_Sompeng',
      'SOYO' => 'Soyombo', 'SUND' => 'Sundanese', 'SYLO' => 'Syloti_Nagri', 'SYRC' => 'Syriac',
      'TAGB' => 'Tagbanwa', 'TAKR' => 'Takri', 'TALE' => 'Tai_Le', 'TALU' => 'New_Tai_Lue',
      'TAML' => 'Tamil', 'TANG' => 'Tangut', 'TAVT' => 'Tai_Viet', 'TELG' => 'Telugu',
      'TELU' => 'Telugu', 'TFNG' => 'Tifinagh', 'TGLG' => 'Tagalog', 'THAA' => 'Thaana',
      'THAI' => 'Thai', 'TIBT' => 'Tibetan', 'TIRH' => 'Tirhuta', 'TNSA' => 'Tangsa',
      'TOTO' => 'Toto', 'UGAR' => 'Ugaritic', 'VAII' => 'Vai', 'VITH' => 'Vithkuqi',
      'WARA' => 'Warang_Citi', 'WCHO' => 'Wancho', 'XOPE' => 'Old_Persian', 'XSUX' => 'Cuneiform',
      'YEZI' => 'Yezidi', 'YIII' => 'Yi', 'ZANB' => 'Zanabazar_Square', 'ZINH' => 'Inherited',
      'ZYYY' => 'Common', 'ZZZZ' => 'Unknown', 'QAAI' => 'Inherited'
    }.freeze

    UNSUPPORTED_SCRIPT_ALIASES = %w[CYRS HRKT JAMO QAAA QAAC].freeze

    BINARY_PROPERTIES = %w[
      ASCII ASCII_Hex_Digit Alphabetic Any Assigned Bidi_Control Bidi_Mirrored Case_Ignorable
      Cased Changes_When_Casefolded Changes_When_Casemapped Changes_When_Lowercased
      Changes_When_NFKC_Casefolded Changes_When_Titlecased Changes_When_Uppercased Dash
      Default_Ignorable_Code_Point Deprecated Diacritic Emoji Emoji_Component Emoji_Modifier
      Emoji_Modifier_Base Emoji_Presentation Extended_Pictographic Extender Grapheme_Base
      Grapheme_Extend Hex_Digit IDS_Binary_Operator IDS_Trinary_Operator ID_Continue ID_Start
      Ideographic Join_Control Logical_Order_Exception Lowercase Math Noncharacter_Code_Point
      Pattern_Syntax Pattern_White_Space Quotation_Mark Radical Regional_Indicator
      Sentence_Terminal Soft_Dotted Terminal_Punctuation Unified_Ideograph Uppercase White_Space
      XID_Continue XID_Start
    ].freeze

    BINARY_PROPERTY_ALIASES = {
      'AHEX' => 'ASCII_Hex_Digit', 'ALPHA' => 'Alphabetic', 'BIDC' => 'Bidi_Control',
      'BIDI_C' => 'Bidi_Control', 'BIDIM' => 'Bidi_Mirrored', 'BIDI_M' => 'Bidi_Mirrored',
      'CASED' => 'Cased', 'CI' => 'Case_Ignorable', 'CWCF' => 'Changes_When_Casefolded',
      'CWCM' => 'Changes_When_Casemapped', 'CWL' => 'Changes_When_Lowercased',
      'CWKCF' => 'Changes_When_NFKC_Casefolded', 'CWT' => 'Changes_When_Titlecased',
      'CWU' => 'Changes_When_Uppercased', 'DI' => 'Default_Ignorable_Code_Point',
      'DEP' => 'Deprecated', 'EMOJI' => 'Emoji', 'EMOJIPRES' => 'Emoji_Presentation',
      'EPRES' => 'Emoji_Presentation', 'EXT' => 'Extender', 'GR_BASE' => 'Grapheme_Base',
      'GR_EXT' => 'Grapheme_Extend', 'HEX' => 'Hex_Digit', 'IDC' => 'ID_Continue',
      'IDS' => 'ID_Start', 'IDEO' => 'Ideographic', 'LOE' => 'Logical_Order_Exception',
      'LOWER' => 'Lowercase', 'NCHAR' => 'Noncharacter_Code_Point', 'PATSYN' => 'Pattern_Syntax',
      'PATWS' => 'Pattern_White_Space', 'QMARK' => 'Quotation_Mark', 'RI' => 'Regional_Indicator',
      'STERM' => 'Sentence_Terminal', 'SD' => 'Soft_Dotted', 'TERM' => 'Terminal_Punctuation',
      'UIDEO' => 'Unified_Ideograph', 'UPPER' => 'Uppercase', 'SPACE' => 'White_Space',
      'WSPACE' => 'White_Space', 'XIDC' => 'XID_Continue', 'XIDS' => 'XID_Start'
    }.freeze

    BINARY_PROPERTY_NAMES = BINARY_PROPERTIES.each_with_object({}) do |name, names|
      names[name.gsub(/[\s_-]/, '').upcase] = name
    end.merge(BINARY_PROPERTY_ALIASES).freeze

    UNSUPPORTED_BINARY_PROPERTIES = %w[Bidi_Mirrored Changes_When_NFKC_Casefolded].freeze

    SYNTAX_CHARACTERS = Set.new(['^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/']).freeze
    class << self
      def ruby_equivalent(pattern)
        new(pattern).ruby_equivalent
      end

      def resolver
        @resolver ||= proc do |pattern|
          Regexp.new(ruby_equivalent(pattern), Regexp::FIXEDENCODING)
        rescue RegexpError => error
          raise Ecma2024URegexpError.new("invalid generated Ruby matcher: #{error.message}", 0)
        end
      end
    end

    def initialize(pattern)
      @source = pattern.encode(Encoding::UTF_8)
      @position = 0
      @group_names = Set.new
      @alternative_group_names = Set.new
      @references = Set.new
    end

    def ruby_equivalent
      result = parse_disjunction
      eof!(@position) unless @position == @source.length
      @references.each do |name, position|
        unless @group_names.include?(name)
          syntax_error!('invalid named backreference', position, name.length + 4)
        end
      end
      result
    end

    private

    def parse_disjunction(nested = false)
      parent_scope = @alternative_group_names
      @alternative_group_names = Set.new
      alternatives = [parse_alternative]
      while consume?('|')
        @alternative_group_names = Set.new
        alternatives << parse_alternative
      end
      if nested
        scope = @alternative_group_names
        @alternative_group_names = parent_scope.merge(scope)
      end
      alternatives.join('|')
    end

    def parse_alternative
      output = +''
      until at_alternative_boundary?
        @quantifiable = true
        atom = parse_atom
        output << atom
        if quantifier?
          quantifier_position = @position
          quantifier = parse_quantifier(atom)
          unless @quantifiable
            syntax_error!('nothing to repeat', quantifier_position, [quantifier.length, 1].max)
          end
          output << quantifier
        end
      end
      output
    end

    def at_alternative_boundary?
      @position >= @source.length || peek == '|' || peek == ')'
    end

    def quantifier?
      peek == '*' || peek == '+' || peek == '?' || peek == '{'
    end

    def parse_quantifier(atom)
      position = @position
      text = consume
      min = 0
      max = nil
      finite_max = false
      if text == '{'
        interval = +'{'
        min = parse_quantifier_number(position)
        interval << min
        finite_max = true
        if consume?(',')
          interval << ','
          finite_max = false
          if digit?
            max = parse_quantifier_number(position)
            finite_max = true
            interval << max
          end
        end
        unless consume?('}')
          syntax_error!('unterminated quantifier', position, @position - position)
        end
        interval << '}'
        if max && max.to_i < min.to_i
          syntax_error!('quantifier range is reversed', position, @position - position)
        end
        lazy = consume?('?')
        quantified = quantified_atom(atom, min.to_i, max&.to_i, finite_max, position)
        return "#{quantified}#{'?' if lazy}"
      end
      text << '?' if consume?('?')
      if quantifier?
        syntax_error!('nothing to repeat', @position)
      end
      text
    end

    def parse_quantifier_number(start)
      number_start = @position
      number = consume_while { |char| char >= '0' && char <= '9' }
      syntax_error!('invalid quantifier', number_start, 1) if number.empty?
      if number.to_i > (2**32 - 1)
        syntax_error!('quantifier exceeds maximum', number_start, number.length)
      elsif number.to_i > 65535
        unsupported!('quantifier exceeds Ruby matcher limit', number_start, number.length)
      end
      number
    end

    def parse_atom
      position = @position
      char = consume
      case char
      when '(' then parse_group(position)
      when '[' then parse_character_class(position)
      when '.' then "[^#{LINE_TERMINATORS}]"
      when '^' then @quantifiable = false; '\A'
      when '$' then @quantifiable = false; '(?:\r?\n|[\r\u2028\u2029])?\z'
      when '\\' then parse_escape(position, false)
      when '*', '+', '?' then syntax_error!('nothing to repeat', position)
      when ']', '}' then es_literal(char, false)
      when '{'
        @position -= 1
        syntax_error!('invalid quantifier', position)
      else es_literal(char, false)
      end
    end

    def parse_group(position)
      if consume?('?:')
        output = +'(?:'
      elsif consume?('?<') || consume?("?'")
        if @source[@position] == '=' || @source[@position] == '!'
          unsupported!('unsupported lookbehind assertion', position, 3)
        end
        closing = @source[@position - 1] == '<' ? '>' : "'"
        name_position = @position
        name = parse_group_name(position, closing)
        if @alternative_group_names.include?(name)
          syntax_error!('duplicate named capture group', name_position, name.length)
        end
        @group_names << name
        @alternative_group_names << name
        output = +"(?<#{name}>"
      elsif peek == '?'
        unsupported!('unsupported group option or assertion', position, 2)
      else
        output = +'('
      end

      output << parse_disjunction(true)
      expect!(')', 'unterminated group', position)
      output << ')'
    end

    def parse_group_name(position, closing)
      name, first = parse_identifier_name
      unless first && consume?(closing)
        syntax_error!('invalid named capture group', position, [@position - position, 2].max)
      end
      name
    end

    def parse_character_class(position)
      negated = consume?('^')
      if consume?(']')
        syntax_error!('empty character class', position, negated ? 3 : 2)
      end

      atom_codepoints = {}
      output = +'['
      output << '^' if negated
      until consume?(']')
        if @position >= @source.length
          syntax_error!('unterminated character class', position, @source.length - position)
        end
        start = @position
        left = parse_class_atom(atom_codepoints)
        if peek == '-' && @source[@position + 1] != ']'
          @position += 1
          right = parse_class_atom(atom_codepoints)
          output << emit_class_range(left, right, atom_codepoints, start)
        else
          output << left
        end
      end
      output << ']'
    end

    def parse_class_atom(codepoints)
      if peek == '\\'
        position = @position
        @position += 1
        parse_escape(position, true, codepoints)
      else
        char = consume
        emitted = es_literal(char, true)
        codepoints[emitted] = char.ord
        if char == '['
          emitted
        elsif char == '&' || char == '~'
          emitted
        elsif char == '-'
          emitted
        else
          emitted
        end
      end
    end

    def emit_class_range(left, right, codepoints, start)
      left_codepoint = codepoints[left]
      right_codepoint = codepoints[right]
      unless left_codepoint && right_codepoint && left_codepoint <= right_codepoint
        syntax_error!('invalid character class range', start, @position - start)
      end
      "#{left}-#{right}"
    end

    def parse_escape(position, in_class, class_codepoints = nil)
      char = consume
      case char
      when 'f' then register_class_atom('\f', 12, class_codepoints)
      when 'n' then register_class_atom('\n', 10, class_codepoints)
      when 'r' then register_class_atom('\r', 13, class_codepoints)
      when 't' then register_class_atom('\t', 9, class_codepoints)
      when 'v' then register_class_atom('\v', 11, class_codepoints)
      when 'b' then in_class ? register_class_atom('\b', 8, class_codepoints) : quantifiable_boundary(word_boundary)
      when 'B' then in_class ? syntax_error!('invalid escape in character class', position, 2) : quantifiable_boundary(non_word_boundary)
      when 'd' then in_class ? DIGIT_CLASS : "[#{DIGIT_CLASS}]"
      when 'D' then in_class ? "^#{DIGIT_CLASS}" : "[^#{DIGIT_CLASS}]"
      when 'w' then in_class ? WORD_CLASS : "[#{WORD_CLASS}]"
      when 'W' then in_class ? "^#{WORD_CLASS}" : "[^#{WORD_CLASS}]"
      when 's' then in_class ? SPACE_CLASS : "[#{SPACE_CLASS}]"
      when 'S' then in_class ? "^#{SPACE_CLASS}" : "[^#{SPACE_CLASS}]"
      when 'k' then in_class ? syntax_error!('invalid named backreference in character class', position, 2) : parse_named_backreference(position)
      when 'p', 'P' then parse_unicode_property(char, position, in_class, class_codepoints)
      when 'x' then parse_hex_escape(position, class_codepoints)
      when 'u' then parse_unicode_escape(position, in_class, class_codepoints)
      when 'c' then parse_control_escape(position, class_codepoints)
      when '0'
        syntax_error!('invalid NUL escape', position, 2) if digit?
        emit_unicode_codepoint(0, class_codepoints)
      when '1'..'9' then unsupported!('numbered backreference', position, 2)
      when nil then syntax_error!('trailing escape', position)
      else parse_identity_escape(char, position, in_class, class_codepoints)
      end
    end

    def word_boundary
      '(?:(?<![A-Za-z0-9_])(?=[A-Za-z0-9_])|(?<=[A-Za-z0-9_])(?![A-Za-z0-9_]))'
    end

    def non_word_boundary
      '(?:(?<![A-Za-z0-9_])(?![A-Za-z0-9_])|(?<=[A-Za-z0-9_])(?=[A-Za-z0-9_]))'
    end

    def quantifiable_boundary(source)
      @quantifiable = false
      source
    end

    def quantified_atom(_atom, min, max, finite_max, _position)
      return "{#{min}}" if finite_max && max.nil?
      max ? "{#{min},#{max}}" : "{#{min},}"
    end

    def register_class_atom(emitted, codepoint, class_codepoints)
      class_codepoints[emitted] = codepoint if class_codepoints
      emitted
    end

    def parse_named_backreference(position)
      delimiter = consume
      closing = case delimiter
      when '<' then '>'
      when "'" then "'"
      else syntax_error!('invalid named backreference', position, 2)
      end
      name_position = @position
      name, first = parse_identifier_name
      unless first && consume?(closing)
        syntax_error!('invalid named backreference', position, @position - position)
      end
      @references << [name, name_position]
      @group_names.include?(name) ? "\\k#{delimiter}#{name}#{closing}" : '(?:)'
    end

    def parse_identifier_name
      characters = []
      first = nil
      loop do
        char = peek
        break unless char == '$' || char == '_' || char =~ /\p{ID_Continue}/ || (char == '\\' && @source[@position + 1] == 'u')
        if char == '\\'
          escape_position = @position
          @position += 1
          syntax_error!('invalid Unicode escape', escape_position, 2) unless consume?('u')
          if consume?('{')
            digits = consume_while { |digit| hex_digit?(digit) }
            unless !digits.empty? && digits.length <= 6 && consume?('}')
              syntax_error!('invalid Unicode escape', escape_position, [@position - escape_position, 3].max)
            end
            codepoint = digits.to_i(16)
            syntax_error!('Unicode codepoint out of range', escape_position, digits.length + 4) if codepoint > 0x10FFFF
          else
            codepoint = 4.times.map { hex_digit(escape_position) }.join.to_i(16)
          end
          if surrogate?(codepoint)
            if high_surrogate?(codepoint) && (pair = peek_fixed_unicode_codepoint(@position)) && low_surrogate?(pair)
              @position += 6
              codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (pair - 0xDC00)
            end
            syntax_error!('lone surrogate escape', escape_position, @position - escape_position) if surrogate?(codepoint)
          end
          char = codepoint.chr(Encoding::UTF_8)
        else
          @position += 1
        end
        first ||= identifier_start?(char)
        characters << char
      end
      [characters.join, first == true]
    end

    def identifier_start?(char)
      char == '$' || char == '_' || !!(char =~ /\p{ID_Start}/)
    end

    def parse_identity_escape(char, position, in_class, class_codepoints)
      allowed = in_class ? SYNTAX_CHARACTERS + ['-'] : SYNTAX_CHARACTERS
      unless allowed.include?(char)
        syntax_error!('invalid identity escape', position, 2)
      end
      emitted = es_literal(char, in_class, true)
      class_codepoints[emitted] = char.ord if class_codepoints
      emitted
    end

    def parse_hex_escape(position, class_codepoints)
      digits = 2.times.map { hex_digit(position) }.join
      emit_unicode_codepoint(digits.to_i(16), class_codepoints)
    end

    def parse_control_escape(position, class_codepoints)
      char = consume
      unless char && char =~ /[A-Za-z]/
        syntax_error!('invalid control escape', position, 2)
      end
      value = char.upcase.ord - 'A'.ord + 1
      emit_unicode_codepoint(value, class_codepoints)
    end

    def parse_unicode_escape(position, in_class, class_codepoints)
      codepoint = read_unicode_codepoint(position)
      if surrogate?(codepoint)
        if high_surrogate?(codepoint)
          pair_position = @position
          pair = peek_fixed_unicode_codepoint(pair_position)
          if pair && low_surrogate?(pair)
            @position = pair_position + 6
            codepoint = 0x10000 + ((codepoint - 0xD800) << 10) + (pair - 0xDC00)
          end
        end
        syntax_error!('lone surrogate escape', position, @position - position) if surrogate?(codepoint)
      end
      emit_unicode_codepoint(codepoint, class_codepoints)
    end

    def read_unicode_codepoint(position)
      if consume?('{')
        start = @position
        digits = consume_while { |char| hex_digit?(char) }
        if digits.empty? || !consume?('}') || digits.length > 6
          syntax_error!('invalid Unicode escape', position, [@position - position, 3].max)
        end
        value = digits.to_i(16)
      else
        digits = 4.times.map { hex_digit(position) }.join
        value = digits.to_i(16)
      end
      if value > 0x10FFFF
        syntax_error!('Unicode codepoint out of range', start, digits&.length || 4)
      end
      value
    end

    def peek_fixed_unicode_codepoint(position)
      return nil unless @source[position, 2] == '\\u'
      digits = @source[position + 2, 4]
      return nil unless digits && digits.length == 4 && digits =~ /\A[0-9A-Fa-f]{4}\z/
      digits.to_i(16)
    end

    def emit_unicode_codepoint(codepoint, class_codepoints = nil)
      emitted = if codepoint > 0xFFFF
        format('\u{%X}', codepoint)
      else
        format('\u%04X', codepoint)
      end
      class_codepoints[emitted] = codepoint if class_codepoints
      emitted
    end

    def surrogate?(codepoint)
      codepoint >= 0xD800 && codepoint <= 0xDFFF
    end

    def high_surrogate?(codepoint)
      codepoint >= 0xD800 && codepoint <= 0xDBFF
    end

    def low_surrogate?(codepoint)
      codepoint >= 0xDC00 && codepoint <= 0xDFFF
    end

    def parse_unicode_property(sign, position, in_class, class_codepoints)
      unless consume?('{')
        syntax_error!('invalid Unicode property escape', position, 2)
      end
      body_start = @position
      body = consume_while { |char| char != '}' }
      unless consume?('}')
        syntax_error!('unterminated Unicode property escape', position, @position - position)
      end
      emitted = unicode_property(body, body_start, position, sign)
      class_codepoints&.delete(emitted)
      emitted
    end

    def unicode_property(body, body_start, start, sign)
      equals = body.index('=')
      name = equals ? property_name(body[0...equals]) : property_name(body)
      value = equals ? property_name(body[(equals + 1)..]) : nil
      ruby_name = if value
        unicode_named_property(name, value, body_start, equals)
      elsif GENERAL_CATEGORY_NORMALIZED_ALIASES.key?(name)
        GENERAL_CATEGORY_NORMALIZED_ALIASES.fetch(name)
      else
        binary_property_name(name, body_start)
      end
      "\\#{sign == 'P' ? 'P' : 'p'}{#{ruby_name}}"
    rescue RegexpError
      syntax_error!('invalid Unicode property escape', start, @source.length - start)
    end

    def property_name(value)
      value.gsub(/[\s_-]/, '').upcase
    end

    def unicode_named_property(name, value, body_start, equals)
      value_position = body_start + equals + 1
      case name
      when 'GENERALCATEGORY', 'GC'
        category = GENERAL_CATEGORY_NORMALIZED_ALIASES[property_name(value)]
        syntax_error!('invalid general category property', value_position, value.length) unless category
        category
      when 'SCRIPT', 'SC'
        script_property_name(value, value_position)
      when 'SCRIPTEXTENSIONS', 'SCX'
        unsupported!('unsupported Unicode Script_Extensions property', body_start, equals)
      else
        syntax_error!('invalid Unicode property name', body_start, equals)
      end
    end

    def binary_property_name(normalized, position)
      canonical = BINARY_PROPERTY_NAMES[normalized]
      syntax_error!('invalid Unicode binary property', position, normalized.length) unless canonical
      if UNSUPPORTED_BINARY_PROPERTIES.include?(canonical)
        unsupported!('unsupported Unicode binary property', position, normalized.length)
      end
      canonical
    end

    def script_property_name(value, position)
      normalized = property_name(value)
      if UNSUPPORTED_SCRIPT_ALIASES.include?(normalized)
        unsupported!('unsupported Unicode script property alias', position, value.length)
      end
      mapped = SCRIPT_ALIASES[normalized]
      return mapped if mapped

      token = value.downcase.to_sym
      if Regexp::Syntax::Token::UnicodeProperty::Script.include?(token)
        return value.downcase.split('_').map(&:capitalize).join
      end
      syntax_error!('invalid Unicode script property', position, value.length)
    end

    def es_literal(char, in_class, escaped = false)
      if [10, 13, 0x2028, 0x2029].include?(char.ord)
        syntax_error!('raw line terminator in pattern', @position - 1)
      end
      source = es_literal_source(char, in_class)
      return source unless char.ord < 0x20 || char == 0x7F
      emit_unicode_codepoint(char.ord)
    end

    def es_literal_source(char, in_class)
      special = char == '\\' || char == ']' || char == '[' || char == '/'
      special ||= in_class && ['^', '-', '&', '~'].include?(char)
      special ||= ['.', '*', '+', '?', '(', ')', '{', '}', '|', '$'].include?(char)
      special ? "\\#{char}" : char
    end

    def hex_digit?(char)
      char =~ /[0-9A-Fa-f]/
    end

    def hex_digit(start)
      char = consume
      unless char && hex_digit?(char)
        syntax_error!('invalid hexadecimal escape', start, 2)
      end
      char
    end

    def digit?
      peek && peek >= '0' && peek <= '9'
    end

    def peek
      @source[@position]
    end

    def consume
      char = @source[@position]
      @position += 1 if char
      char
    end

    def consume?(expected)
      if @source[@position, expected.length] == expected
        @position += expected.length
        expected
      end
    end

    def consume_while
      start = @position
      @position += 1 while @position < @source.length && yield(@source[@position])
      @source[start...@position]
    end

    def expect!(char, message, position)
      unless consume?(char)
        syntax_error!(message, position, @source.length - position)
      end
    end

    def eof!(position)
      syntax_error!('unmatched )', position)
    end

    def syntax_error!(message, position, length = 1)
      raise Ecma2024URegexpError.new(message, position, [length, 1].max)
    end

    def unsupported!(message, position, length = 1)
      raise UnsupportedEcma2024URegexp.new(message, position, [length, 1].max)
    end
  end
end
