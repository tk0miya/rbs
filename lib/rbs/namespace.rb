# frozen_string_literal: true

module RBS
  class Namespace
    # Process-wide flyweight cache. Every interned Namespace is itself a
    # node in the trie: it carries a direct `@parent_ns` pointer to its
    # parent namespace, the `@last_component` it was reached by, and a
    # lazily-allocated `@children` Hash[Symbol, Namespace] of the
    # namespaces that extend it. The cache therefore needs nothing more
    # than two roots (one per `absolute` flag); `parent` is an O(1)
    # pointer dereference and `append` is a single `Hash#[]` lookup.
    @intern_mutex = Mutex.new
    @intern_root_absolute = nil
    @intern_root_relative = nil

    class << self
      # Internal: returns the canonical empty Namespace for the given
      # absoluteness flag. Both roots are themselves interned Namespace
      # instances; they are the only nodes with `@parent_ns == nil`.
      def _intern_root(absolute)
        if absolute
          @intern_root_absolute ||= _new_interned(parent_ns: nil, last_component: nil, absolute: true)
        else
          @intern_root_relative ||= _new_interned(parent_ns: nil, last_component: nil, absolute: false)
        end
      end

      def _new_interned(parent_ns:, last_component:, absolute:)
        ns = allocate
        ns.send(:_init_interned, parent_ns: parent_ns, last_component: last_component, absolute: absolute)
        ns
      end

      def _intern_mutex
        @intern_mutex
      end
    end

    # Returns a canonical `Namespace` instance for the given `path` /
    # `absolute` pair. Repeated calls with structurally equal arguments
    # return the same object, so callers can rely on `equal?` for fast
    # equality.
    def self.[](path, absolute)
      absolute = absolute ? true : false
      root = _intern_root(absolute)
      return root if path.empty?

      # Lock-free fast path: walk the trie reading existing children.
      # Each interned Namespace owns a non-nil `@children` hash so the
      # walk is exactly one `Hash#[]` lookup per level.
      cur = root
      path.each do |sym|
        child = cur._children[sym]
        unless child
          cur = nil
          break
        end
        cur = child
      end
      return cur if cur

      # Slow path: extend the trie under the mutex.
      @intern_mutex.synchronize do
        cur = root
        path.each do |sym|
          cur = cur._intern_child(sym)
        end
        cur
      end
    end

    def self.empty
      _intern_root(false)
    end

    def self.root
      _intern_root(true)
    end

    # Public constructor for backwards compatibility. Produces an
    # uninterned Namespace; structural equality still holds (`==`,
    # `eql?`, `hash`) so it interoperates with cached entries via Hash /
    # Set, but `equal?` may differ. Prefer `Namespace.[]` for new code.
    def initialize(path:, absolute:)
      @path = path
      @absolute = absolute ? true : false
      @parent_ns = nil
      @last_component = nil
      @children = nil
      @interned = false
    end

    def _init_interned(parent_ns:, last_component:, absolute:)
      @parent_ns = parent_ns
      @last_component = last_component
      @absolute = absolute
      # Always allocate the children hash up front so the lock-free
      # `Namespace.[]` walk can do exactly one Hash lookup per level
      # without an extra nil-check or ivar fetch + branch.
      @children = {}
      @path = nil
      @interned = true
    end
    protected :_init_interned

    # Internal readers used by the trie walk in `Namespace.[]` and by
    # `path` reification. Non-nil for interned namespaces; on uninterned
    # ones `_children` returns nil and the other two return nil.
    def _children;       @children       end
    def _parent_ns;      @parent_ns      end
    def _last_component; @last_component end

    # Returns or creates the interned child for `component`. Caller must
    # hold the intern mutex.
    def _intern_child(component)
      @children[component] ||= Namespace._new_interned(
        parent_ns: self,
        last_component: component,
        absolute: @absolute,
      )
    end

    # Returns the path as an Array[Symbol]. For interned namespaces the
    # array is built lazily on first access and frozen; for uninterned
    # ones it is whatever was passed to `new`.
    def path
      return @path if @path
      return @path unless @interned

      # Walk up once and reify a frozen Array[Symbol]. The walk is
      # bounded by the depth, and the result is memoized.
      depth = 0
      cur = self
      while cur._parent_ns
        depth += 1
        cur = cur._parent_ns
      end
      arr = Array.new(depth)
      cur = self
      idx = depth - 1
      while idx >= 0
        arr[idx] = cur._last_component
        cur = cur._parent_ns
        idx -= 1
      end
      @path = arr.freeze
    end

    def +(other)
      if other.absolute?
        other
      elsif other.empty?
        self
      elsif @interned
        # Walk down the cache from self, one component at a time.
        other.path.inject(self) { |ns, sym| ns.append(sym) }
      else
        Namespace[path + other.path, absolute?]
      end
    end

    def append(component)
      if @interned
        existing = @children[component]
        return existing if existing
        Namespace._intern_mutex.synchronize do
          _intern_child(component)
        end
      else
        Namespace[path + [component], absolute?]
      end
    end

    def parent
      if @interned
        @parent_ns or raise "Parent with empty namespace"
      else
        @parent ||= begin
          raise "Parent with empty namespace" if empty?
          Namespace[path.take(path.size - 1), absolute?]
        end
      end
    end

    def absolute?
      @absolute
    end

    def relative?
      !absolute?
    end

    def absolute!
      return self if @absolute
      if @interned
        @absolute_view ||= begin
          if @parent_ns
            @parent_ns.absolute!.append(@last_component)
          else
            Namespace.root
          end
        end
      else
        Namespace[path, true]
      end
    end

    def relative!
      return self unless @absolute
      if @interned
        @relative_view ||= begin
          if @parent_ns
            @parent_ns.relative!.append(@last_component)
          else
            Namespace.empty
          end
        end
      else
        Namespace[path, false]
      end
    end

    def empty?
      if @interned
        @parent_ns.nil?
      else
        path.empty?
      end
    end

    def ==(other)
      return true if equal?(other)
      other.is_a?(Namespace) && other.path == path && other.absolute? == absolute?
    end

    alias eql? ==

    def hash
      @hash ||= path.hash ^ absolute?.hash
    end

    def split
      if @interned
        return nil unless @parent_ns
        [@parent_ns, @last_component]
      else
        last = path.last or return
        [self.parent, last]
      end
    end

    def to_s
      if empty?
        absolute? ? "::" : ""
      else
        s = path.join("::")
        absolute? ? "::#{s}::" : "#{s}::"
      end
    end

    def to_type_name
      parent, name = split

      raise unless name
      raise unless parent

      TypeName[parent, name]
    end

    def self.parse(string)
      if string.start_with?("::")
        self[string.split("::").drop(1).map(&:to_sym), true]
      else
        self[string.split("::").map(&:to_sym), false]
      end
    end

    def ascend
      if block_given?
        current = self

        until current.empty?
          yield current
          current = _ = current.parent
        end

        yield current

        self
      else
        enum_for(:ascend)
      end
    end
  end
end
