# frozen_string_literal: true
module JSONSchemer
  class SchemaMigration
    TARGET_SCHEMA = Draft202012::BASE_URI.to_s
    MIGRATION_EXTENSION = 'x-json-schemer-migration'

    DRAFT4_SCHEMAS = ['http://json-schema.org/draft-04/schema#', 'http://json-schema.org/draft-04/schema'].freeze
    DRAFT7_SCHEMAS = ['http://json-schema.org/draft-07/schema#', 'http://json-schema.org/draft-07/schema'].freeze
    ANCHOR_REGEX = /\A[A-Za-z_][-A-Za-z0-9._]*\z/.freeze

    ANNOTATION_KEYWORDS = %w[
      title description default deprecated examples readOnly writeOnly $comment
    ].freeze

    SCHEMA_ARRAY_KEYWORDS = %w[
      allOf anyOf oneOf prefixItems items
    ].freeze

    SCHEMA_MAP_KEYWORDS = %w[
      properties patternProperties additionalProperties propertyNames dependentSchemas
      not if then else contains unevaluatedItems unevaluatedProperties $defs definitions
    ].freeze

    SINGLE_SCHEMA_KEYWORDS = %w[
      additionalItems additionalProperties contains contentSchema if items not propertyNames
      then else unevaluatedItems unevaluatedProperties
    ].freeze

    def initialize(schema, source: nil)
      @schema = deep_copy(schema)
      @source = source
      @transforms = []
      @diagnostics = []
    end

    def to_202012
      source = source_draft(@schema, @source)
      unless %w[draft4 draft7].include?(source)
        unsupported_schema_diagnostic('', @schema['$schema'] || @source)
        return result
      end

      converted = convert(@schema, '', source, true, nil)
      if converted.is_a?(Hash)
        converted['$schema'] = TARGET_SCHEMA
        transform('', '$schema', 'set target dialect to Draft 2020-12')
      end
      MigrationResult.new(:schema => converted, :transforms => @transforms, :diagnostics => @diagnostics)
    end

    private

    MigrationResult = Struct.new(:schema, :transforms, :diagnostics, keyword_init: true) do
      def equivalent?
        diagnostics.none? { |diagnostic| diagnostic.fetch('severity') == 'error' }
      end
    end

    def result
      MigrationResult.new(:schema => deep_copy(@schema), :transforms => @transforms, :diagnostics => @diagnostics)
    end

    def convert(value, pointer, source, root = false, base_uri = nil)
      case value
      when true, false
        value
      when Array
        value.each_with_index { |item, index| convert(item, "#{pointer}/#{index}", source, false, base_uri) }
      when Hash
        nested_source = nested_source(value, source, root)
        next_base_uri = preprocess_hash(value, pointer, nested_source, base_uri)
        value.each_key { |key| convert_child(value, key, pointer, nested_source, next_base_uri) }
        postprocess_hash(value, pointer, nested_source)
      else
        value
      end
    end

    def convert_child(value, key, pointer, source, base_uri)
      location = join_pointer(pointer, key)
      child = value.fetch(key)

      return if %w[enum const default examples].include?(key)

      if key == 'dependencies' && child.is_a?(Hash)
        child.each_key { |dependency| convert(child[dependency], join_pointer(location, dependency), source, false, base_uri) }
      elsif SCHEMA_ARRAY_KEYWORDS.include?(key) && child.is_a?(Array)
        child.each_with_index { |item, index| convert(item, "#{location}/#{index}", source, false, base_uri) }
      elsif SCHEMA_MAP_KEYWORDS.include?(key) && child.is_a?(Hash)
        child.each_key { |name| convert(child[name], join_pointer(location, name), source, false, base_uri) }
      elsif SINGLE_SCHEMA_KEYWORDS.include?(key) && schema_keyword?(child)
        convert(child, location, source, false, base_uri)
      end
    end

    def nested_source(value, fallback, root)
      return fallback if root
      return 'draft202012' if value.fetch('$schema', nil) == TARGET_SCHEMA
      value.key?('$schema') ? (source_draft(value, nil) || fallback) : fallback
    end

    def preprocess_hash(value, pointer, source, base_uri)
      return base_uri unless value.is_a?(Hash) && source != 'draft202012'

      quarantine_unsupported_keywords(value, pointer, source)
      if value.key?('$ref')
        preserve_ref_resource_keywords(value, pointer)
        base_uri
      else
        convert_schema_dialect(value, pointer, source)
        convert_id(value, pointer, source, base_uri)
      end
    end

    def postprocess_hash(value, pointer, source)
      return value unless value.is_a?(Hash)
      return value unless source != 'draft202012'

      diagnose_unknown_keywords(value, pointer, source)
      convert_ref_siblings(value, pointer, source)
      convert_number_boundaries(value, pointer) if source == 'draft4'
      convert_tuple_items(value, pointer)
      detect_non_tuple_additional_items(value, pointer)
      convert_dependencies(value, pointer)
      convert_definitions(value, pointer)
      value
    end

    def preserve_ref_resource_keywords(value, pointer)
      %w[$schema id $id].each do |keyword|
        next unless value.key?(keyword)

        original = value.delete(keyword)
        add_ignored(value, "ignored-ref-sibling-#{keyword}", original)
        diagnostic(join_pointer(pointer, keyword), 'warning', "keyword #{keyword} next to $ref was ignored by the source draft and is preserved as data")
      end
    end

    def convert_schema_dialect(value, pointer, source)
      return unless value.key?('$schema')
      location = join_pointer(pointer, '$schema')
      schema = value.fetch('$schema')
      return if value.key?('$ref')

      if schema.is_a?(String) && %w[draft4 draft7].include?(source_draft(value, nil))
        value['$schema'] = TARGET_SCHEMA
        transform(location, location, 'updated embedded dialect to Draft 2020-12')
      elsif schema != TARGET_SCHEMA
        move_to_extension(value, '$schema', schema)
        diagnostic(location, 'error', 'embedded $schema declares an unsupported dialect')
      end
    end

    def convert_id(value, pointer, source, base_uri)
      id_keyword = source == 'draft4' ? 'id' : '$id'
      return base_uri unless value.key?(id_keyword)

      id = value.delete(id_keyword)
      location = join_pointer(pointer, id_keyword)
      unless id.is_a?(String)
        move_to_extension(value, id_keyword, id)
        diagnostic(location, 'error', 'identifier is not a string')
        return base_uri
      end

      uri = URI.parse(id)
      uri = URI.join(base_uri.to_s, uri) unless uri.absolute? || id.start_with?('#')
      if uri.fragment.nil? || uri.fragment.empty?
        value['$id'] = uri.to_s
        transform(location, join_pointer(pointer, '$id'), 'renamed resource identifier')
        return uri
      end

      fragment = uri.fragment
      if fragment.start_with?('/') || value.key?('$anchor') || !fragment.match?(ANCHOR_REGEX)
        move_to_extension(value, id_keyword, id)
        diagnostic(location, 'error', 'fragment identifier cannot be represented as a Draft 2020-12 $anchor')
        return base_uri
      end
      if value.key?('$id') && id_keyword == 'id'
        move_to_extension(value, '$id', value.fetch('$id'))
        diagnostic(join_pointer(pointer, '$id'), 'error', 'existing $id cannot coexist with a converted Draft 4 fragment identifier')
        return base_uri
      end

      uri.fragment = nil
      value['$id'] = uri.to_s unless id.start_with?('#') || uri.to_s.empty?
      value['$anchor'] = fragment
      transform(location, join_pointer(pointer, '$anchor'), 'split fragment identifier into $id and $anchor')
      uri
    rescue URI::InvalidURIError
      move_to_extension(value, id_keyword, id)
      diagnostic(location, 'error', 'identifier is not a valid URI reference')
      base_uri
    end

    def convert_ref_siblings(value, pointer, source)
      return unless value.key?('$ref')

      ref = value.fetch('$ref')
      location = join_pointer(pointer, '$ref')
      unless ref.is_a?(String)
        move_to_extension(value, '$ref', ref)
        diagnostic(location, 'error', '$ref must be a string')
        return
      end

      value['$ref'] = rewrite_ref(ref, location)

      ignored = {}
      value.keys.each do |key|
        next if key == '$ref' || ANNOTATION_KEYWORDS.include?(key) || key == MIGRATION_EXTENSION
        next if key == 'definitions'
        next if key == '$schema'

        ignored[key] = value.delete(key)
        diagnostic(
          join_pointer(pointer, key),
          'warning',
          "Draft 2020-12 applies sibling keyword `#{key}` next to `$ref`; the old draft ignored it. The rule is preserved as data under `#{MIGRATION_EXTENSION}`."
        )
      end

      if value.key?('definitions')
        value['$defs'] = value.delete('definitions')
        transform(join_pointer(pointer, 'definitions'), join_pointer(pointer, '$defs'), 'moved reference-local definitions to $defs')
      end

      add_ignored(value, 'ignored-ref-siblings', ignored) unless ignored.empty?
      transform(location, location, 'kept $ref and preserved old-draft sibling keywords as non-assertions')
    end

    def rewrite_ref(ref, location)
      if ref.start_with?('#/definitions/')
        rewritten = "#/$defs/#{ref.delete_prefix('#/definitions/')}"
        transform(location, location, 'updated local definitions reference to $defs')
        rewritten
      else
        rewrite_root_ref(ref, location)
      end
    end

    def rewrite_root_ref(ref, location)
      return ref if ref.start_with?('#')

      root_id = @schema.is_a?(Hash) ? @schema.fetch('id', @schema.fetch('$id', nil)) : nil
      uri = URI.parse(ref)
      root_uri = URI.parse(root_id) if root_id.is_a?(String)
      fragment = uri.fragment

      if root_uri && fragment.to_s.start_with?('/definitions/') && same_resource?(uri, root_uri)
        uri.fragment = fragment.sub('/definitions/', '/$defs/')
        transform(location, location, 'updated root definitions reference to $defs')
        uri.to_s
      else
        diagnostic(location, 'error', 'external reference target is not part of the converted schema document')
        ref
      end
    rescue URI::InvalidURIError
      diagnostic(location, 'error', 'reference is not a valid URI reference')
    end

    def same_resource?(uri, root_uri)
      without_fragment(uri) == without_fragment(root_uri)
    end

    def without_fragment(uri)
      uri.dup.tap { |item| item.fragment = nil }.to_s
    end

    def convert_number_boundaries(value, pointer)
      %w[exclusiveMaximum exclusiveMinimum].each do |keyword|
        next unless value.key?(keyword)
        boundary_keyword = keyword == 'exclusiveMaximum' ? 'maximum' : 'minimum'
        location = join_pointer(pointer, keyword)
        exclusive = value.delete(keyword)

        if exclusive == true && value[boundary_keyword].is_a?(Numeric)
          preserve_keyword(value, keyword, pointer) if value.key?(keyword)
          value[keyword] = value.delete(boundary_keyword)
          transform(join_pointer(pointer, boundary_keyword), location, 'converted boolean exclusive boundary to numeric boundary')
        elsif exclusive == false
          transform(location, join_pointer(pointer, boundary_keyword), 'removed inactive boolean exclusive boundary')
        else
          move_to_extension(value, keyword, exclusive)
          diagnostic(location, 'error', "`#{keyword}` requires a numeric `#{boundary_keyword}` in Draft 2020-12")
        end
      end
    end

    def convert_tuple_items(value, pointer)
      return unless value['items'].is_a?(Array)

      preserve_keyword(value, 'prefixItems', pointer) if value.key?('prefixItems')
      items = value.delete('items')
      value['prefixItems'] = items
      transform(join_pointer(pointer, 'items'), join_pointer(pointer, 'prefixItems'), 'converted tuple items to prefixItems')

      return unless value.key?('additionalItems')
      additional_items = value.delete('additionalItems')
      value['items'] = additional_items
      transform(join_pointer(pointer, 'additionalItems'), join_pointer(pointer, 'items'), 'converted additionalItems to items')
    end

    def detect_non_tuple_additional_items(value, pointer)
      return unless value.key?('additionalItems') && !value['items'].is_a?(Array)

      diagnostic(join_pointer(pointer, 'additionalItems'), 'warning', 'additionalItems is ignored without tuple items; it is retained as an unknown annotation')
    end

    def convert_dependencies(value, pointer)
      return unless value.key?('dependencies')

      dependencies = value.delete('dependencies')
      unless dependencies.is_a?(Hash)
        move_to_extension(value, 'dependencies', dependencies)
        diagnostic(join_pointer(pointer, 'dependencies'), 'error', 'dependencies must be an object')
        return
      end

      required = {}
      schemas = {}
      invalid = {}
      preserve_keyword(value, 'dependentRequired', pointer) if value.key?('dependentRequired')
      preserve_keyword(value, 'dependentSchemas', pointer) if value.key?('dependentSchemas')
      dependencies.each do |name, dependency|
        case dependency
        when Array
          if dependency.all? { |item| item.is_a?(String) } && !dependency.empty?
            required[name] = dependency
          else
            invalid[name] = dependency
            diagnostic(join_pointer(join_pointer(pointer, 'dependencies'), name), 'error', 'property dependency must be a non-empty string array')
          end
        when true, false, Hash
          schemas[name] = dependency
        else
          invalid[name] = dependency
          diagnostic(join_pointer(join_pointer(pointer, 'dependencies'), name), 'error', 'dependency must be a schema or property-name array')
        end
      end

      unless required.empty?
        value['dependentRequired'] = required
        transform(join_pointer(pointer, 'dependencies'), join_pointer(pointer, 'dependentRequired'), 'split property-array dependencies into dependentRequired')
      end
      unless schemas.empty?
        value['dependentSchemas'] = schemas
        transform(join_pointer(pointer, 'dependencies'), join_pointer(pointer, 'dependentSchemas'), 'split schema dependencies into dependentSchemas')
      end
      add_ignored(value, 'invalid-dependencies', invalid) unless invalid.empty?
    end

    def convert_definitions(value, pointer)
      return unless value.key?('definitions') && !value.key?('$ref')

      definitions = value.fetch('definitions')
      if definitions.is_a?(Hash)
        preserve_keyword(value, '$defs', pointer) if value.key?('$defs')
        value['$defs'] = value.delete('definitions')
        transform(join_pointer(pointer, 'definitions'), join_pointer(pointer, '$defs'), 'renamed definitions to $defs')
      else
        diagnostic(join_pointer(pointer, 'definitions'), 'error', 'definitions must be an object')
      end
    end

    def diagnose_unknown_keywords(value, pointer, source)
      meta_schema = JSONSchemer.public_send(source)
      value.keys.each do |keyword|
        next if keyword == MIGRATION_EXTENSION
        next if meta_schema.keywords.key?(keyword)
        next if %w[enum const default examples].include?(keyword)
        next if ANNOTATION_KEYWORDS.include?(keyword)
        next if unsupported_keyword?(keyword, source)

        diagnostic(join_pointer(pointer, keyword), 'warning', "unknown extension `#{keyword}` is preserved, but its semantics cannot be guaranteed across drafts")
      end
    end

    def preserve_keyword(value, keyword, pointer)
      original = value.delete(keyword)
      add_ignored(value, "original-#{keyword}", original)
      diagnostic(join_pointer(pointer, keyword), 'warning', "existing `#{keyword}` was ignored by the source draft and is preserved as data to avoid overwriting it")
    end

    def quarantine_unsupported_keywords(value, pointer, source)
      value.keys.each do |keyword|
        next unless unsupported_keyword?(keyword, source)
        next if value.key?('$ref') && keyword == MIGRATION_EXTENSION

        original = value.fetch(keyword)
        move_to_extension(value, keyword, original)
        diagnostic(join_pointer(pointer, keyword), 'warning', "keyword `#{keyword}` has no guaranteed equivalent in the source draft environment; the rule is preserved as data under `#{MIGRATION_EXTENSION}`.")
      end
    end

    def unsupported_keyword?(keyword, source)
      return false if %w[$schema id $id definitions dependencies items additionalItems exclusiveMaximum exclusiveMinimum].include?(keyword)
      return true if %w[$dynamicAnchor $dynamicRef $recursiveAnchor $recursiveRef unevaluatedItems unevaluatedProperties maxContains minContains $anchor $vocabulary contentSchema].include?(keyword)
      return true if source == 'draft4' && %w[$id const contains propertyNames examples if then else readOnly writeOnly $comment].include?(keyword)
      false
    end

    def move_to_extension(value, keyword, original)
      add_ignored(value, keyword, original)
      value.delete(keyword)
    end

    def add_ignored(value, keyword, original)
      value[MIGRATION_EXTENSION] ||= {}
      value[MIGRATION_EXTENSION][keyword] = original
    end

    def source_draft(value, explicit)
      explicit = explicit.to_s if explicit
      return explicit if %w[draft4 draft7].include?(explicit)
      schema = value.is_a?(Hash) ? value.fetch('$schema', nil) : nil
      normalized = explicit.to_s.sub('draft', '')
      return 'draft4' if DRAFT4_SCHEMAS.include?(schema) || (!schema && normalized == '4')
      return 'draft7' if DRAFT7_SCHEMAS.include?(schema) || (!schema && normalized == '7')
      nil
    end

    def unsupported_schema_diagnostic(pointer, source)
      @diagnostics << {
        'pointer' => pointer,
        'severity' => 'error',
        'message' => "unsupported source draft: #{source.inspect}; expected draft4 or draft7"
      }
    end

    def diagnostic(pointer, severity, message)
      @diagnostics << { 'pointer' => pointer, 'severity' => severity, 'message' => message }
    end

    def transform(from, to, description)
      @transforms << { 'from' => from, 'to' => to, 'description' => description }
    end

    def join_pointer(pointer, token)
      token = token.to_s.gsub('~', '~0').gsub('/', '~1')
      pointer.empty? ? "/#{token}" : "#{pointer}/#{token}"
    end

    def schema_keyword?(value)
      value.is_a?(Hash) || value == true || value == false
    end

    def deep_copy(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, item), out| out[key] = deep_copy(item) }
      when Array
        value.map { |item| deep_copy(item) }
      else
        value
      end
    end
  end
end
