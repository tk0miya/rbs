# frozen_string_literal: true

module RBS
  class Environment
    # Resolves type names in an `Environment` and produces a new `Environment` with
    # absolute type names.
    #
    # ```ruby
    # resolved = Environment::Resolver.new(env).call
    # ```
    #
    class Resolver
      attr_reader :env

      def initialize(env)
        @env = env
      end

      # Resolves all type names in the environment and returns a new `Environment`.
      #
      # When `only` is given, only the declarations contained in the set are resolved.
      # The others are kept as-is. This is useful for partial updates.
      #
      def call(only: nil)
        resolver = RBS::Resolver::TypeNameResolver.build(env)
        new_env = Environment.new

        table = UseMap::Table.new()
        table.known_types.merge(env.class_decls.keys)
        table.known_types.merge(env.class_alias_decls.keys)
        table.known_types.merge(env.type_alias_decls.keys)
        table.known_types.merge(env.interface_decls.keys)
        table.compute_children

        env.each_rbs_source do |source|
          resolve = source.directives.find { _1.is_a?(AST::Directives::ResolveTypeNames) } #: AST::Directives::ResolveTypeNames?
          if !resolve || resolve.value
            _, decls = resolve_signature(resolver, table, source.directives, source.declarations, only: only)
          else
            decls = source.declarations
          end
          new_env.add_source(Source::RBS.new(source.buffer, source.directives, decls))
        end

        env.each_ruby_source do |source|
          decls = source.declarations.map do |decl|
            if only
              if only.include?(decl)
                resolve_ruby_decl(resolver, decl, context: nil, prefix: Namespace.root)
              else
                decl
              end
            else
              resolve_ruby_decl(resolver, decl, context: nil, prefix: Namespace.root)
            end
          end

          new_env.add_source(Source::Ruby.new(source.buffer, source.prism_result, decls, source.diagnostics))
        end

        new_env
      end

      def resolve_signature(resolver, table, dirs, decls, only: nil)
        map = UseMap.new(table: table)
        dirs.each do |dir|
          case dir
          when AST::Directives::Use
            dir.clauses.each do |clause|
              map.build_map(clause)
            end
          end
        end

        decls = decls.map do |decl|
          if only && !only.member?(decl)
            decl
          else
            resolve_declaration(resolver, map, decl, context: nil, prefix: Namespace.root)
          end
        end

        [dirs, decls]
      end

      private

      def append_context(context, decl)
        if (_, last = context)
          last or raise
          [context, last + decl.name]
        else
          [nil, decl.name.absolute!]
        end
      end

      def resolve_declaration(resolver, map, decl, context:, prefix:)
        if decl.is_a?(AST::Declarations::Global)
          # @type var decl: AST::Declarations::Global
          return AST::Declarations::Global.new(
            name: decl.name,
            type: absolute_type(resolver, map, decl.type, context: nil),
            location: decl.location,
            comment: decl.comment,
            annotations: decl.annotations
          )
        end

        case decl
        when AST::Declarations::Class
          outer_context = context
          inner_context = append_context(outer_context, decl)

          prefix_ = prefix + decl.name.to_namespace
          AST::Declarations::Class.new(
            name: decl.name.with_prefix(prefix),
            type_params: resolve_type_params(resolver, map, decl.type_params, context: inner_context),
            super_class: decl.super_class&.yield_self do |super_class|
              AST::Declarations::Class::Super.new(
                name: absolute_type_name(resolver, map, super_class.name, context: outer_context),
                args: super_class.args.map {|type| absolute_type(resolver, map, type, context: outer_context) },
                location: super_class.location
              )
            end,
            members: decl.members.map do |member|
              case member
              when AST::Members::Base
                resolve_member(resolver, map, member, context: inner_context)
              when AST::Declarations::Base
                resolve_declaration(
                  resolver,
                  map,
                  member,
                  context: inner_context,
                  prefix: prefix_
                )
              else
                raise
              end
            end,
            location: decl.location,
            annotations: decl.annotations,
            comment: decl.comment
          )

        when AST::Declarations::Module
          outer_context = context
          inner_context = append_context(outer_context, decl)

          prefix_ = prefix + decl.name.to_namespace
          AST::Declarations::Module.new(
            name: decl.name.with_prefix(prefix),
            type_params: resolve_type_params(resolver, map, decl.type_params, context: inner_context),
            self_types: decl.self_types.map do |module_self|
              AST::Declarations::Module::Self.new(
                name: absolute_type_name(resolver, map, module_self.name, context: inner_context),
                args: module_self.args.map {|type| absolute_type(resolver, map, type, context: inner_context) },
                location: module_self.location
              )
            end,
            members: decl.members.map do |member|
              case member
              when AST::Members::Base
                resolve_member(resolver, map, member, context: inner_context)
              when AST::Declarations::Base
                resolve_declaration(
                  resolver,
                  map,
                  member,
                  context: inner_context,
                  prefix: prefix_
                )
              else
                raise
              end
            end,
            location: decl.location,
            annotations: decl.annotations,
            comment: decl.comment
          )

        when AST::Declarations::Interface
          AST::Declarations::Interface.new(
            name: decl.name.with_prefix(prefix),
            type_params: resolve_type_params(resolver, map, decl.type_params, context: context),
            members: decl.members.map do |member|
              resolve_member(resolver, map, member, context: context)
            end,
            comment: decl.comment,
            location: decl.location,
            annotations: decl.annotations
          )

        when AST::Declarations::TypeAlias
          AST::Declarations::TypeAlias.new(
            name: decl.name.with_prefix(prefix),
            type_params: resolve_type_params(resolver, map, decl.type_params, context: context),
            type: absolute_type(resolver, map, decl.type, context: context),
            location: decl.location,
            annotations: decl.annotations,
            comment: decl.comment
          )

        when AST::Declarations::Constant
          AST::Declarations::Constant.new(
            name: decl.name.with_prefix(prefix),
            type: absolute_type(resolver, map, decl.type, context: context),
            location: decl.location,
            comment: decl.comment,
            annotations: decl.annotations
          )

        when AST::Declarations::ClassAlias
          AST::Declarations::ClassAlias.new(
            new_name: decl.new_name.with_prefix(prefix),
            old_name: absolute_type_name(resolver, map, decl.old_name, context: context),
            location: decl.location,
            comment: decl.comment,
            annotations: decl.annotations
          )

        when AST::Declarations::ModuleAlias
          AST::Declarations::ModuleAlias.new(
            new_name: decl.new_name.with_prefix(prefix),
            old_name: absolute_type_name(resolver, map, decl.old_name, context: context),
            location: decl.location,
            comment: decl.comment,
            annotations: decl.annotations
          )
        end
      end

      def resolve_ruby_decl(resolver, decl, context:, prefix:)
        case decl
        when AST::Ruby::Declarations::ClassDecl
          full_name = decl.class_name.with_prefix(prefix)
          inner_context = [context, full_name] #: Resolver::context
          inner_prefix = full_name.to_namespace

          super_class = decl.super_class&.yield_self do |super_class|
            AST::Ruby::Declarations::ClassDecl::SuperClass.new(
              super_class.type_name_location,
              super_class.operator_location,
              absolute_type_name(resolver, nil, super_class.name, context: context),
              super_class.type_annotation&.map_type_name {|name, _, _| absolute_type_name(resolver, nil, name, context: context) }
            )
          end

          AST::Ruby::Declarations::ClassDecl.new(decl.buffer, full_name, decl.node, super_class).tap do |resolved|
            decl.members.each do |member|
              case member
              when AST::Ruby::Declarations::Base
                resolved.members << resolve_ruby_decl(resolver, member, context: inner_context, prefix: inner_prefix)
              when AST::Ruby::Members::Base
                resolved.members << resolve_ruby_member(resolver, member, context: inner_context)
              else
                raise "Unknown member type: #{member.class}"
              end
            end
          end

        when AST::Ruby::Declarations::ModuleDecl
          full_name = decl.module_name.with_prefix(prefix)
          inner_context = [context, full_name] #: Resolver::context
          inner_prefix = full_name.to_namespace

          AST::Ruby::Declarations::ModuleDecl.new(decl.buffer, full_name, decl.node).tap do |resolved|
            decl.members.each do |member|
              case member
              when AST::Ruby::Declarations::Base
                resolved.members << resolve_ruby_decl(resolver, member, context: inner_context, prefix: inner_prefix)
              when AST::Ruby::Members::Base
                resolved.members << resolve_ruby_member(resolver, member, context: inner_context)
              else
                raise "Unknown member type: #{member.class}"
              end
            end
          end

        when AST::Ruby::Declarations::ConstantDecl
          full_name = decl.constant_name.with_prefix(prefix)

          AST::Ruby::Declarations::ConstantDecl.new(
            decl.buffer,
            full_name,
            decl.node,
            decl.leading_comment,
            decl.type_annotation&.map_type_name {|name, _, _| absolute_type_name(resolver, nil, name, context: context) }
          )

        when AST::Ruby::Declarations::ClassModuleAliasDecl
          full_name = decl.new_name.with_prefix(prefix)
          resolved_annotation = decl.annotation.map_type_name {|name, _, _| absolute_type_name(resolver, nil, name, context: context) }
          resolved_infered_name = decl.infered_old_name&.yield_self {|name| absolute_type_name(resolver, nil, name, context: context) }

          AST::Ruby::Declarations::ClassModuleAliasDecl.new(
            decl.buffer,
            decl.node,
            full_name,
            resolved_infered_name,
            decl.leading_comment,
            resolved_annotation
          )

        else
          raise "Unknown declaration type: #{decl.class}"
        end
      end

      def resolve_ruby_member(resolver, member, context:)
        case member
        when AST::Ruby::Members::DefMember
          AST::Ruby::Members::DefMember.new(
            member.buffer,
            member.name,
            member.node,
            member.method_type.map_type_name {|name, _, _| absolute_type_name(resolver, nil, name, context: context) },
            member.leading_comment,
            kind: member.kind
          )
        when AST::Ruby::Members::IncludeMember
          resolved_annotation = member.annotation&.map_type_name {|name, _, _| absolute_type_name(resolver, nil, name, context: context) }
          AST::Ruby::Members::IncludeMember.new(
            member.buffer,
            member.node,
            absolute_type_name(resolver, nil, member.module_name, context: context),
            resolved_annotation
          )
        when AST::Ruby::Members::ExtendMember
          resolved_annotation = member.annotation&.map_type_name {|name, _, _| absolute_type_name(resolver, nil, name, context: context) }
          AST::Ruby::Members::ExtendMember.new(
            member.buffer,
            member.node,
            absolute_type_name(resolver, nil, member.module_name, context: context),
            resolved_annotation
          )
        when AST::Ruby::Members::PrependMember
          resolved_annotation = member.annotation&.map_type_name {|name, _, _| absolute_type_name(resolver, nil, name, context: context) }
          AST::Ruby::Members::PrependMember.new(
            member.buffer,
            member.node,
            absolute_type_name(resolver, nil, member.module_name, context: context),
            resolved_annotation
          )
        when AST::Ruby::Members::AttrReaderMember
          resolved_type_annotation = member.type_annotation&.map_type_name {|name, _, _| absolute_type_name(resolver, nil, name, context: context) }
          AST::Ruby::Members::AttrReaderMember.new(
            member.buffer,
            member.node,
            member.name_nodes,
            member.leading_comment,
            resolved_type_annotation
          )
        when AST::Ruby::Members::AttrWriterMember
          resolved_type_annotation = member.type_annotation&.map_type_name {|name, _, _| absolute_type_name(resolver, nil, name, context: context) }
          AST::Ruby::Members::AttrWriterMember.new(
            member.buffer,
            member.node,
            member.name_nodes,
            member.leading_comment,
            resolved_type_annotation
          )
        when AST::Ruby::Members::AttrAccessorMember
          resolved_type_annotation = member.type_annotation&.map_type_name {|name, _, _| absolute_type_name(resolver, nil, name, context: context) }
          AST::Ruby::Members::AttrAccessorMember.new(
            member.buffer,
            member.node,
            member.name_nodes,
            member.leading_comment,
            resolved_type_annotation
          )
        when AST::Ruby::Members::InstanceVariableMember
          resolved_annotation = member.annotation.map_type_name {|name| absolute_type_name(resolver, nil, name, context: context) }
          AST::Ruby::Members::InstanceVariableMember.new(
            member.buffer,
            resolved_annotation
          )
        when AST::Ruby::Members::ModuleSelfMember
          resolved_annotation = member.annotation.map_type_name {|name| absolute_type_name(resolver, nil, name, context: context) }
          AST::Ruby::Members::ModuleSelfMember.new(
            member.buffer,
            resolved_annotation
          )
        else
          raise "Unknown member type: #{member.class}"
        end
      end

      def resolve_member(resolver, map, member, context:)
        case member
        when AST::Members::MethodDefinition
          AST::Members::MethodDefinition.new(
            name: member.name,
            kind: member.kind,
            overloads: member.overloads.map do |overload|
              overload.update(
                method_type: resolve_method_type(resolver, map, overload.method_type, context: context)
              )
            end,
            comment: member.comment,
            overloading: member.overloading?,
            annotations: member.annotations,
            location: member.location,
            visibility: member.visibility
          )
        when AST::Members::AttrAccessor
          AST::Members::AttrAccessor.new(
            name: member.name,
            type: absolute_type(resolver, map, member.type, context: context),
            kind: member.kind,
            annotations: member.annotations,
            comment: member.comment,
            location: member.location,
            ivar_name: member.ivar_name,
            visibility: member.visibility
          )
        when AST::Members::AttrReader
          AST::Members::AttrReader.new(
            name: member.name,
            type: absolute_type(resolver, map, member.type, context: context),
            kind: member.kind,
            annotations: member.annotations,
            comment: member.comment,
            location: member.location,
            ivar_name: member.ivar_name,
            visibility: member.visibility
          )
        when AST::Members::AttrWriter
          AST::Members::AttrWriter.new(
            name: member.name,
            type: absolute_type(resolver, map, member.type, context: context),
            kind: member.kind,
            annotations: member.annotations,
            comment: member.comment,
            location: member.location,
            ivar_name: member.ivar_name,
            visibility: member.visibility
          )
        when AST::Members::InstanceVariable
          AST::Members::InstanceVariable.new(
            name: member.name,
            type: absolute_type(resolver, map, member.type, context: context),
            comment: member.comment,
            location: member.location
          )
        when AST::Members::ClassInstanceVariable
          AST::Members::ClassInstanceVariable.new(
            name: member.name,
            type: absolute_type(resolver, map, member.type, context: context),
            comment: member.comment,
            location: member.location
          )
        when AST::Members::ClassVariable
          AST::Members::ClassVariable.new(
            name: member.name,
            type: absolute_type(resolver, map, member.type, context: context),
            comment: member.comment,
            location: member.location
          )
        when AST::Members::Include
          AST::Members::Include.new(
            name: absolute_type_name(resolver, map, member.name, context: context),
            args: member.args.map {|type| absolute_type(resolver, map, type, context: context) },
            comment: member.comment,
            location: member.location,
            annotations: member.annotations
          )
        when AST::Members::Extend
          AST::Members::Extend.new(
            name: absolute_type_name(resolver, map, member.name, context: context),
            args: member.args.map {|type| absolute_type(resolver, map, type, context: context) },
            comment: member.comment,
            location: member.location,
            annotations: member.annotations
          )
        when AST::Members::Prepend
          AST::Members::Prepend.new(
            name: absolute_type_name(resolver, map, member.name, context: context),
            args: member.args.map {|type| absolute_type(resolver, map, type, context: context) },
            comment: member.comment,
            location: member.location,
            annotations: member.annotations
          )
        else
          member
        end
      end

      def resolve_method_type(resolver, map, type, context:)
        type.map_type do |ty|
          absolute_type(resolver, map, ty, context: context)
        end.map_type_bound do |bound|
          _ = absolute_type(resolver, map, bound, context: context)
        end
      end

      def resolve_type_params(resolver, map, params, context:)
        params.map do |param|
          param.map_type {|type| _ = absolute_type(resolver, map, type, context: context) }
        end
      end

      def absolute_type_name(resolver, map, type_name, context:)
        type_name = map.resolve(type_name) if map
        resolver.resolve(type_name, context: context) || type_name
      end

      def absolute_type(resolver, map, type, context:)
        type.map_type_name do |name, _, _|
          absolute_type_name(resolver, map, name, context: context)
        end
      end
    end
  end
end
