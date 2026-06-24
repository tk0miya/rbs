# frozen_string_literal: true

module RBS
  class DefinitionBuilder
    class AncestorBuilder
      class OneAncestors
        attr_reader :type_name
        attr_reader :params
        attr_reader :super_class
        attr_reader :self_types
        attr_reader :included_modules
        attr_reader :included_interfaces
        attr_reader :prepended_modules
        attr_reader :extended_modules
        attr_reader :extended_interfaces

        def initialize(type_name:, params:, super_class:, self_types:, included_modules:, included_interfaces:, prepended_modules:, extended_modules:, extended_interfaces:)
          @type_name = type_name
          @params = params
          @super_class = super_class
          @self_types = self_types
          @included_modules = included_modules
          @included_interfaces = included_interfaces
          @prepended_modules = prepended_modules
          @extended_modules = extended_modules
          @extended_interfaces = extended_interfaces
        end

        def each_ancestor(&block)
          if block
            if s = super_class
              yield s
            end

            each_self_type(&block)
            each_included_module(&block)
            each_included_interface(&block)
            each_prepended_module(&block)
            each_extended_module(&block)
            each_extended_interface(&block)
          else
            enum_for :each_ancestor
          end
        end

        def each_self_type(&block)
          if block
            self_types&.each(&block)
          else
            enum_for :each_self_type
          end
        end

        def each_included_module(&block)
          if block
            included_modules&.each(&block)
          else
            enum_for :each_included_module
          end
        end

        def each_included_interface(&block)
          if block
            included_interfaces&.each(&block)
          else
            enum_for :each_included_interface
          end
        end

        def each_prepended_module(&block)
          if block
            prepended_modules&.each(&block)
          else
            enum_for :each_prepended_module
          end
        end

        def each_extended_module(&block)
          if block
            extended_modules&.each(&block)
          else
            enum_for :each_extended_module
          end
        end

        def each_extended_interface(&block)
          if block
            extended_interfaces&.each(&block)
          else
            enum_for :each_extended_interface
          end
        end

        def self.class_instance(type_name:, params:, super_class:)
          new(
            type_name: type_name,
            params: params,
            super_class: super_class,
            self_types: nil,
            included_modules: [],
            included_interfaces: [],
            prepended_modules: [],
            extended_modules: nil,
            extended_interfaces: nil
          )
        end

        def self.singleton(type_name:, super_class:)
          new(
            type_name: type_name,
            params: nil,
            super_class: super_class,
            self_types: nil,
            included_modules: nil,
            included_interfaces: nil,
            prepended_modules: nil,
            extended_modules: [],
            extended_interfaces: []
          )
        end

        def self.module_instance(type_name:, params:)
          new(
            type_name: type_name,
            params: params,
            self_types: [],
            included_modules: [],
            included_interfaces: [],
            prepended_modules: [],
            super_class: nil,
            extended_modules: nil,
            extended_interfaces: nil
          )
        end

        def self.interface(type_name:, params:)
          new(
            type_name: type_name,
            params: params,
            self_types: nil,
            included_modules: nil,
            included_interfaces: [],
            prepended_modules: nil,
            super_class: nil,
            extended_modules: nil,
            extended_interfaces: nil
          )
        end
      end

      attr_reader :env

      attr_reader :one_instance_ancestors_cache
      attr_reader :instance_ancestors_cache

      attr_reader :one_singleton_ancestors_cache
      attr_reader :singleton_ancestors_cache

      attr_reader :one_interface_ancestors_cache
      attr_reader :interface_ancestors_cache

      def initialize(env:)
        @env = env

        @one_instance_ancestors_cache = {}
        @instance_ancestors_cache = {}

        @one_singleton_ancestors_cache = {}
        @singleton_ancestors_cache = {}

        @one_interface_ancestors_cache = {}
        @interface_ancestors_cache = {}
      end

      # Returns a new AncestorBuilder for `env`, reusing this builder's cached ancestors where they
      # cannot have changed.
      #
      # When this builder has cached ancestors, they are carried over to the new builder except for
      # the type names whose ancestors may have changed (computed by {#changed_type_names}); those are
      # dropped so they are rebuilt lazily against `env`.  When this builder has no cached ancestors,
      # the new builder simply starts empty.  The caller decides what to (re)build afterwards.
      #
      def update(env:)
        AncestorBuilder.new(env: env).tap do |copy|
          # Nothing to reuse: leave the new builder empty so everything is built on demand.
          next if one_instance_ancestors_cache.empty?

          copy.one_instance_ancestors_cache.merge!(one_instance_ancestors_cache)
          copy.instance_ancestors_cache.merge!(instance_ancestors_cache)
          copy.one_singleton_ancestors_cache.merge!(one_singleton_ancestors_cache)
          copy.singleton_ancestors_cache.merge!(singleton_ancestors_cache)
          copy.one_interface_ancestors_cache.merge!(one_interface_ancestors_cache)
          copy.interface_ancestors_cache.merge!(interface_ancestors_cache)

          changed_type_names(env).each do |type_name|
            copy.one_instance_ancestors_cache.delete(type_name)
            copy.instance_ancestors_cache.delete(type_name)
            copy.one_singleton_ancestors_cache.delete(type_name)
            copy.singleton_ancestors_cache.delete(type_name)
            copy.one_interface_ancestors_cache.delete(type_name)
            copy.interface_ancestors_cache.delete(type_name)
          end
        end
      end

      # Returns the set of type names whose ancestors may differ between the current `env` and
      # `new_env`.  {#update} uses this to decide which cached ancestors to drop.
      #
      # The set is computed without resolving the whole ancestor chains:
      #
      # 1. Compare the _ancestor surface_ (super class, mixins, self types and type params) of each
      #    type's declarations.  The type names whose surface differs, are added, or are removed form
      #    the seed set.
      # 2. When a module/class alias's target changes, the type names referring to the alias are added
      #    to the seed, since their normalization result changes.
      # 3. Expand the seed with the descendants in the *current* ancestor graph, because the resolved
      #    ancestors of a type embed the ancestors of its super class and mixins.
      #
      def changed_type_names(new_env)
        old_surface = ancestor_surfaces(env)
        new_surface = ancestor_surfaces(new_env)

        seed = Set[] #: Set[TypeName]
        (old_surface.keys | new_surface.keys).each do |type_name|
          seed << type_name if old_surface[type_name] != new_surface[type_name]
        end

        changed_aliases = changed_alias_names(env, new_env)
        unless changed_aliases.empty?
          referrers = ancestor_reference_index(env)
          changed_aliases.each do |alias_name|
            seed << alias_name
            referrers[alias_name]&.each {|referrer| seed << referrer }
          end
        end

        graph = AncestorGraph.new(env: env, ancestor_builder: self)
        changed = Set[] #: Set[TypeName]
        seed.each do |type_name|
          changed << type_name
          [AncestorGraph::InstanceNode, AncestorGraph::SingletonNode].each do |node_class|
            node = node_class.new(type_name: type_name)
            next unless graph.parents.key?(node) || graph.children.key?(node)
            graph.each_descendant(node) {|descendant| changed << descendant.type_name }
          end
        end
        changed
      end

      def validate_super_class!(type_name, entry)
        with_super_classes = entry.each_decl.select {|decl| decl.super_class }

        return if with_super_classes.size <= 1

        super_types = with_super_classes.map do |decl|
          super_class = decl.super_class or raise
          Types::ClassInstance.new(name: super_class.name, args: super_class.args, location: nil)
        end

        super_types.uniq!

        return if super_types.size == 1

        raise SuperclassMismatchError.new(name: type_name, entry: entry)
      end

      def one_instance_ancestors(type_name)
        type_name = env.normalize_module_name(type_name)

        as = one_instance_ancestors_cache[type_name] and return as

        entry = env.class_decls[type_name] or raise "Unknown name for one_instance_ancestors: #{type_name}"
        params = entry.type_params.each.map(&:name)

        case entry
        when Environment::ClassEntry
          validate_super_class!(type_name, entry)
          primary = entry.primary_decl
          super_class = primary.super_class

          if type_name != BuiltinNames::BasicObject.name
            if super_class
              super_name = super_class.name
              super_args = super_class.args
            else
              super_name = BuiltinNames::Object.name
              super_args = [] #: Array[Types::t]
            end

            super_name = env.normalize_module_name(super_name)

            NoSuperclassFoundError.check!(super_name, env: env, location: primary.location)
            if super_class
              InheritModuleError.check!(super_class, env: env)
              InvalidTypeApplicationError.check2!(type_name: super_class.name, args: super_class.args, env: env, location: super_class.location)
            end

            super_entry = env.class_entry(super_name, normalized: true) or raise
            super_args = AST::TypeParam.normalize_args(super_entry.type_params, super_args)

            ancestors = OneAncestors.class_instance(
              type_name: type_name,
              params: params,
              super_class: Definition::Ancestor::Instance.new(name: super_name, args: super_args, source: :super)
            )
          else
            ancestors = OneAncestors.class_instance(
              type_name: type_name,
              params: params,
              super_class: nil
            )
          end
        when Environment::ModuleEntry
          ancestors = OneAncestors.module_instance(type_name: type_name, params: params)

          self_types = ancestors.self_types or raise
          if entry.self_types.empty?
            self_types.push Definition::Ancestor::Instance.new(name: BuiltinNames::Object.name, args: [], source: nil)
          else
            entry.self_types.each do |module_self|
              NoSelfTypeFoundError.check!(module_self, env: env)
              InvalidTypeApplicationError.check2!(type_name: module_self.name, args: module_self.args, env: env, location: module_self.location)

              module_name = module_self.name
              if module_name.class?
                module_entry = env.module_class_entry(module_name, normalized: true) or raise
                module_name = module_entry.name
                self_args = AST::TypeParam.normalize_args(module_entry.type_params, module_self.args)
              end
              if module_name.interface?
                interface_entry = env.interface_decls.fetch(module_name)
                self_args = AST::TypeParam.normalize_args(interface_entry.decl.type_params, module_self.args)
              end
              self_args or raise

              self_types.push Definition::Ancestor::Instance.new(name: module_name, args: self_args, source: module_self)
            end
          end
        end

        mixin_ancestors(entry,
                        type_name,
                        included_modules: ancestors.included_modules,
                        included_interfaces: ancestors.included_interfaces,
                        prepended_modules: ancestors.prepended_modules,
                        extended_modules: nil,
                        extended_interfaces: nil)

        one_instance_ancestors_cache[type_name] = ancestors
      end

      def one_singleton_ancestors(type_name)
        type_name = env.normalize_module_name(type_name)
        as = one_singleton_ancestors_cache[type_name] and return as

        entry = env.class_decls[type_name] or raise "Unknown name for one_singleton_ancestors: #{type_name}"

        case entry
        when Environment::ClassEntry
          validate_super_class!(type_name, entry)
          primary = entry.primary_decl
          super_class = primary.super_class

          if type_name != BuiltinNames::BasicObject.name
            if super_class
              super_name = super_class.name
            else
              super_name = BuiltinNames::Object.name
            end

            super_name = env.normalize_module_name(super_name)

            NoSuperclassFoundError.check!(super_name, env: env, location: primary.location)
            if super_class
              InheritModuleError.check!(super_class, env: env)
            end

            ancestors = OneAncestors.singleton(
              type_name: type_name,
              super_class: Definition::Ancestor::Singleton.new(name: super_name)
            )
          else
            ancestors = OneAncestors.singleton(
              type_name: type_name,
              super_class: Definition::Ancestor::Instance.new(name: BuiltinNames::Class.name, args: [], source: :super)
            )
          end
        when Environment::ModuleEntry
          ancestors = OneAncestors.singleton(
            type_name: type_name,
            super_class: Definition::Ancestor::Instance.new(name: BuiltinNames::Module.name, args: [], source: :super)
          )
        end

        mixin_ancestors(entry,
                        type_name,
                        included_modules: nil,
                        included_interfaces: nil,
                        prepended_modules: nil,
                        extended_modules: ancestors.extended_modules,
                        extended_interfaces: ancestors.extended_interfaces)

        one_singleton_ancestors_cache[type_name] = ancestors
      end

      def one_interface_ancestors(type_name)
        one_interface_ancestors_cache[type_name] ||=
          begin
            entry = env.interface_decls[type_name] or raise "Unknown name for one_interface_ancestors: #{type_name}"
            params = entry.decl.type_params.each.map(&:name)

            OneAncestors.interface(type_name: type_name, params: params).tap do |ancestors|
              mixin_ancestors0(entry.decl,
                               type_name,
                               align_params: nil,
                               included_modules: nil,
                               included_interfaces: ancestors.included_interfaces,
                               prepended_modules: nil,
                               extended_modules: nil,
                               extended_interfaces: nil)
            end
          end
      end

      def mixin_ancestors0(decl, type_name, align_params:, included_modules:, included_interfaces:, extended_modules:, prepended_modules:, extended_interfaces:)
        case decl
        when AST::Declarations::Base
          decl.each_mixin do |member|
            case member
            when AST::Members::Include
              module_name = member.name
              module_args = member.args.map {|type| align_params ? type.sub(align_params) : type }

              case
              when member.name.class? && included_modules
                MixinClassError.check!(type_name: type_name, env: env, member: member)
                NoMixinFoundError.check!(member.name, env: env, member: member)

                module_decl = env.module_entry(module_name, normalized: true) or raise
                module_args = AST::TypeParam.normalize_args(module_decl.type_params, module_args)

                module_name = env.normalize_module_name(module_name)
                included_modules << Definition::Ancestor::Instance.new(name: module_name, args: module_args, source: member)
              when member.name.interface? && included_interfaces
                NoMixinFoundError.check!(member.name, env: env, member: member)

                interface_decl = env.interface_decls.fetch(module_name)
                module_args = AST::TypeParam.normalize_args(interface_decl.decl.type_params, module_args)

                included_interfaces << Definition::Ancestor::Instance.new(name: module_name, args: module_args, source: member)
              end

            when AST::Members::Prepend
              if prepended_modules
                MixinClassError.check!(type_name: type_name, env: env, member: member)
                NoMixinFoundError.check!(member.name, env: env, member: member)

                module_decl = env.module_entry(member.name, normalized: true) or raise
                module_name = module_decl.name

                module_args = member.args.map {|type| align_params ? type.sub(align_params) : type }
                module_args = AST::TypeParam.normalize_args(module_decl.type_params, module_args)

                prepended_modules << Definition::Ancestor::Instance.new(name: module_name, args: module_args, source: member)
              end

            when AST::Members::Extend
              module_name = member.name
              module_args = member.args

              case
              when member.name.class? && extended_modules
                MixinClassError.check!(type_name: type_name, env: env, member: member)
                NoMixinFoundError.check!(member.name, env: env, member: member)

                module_decl = env.module_entry(module_name, normalized: true) or raise
                module_args = AST::TypeParam.normalize_args(module_decl.type_params, module_args)

                module_name = env.normalize_module_name(module_name)
                extended_modules << Definition::Ancestor::Instance.new(name: module_name, args: module_args, source: member)
              when member.name.interface? && extended_interfaces
                NoMixinFoundError.check!(member.name, env: env, member: member)

                interface_decl = env.interface_decls.fetch(module_name)
                module_args = AST::TypeParam.normalize_args(interface_decl.decl.type_params, module_args)

                extended_interfaces << Definition::Ancestor::Instance.new(name: module_name, args: module_args, source: member)
              end
            end
          end
        when AST::Ruby::Declarations::Base
          decl.members.each do |member|
            case member
            when AST::Ruby::Members::IncludeMember
              if included_modules
                module_name = member.module_name
                module_args = member.type_args

                # Check if mixing in a class (not allowed)
                if env.class_decl?(module_name)
                  raise MixinClassError.new(type_name: type_name, member: member)
                end

                # Check if module exists
                module_decl = env.module_entry(module_name, normalized: true) or raise NoMixinFoundError.new(type_name: module_name, member: member)
                module_args = AST::TypeParam.normalize_args(module_decl.type_params, module_args)
                module_name = env.normalize_module_name(module_name)
                included_modules << Definition::Ancestor::Instance.new(name: module_name, args: module_args, source: member)
              end

            when AST::Ruby::Members::ExtendMember
              if extended_modules
                module_name = member.module_name
                module_args = member.type_args

                # Check if mixing in a class (not allowed)
                if env.class_decl?(module_name)
                  raise MixinClassError.new(type_name: type_name, member: member)
                end

                # Check if module exists
                module_decl = env.module_entry(module_name, normalized: true) or raise NoMixinFoundError.new(type_name: module_name, member: member)
                module_args = AST::TypeParam.normalize_args(module_decl.type_params, module_args)
                module_name = env.normalize_module_name(module_name)
                extended_modules << Definition::Ancestor::Instance.new(name: module_name, args: module_args, source: member)
              end

            when AST::Ruby::Members::PrependMember
              if prepended_modules
                module_name = member.module_name
                module_args = member.type_args

                # Check if mixing in a class (not allowed)
                if env.class_decl?(module_name)
                  raise MixinClassError.new(type_name: type_name, member: member)
                end

                # Check if module exists
                module_decl = env.module_entry(module_name, normalized: true) or raise NoMixinFoundError.new(type_name: module_name, member: member)
                module_args = AST::TypeParam.normalize_args(module_decl.type_params, module_args)
                module_name = env.normalize_module_name(module_name)
                prepended_modules << Definition::Ancestor::Instance.new(name: module_name, args: module_args, source: member)
              end
            end
          end
        end
      end

      def mixin_ancestors(entry, type_name, included_modules:, included_interfaces:, extended_modules:, prepended_modules:, extended_interfaces:)
        entry.each_decl do |decl|
          align_params = Substitution.build(
            decl.type_params.each.map(&:name),
            entry.type_params.map {|param| Types::Variable.new(name: param.name, location: param.location) }
          )

          mixin_ancestors0(decl,
                           type_name,
                           align_params: align_params,
                           included_modules: included_modules,
                           included_interfaces: included_interfaces,
                           extended_modules: extended_modules,
                           prepended_modules: prepended_modules,
                           extended_interfaces: extended_interfaces)
        end
      end

      def instance_ancestors(type_name, building_ancestors: [])
        as = instance_ancestors_cache[type_name] and return as

        entry = env.class_decls[type_name] or raise "Unknown name for instance_ancestors: #{type_name}"
        params = entry.type_params.each.map(&:name)
        args = entry.type_params.map do |type_param|
          Types::Variable.new(name: type_param.name, location: type_param.location)
        end
        self_ancestor = Definition::Ancestor::Instance.new(name: type_name, args: args, source: nil)

        RecursiveAncestorError.check!(self_ancestor,
                                      ancestors: building_ancestors,
                                      location: entry.primary_decl.location)
        building_ancestors.push self_ancestor

        one_ancestors = one_instance_ancestors(type_name)

        # @type var ancestors: Array[::RBS::Definition::Ancestor::t]
        ancestors = []

        case entry
        when Environment::ClassEntry
          if super_class = one_ancestors.super_class
            # @type var super_class: Definition::Ancestor::Instance
            super_name = super_class.name
            super_args = super_class.args

            super_ancestors =
              instance_ancestors(super_name, building_ancestors: building_ancestors)
                .apply(super_args, env: env, location: entry.primary_decl.super_class&.location)
            super_ancestors.map! {|ancestor| fill_ancestor_source(ancestor, name: super_name, source: :super) }
            ancestors.unshift(*super_ancestors)
          end
        end

        if self_types = one_ancestors.self_types
          self_types.each do |mod|
            if mod.name.class?
              # Ensure there is no loop in ancestors chain
              instance_ancestors(mod.name, building_ancestors: building_ancestors)
            end
          end
        end

        if included_modules = one_ancestors.included_modules
          included_modules.each do |mod|
            name = mod.name
            arg_types = mod.args
            (mod.source.is_a?(AST::Members::Include) || mod.source.is_a?(AST::Ruby::Members::IncludeMember)) or raise
            mod_ancestors =
              instance_ancestors(name, building_ancestors: building_ancestors)
                .apply(arg_types, env: env, location: mod.source.location)
            mod_ancestors.map! {|ancestor| fill_ancestor_source(ancestor, name: name, source: mod.source) }
            ancestors.unshift(*mod_ancestors)
          end
        end

        ancestors.unshift(self_ancestor)

        if prepended_modules = one_ancestors.prepended_modules
          prepended_modules.each do |mod|
            name = mod.name
            arg_types = mod.args
            (mod.source.is_a?(AST::Members::Prepend) || mod.source.is_a?(AST::Ruby::Members::PrependMember)) or raise
            mod_ancestors =
              instance_ancestors(name, building_ancestors: building_ancestors)
                .apply(arg_types, env: env, location: mod.source.location)
            mod_ancestors.map! {|ancestor| fill_ancestor_source(ancestor, name: name, source: mod.source) }
            ancestors.unshift(*mod_ancestors)
          end
        end

        building_ancestors.pop

        instance_ancestors_cache[type_name] = Definition::InstanceAncestors.new(
          type_name: type_name,
          params: params,
          ancestors: ancestors
        )
      end

      def singleton_ancestors(type_name, building_ancestors: [])
        as = singleton_ancestors_cache[type_name] and return as

        entry = env.class_decls[type_name] or raise "Unknown name for singleton_ancestors: #{type_name}"
        self_ancestor = Definition::Ancestor::Singleton.new(name: type_name)

        RecursiveAncestorError.check!(self_ancestor,
                                      ancestors: building_ancestors,
                                      location: entry.primary_decl.location)
        building_ancestors.push self_ancestor

        one_ancestors = one_singleton_ancestors(type_name)

        ancestors = [] #: Array[Definition::Ancestor::t]

        case super_class = one_ancestors.super_class
        when Definition::Ancestor::Instance
          super_name = super_class.name
          super_args = super_class.args

          super_ancestors =
            instance_ancestors(super_name, building_ancestors: building_ancestors)
              .apply(super_args, env: env, location: nil)
          super_ancestors.map! {|ancestor| fill_ancestor_source(ancestor, name: super_name, source: :super) }
          ancestors.unshift(*super_ancestors)

        when Definition::Ancestor::Singleton
          super_name = super_class.name

          super_ancestors = singleton_ancestors(super_name, building_ancestors: [])
          ancestors.unshift(*super_ancestors.ancestors)
        end

        extended_modules = one_ancestors.extended_modules or raise
        extended_modules.each do |mod|
          name = mod.name
          args = mod.args
          (mod.source.is_a?(AST::Members::Extend) || mod.source.is_a?(AST::Ruby::Members::ExtendMember)) or raise
          mod_ancestors =
            instance_ancestors(name, building_ancestors: building_ancestors)
              .apply(args, env: env, location: mod.source.location)
          mod_ancestors.map! {|ancestor| fill_ancestor_source(ancestor, name: name, source: mod.source) }
          ancestors.unshift(*mod_ancestors)
        end

        ancestors.unshift(self_ancestor)

        building_ancestors.pop

        singleton_ancestors_cache[type_name] = Definition::SingletonAncestors.new(
          type_name: type_name,
          ancestors: ancestors
        )
      end

      def interface_ancestors(type_name, building_ancestors: [])
        as = interface_ancestors_cache[type_name] and return as

        entry = env.interface_decls[type_name] or raise "Unknown name for interface_ancestors: #{type_name}"
        params = entry.decl.type_params.each.map(&:name)
        args = Types::Variable.build(params)
        self_ancestor = Definition::Ancestor::Instance.new(name: type_name, args: args, source: nil)

        RecursiveAncestorError.check!(self_ancestor,
                                      ancestors: building_ancestors,
                                      location: entry.decl.location)
        building_ancestors.push self_ancestor

        one_ancestors = one_interface_ancestors(type_name)
        ancestors = [] #: Array[Definition::Ancestor::t]

        included_interfaces = one_ancestors.included_interfaces or raise
        included_interfaces.each do |a|
          a.source.is_a?(AST::Members::Include) or raise
          included_ancestors =
            interface_ancestors(a.name, building_ancestors: building_ancestors)
              .apply(a.args, env: env, location: a.source.location)
          included_ancestors.map! {|ancestor| fill_ancestor_source(ancestor, name: a.name, source: a.source) }
          ancestors.unshift(*included_ancestors)
        end

        ancestors.unshift(self_ancestor)
        building_ancestors.pop

        interface_ancestors_cache[type_name] = Definition::InstanceAncestors.new(
          type_name: type_name,
          params: params,
          ancestors: ancestors
        )
      end

      def fill_ancestor_source(ancestor, name:, source:, &block)
        case ancestor
        when Definition::Ancestor::Instance
          if ancestor.name == name && !ancestor.source
            Definition::Ancestor::Instance.new(name: ancestor.name, args: ancestor.args, source: source)
          else
            ancestor
          end
        else
          ancestor
        end
      end

      # Returns a Hash from a type name to a (location-free) representation of its _ancestor surface_:
      # the super class, mixins, self types and type params that {#one_instance_ancestors} and friends
      # read from the type's own declarations.  Two surfaces are compared with `#==`, which ignores
      # locations, so an edit that does not touch the ancestor surface produces an equal value.
      #
      def ancestor_surfaces(target_env)
        surfaces = {} #: Hash[TypeName, untyped]

        target_env.class_decls.each do |type_name, entry|
          surfaces[type_name] = entry.each_decl.map {|decl| decl_ancestor_surface(decl) }
        end
        target_env.interface_decls.each do |type_name, entry|
          surfaces[type_name] = [decl_ancestor_surface(entry.decl)]
        end

        surfaces
      end

      def decl_ancestor_surface(decl)
        type_params = decl.type_params.map {|param| [param.name, param.default_type] }

        super_class =
          case decl
          when AST::Declarations::Class
            decl.super_class&.then {|s| [s.name, s.args] }
          when AST::Ruby::Declarations::ClassDecl
            decl.super_class&.then {|s| [s.name, []] }
          end

        mixins = [] #: Array[untyped]
        self_types = [] #: Array[untyped]

        case decl
        when AST::Declarations::Base
          decl.each_mixin do |member|
            mixins << [member.class, member.name, member.args]
          end
        when AST::Ruby::Declarations::Base
          decl.members.each do |member|
            case member
            when AST::Ruby::Members::IncludeMember, AST::Ruby::Members::ExtendMember, AST::Ruby::Members::PrependMember
              mixins << [member.class, member.module_name, member.type_args]
            end
          end
        end

        if decl.respond_to?(:self_types) && (types = decl.self_types)
          self_types = types.map {|type| [type.name, type.args] }
        end

        [type_params, super_class, mixins, self_types]
      end

      # Returns the alias names whose target (old name) differs between the two environments.
      #
      def changed_alias_names(old_env, new_env)
        old_aliases = old_env.class_alias_decls
        new_aliases = new_env.class_alias_decls

        (old_aliases.keys | new_aliases.keys).select do |name|
          old_aliases[name]&.decl&.old_name != new_aliases[name]&.decl&.old_name
        end
      end

      # Returns a Hash from a referenced type name (as written in the declarations, before
      # normalization) to the type names that refer to it in ancestor position.
      #
      def ancestor_reference_index(target_env)
        index = Hash.new {|hash, key| hash[key] = [] } #: Hash[TypeName, Array[TypeName]]

        register = ->(referrer, decl) do
          _, super_class, mixins, self_types = decl_ancestor_surface(decl)
          index[super_class[0]] << referrer if super_class
          mixins.each {|mixin| index[mixin[1]] << referrer }
          self_types.each {|self_type| index[self_type[0]] << referrer }
        end

        target_env.class_decls.each do |_, entry|
          entry.each_decl {|decl| register.call(entry.name, decl) }
        end
        target_env.interface_decls.each do |_, entry|
          register.call(entry.name, entry.decl)
        end

        index
      end
    end
  end
end
