# typed: true
#
# platin toolkit
#
# program information: flowfacts, timing, memory accesses
#
require 'core/utils'
require 'core/pmlbase'
require 'core/context'
require 'core/program'
require 'core/symbolic_expr'
require 'core/model'

module PML

  # Flow fact classification and selection
  class FlowFactClassifier
    def initialize(pml)
      @pml = pml
    end

    # FIXME: cache
    def classify(ff)
      c = OpenStruct.new
      # context-independent loop bound
      c.is_loop_bound = !ff.get_loop_bound.nil?
      # context-independent block infeasibility
      c.is_infeasible = !ff.get_block_infeasible.empty?
      # context-independent calltarget restriction
      (_,cs) = ff.get_calltargets
      c.is_indirect_calltarget = cs && cs.programpoint.unresolved_call?

      # rt: involves machine-code only function (usually from compiler-rt or operating system)
      if @pml
        mcofs = @pml.machine_code_only_functions
        c.is_rt = ff.lhs.any? { |term|
                    term.programpoint.function &&
                      mcofs.include?(term.programpoint.function.label)
                  }
      else
        c.is_rt = false
      end

      c.is_minimal = c.is_loop_bound || c.is_infeasible || c.is_indirect_calltarget
      c.is_local   = ff.local?
      c
    end

    def classification_group(ff)
      c = classify(ff)
      group_for_classification(c)
    end

    def group_for_classification(c)
      s = if c.is_loop_bound
            "loop-bound"
          elsif c.is_infeasible
            "infeasible"
          elsif c.is_indirect_calltarget
            "indirect-call-target"
          elsif c.is_local
            "local"
          else
            "global"
          end
      s = "#{s}-rt" if c.is_rt
      s
    end

    def included?(ff, profile)
      c = classify(ff)
      return true if profile == "all"
      case profile
      when "minimal"    then c.is_minimal
      when "local"      then c.is_minimal || c.is_local
      # FIXME: indirect calltargets are needed on MC level to build callgraph
      when "rt-support-all"   then c.is_rt || c.is_indirect_calltarget
      when "rt-support-local" then (c.is_rt && (c.is_local || c.is_minimal)) || c.is_indirect_calltarget
      when "rt-support-minimal" then (c.is_rt && c.is_minimal) || c.is_indirect_calltarget
      else raise Exception, "Bad Flow-Fact Selection Profile: #{profile}"
      end
    end
  end

  # List of flowfacts (modifiable)
  class FlowFactList < PMLList
    extend PMLListGen
    pml_list(:FlowFact,[],[:origin])
    # customized by_origin implementation
    def by_origin(origin)
      if origin.kind_of?(String)
        @list.select { |ff| origin == ff.origin }
      else
        @list.select { |ff| origin.include?(ff.origin) }
      end
    end

    def add_copies(flowfacts, new_origin)
      copies = []
      flowfacts.each do |ff|
        ff_copy = ff.deep_clone
        ff_copy.origin = new_origin
        add(ff_copy)
        copies.push(ff_copy)
      end
      copies
    end

    def reject!
      rejects = []
      @list.reject! do |ff|
        r = yield ff
        rejects.push(r)
        r
      end
      data.reject! { |_ff| rejects.shift }
    end

    def filter(pml, ff_selection, ff_srcs, _ff_levels, _exclude_symbolic = false)
      classifier = FlowFactClassifier.new(pml)
      @list.select do |ff|
        # skip if level does not match
        # if ! ff_levels.include?(ff.level)
        #  false
        # skip if source is not included
        if ff_srcs != "all" && !ff_srcs.include?(ff.origin)
          false
        elsif !classifier.included?(ff, ff_selection)
          false
        # elsif exclude_symbolic && ! ff.rhs.constant?
        #  false
        # always filter unknown bounds since we cannot handle them in the analyses
        elsif ff.rhs.kind_of?(SEUnknown)
          false
        else
          true
        end
      end
    end

    def stats(pml)
      classifier = FlowFactClassifier.new(pml)
      by_level = {}
      @list.each do |ff|
        klass = classifier.classification_group(ff)
        by_origin = (by_level[ff.level] ||= {})
        by_origin[:cnt] = (by_origin[:cnt] || 0) + 1
        by_group = (by_origin[ff.origin] ||= {})
        by_group[:cnt] = (by_group[:cnt] || 0) + 1
        by_klass = (by_group[klass] ||= {})
        by_klass[:cnt] = (by_klass[:cnt] || 0) + 1
      end
      by_level
    end

    def dump_stats(pml, io = $stderr)
      io.puts "Flow-Facts, classified"
      stats(pml).each do |level,by_group|
        io.puts " #{level.to_s.ljust(39)} #{by_group[:cnt]}"
        by_group.each do |group,by_klass|
          next if group == :cnt
          io.puts "   #{group.to_s.ljust(37)} #{by_klass[:cnt]}"
          by_klass.each do |klass,stats|
            next if klass == :cnt
            io.puts "     #{klass.to_s.ljust(35)} #{stats[:cnt]}"
          end
        end
      end
    end
  end

  # List of Terms
  class TermList < PMLList
    extend PMLListGen
    pml_list(:Term,[])
  end

  # Term (ProgramPoint, Factor)
  # Immutable
  class Term < PMLObject
    attr_reader :factor, :ppref
    def initialize(pp,factor,data = nil)
      pp = ContextRef.new(pp, Context.empty) if pp.kind_of?(ProgramPoint)
      assert("Term#initialize: pp not a programpoint reference") { pp.kind_of?(ContextRef) }
      assert("Term#initialize: not a context-sensitive reference: #{pp} :: #{pp.class}") { pp.kind_of?(ContextRef) }
      @ppref, @factor = pp,factor
      set_yaml_repr(data)
    end

    def context
      @ppref.context
    end

    def programpoint
      @ppref.programpoint
    end

    # pp and factor are immutable, no clone necessary
    def deep_clone
      Term.new(@ppref, @factor)
    end

    def to_s
      "#{@factor} #{ppref}"
    end

    def to_pml
      { 'factor' => @factor, 'program-point' => @ppref.data }
    end

    def self.from_pml(mod,data)
      Term.new(ContextRef.from_pml(mod,data['program-point']), data['factor'])
    end
  end

  # List of modelfacts (modifiable)
  class ModelFactList < PMLList
    extend PMLListGen
    # pml_list(element_type, unique_indices = [], indices = [])
    pml_list(:ModelFact,[],[:origin,:type])
    # customized by_origin implementation
    def by_origin(origin)
      if origin.kind_of?(String)
        @list.select { |mf| origin == mf.origin }
      else
        @list.select { |mf| origin.include?(mf.origin) }
      end
    end

    def add_copies(flowfacts, new_origin)
      copies = []
      flowfacts.each do |mf|
        mf_copy = mf.deep_clone
        mf_copy.origin = new_origin
        add(mf_copy)
        copies.push(mf_copy)
      end
      copies
    end

    def reject!
      rejects = []
      @list.reject! do |mf|
        r = yield mf
        rejects.push(r)
        r
      end
      data.reject! { |_mf| rejects.shift }
    end

    def stats(_pml)
      assert("Unimplemented") { false }
    end

    def dump_stats(_pml, _io = $stderr)
      assert("Unimplemented") { false }
    end

    def to_set
      set = Set.new
      each do |mf|
        set.add(mf)
      end
      set
    end
  end

  # Model Fact utility class
  # Kind of flow facts of interest
  # guard:    * boolexpr         ... specifies code (blocks) not executed
  class ModelFact < PMLObject
    attr_reader :attributes, :ppref, :type, :expr, :mode
    include ProgramInfoObject
    include PML

    def initialize(ppref, type, expr, attrs, mode, data = nil)
      assert("ModelFact#initialize: program point reference has wrong type (#{ppref.class})") do
        ppref.kind_of?(ContextRef)
      end
      @ppref, @type, @expr = ppref, type, expr
      @attributes = attrs
      @mode = mode
      set_yaml_repr(data)
    end

    def programpoint
      @ppref.programpoint
    end

    def self.from_pml(pml, data, mode = 'platin')
      fs = pml.toplevel_objects_for_level(data['level'])
      ModelFact.new(ContextRef.from_pml(fs,data['program-point']),
                    data['type'], data['expression'],
                    ProgramInfoObject.attributes_from_pml(pml, data),
                    mode,
                    data)
    end

    def to_pml
       # rubocop:disable Layout/MultilineHashBraceLayout
      { 'program-point' => @ppref.data,
        'type' => @type,
        'expression' => @expr
      }.merge(attributes)
       # rubocop:enable Layout/MultilineHashBraceLayout
    end

    def to_source
      @ppref.programpoint.block.src_hint + ": " \
        "#pragma platina " + type + " " + '"' + expr + '"'
    end

    # string representation of the value fact
    def to_s
      "#<ModelFact #{attributes.map { |k,v| "#{k}=#{v}" }.join(",")}, #{type} at #{ppref}: #{expr}>"
    end

    # deep clone: clone flow fact, lhs and attributes
    def deep_clone
      ModelFact.new(ppref.dup, type.dup, expr.dup, attributes.dup)
    end

    def ==(other)
      return false if other.nil?
      return false unless other.kind_of?(ModelFact)
      @ppref == other.ppref && @type == other.type && @expr == other.expr
    end

    def eql?(other); self == other; end

    def hash
      return @hash if @hash
      @hash = @ppref.hash ^ @expr.hash ^ @type.hash
    end

    def <=>(other)
      hash <=> other.hash
    end

    def to_fact(pml, model)
      case @type
        # "Never go into the Dark Wood, my friend.", said Ratty Rupert. "There
        # are bad things in there"     -- Mr Bunnsy has an adventure
      when "guard"

                                # We aim for the following kind of flowfact
        # - scope:
        #     function: snd_ac97_pcm_open
        #     loop: for.body80
        #   lhs:
        #   - factor: 1
        #     program-point:
        #       function: snd_ac97_pcm_open
        #       block: for.body80
        #   op: less-equal
        #   rhs: '0'
        #   level: bitcode
        #   origin: model.bc

        # We do not deal with markers and declare our guard at function level
        # Ugly as hell, but use reflection to check for the :function attr
        # accessor
        assert("guards match on function scope, no function found #{ppref} in #{self}") \
              { ppref.respond_to?(:function) }
        assert("guards set a blockfreq, no block found for #{ppref} in #{self}") \
              do
                ppref.kind_of?(ContextRef) \
                      && ppref.respond_to?("programpoint") \
                      && ppref.programpoint.kind_of?(Block)
              end
        assert("guard operate on bitcode level") { level == 'bitcode' }
        fun = ppref.function

        # When the guardexpression is false, then this path is infeasible
        guardexpr = Peaches::evaluate_expression(model.context, expr, :boolean)
        unless guardexpr
          # FlowFact.block_frequency(scoperef, blockref, freq, attrs)
          fact = FlowFact.block_frequency(fun, ppref.programpoint, [SEInt.new(0)], attributes)
          fact.origin = 'model.bc'
          fact
        end

        # "The important thing about adventures, thought Mr Bunnsy, was that
        # they shouldn't be so long as to make you miss mealtimes"
        #                                   -- Mr Bunnsy has an adventure
      when "lbound"
        # modelfacts:
        #   - program-point:
        #       function:        c_entry
        #       block:           while.body
        #     origin:          platina.bc
        #     level:           bitcode
        #     type:            lbound
        #     expression:      '10'

        assert("lbound operates on bitcode level") { level == 'bitcode' }
        assert("lbounds match on function scope, no function found #{ppref} in #{self}") \
              { ppref.respond_to?(:function) }
        assert("lbounds set a blockfreq, no block found for #{ppref} in #{self}") \
              do
                ppref.kind_of?(ContextRef) \
                      && ppref.respond_to?("programpoint") \
                      && ppref.programpoint.kind_of?(Block)
              end

        # To use Flowfact.loop_bound, we need a scope at the level of our
        # programpoint easiest way to achieve this is to use ProgramPoint.from_pml...
        # Therefore, we fake the appropriate input here:
        fs = pml.toplevel_objects_for_level(level)
        data = {}
        data['function'] = ppref.function.name
        data['loop']     = ppref.programpoint.block.name
        scope = ContextRef.from_pml(fs, data)
        assert("lbounds operate on loops, no loop found for #{ppref} in #{self}") \
              { scope != nil && scope.programpoint.kind_of?(Loop) }
        # XXX: use model-eval-foo here
        bound = Peaches::evaluate_expression(model.context, expr, :number)
        assert("lbounds operate on positive integers, but (#{expr}) evaluates to #{bound}") do
          bound >= 0
        end

        fact = FlowFact.loop_bound(scope, SEInt.new(bound + 1), attributes)
        fact.origin = 'model.bc'
        fact

        # "And because of Olly the Snake's trick with the road sign, Mr Bunnsy
        # did not know that he had lost his way. He wasn't going to Howard the
        # Stoat's tea party. He was heading into the Dark Wood."
        #                                   -- Mr Bunnsy has an adventure
      when "callee"
        assert("callee operates on machinecode level") { level == 'machinecode' }
        assert("callee targets call instructions" \
               ", no unresolved call found for #{ppref} in #{self}") \
              do
                ppref.kind_of?(ContextRef) \
                      && ppref.respond_to?("programpoint") \
                      && ppref.programpoint.kind_of?(Instruction) \
                      && ppref.programpoint.calls? && ppref.programpoint.unresolved_call?
              end

        # XXX: use model-eval-foo here
        listfields = /\[(.*)\]/.match(expr)
        assert("Not a list: #{expr}") { listfields != nil }
        entries = listfields[1].split(",")
        # Remove whitespace
        entries.map! { |entry| entry.strip }

        # If we have a qualified identifier, perform patmos-clang-style
        # namemangling (only for static identifiers)
        entries.map! do |entry|
          entry.sub(/^([^:]+):(.+)$/) do
            fname = $2; # because, well, fuck you, we are using global variables
                        # for our regex matching. scoping is for loosers.
            $1.gsub(/[^0-9A-Za-z]/, '_') + '_' + fname
          end
        end

        mutation = PMLMachineCalleeMutation.new(ppref.programpoint, entries)
        mutation
      else
        assert("Cannot translate type #{@type} to a fact") { false }
      end
    end
  end

  # Flow Fact utility class
  # Kind of flow facts of interest
  # validity: * analysis-context ... flow fact is valid for the analyzed program
  #           * scope            ... flow fact is valid for each execution of its scope
  # scope:    * function,loop    ... flow fact applies to every execution of the scope
  # general:  * edges            ... relates CFG edges
  #           * blocks           ... relates CFG blocks
  #           * calltargets      ... relates call-sites and function entries
  # special:  * infeasible       ... specifies code (blocks) not executed
  #           * header           ... specifies bound on loop header
  #           * backedges        ... specifies bound of backedges
  class FlowFact < PMLObject
    attr_reader :scope, :lhs, :op, :rhs, :attributes
    include ProgramInfoObject

    def initialize(scope, lhs, op, rhs, attributes, data = nil)
      scope = ContextRef.new(scope, Context.empty) if scope.kind_of?(ProgramPoint)
      assert("scope not a reference") { scope.kind_of?(ContextRef) }
      assert("lhs not a list proxy") { lhs.kind_of?(PMLList) }
      assert("lhs is not a list of terms") { lhs.empty? || lhs[0].kind_of?(Term) }

      @scope, @lhs, @op, @rhs = scope, lhs, op, rhs
      @rhs = SEInt.new(@rhs) if rhs.kind_of?(Integer)
      @attributes = attributes
      raise Exception, "No level attribute!" unless level
      set_yaml_repr(data)
    end

    # whether this flow fact has a symbolic constant (not fully supported)
    def symbolic_bound?
      !@rhs.constant?
    end

    # string representation of the flow fact
    def to_s
      "#<FlowFact #{attributes.map { |k,v| "#{k}=#{v}" }.join(",")}, in #{scope}: #{lhs} #{op} #{rhs}>"
    end

    # deep clone: clone flow fact, lhs and attributes
    def deep_clone
      FlowFact.new(scope.dup, lhs.deep_clone, op, rhs, attributes.dup)
    end

    def classification_group(pml = nil)
      FlowFactClassifier.new(pml).classification_group(self)
    end

    def self.from_pml(pml, data)
      mod = pml.toplevel_objects_for_level(data['level'])
      scope = ContextRef.from_pml(mod,data['scope'])
      lhs = TermList.new(data['lhs'].map { |t| Term.from_pml(mod,t) })
      attrs = ProgramInfoObject.attributes_from_pml(pml, data)
      rhs = SymbolicExpression.parse(data['rhs'])
      rhs = rhs.map_names do |ty,name|
        if ty == :variable # ok
          name
        elsif ty == :loop
          b = scope.function.blocks.by_name(name[1..-1]).loop
          raise Exception, "Unable to lookup loop: #{name} in #{b}" unless b
          b
        end
      end
      ff = FlowFact.new(scope, lhs, data['op'], rhs, attrs, data)
      ff
    end

    def to_pml
      # rubocop:disable Layout/MultilineHashBraceLayout
      assert("no 'level' attribute for flow-fact") { level }
      { 'scope' => scope.data,
        'lhs' => lhs.data,
        'op' => op,
        'rhs' => rhs.to_s,
      }.merge(attributes)
      # rubocop:enable Layout/MultilineHashBraceLayout
    end

    # Flow fact builders
    def self.block_frequency(scoperef, blockref, freq, attrs)
      terms = [Term.new(blockref, 1)]
      flowfact = FlowFact.new(scoperef, TermList.new(terms),'less-equal',freq.max, attrs.dup)
      flowfact
    end

    def self.calltargets(scoperef, csref, receivers, attrs)
      terms = [Term.new(csref,1)]
      receivers.each do |fref|
        terms.push(Term.new(fref,-1))
      end
      flowfact = FlowFact.new(scoperef,TermList.new(terms),'less-equal',0, attrs.dup)
      flowfact
    end

    def self.loop_bound(scope, bound, attrs)
      blockref = ContextRef.new(scope.programpoint.loopheader, Context.empty)
      flowfact = FlowFact.new(scope, TermList.new([Term.new(blockref,1)]), 'less-equal',
                              bound, attrs.dup)
      flowfact
    end

    def self.inner_loop_bound(scoperef, blockref, bound, attrs)
      flowfact = FlowFact.new(scoperef, TermList.new([Term.new(blockref,1)]), 'less-equal',
                              bound, attrs.dup)
      flowfact
    end

    def self.from_string(pml, ff)
      x = ff.split(/\s*:\s*/)
      assert("Invalid Flow Fact format #{ff} ( <scope> : <context> : <fact> = <const> )") {
        x.length == 3
      }
      scope, context, fact = x
      assert("Only the foreach context supported ( '<>' )") {
        context == "<>"
      }
      m = /\s*([^<=]*?)\s*(=|<=)\s*([0-9]*)/.match(fact)
      lhs, op, rhs = m[1..3]

      if lhs[0] != "-"
        lhs = "+ " + lhs
      end
      terms = []
      mf_scope = pml.machine_functions.by_label(scope)
      while lhs != "" do
        m = /(?<sign>[+-])\s*((?<factor>[0-9]+)\s*)?(?<pp>[^+-]*)\s*(?<lhs>.*)/.match(lhs)

        if m[:pp][0] == "/"
          reg = Regexp.new m[:pp][1..-2]
          functions = pml.machine_functions\
                      .select {|mf| mf.label =~ reg  && mf_scope.callees.member?(mf.label) }\
                      .map {|mf| mf.label}
        else
          functions = [m[:pp]]
        end
        functions.each {|mf_label|
          factor = (m[:factor] || "1").to_i
          factor *= {"+"=>1, "-"=>-1}[m[:sign]]
          terms.push ({"factor"=>factor,
                       "program-point"=> {"function"=>mf_label}})
        }
        lhs = m[:lhs]
      end

      flowfact = {'scope'=> {'function'=> scope},
                  'level'=> 'machinecode',
                  'origin'=> 'user',
                  'op' => {"=" => "equal", "<=" => "less-equal"}[op],
                  'rhs' => rhs.to_i,
                  'lhs' => terms,
                 }

      FlowFact.from_pml(pml, flowfact)
    end

    def globally_valid?(entry_function)
      # local relative flow facts are globally valid
      return true if local? && rhs.constant? && rhs.to_i == 0
      # otherwise, the scoep has to be the entry function
      scope.programpoint.kind_of?(Function) &&
        scope.function == entry_function &&
        scope.context.empty?
    end

    def local?
      lhs.all? do |term|
        pp = term.programpoint
        pp.kind_of?(ConstantProgramPoint) || (pp.function && pp.function == scope.function)
      end
    end

    def loop_bound?
      !get_loop_bound.nil?
    end

    def loop_scope?
      scope.programpoint.kind_of?(Loop)
    end

    def context_sensitive?
      return true if lhs.any? { |term| !term.context.empty? }
      !scope.context.empty?
    end

    def references_empty_block?
      lhs.any? { |t| t.programpoint.kind_of?(Block) && t.programpoint.instructions.empty? }
    end

    def references_edges?
      lhs.any? { |t| t.programpoint.kind_of?(Edge) }
    end

    def blocks_constraint?
      lhs.all? { |t| t.programpoint.kind_of?(Block) }
    end

    # if this constraint is a loop bound, return loop scope and bound
    def get_loop_bound
      s,b,rhs = get_block_frequency_bound
      return nil unless s
      return nil unless s.programpoint.kind_of?(Loop)
      return nil unless s.programpoint.loopheader == b.programpoint.block && b.context.empty?
      [s,rhs]
    end

    # if this constraints marks a block infeasible,
    # return [[scope,block]]
    def get_block_infeasible
      # Terms for infeasible blocks have a specific structure:
      #   \sum_{i = 0}^{n} c_i * block_i <= 0 mit c_i \in \mathbb{N}
      # This is what we match for below

      return [] unless rhs.constant? && rhs.to_i == 0
      infeasible_blocks = []
      lhs.list.each do |term|
        factor,ppref,pp = term.factor,term.ppref,term.programpoint
        return [] unless factor.to_i >= 0
        return [] unless pp.kind_of?(Block)
        # Note: this allows (factor = 0) without marking them infeasible. No
        #       This is intentional, as those blocks are _not_ infeasible from
        #       this formula
        infeasible_blocks << [scope, ppref] if factor.to_i > 0
      end
      require 'pp'
      pp infeasible_blocks
      infeasible_blocks
    end

    # if this is a flowfact constraining the frequency of a single block,
    # return [scope, block, freq]
    #  block  ... Block
    #  freq   ... Integer
    def get_block_frequency_bound
      return nil unless lhs.list.length == 1
      term = lhs.list.first
      return nil unless term.factor == 1
      return nil unless term.programpoint.kind_of?(Block)
      [scope, term.ppref, rhs]
    end

    # if this is a calltarget-* flowfact, return [scope, cs, targets]:
    #   cs      ... ContextRef <Instruction>
    #   targets ... [Function]
    def get_calltargets
      callsite_candidate = lhs.list.select do |term|
        term.factor == 1 && term.programpoint.kind_of?(Instruction)
      end
      return nil unless callsite_candidate.length == 1
      callsite_ref = callsite_candidate.first.ppref
      opposite_factor = -1
      targets = []
      lhs.each do |term|
        next if term == callsite_candidate.first
        return nil unless term.factor == opposite_factor
        return nil unless term.programpoint.kind_of?(Function)
        targets.push(term.programpoint)
      end
      [scope, callsite_ref, targets]
    end
  end

  # List of value analysis entries (modifiable)
  class ValueFactList < PMLList
    extend PMLListGen
    pml_list(:ValueFact,[],[:origin])
  end

  class ValueSet < PMLList
    extend PMLListGen
    pml_list(:ValueRange)
    def dup
      ValueSet.new(@list.dup)
    end
  end

  class ValueRange < PMLObject
    attr_reader :symbol, :min, :max
    def initialize(min, max, symbol, data = nil)
      @min, @max, @symbol = min, max, symbol
      set_yaml_repr(data)
      raise Exception, "Bad ValueRange: #{self}" if @min && @min > @max
    end

    def inspect
      "ValueRange<min=#{min.inspect},max=#{max.inspect},symbol=#{symbol}>"
    end

    def to_s
      symbol.to_s + (range ? range.to_s : '')
    end

    def range
      return nil unless max
      Range.new(min,max)
    end

    def self.from_pml(_,data)
      ValueRange.new(data['min'],data['max'],data['symbol'],data)
    end

    def to_pml
      { 'min' => @min, 'max' => @max, 'symbol' => @symbol }.delete_if { |_,v| v.nil? }
    end
  end

  # value facts record results from value analysis (at the binary or bitcode level)
  #
  # program-point: pp
  # variable: mem-address-read, mem-address-write, register name
  # width: int
  # values: list of { min: x, max: x }
  class ValueFact < PMLObject
    attr_reader :attributes, :ppref, :variable, :width, :values
    include ProgramInfoObject
    def initialize(ppref, variable, width, values, attrs, data = nil)
      assert("ValueFact#initialize: program point reference has wrong type (#{ppref.class})") do
        ppref.kind_of?(ContextRef)
      end
      @ppref, @variable, @width, @values = ppref, variable, width, values
      @attributes = attrs
      set_yaml_repr(data)
    end

    def programpoint
      @ppref.programpoint
    end

    def self.from_pml(pml, data)
      fs = pml.toplevel_objects_for_level(data['level'])
      ValueFact.new(ContextRef.from_pml(fs,data['program-point']),
                    data['variable'], data['width'],
                    ValueSet.from_pml(fs,data['values']),
                    ProgramInfoObject.attributes_from_pml(pml, data),
                    data)
    end

    def to_pml
      { 'program-point' => @ppref.data,
        'variable' => @variable,
        'width' => @width,
        'values' => @values.data }.merge(attributes)
    end

    # string representation of the value fact
    def to_s
      vs = values.map { |vr| vr.to_s }.join(", ")
      "#<ValueFact #{attributes.map { |k,v| "#{k}=#{v}" }.join(",")}, " \
        "at #{ppref}: #{variable}#{"[width=#{width}]" if width} \\in {#{vs}}>"
    end
  end

  # List of timing entries (modifiable)
  class TimingList < PMLList
    extend PMLListGen
    pml_list(:TimingEntry, [], [:origin])
  end
  class Profile < PMLList
    extend PMLListGen
    pml_list(:ProfileEntry, [:reference], [])
  end
  class ProfileEntry < PMLObject
    attr_reader :reference, :cycles, :wcetfreq, :criticality, :wcet_contribution
    def initialize(reference, cycles, wcetfreq, wcet_contribution, criticality = nil, data = nil)
      @reference, @cycles, @wcetfreq, @wcet_contribution, @criticality =
        reference, cycles, wcetfreq, wcet_contribution, criticality
      set_yaml_repr(data)
    end

    def self.from_pml(fs, data)
      ProfileEntry.new(ContextRef.from_pml(fs,data['reference']), data['cycles'],
                       data['wcet-frequency'], data['wcet-contribution'], data['criticality'], data)
    end

    def criticality=(c)
      @criticality = c
      @data['criticality'] = c if @data
    end

    def to_pml
      { 'reference' => reference.data, 'cycles' => cycles, 'wcet-frequency' => wcetfreq,
        'criticality' => criticality, 'wcet-contribution' => wcet_contribution }.delete_if { |_k,v| v.nil? }
    end

    def to_s
      data
    end
  end

  # timing entries are used to record WCET analysis results or measurement results
  class TimingEntry < PMLObject
    attr_reader :cycles, :scope, :profile
    attr_reader :attributes
    include ProgramInfoObject

    def initialize(scope, cycles, profile, attrs, data = nil)
      @scope = scope
      @scope = ContextRef.new(@scope, Context.empty) if scope.kind_of?(ProgramPoint)
      assert("TimingEntry#initialize: not a programpoint reference") { @scope.kind_of?(ContextRef) }
      @cycles = cycles
      @profile = profile
      @attributes = attrs
      set_yaml_repr(data)
    end

    def profile=(p)
      @profile = p
      @data['profile'] = @profile.data if @data
    end

    def self.from_pml(pml, data)
      fs = pml.toplevel_objects_for_level(data['level'])
      profile = data['profile'] ? Profile.from_pml(fs, data['profile']) : nil
      TimingEntry.new(ContextRef.from_pml(fs,data['scope']), data['cycles'],
                      profile,
                      ProgramInfoObject.attributes_from_pml(pml,data), data)
    end

    def to_pml
      pml = { 'scope' => @scope.data, 'cycles' => @cycles }.merge(attributes)
      pml['profile'] = @profile.data if @profile
      pml
    end

    def to_s
      "#<TimingEntry #{attributes.map { |k,v| "#{k}=#{v}" }.join(",")}, in #{scope}: #{cycles} cycles>"
    end
  end

  # Graph structure representing stack cache analysis results
  class SCAGraph < PMLObject
    attr_reader :nodes,:edges,:pml
    def initialize(pml, data)
      set_yaml_repr(data)
      @pml = pml
      @nodes = SCANodeList.new(data['nodes'] || [], self)
      @edges = SCAEdgeList.new(data['edges'] || [], self)
    end
  end

  # List of stack cache graph nodes
  class SCANodeList < PMLList
    extend PMLListGen
    pml_name_index_list(:SCAEdge)
    def initialize(data, tree)
      @list = data.map { |n| SCANode.new(n,tree.pml) }
      set_yaml_repr(data)
    end
  end

  # List of stack cache graph edges
  class SCAEdgeList < PMLList
    extend PMLListGen
    pml_name_index_list(:SCANode)
    def initialize(data, _tree)
      @list = data.map { |n| SCAEdge.new(n) }
      set_yaml_repr(data)
    end
  end

  # Stack cache graph node
  class SCANode < PMLObject
    attr_reader :id,:function,:size
    def initialize(data, pml)
      set_yaml_repr(data)
      @id = data['id']
      @function = pml.machine_functions.by_label(data['function'])
      @size = data['spillsize']
    end

    def to_s
      "#{id}:#{function}:#{size}"
    end

    def qname
      @id
    end
  end

  # Stack cache graph edge
  class SCAEdge < PMLObject
    attr_reader :src,:dst,:block,:inst
    def initialize(data)
      set_yaml_repr(data)
      @src = data['src']
      @dst = data['dst']
      @block = data['callblock']
      @inst = data['callindex']
    end

    def to_s
      "#{src}:#{block}:#{inst}->#{dst}"
    end
  end

# end of module PML
end
