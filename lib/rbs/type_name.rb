# frozen_string_literal: true

module RBS
  class TypeName
    attr_reader :namespace
    attr_reader :name
    attr_reader :kind

    # Process-wide flyweight cache. Two-level Hash keyed by Namespace
    # identity (outer uses `compare_by_identity`) and name Symbol. Every
    # Namespace is already canonical so the outer key needs no
    # normalization step.
    @intern_mutex = Mutex.new
    @intern_cache = {}  #: Hash[Namespace, Hash[Symbol, TypeName]]
    @intern_cache.compare_by_identity

    class << self
      def _intern_mutex
        @intern_mutex
      end

      def _intern_cache
        @intern_cache
      end
    end

    # `TypeName.new(namespace:, name:)` is retained as an alias for
    # `TypeName[namespace, name]` so every TypeName flows through the
    # flyweight cache. Repeated calls with structurally equal arguments
    # return the very same object.
    def self.new(namespace:, name:)
      self[namespace, name]
    end

    # Returns the canonical TypeName for the given `namespace` / `name`
    # pair. Callers can rely on `equal?` for fast equality.
    def self.[](namespace, name)
      inner = @intern_cache[namespace]
      if inner && (cached = inner[name])
        return cached
      end

      @intern_mutex.synchronize do
        inner = (@intern_cache[namespace] ||= {})
        inner[name] ||= begin
          tn = allocate
          tn.send(:_init, namespace: namespace, name: name)
          tn
        end
      end
    end

    def _init(namespace:, name:)
      @namespace = namespace
      @name = name
      # Kind is determined by the first byte of the name without
      # constructing a regex match object.
      first = name.length > 0 ? name.to_s.getbyte(0) : nil
      @kind = if first.nil?
                :class
              elsif first == 0x5F                # '_'
                :interface
              elsif first >= 0x61 && first <= 0x7A # 'a'..'z'
                :alias
              else
                :class
              end
    end
    protected :_init

    def ==(other)
      # Every TypeName is interned, so `equal?` and `==` coincide.
      equal?(other)
    end

    alias eql? ==

    def hash
      # Object identity hash is fine since interning guarantees one
      # instance per structural value.
      __id__
    end

    def to_s
      "#{namespace.to_s}#{name}"
    end

    def to_json(state = nil)
      to_s.to_json(state)
    end

    def to_namespace
      namespace.append(self.name)
    end

    def class?
      kind == :class
    end

    def alias?
      kind == :alias
    end

    def absolute!
      TypeName[namespace.absolute!, name]
    end

    def absolute?
      namespace.absolute?
    end

    def relative!
      TypeName[namespace.relative!, name]
    end

    def interface?
      kind == :interface
    end

    def with_prefix(namespace)
      TypeName[namespace + self.namespace, name]
    end

    def split
      namespace.path + [name]
    end

    def +(other)
      if other.absolute?
        other
      else
        TypeName[self.to_namespace + other.namespace, other.name]
      end
    end

    def self.parse(string)
      absolute = string.start_with?("::")

      *path, name = string.delete_prefix("::").split("::").map(&:to_sym)
      raise unless name

      TypeName[Namespace[path, absolute], name]
    end
  end
end
