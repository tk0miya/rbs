# frozen_string_literal: true

module RBS
  class Environment
    attr_reader :class_decls
    attr_reader :interface_decls
    attr_reader :type_alias_decls
    attr_reader :constant_decls
    attr_reader :global_decls
    attr_reader :class_alias_decls

    attr_reader :sources

    def declarations
      sources.flat_map(&:declarations)
    end

    class SingleEntry
      attr_reader :name
      attr_reader :context
      attr_reader :decl

      def initialize(name:, decl:, context:)
        @name = name
        @decl = decl
        @context = context
      end
    end

    class ModuleAliasEntry < SingleEntry
    end

    class ClassAliasEntry < SingleEntry
    end

    class InterfaceEntry < SingleEntry
    end

    class TypeAliasEntry < SingleEntry
    end

    class ConstantEntry < SingleEntry
    end

    class GlobalEntry < SingleEntry
    end

    def initialize
      @sources = []
      @class_decls = {}
      @interface_decls = {}
      @type_alias_decls = {}
      @constant_decls = {}
      @global_decls = {}
      @class_alias_decls = {}
      @normalize_module_name_cache = {}
    end

    def initialize_copy(other)
      @sources = other.sources.dup
      @class_decls = other.class_decls.dup
      @interface_decls = other.interface_decls.dup
      @type_alias_decls = other.type_alias_decls.dup
      @constant_decls = other.constant_decls.dup
      @global_decls = other.global_decls.dup
      @class_alias_decls = other.class_alias_decls.dup
      @normalize_module_name_cache = {}
    end

    # Replace the contents of `self` with those of `other`.
    #
    # Useful when callers hold a reference to an `Environment` and need its
    # contents to be swapped for a freshly built one (e.g. after name resolution).
    #
    def replace_contents_from(other)
      initialize_copy(other)
      self
    end

    def self.from_loader(loader, resolve: false)
      self.new.tap do |env|
        loader.load(env: env, resolve: resolve)
      end
    end

    def interface_name?(name)
      interface_decls.key?(name)
    end

    def type_alias_name?(name)
      type_alias_decls.key?(name)
    end

    def module_name?(name)
      class_decls.key?(name) || class_alias_decls.key?(name)
    end

    def type_name?(name)
      interface_name?(name) ||
        type_alias_name?(name) ||
        module_name?(name)
    end

    def constant_name?(name)
      constant_decl?(name) || module_name?(name)
    end

    def constant_decl?(name)
      constant_decls.key?(name)
    end

    def class_decl?(name)
      class_decls[name].is_a?(ClassEntry)
    end

    def module_decl?(name)
      class_decls[name].is_a?(ModuleEntry)
    end

    def module_alias?(name)
      if decl = class_alias_decls[name]
        decl.decl.is_a?(AST::Declarations::ModuleAlias)
      else
        false
      end
    end

    def class_alias?(name)
      if decl = class_alias_decls[name]
        decl.decl.is_a?(AST::Declarations::ClassAlias)
      else
        false
      end
    end

    def class_entry(type_name, normalized: false)
      case entry = constant_entry(type_name, normalized: normalized || false)
      when ClassEntry, ClassAliasEntry
        entry
      end
    end

    def module_entry(type_name, normalized: false)
      case entry = constant_entry(type_name, normalized: normalized || false)
      when ModuleEntry, ModuleAliasEntry
        entry
      end
    end

    def normalized_class_entry(type_name)
      if name = normalize_module_name?(type_name)
        case entry = class_entry(name)
        when ClassEntry, nil
          entry
        when ClassAliasEntry
          raise
        end
      end
    end

    def normalized_module_entry(type_name)
      module_entry(type_name, normalized: true)
    end

    def module_class_entry(type_name, normalized: false)
      entry = constant_entry(type_name, normalized: normalized || false)
      if entry.is_a?(ConstantEntry)
        nil
      else
        entry
      end
    end

    def normalized_module_class_entry(type_name)
      module_class_entry(type_name, normalized: true)
    end

    def constant_entry(type_name, normalized: false)
      if normalized
        if normalized_name = normalize_module_name?(type_name)
          class_decls.fetch(normalized_name, nil)
        else
          # The type_name may be declared with constant declaration
          unless type_name.namespace.empty?
            parent = type_name.namespace.to_type_name
            normalized_parent = normalize_module_name?(parent) or return
            constant_name = TypeName[normalized_parent.to_namespace, type_name.name]
            constant_decls.fetch(constant_name, nil)
          end
        end
      else
        class_decls.fetch(type_name, nil) ||
          class_alias_decls.fetch(type_name, nil) ||
          constant_decls.fetch(type_name, nil)
      end
    end

    def normalize_type_name?(name)
      return normalize_module_name?(name) if name.class?

      type_name =
        unless name.namespace.empty?
          parent = name.namespace.to_type_name
          parent = normalize_module_name?(parent)
          return parent unless parent

          TypeName[parent.to_namespace, name.name]
        else
          name
        end

      if type_name?(type_name)
        type_name
      end
    end

    def normalize_type_name!(name)
      result = normalize_type_name?(name)

      case result
      when TypeName
        result
      when false
        raise "Type name `#{name}` cannot be normalized because it's a cyclic definition"
      when nil
        raise "Type name `#{name}` cannot be normalized because of unknown type name in the path"
      end
    end

    def normalize_type_name(name)
      normalize_type_name?(name) || name
    end

    def normalized_type_name?(type_name)
      case
      when type_name.interface?
        interface_decls.key?(type_name)
      when type_name.class?
        class_decls.key?(type_name)
      when type_name.alias?
        type_alias_decls.key?(type_name)
      else
        false
      end
    end

    def normalized_type_name!(name)
      normalized_type_name?(name) or raise "Normalized type name is expected but given `#{name}`"
      name
    end

    def normalize_module_name?(name)
      raise "Class/module name is expected: #{name}" unless name.class?
      name = name.absolute! unless name.absolute?

      original_name = name

      if @normalize_module_name_cache.key?(original_name)
        return @normalize_module_name_cache[original_name]
      end

      if alias_entry = class_alias_decls.fetch(name, nil)
        unless alias_entry.decl.old_name.absolute?
          # Having relative old_name means the type name resolution was failed.
          # Run TypeNameResolver for failure reason
          resolver = RBS::Resolver::TypeNameResolver.build(self)
          name = resolver.resolve_namespace(name, context: nil)
          @normalize_module_name_cache[original_name] = name
          return name
        end

        name = alias_entry.decl.old_name
      end

      if class_decls.key?(name)
        @normalize_module_name_cache[original_name] = name
      end
    end

    def normalize_module_name(name)
      normalize_module_name?(name) || name
    end

    def normalize_module_name!(name)
      normalize_module_name?(name) or raise "Module name `#{name}` cannot be normalized"
    end

    def insert_rbs_decl(decl, context:, namespace:)
      case decl
      when AST::Declarations::Class, AST::Declarations::Module
        name = decl.name.with_prefix(namespace)

        if cdecl = constant_entry(name)
          if cdecl.is_a?(ConstantEntry) || cdecl.is_a?(ModuleAliasEntry) || cdecl.is_a?(ClassAliasEntry)
            raise DuplicatedDeclarationError.new(name, decl, cdecl.decl)
          end
        end

        unless class_decls.key?(name)
          case decl
          when AST::Declarations::Class
            class_decls[name] ||= ClassEntry.new(name)
          when AST::Declarations::Module
            class_decls[name] ||= ModuleEntry.new(name)
          end
        end

        existing_entry = class_decls[name]

        case
        when decl.is_a?(AST::Declarations::Module) && existing_entry.is_a?(ModuleEntry)
          existing_entry << [context, decl]
        when decl.is_a?(AST::Declarations::Class) && existing_entry.is_a?(ClassEntry)
          existing_entry << [context, decl]
        else
          raise DuplicatedDeclarationError.new(name, decl, existing_entry.primary_decl)
        end

        inner_context = [context, name] #: Resolver::context
        inner_namespace = name.to_namespace
        decl.each_decl do |d|
          insert_rbs_decl(d, context: inner_context, namespace: inner_namespace)
        end

      when AST::Declarations::Interface
        name = decl.name.with_prefix(namespace)

        if interface_entry = interface_decls[name]
          raise DuplicatedDeclarationError.new(name, decl, interface_entry.decl)
        end

        interface_decls[name] = InterfaceEntry.new(name: name, decl: decl, context: context)

      when AST::Declarations::TypeAlias
        name = decl.name.with_prefix(namespace)

        if entry = type_alias_decls[name]
          raise DuplicatedDeclarationError.new(name, decl, entry.decl)
        end

        type_alias_decls[name] = TypeAliasEntry.new(name: name, decl: decl, context: context)

      when AST::Declarations::Constant
        name = decl.name.with_prefix(namespace)

        if entry = constant_entry(name)
          case entry
          when ClassAliasEntry, ModuleAliasEntry, ConstantEntry
            raise DuplicatedDeclarationError.new(name, decl, entry.decl)
          when ClassEntry, ModuleEntry
            raise DuplicatedDeclarationError.new(name, decl, *entry.each_decl.to_a)
          end
        end

        constant_decls[name] = ConstantEntry.new(name: name, decl: decl, context: context)

      when AST::Declarations::Global
        if entry = global_decls[decl.name]
          raise DuplicatedDeclarationError.new(decl.name, decl, entry.decl)
        end

        global_decls[decl.name] = GlobalEntry.new(name: decl.name, decl: decl, context: context)

      when AST::Declarations::ClassAlias, AST::Declarations::ModuleAlias
        name = decl.new_name.with_prefix(namespace)

        if entry = constant_entry(name)
          case entry
          when ClassAliasEntry, ModuleAliasEntry, ConstantEntry
            raise DuplicatedDeclarationError.new(name, decl, entry.decl)
          when ClassEntry, ModuleEntry
            raise DuplicatedDeclarationError.new(name, decl, *entry.each_decl.to_a)
          end
        end

        case decl
        when AST::Declarations::ClassAlias
          class_alias_decls[name] = ClassAliasEntry.new(name: name, decl: decl, context: context)
        when AST::Declarations::ModuleAlias
          class_alias_decls[name] = ModuleAliasEntry.new(name: name, decl: decl, context: context)
        end
      end
    end

    def insert_ruby_decl(decl, context:, namespace:)
      case decl
      when AST::Ruby::Declarations::ClassDecl
        name = decl.class_name.with_prefix(namespace)

        if entry = constant_entry(name)
          if entry.is_a?(ConstantEntry) || entry.is_a?(ModuleAliasEntry) || entry.is_a?(ClassAliasEntry)
            raise DuplicatedDeclarationError.new(name, decl, entry.decl)
          end
          if entry.is_a?(ModuleEntry)
            raise DuplicatedDeclarationError.new(name, decl, *entry.each_decl.to_a)
          end
        else
          entry = class_decls[name] = ClassEntry.new(name)
        end

        entry << [context, decl]

        inner_context = [context, name] #: Resolver::context
        decl.each_decl do |member|
          insert_ruby_decl(member, context: inner_context, namespace: name.to_namespace)
        end

      when AST::Ruby::Declarations::ModuleDecl
        name = decl.module_name.with_prefix(namespace)

        if entry = constant_entry(name)
          if entry.is_a?(ConstantEntry) || entry.is_a?(ModuleAliasEntry) || entry.is_a?(ClassAliasEntry)
            raise DuplicatedDeclarationError.new(name, decl, entry.decl)
          end
          if entry.is_a?(ClassEntry)
            raise DuplicatedDeclarationError.new(name, decl, *entry.each_decl.to_a)
          end
        else
          entry = class_decls[name] = ModuleEntry.new(name)
        end

        entry << [context, decl]

        inner_context = [context, name] #: Resolver::context
        decl.each_decl do |member|
          insert_ruby_decl(member, context: inner_context, namespace: name.to_namespace)
        end

      when AST::Ruby::Declarations::ConstantDecl
        name = decl.constant_name.with_prefix(namespace)

        if entry = constant_entry(name)
          case entry
          when ClassAliasEntry, ModuleAliasEntry, ConstantEntry
            raise DuplicatedDeclarationError.new(name, decl, entry.decl)
          when ClassEntry, ModuleEntry
            raise DuplicatedDeclarationError.new(name, decl, *entry.each_decl.to_a)
          end
        end

        constant_decls[name] = ConstantEntry.new(name: name, decl: decl, context: context)

      when AST::Ruby::Declarations::ClassModuleAliasDecl
        name = decl.new_name.with_prefix(namespace)

        if entry = constant_entry(name)
          case entry
          when ClassAliasEntry, ModuleAliasEntry, ConstantEntry
            raise DuplicatedDeclarationError.new(name, decl, entry.decl)
          when ClassEntry, ModuleEntry
            raise DuplicatedDeclarationError.new(name, decl, *entry.each_decl.to_a)
          end
        end

        case decl.annotation
        when AST::Ruby::Annotations::ClassAliasAnnotation
          class_alias_decls[name] = ClassAliasEntry.new(name: name, decl: decl, context: context)
        when AST::Ruby::Annotations::ModuleAliasAnnotation
          class_alias_decls[name] = ModuleAliasEntry.new(name: name, decl: decl, context: context)
        end
      else
        raise "Unknown Ruby declaration type: #{decl.class}"
      end
    end

    def add_source(source)
      sources << source

      case source
      when Source::RBS
        source.declarations.each do |decl|
          insert_rbs_decl(decl, context: nil, namespace: Namespace.root)
        end
      when Source::Ruby
        source.declarations.each do |dir|
          insert_ruby_decl(dir, context: nil, namespace: Namespace.root)
        end
      end
    end

    def each_rbs_source(&block)
      if block
        sources.each do |source|
          if source.is_a?(Source::RBS)
            yield source
          end
        end
      else
        enum_for(:each_rbs_source)
      end
    end

    def each_ruby_source(&block)
      if block
        sources.each do |source|
          if source.is_a?(Source::Ruby)
            yield source
          end
        end
      else
        enum_for(:each_ruby_source)
      end
    end

    def validate_type_params
      class_decls.each_value do |decl|
        decl.validate_type_params
      end
    end

    def resolve_type_names(only: nil)
      Resolver.new(self).call(only: only)
    end

    def inspect
      ivars = %i[@sources @class_decls @class_alias_decls @interface_decls @type_alias_decls @constant_decls @global_decls]
      "\#<RBS::Environment #{ivars.map { |iv| "#{iv}=(#{instance_variable_get(iv).size} items)"}.join(' ')}>"
    end

    def buffers
      sources.map(&:buffer)
    end

    def unload(paths)
      ps = Set[]
      paths.each do |path|
        if path.is_a?(Buffer)
          ps << path.name
        else
          ps << path
        end
      end

      env = Environment.new()

      each_rbs_source do |source|
        next if ps.include?(source.buffer.name)
        env.add_source(source)
      end

      each_ruby_source do |source|
        next if ps.include?(source.buffer.name)
        env.add_source(source)
      end

      env
    end
  end
end
