# frozen_string_literal: true
module JSONSchemer
  class SchemaMigration
    attr_reader :source, :schema, :changes, :diagnostics

    def initialize(source, schema, changes, diagnostics)
      @source = source
      @schema = schema
      @changes = changes
      @diagnostics = diagnostics
    end

    def valid?
      diagnostics.none? { |diagnostic| diagnostic['severity'] == 'error' }
    end
    alias equivalent? valid?

    def to_h
      {
        'source' => source,
        'schema' => schema,
        'changes' => changes,
        'diagnostics' => diagnostics
      }
    end
  end

  class SchemaMigrator
    TARGET = 'https://json-schema.org/draft/2020-12/schema'
    IGNORED_KEY = 'x-json-schemer-ignored-keywords'
    ANCHOR_REGEX = /\A[A-Za-z_][-A-Za-z0-9._]*\z/

    DRAFTS = {
      'draft4' => {
        :id_keyword => 'id',
        :boolean_schemas => false
      },
      'draft7' => {
        :id_keyword => '$id',
        :boolean_schemas => true
      },
      'draft6' => {
        :id_keyword => '$id',
        :boolean_schemas => true
      }
    }.freeze

    DRAFT_URIS = {
      'http://json-schema.org/draft-04/schema' => 'draft4',
      'http://json-schema.org/draft-04/schema#' => 'draft4',
      'http://json-schema.org/schema' => 'draft4',
      'http://json-schema.org/schema#' => 'draft4',
      'http://json-schema.org/draft-06/schema' => 'draft6',
      'http://json-schema.org/draft-06/schema#' => 'draft6',
      'http://json-schema.org/draft-07/schema' => 'draft7',
      'http://json-schema.org/draft-07/schema#' => 'draft7'
    }.freeze

    TARGET_SEMANTIC_KEYS = [
      Draft202012::Vocab::CORE.keys,
      Draft202012::Vocab::APPLICATOR.keys,
      Draft202012::Vocab::VALIDATION.keys,
      Draft202012::Vocab::UNEVALUATED.keys,
      Draft202012::Vocab::CONTENT.keys
    ].flatten.uniq.freeze

    ANNOTATION_KEYS = [
      'title', 'description', 'default', 'examples', 'deprecated', 'readOnly', 'writeOnly',
      '$comment', 'x-error'
    ].freeze

    def self.migrate(schema, from: nil)
      new.migrate(schema, from: from)
    end

    def initialize
      @changes = []
      @diagnostics = []
      @definition_maps = []
      @structural_maps = []
      @converted_nodes = {}
      @original_target_nodes = {}
    end

    def migrate(schema, from: nil)
      source = deep_dup(parse_schema(schema))
      @original_schema = source
      unless source.is_a?(Hash) || source == true || source == false
        diagnostic('', 'invalid-schema', 'schema must be an object or boolean', 'error')
        return SchemaMigration.new('unknown', source, @changes, @diagnostics)
      end

      source_draft = detect_draft(source, from)
      if source_draft == '2020-12'
        return SchemaMigration.new(source_draft, source, [], [])
      end

      unless DRAFTS.key?(source_draft)
        diagnostic('', 'unsupported-source-draft', "unsupported source draft: #{source_draft}", 'error')
        return SchemaMigration.new(source_draft, source, @changes, @diagnostics)
      end

      converted = migrate_node(source, [], source_draft, true)
      rewrite_refs(converted, [], true)
      SchemaMigration.new(source_draft, converted, @changes, @diagnostics)
    end

    private

    def parse_schema(schema)
      schema
    end

    def detect_draft(schema, from)
      return normalize_draft(from) if from

      declared = nil
      declared = schema['$schema'] if schema.is_a?(Hash)
      if !declared.nil? && !declared.empty?
        return normalize_draft(declared)
      end

      if schema.is_a?(Hash) && ((schema['exclusiveMaximum'].is_a?(TrueClass) || schema['exclusiveMinimum'].is_a?(TrueClass)) || (schema['exclusiveMaximum'] == false || schema['exclusiveMinimum'] == false))
        'draft4'
      else
        'draft7'
      end
    end

    def normalize_draft(value)
      case value.to_s
      when 'draft4', '4', '04' then 'draft4'
      when 'draft6', '6', '06' then 'draft6'
      when 'draft7', '7', '07' then 'draft7'
      when '2020-12', 'draft2020-12', Draft202012::BASE_URI.to_s
        '2020-12'
      when '2019-09', 'draft2019-09', Draft201909::BASE_URI.to_s
        '2019-09'
      else
        DRAFT_URIS.fetch(value.to_s, value.to_s)
      end
    end

    def source_keywords(draft)
      @source_keywords ||= {}
      @source_keywords[draft] ||= if draft == 'draft4'
        JSONSchemer.draft4.keywords
      elsif draft == 'draft6'
        JSONSchemer.draft6.keywords
      else
        JSONSchemer.draft7.keywords
      end
    end

    def target_semantic_key?(key)
      TARGET_SEMANTIC_KEYS.include?(key)
    end

    def annotation_key?(key)
      ANNOTATION_KEYS.include?(key)
    end

    def unknown_extension?(key)
      key.start_with?('x-') && key != IGNORED_KEY && key != 'x-error'
    end

    def migrate_node(node, path, draft, root_node = false)
      if node.equal?(true) || node.equal?(false)
        if !DRAFTS.fetch(draft)[:boolean_schemas] && root_node
          diagnostic(path, 'boolean-schema', 'boolean schemas are not valid in Draft 4 and have no equivalent source semantics', 'error')
        end
        mark_converted(node)
        node
      else
        migrate_object(node, path, draft, root_node)
      end
    end

    def migrate_object(object, path, draft, root_node)
      result = object.dup
      node_draft = draft

      if result.key?('$schema')
        declared = normalize_draft(result['$schema'])
        if root_node
          result.delete('$schema')
        elsif declared == '2020-12'
          duplicate = deep_dup(object)
          @original_target_nodes[duplicate.object_id] = true
          return duplicate
        elsif DRAFTS.key?(declared)
          node_draft = declared
          result.delete('$schema')
        else
          diagnostic(path, 'embedded-dialect', "embedded $schema cannot be migrated: #{object['$schema']}", 'error')
          duplicate = deep_dup(object)
          @original_target_nodes[duplicate.object_id] = true
          return duplicate
        end
      end

      mark_converted(result)
      quarantine_target_only_keywords(result, path, node_draft)

      if result.key?('$ref')
        preserve_exclusive_ref_scope(result, path, node_draft)
        migrate_identifier(result, path, node_draft)
        migrate_definitions_contents(result, path, node_draft)
      else
        migrate_draft4_boundaries(result, path) if node_draft == 'draft4'
        migrate_identifier(result, path, node_draft)
        migrate_content_assertions(result, path, node_draft)
        migrate_tuple_items(result, path, node_draft)
        split_dependencies(result, path, node_draft)
        convert_definitions(result, path, node_draft)
        migrate_nested_schemas(result, path, node_draft)
        warn_draft4_integer(result, path, node_draft)
      end

      if root_node
        result['$schema'] = TARGET
        add_change(path, '$schema', path, '$schema', 'set target meta-schema to Draft 2020-12')
      end

      unless result.key?('$ref')
        result.keys.each do |key|
          if unknown_extension?(key)
            diagnostic(path + [key], 'custom-extension', 'custom extensions may change validation behavior; verify the extension in the Draft 2020-12 environment', 'warning')
          end
        end
      end

      result
    end

    def quarantine_target_only_keywords(object, path, draft)
      keywords = source_keywords(draft)
      object.keys.each do |key|
        next if key == 'definitions' || annotation_key?(key) || key == IGNORED_KEY
        next unless target_semantic_key?(key) && !keywords.key?(key)
        next if %w[contentEncoding contentMediaType contentSchema].include?(key) && draft != 'draft7'

        move_ignored_keyword(object, key, path + [key], 'target keyword is not recognized by the source draft and was ignored there', 'warning')
      end
    end

    def preserve_exclusive_ref_scope(object, path, draft)
      keywords = source_keywords(draft)
      object.keys.each do |key|
        next if key == '$ref' || key == 'definitions' || key == IGNORED_KEY
        next if annotation_key?(key)

        if unknown_extension?(key)
          diagnostic(path + [key], 'ref-sibling-extension', 'sibling custom extension of $ref was ignored by the source draft; retain it only after verifying the target environment', 'warning')
        end
        if keywords.key?(key)
          move_ignored_keyword(object, key, path + [key], 'sibling keyword of $ref was ignored before Draft 2019-09', 'warning')
        end
      end
    end

    def migrate_draft4_boundaries(object, path)
      boundaries = {
        'exclusiveMaximum' => 'maximum',
        'exclusiveMinimum' => 'minimum'
      }

      boundaries.each do |exclusive_key, boundary_key|
        next unless object.key?(exclusive_key)

        value = object[exclusive_key]
        if value.equal?(true) || value.equal?(false)
        if value.equal?(false)
          object.delete(exclusive_key)
          add_change(path + [exclusive_key], exclusive_key, path + [exclusive_key], exclusive_key, "removed no-op Draft 4 boolean #{exclusive_key}")
        elsif object.key?(boundary_key)
          object[exclusive_key] = object[boundary_key]
          add_change(path + [exclusive_key], exclusive_key, path + [exclusive_key], exclusive_key, "expanded Draft 4 boolean #{exclusive_key} with #{boundary_key} value")
        else
          diagnostic(path + [exclusive_key], 'missing-boundary', "#{exclusive_key}=true requires #{boundary_key}; rule was removed", 'error')
        end
        object.delete(exclusive_key) unless object.key?(boundary_key) || value.equal?(false)
        else
          move_ignored_keyword(object, exclusive_key, path + [exclusive_key], "Draft 4 #{exclusive_key} must be boolean; non-boolean value was not a valid source rule")
        end
      end
    end

    def migrate_identifier(object, path, draft)
      id_keyword = DRAFTS.fetch(draft)[:id_keyword]
      return unless object.key?(id_keyword)

      value = object[id_keyword]
      unless value.is_a?(String)
        move_ignored_keyword(object, id_keyword, path + [id_keyword], "#{id_keyword} must be a string")
        return
      end

      begin
        uri = URI.parse(value)
      rescue URI::InvalidURIError
        move_ignored_keyword(object, id_keyword, path + [id_keyword], "invalid URI in #{id_keyword}")
        return
      end

      fragment = uri.fragment
      uri.fragment = nil
      base = uri.to_s

      if fragment.nil? || fragment.empty? || fragment.start_with?('/')
        object.delete(id_keyword)
        object['$id'] = base unless base.empty?
        if fragment
          store_raw_ignored(object, id_keyword, value, path + [id_keyword], 'JSON Pointer fragment identifiers cannot be represented as a Draft 2020-12 $anchor', 'error')
        end
        destination = object.key?('$id') ? path + ['$id'] : path
        add_change(path + [id_keyword], id_keyword, destination, '$id', "renamed #{id_keyword} to $id")
        return
      end

      object.delete(id_keyword)
      if ANCHOR_REGEX.match?(fragment)
        object['$anchor'] = fragment
        object['$id'] = base unless base.empty?
        add_change(path + [id_keyword], id_keyword, path + ['$anchor'], '$anchor', 'moved plain-name fragment to $anchor')
      else
        object['$id'] = base unless base.empty?
        store_raw_ignored(object, id_keyword, value, path + [id_keyword], "plain-name fragment #{fragment.inspect} is not a valid Draft 2020-12 $anchor", 'error')
      end
    end

    def migrate_content_assertions(object, path, draft)
      return unless draft == 'draft7'

      %w[contentEncoding contentMediaType].each do |key|
        next unless object.key?(key)

        move_ignored_keyword(object, key, path + [key], 'Draft 7 content assertions are annotations in Draft 2020-12')
      end
    end

    def warn_draft4_integer(object, path, draft)
      return unless draft == 'draft4' && object.key?('type')

      types = Array(object['type'])
      return unless types.include?('integer')

      diagnostic(path + ['type'], 'integer-semantics', 'Draft 4 only accepts Ruby Integer values for type integer, while Draft 2020-12 also accepts numeric values with zero fractional parts', 'warning')
    end

    def migrate_tuple_items(object, path, draft)
      return unless object.key?('items') && object['items'].is_a?(Array)

      tuple = object.delete('items')
      invalid = tuple.reject { |item| valid_schema_node?(item, draft) }
      if tuple.empty? || invalid.any?
        object['items'] = tuple
        move_ignored_keyword(object, 'items', path + ['items'], 'tuple items must be a non-empty array of schemas')
        return
      end

      object['prefixItems'] = tuple.map.with_index do |item, index|
        migrate_node(item, path + ['items', index.to_s], draft)
      end
      @structural_maps << { :old => path + ['items'], :new => path + ['prefixItems'] }
      add_change(path + ['items'], 'items', path + ['prefixItems'], 'prefixItems', 'moved tuple item schemas to prefixItems')

      if object.key?('additionalItems')
        additional = object.delete('additionalItems')
        if valid_schema_node?(additional, draft)
          object['items'] = migrate_node(additional, path + ['additionalItems'], draft)
          @structural_maps << { :old => path + ['additionalItems'], :new => path + ['items'] }
          add_change(path + ['additionalItems'], 'additionalItems', path + ['items'], 'items', 'moved additional tuple item schema to items')
        else
          store_raw_ignored(object, 'additionalItems', additional, path + ['additionalItems'], 'additionalItems must be a schema')
        end
      end
    end

    def split_dependencies(object, path, draft)
      return unless object.key?('dependencies')

      dependencies = object.delete('dependencies')
      unless dependencies.is_a?(Hash)
        store_raw_ignored(object, 'dependencies', dependencies, path + ['dependencies'], 'dependencies must be an object')
        return
      end

      dependent_schemas = {}
      dependent_required = {}

      dependencies.each do |key, value|
        if value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
          dependent_required[key] = value.uniq
          if value.uniq.length != value.length
            add_change(path + ['dependencies', key], 'dependencies', path + ['dependentRequired', key], 'dependentRequired', 'removed duplicate required property entries')
          end
        elsif valid_schema_node?(value, draft)
          dependent_schemas[key] = migrate_node(value, path + ['dependencies', key], draft)
        else
          store_raw_ignored(object, "dependencies/#{key}", value, path + ['dependencies', key], 'dependency must be a schema or an array of unique strings')
        end
      end

      unless dependent_schemas.empty?
        object['dependentSchemas'] = dependent_schemas
        @structural_maps << { :old => path + ['dependencies'], :new => path + ['dependentSchemas'] }
        add_change(path + ['dependencies'], 'dependencies', path + ['dependentSchemas'], 'dependentSchemas', 'moved schema dependencies to dependentSchemas')
      end

      unless dependent_required.empty?
        object['dependentRequired'] = dependent_required
        @structural_maps << { :old => path + ['dependencies'], :new => path + ['dependentRequired'] }
        add_change(path + ['dependencies'], 'dependencies', path + ['dependentRequired'], 'dependentRequired', 'moved property dependencies to dependentRequired')
      end
    end

    def convert_definitions(object, path, draft)
      return unless object.key?('definitions')

      definitions = object.delete('definitions')
      unless definitions.is_a?(Hash)
        store_raw_ignored(object, 'definitions', definitions, path + ['definitions'], 'definitions must be an object')
        return
      end

      converted_defs = migrated_definitions(definitions, object, path, draft)

      object['$defs'] = converted_defs
      @definition_maps << { :old => path + ['definitions'], :new => path + ['$defs'] }
      add_change(path + ['definitions'], 'definitions', path + ['$defs'], '$defs', 'moved definitions to $defs')
    end

    def migrate_definitions_contents(object, path, draft)
      definitions = object['definitions']
      return unless definitions.is_a?(Hash)

      invalid_definitions = []
      definitions.each do |key, value|
        if valid_schema_node?(value, draft)
          definitions[key] = migrate_definition_node(value, path + ['definitions', key], draft)
        else
          invalid_definitions << [key, value]
        end
      end
      invalid_definitions.each do |key, value|
        definitions.delete(key)
        store_raw_ignored(object, "definitions/#{key}", value, path + ['definitions', key], 'definition value must be a schema')
      end

      object.delete('definitions')
      return if definitions.empty?

      object['$defs'] = definitions
      @definition_maps << { :old => path + ['definitions'], :new => path + ['$defs'] }
      add_change(path + ['definitions'], 'definitions', path + ['$defs'], '$defs', 'moved definitions to $defs')
    end

    def migrated_definitions(definitions, object, path, draft)
      definitions.each_with_object({}) do |(key, value), result|
        if valid_schema_node?(value, draft)
          result[key] = migrate_definition_node(value, path + ['definitions', key], draft)
        else
          store_raw_ignored(object, "definitions/#{key}", value, path + ['definitions', key], 'definition value must be a schema')
        end
      end
    end

    def migrate_definition_node(value, path, draft)
      migrate_node(value, path, draft)
    end

    def migrate_nested_schemas(object, path, draft)
      %w[allOf anyOf oneOf].each do |key|
        next unless object.key?(key)

        value = object[key]
        if value.is_a?(Array) && !value.empty? && value.all? { |item| valid_schema_node?(item, draft) }
          object[key] = value.map.with_index do |item, index|
            migrate_node(item, path + [key, index.to_s], draft)
          end
        else
          move_ignored_keyword(object, key, path + [key], "#{key} must be an array of schemas")
        end
      end

      single_keys = %w[not if then else additionalProperties contains items propertyNames unevaluatedItems unevaluatedProperties]
      single_keys.each do |key|
        next unless object.key?(key)

        if valid_schema_node?(object[key], draft)
          object[key] = migrate_node(object[key], path + [key], draft)
        else
          move_ignored_keyword(object, key, path + [key], "#{key} must be a schema")
        end
      end

      %w[properties patternProperties].each do |key|
        next unless object.key?(key)

        value = object[key]
        unless value.is_a?(Hash)
          move_ignored_keyword(object, key, path + [key], "#{key} must be an object")
          next
        end

        value.each do |property, child|
          if valid_schema_node?(child, draft)
            value[property] = migrate_node(child, path + [key, property], draft)
          else
            store_raw_ignored(object, "#{key}/#{property}", child, path + [key, property], "#{key} values must be schemas")
            value.delete(property)
          end
        end
        object.delete(key) if value.empty? && object[key].equal?(value)
      end
    end

    def valid_schema_node?(value, draft)
      return true if value == true || value == false
      value.is_a?(Hash) && (draft != 'draft4' || !value.key?('$schema') || DRAFTS.key?(normalize_draft(value['$schema'])) || normalize_draft(value['$schema']) == '2020-12')
    end

    def move_ignored_keyword(object, key, source_location, message, severity = 'error')
      value = object.delete(key)
      store_raw_ignored(object, key, value, source_location, message, severity)
    end

    def unique_key(object, base_key)
      return base_key unless object.key?(base_key)

      "#{base_key}-1"
    end

    def store_raw_ignored(object, name, value, source_location, message, severity = 'error')
      ignored = object[IGNORED_KEY].is_a?(Hash) ? object[IGNORED_KEY] : {}
      key = unique_key(ignored, name)
      ignored[key] = value
      object[IGNORED_KEY] = ignored

      destination = source_location + [IGNORED_KEY, key]
      add_change(source_location, name, destination, key, "preserved non-portable rule under #{IGNORED_KEY}")
      diagnostic(source_location, 'non-equivalent-rule', message, severity)
    end

    def rewrite_refs(node, path, marked_schema = false)
      return if @original_target_nodes.key?(node.object_id)

      case node
      when Hash
        rewrite_ref(node, path) if node.key?('$ref')
        rewrite_array_keyword(node, path, 'prefixItems')
        %w[allOf anyOf oneOf].each { |key| rewrite_array_keyword(node, path, key) }
        %w[not if then else items additionalProperties contains propertyNames unevaluatedItems unevaluatedProperties].each do |key|
          value = node[key]
          rewrite_refs(value, path + [key], true) if value.is_a?(Hash) || value == true || value == false
        end
        %w[properties patternProperties dependentSchemas].each { |key| rewrite_schema_map(node[key], path + [key]) }
        if node['$defs'].is_a?(Hash)
          rewrite_defs_map(node['$defs'], path + ['$defs'])
        end
      end
    end

    def rewrite_array_keyword(object, path, key)
      return unless object[key].is_a?(Array)

      object[key].each_with_index do |item, index|
        rewrite_refs(item, path + [key, index.to_s], true)
      end
    end

    def rewrite_schema_map(map, path)
      return unless map.is_a?(Hash)

      map.each { |key, child| rewrite_refs(child, path + [key], true) }
    end

    def rewrite_defs_map(map, path)
      map.each do |key, child|
        rewrite_refs(child, path + [key], true)
      end
    end

    def rewrite_ref(object, path)
      value = object['$ref']
      unless value.is_a?(String)
        diagnostic(path + ['$ref'], 'invalid-ref', '$ref must be a string', 'error')
        return
      end

      begin
        uri = URI.parse(value)
      rescue URI::InvalidURIError
        diagnostic(path + ['$ref'], 'invalid-ref', "invalid URI reference: #{value}", 'error')
        return
      end

      unless value.start_with?('#')
        diagnostic(path + ['$ref'], 'external-reference', 'external and relative references were not rewritten; convert the referenced resource in its original reference environment', 'error')
        return
      end

      fragment = uri.fragment
      return if fragment.nil? || fragment.empty? || !fragment.start_with?('/')

      tokens = pointer_tokens(fragment)
      unless tokens
        diagnostic(path + ['$ref'], 'invalid-ref', "invalid JSON Pointer in $ref: #{value}", 'error')
        return
      end

      candidates = reference_maps.select { |item| reference_mapping_matches?(tokens, item) }
      mapping = candidates.max_by { |item| [item[:old].length, item[:new].last == 'dependentSchemas' ? 0 : 1] }
      return unless mapping

      rewritten_tokens = mapping[:new] + tokens[mapping[:old].length..-1].to_a
      rewritten = '#/' + rewritten_tokens.map { |token| encode_uri_fragment_token(token) }.join('/')
      object['$ref'] = rewritten
      add_change(path + ['$ref'], '$ref', path + ['$ref'], '$ref', "rewrote definitions pointer to #{rewritten}")
    end

    def starts_with?(tokens, prefix)
      tokens.length >= prefix.length && tokens[0...prefix.length] == prefix
    end

    def reference_maps
      @definition_maps + @structural_maps
    end

    def reference_mapping_matches?(tokens, mapping)
      old_path = mapping[:old]
      if old_path.last == 'dependencies'
        key = tokens[old_path.length]
        schema_dependency = mapping[:new].last == 'dependentSchemas'
        value = @original_schema.dig(*(old_path + [key]))
        value.is_a?(Hash) == schema_dependency
      else
        starts_with?(tokens, old_path)
      end
    end

    def pointer_tokens(pointer)
      pointer[1..-1].split('/', -1).map do |token|
        decoded_token = token.gsub('~1', '/').gsub('~0', '~')
        decoded = URI.decode_www_form_component(decoded_token)
        return nil unless decoded.valid_encoding?

        decoded
      end
    end

    def encode_json_pointer_token(token)
      Location.escape_json_pointer_token(token.to_s)
    end

    def encode_uri_fragment_token(token)
      encode_json_pointer_token(token).gsub(/[^A-Za-z0-9\-._~!$&'()*+,;=:@\/?]/) do |character|
        "%#{character.ord.to_s(16).upcase.rjust(2, '0')}"
      end
    end

    def add_change(source_location, source_keyword, destination_location, destination_keyword, message)
      @changes << {
        'location' => pointer_from_tokens(source_location),
        'source_keyword' => source_keyword,
        'destination_location' => pointer_from_tokens(destination_location),
        'destination_keyword' => destination_keyword,
        'message' => message
      }
    end

    def diagnostic(location, code, message, severity)
      @diagnostics << {
        'location' => pointer_from_tokens(location),
        'code' => code,
        'message' => message,
        'severity' => severity
      }
    end

    def pointer_from_tokens(tokens)
      return tokens if tokens.is_a?(String)

      tokens.map { |token| encode_json_pointer_token(token) }.join('/').prepend('/')
    end

    def mark_converted(node)
      @converted_nodes[node.object_id] = true
      node
    end

    def deep_dup(value)
      case value
      when Hash
        value.each_with_object({}) do |(key, item), result|
          result[key] = deep_dup(item)
        end
      when Array
        value.map { |item| deep_dup(item) }
      else
        value
      end
    end
  end
end
