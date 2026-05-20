# frozen_string_literal: true

module RBS
  class Namespace
    # Process-wide flyweight cache. Every Namespace is itself a node in
    # the trie: it carries a direct `@parent_ns` pointer to its parent
    # namespace, the `@last_component` Symbol it was reached by, and a
    # non-nil `@children` Hash[Symbol, Namespace] of the namespaces that
    # extend it. The cache therefore needs nothing more than two roots
    # (one per `absolute` flag); `parent` is an O(1) pointer dereference
    # and `append` is a single `Hash#[]` lookup.
    @intern_mutex = Mutex.new
    @intern_root_absolute = nil
    @intern_root_relative = nil

    class << self
      # Internal: returns the canonical empty Namespace for the given
      # absoluteness flag. Both roots are themselves Namespace instances;
      # they are the only nodes with `@parent_ns == nil`.
      def _intern_root(absolute)
        if absolute
          @intern_root_absolute ||= _new_node(parent_ns: nil, last_component: nil, absolute: true)
        else
          @intern_root_relative ||= _new_node(parent_ns: nil, last_component: nil, absolute: false)
        end
      end

      def _new_node(parent_ns:, last_component:, absolute:)
        ns = allocate
        ns.send(:_init, parent_ns: parent_ns, last_component: last_component, absolute: absolute)
        ns
      end

      def _intern_mutex
        @intern_mutex
      end
    end

    # `Namespace.new(path:, absolute:)` is retained as an alias for
    # `Namespace[path, absolute]` so every Namespace flows through the
    # flyweight cache. Repeated calls with structurally equal arguments
    # return the very same object.
    def self.new(path:, absolute:)
      self[path, absolute]
    end

    # Returns the canonical Namespace for the given `path` / `absolute`
    # pair. Callers can rely on `equal?` for fast equality.
    def self.[](path, absolute)
      absolute = absolute ? true : false
      root = _intern_root(absolute)
      return root if path.empty?

      # Lock-free fast path: walk the trie reading existing children.
      # Each Namespace owns a non-nil `@children` hash so the walk is
      # exactly one `Hash#[]` lookup per level.
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

    def _init(parent_ns:, last_component:, absolute:)
      @parent_ns = parent_ns
      @last_component = last_component
      @absolute = absolute
      # Always allocate the children hash up front so the lock-free
      # `Namespace.[]` walk can do exactly one Hash lookup per level
      # without an extra nil-check or ivar fetch + branch.
      @children = {}
      @path = nil
    end
    protected :_init

    # Internal readers used by the trie walk in `Namespace.[]` and by
    # `path` reification.
    def _children;       @children       end
    def _parent_ns;      @parent_ns      end
    def _last_component; @last_component end

    # Returns or creates the child Namespace for `component`. Caller must
    # hold the intern mutex.
    def _intern_child(component)
      @children[component] ||= Namespace._new_node(
        parent_ns: self,
        last_component: component,
        absolute: @absolute,
      )
    end

    # Returns the path as an Array[Symbol], built lazily on first
    # access and frozen.
    def path
      @path ||= begin
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
        arr.freeze
      end
    end

    def +(other)
      if other.absolute?
        other
      elsif other.empty?
        self
      else
        # Recursive form: `self + other` = (`self + other.parent`).append(last).
        # No Array[Symbol] is built; `+` results may also be reached
        # through the cache by future calls.
        (self + other._parent_ns).append(other._last_component)
      end
    end

    def append(component)
      existing = @children[component]
      return existing if existing
      Namespace._intern_mutex.synchronize do
        _intern_child(component)
      end
    end

    def parent
      @parent_ns or raise "Parent with empty namespace"
    end

    def absolute?
      @absolute
    end

    def relative?
      !absolute?
    end

    def absolute!
      return self if @absolute
      @absolute_view ||= if @parent_ns
                           @parent_ns.absolute!.append(@last_component)
                         else
                           Namespace.root
                         end
    end

    def relative!
      return self unless @absolute
      @relative_view ||= if @parent_ns
                           @parent_ns.relative!.append(@last_component)
                         else
                           Namespace.empty
                         end
    end

    def empty?
      @parent_ns.nil?
    end

    def ==(other)
      # Every Namespace is interned, so `equal?` and `==` coincide.
      equal?(other)
    end

    alias eql? ==

    def hash
      # Object identity hash is fine since interning guarantees
      # one instance per structural value.
      __id__
    end

    def split
      return nil unless @parent_ns
      [@parent_ns, @last_component]
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
