# typed: false
#
# platin tool set
#
# ILP module
#
require 'set'

module PML

class UnknownVariableException < Exception
  def initialize(msg)
    super(msg)
  end
end

class InconsistentConstraintException < Exception
  def initialize(msg)
    super(msg)
  end
end

class ILPSolverException < Exception
  attr_accessor :cycles, :freqs, :unbounded

  def initialize(msg, cycles, freqs, unbounded)
    super(msg)
    @cycles    = cycles
    @freqs     = freqs
    @unbounded = unbounded
  end
end

# Indexed Constraints (normalized, with fast hashing)
# Terms: Index => Integer != 0
# Rhs: Integer
# Invariant: gcd(lhs.map(:second) + [rhs]) == 1
class IndexedConstraint
  attr_reader :name, :lhs, :op, :rhs, :key, :hash, :tags
  def initialize(ilp, lhs, op, rhs, name, tags = [])
    @ilp = ilp
    @name, @lhs, @op, @rhs = name, lhs, op, rhs
    @tags = tags
    raise Exception, "add_indexed_constraint: name is nil" unless name
    assert("unexpected op #{@op}") { %w{equal less-equal}.include? @op }
    normalize!
  end

  def tautology?
    normalize! if @tauto.nil?
    @tauto
  end

  def inconsistent?
    normalize! if @inconsistent.nil?
    @inconsistent
  end

  # Check if this constraint has the form 'x <= c' or 'x >= c'
  def bound?
    normalize! if @inconsistent.nil?
    return false if (@op != 'less-equal') || (@lhs.length != 1)
    v,c = @lhs.first
    c == -1 || c == 1
  end

  # Check if this constraint has the form '-x <= 0'
  def non_negative_bound?
    normalize! if @inconsistent.nil?
    return false if (@op != 'less-equal') || (@lhs.length != 1) || (@rhs != 0)
    v,c = @lhs.first
    c == -1
  end

  def get_coeff(v)
    @lhs[v]
  end

  def named_lhs
    named_lhs = Hash.new(0)
    @lhs.each { |vi,c| named_lhs[@ilp.var_by_index(vi)] = c }
    named_lhs
  end

  def set(v,c)
    @lhs[v] = c
    invalidate!
  end

  def add(v,c)
    set(v,c + @lhs[v])
  end

  def invalidate!
    @key, @hash, @gcd, @tauto, @inconsistent = nil, nil, nil, nil,nil
  end

  def normalize!
    return unless @tauto.nil?
    @lhs.delete_if { |_v,c| c == 0 }
    @tauto, @inconsistent = false, false
    if @lhs.empty?
      if @rhs == 0
        @tauto = true
      elsif @rhs >= 0 && @op == "less-equal"
        @tauto = true
      else
        @inconsistent = true
      end
    elsif @lhs.length == 1 && @op == "equal" && @rhs == 0
      # c != 0 -> c x = 0 <=> x = 0
      v, c = @lhs.first
      @lhs[v] = 1
    else
      @gcd = @lhs.values.inject(@rhs, :gcd)
      @lhs.merge!(@lhs) { |_v,c| c / @gcd }
      @rhs /= @gcd
    end
  end

  def hash
    @hash if @hash
    @hash = key.hash
  end

  def key
    @key if @key
    normalize!
    @key = [@lhs,@op == 'equal',@rhs]
  end

  def ==(other)
    key == other.key
  end

  def <=>(other)
    key <=> other.key
  end

  def eql?(other); self == other; end

  def inspect
    "Constraint#<#{lhs.inspect},#{@op.inspect},#{rhs.inspect}>"
  end

  def to_s(use_indices = false)
    lhs, rhs = Hash.new(0), Hash.new(0)
    (@lhs.to_a + [[0,-@rhs]]).each do |v,c|
      if c > 0
        lhs[v] += c
      else
        rhs[v] -= c
      end
    end
    [lhs.to_a, rhs.to_a].map do |ts|
      ts.map do |v,c|
        if v == 0
          c == 0 ? nil : c
        else
          vname = use_indices ? v.to_s : @ilp.var_by_index(v).to_s
          c == 1 ? vname : "#{c} #{vname}"
        end
      end.compact.join(" + ")
    end.map { |s| s.empty? ? "0" : s }.join(@op == "equal" ? " = " : " <= ")
  end
end

# ILP base class (FIXME)
class ILP
  attr_reader :variables, :constraints, :costs, :options, :vartype, :solvertime, :sos1
  # variables ... array of distinct, comparable items
  def initialize(options = nil)
    @solvertime = 0
    @sos1 = {}
    @options = options
    @variables = []
    @indexmap = {}
    @vartype = {}
    @eliminated = Hash.new(false)
    @constraints = Set.new
    @do_diagnose = !options.disable_ipet_diagnosis
    reset_cost
  end

  # number of non-eliminated variables
  def num_variables
    variables.length - @eliminated.length
  end

  # short description
  def to_s
    "#<#{self.class}:#{num_variables} vars, #{constraints.length} cs>"
  end

  # print ILP
  def dump(io = $stderr)
    io.puts("max " + costs.map { |v,c| "#{c} #{v}" }.join(" + "))
    @indexmap.each do |v,ix|
      next if @eliminated[ix]
      io.puts " #{ix}: int #{v} #{costs[v]}"
    end
    @sos1.each do |v,ix|
      io.puts " SOS: [#{ix}] #{v} "
    end
    @constraints.each_with_index do |c,ix|
      io.puts " #{ix}: constraint [#{c.name}]: #{c}"
    end
  end

  # index of a variable
  def index(variable)
    @indexmap[variable] or raise UnknownVariableException.new("unknown variable: #{variable}")
  end

  # variable indices
  def variable_indices
    @indexmap.values
  end

  # variable by index
  def var_by_index(ix)
    @variables[ix - 1]
  end

  # set cost of all variables to 0
  def reset_cost
    @costs = Hash.new(0)
  end

  # get cost of variable
  def get_cost(v)
    @costs[v]
  end

  # remove all constraints
  def reset_constraints
    @constraints = Set.new
  end

  # add cost to the specified variable
  def add_cost(variable, cost)
    assert("Unknown variable: #{variable}") { not variable.nil? and has_variable?(variable)}
    @costs[variable] += cost
    debug(@options, :ilp) { "Adding costs #{variable} = #{cost}" }
  end

  # add a new variable, if necessary
  def has_variable?(v)
    !@indexmap[v].nil?
  end

  # add a new variable
  def add_variable(v, vartype = :machinecode, upper_bound = :unbounded)
    raise Exception, "Duplicate variable: #{v}" if @indexmap[v]
    assert("ILP#add_variable: type is not a symbol") { vartype.kind_of?(Symbol) }
    debug(@options, :ilp) { "Adding variable #{v} :: #{vartype.inspect}" }

    @variables.push(v)
    index = @variables.length # starting with 1
    @indexmap[v] = index
    @vartype[v] = vartype
    @eliminated.delete(v)
    add_constraint([[v, -1]], 'less-equal', 0,
                   "lower_bound_v_#{index}", :range)
    if upper_bound != :unbounded
      add_constraint([[v, 1]], 'less-equal', upper_bound,
                     "upper_bound_v_#{index}", :range)
    end
    # add_indexed_constraint({index => -1},"less-equal",0,,Set.new([:positive]))
    index
  end

  def add_sos1(name, variables, card=1, vartype= :machinecode)
    raise Exception.new("Duplicate SOS: #{name}") if @sos1[name]
    @sos1[name] = [variables, card]

    variables.each { |v|
      add_variable(v, vartype)
    }
  end

  # add constraint:
  # terms_lhs .. [ [v,c] ]
  # op        .. "equal" or "less-equal"
  # const_rhs .. integer
  def add_constraint(terms_lhs,op,const_rhs,name,tag)
    assert("Markers should not appear in ILP") do
      terms_lhs.none? { |v,_c| v.kind_of?(Marker) }
    end
    terms_indexed = Hash.new(0)
    terms_lhs.each do |v,c|
      terms_indexed[index(v)] += c
    end
    c = add_indexed_constraint(terms_indexed,op,const_rhs,name,Set.new([tag]))
    debug(options, :ilp) { "Adding constraint: #{terms_lhs} #{op} #{const_rhs} ==> #{c}" }
    c
  end

  # Generate a nice string-representation of a frequencymap for
  # diganose_unbounded
  def debug_bound_frequencies(freq)
    margin = BIGM/100_000
    freq.each do |v,k|
      freq[v] = if k < BIGM - margin
                  k.to_i
                elsif k >= BIGM - margin && k <= BIGM
                  "\u221e"
                else
                  "c\u221e"
                end
    end
  end

  # conceptually private; friend VariableElimination needs access
  def create_indexed_constraint(terms_indexed, op, const_rhs, name, tags)
    terms_indexed.default = 0
    constr = IndexedConstraint.new(self, terms_indexed, op, const_rhs, name, tags)
    return nil if constr.tautology?
    raise InconsistentConstraintException, "Inconsistent constraint #{name}: #{constr}" if constr.inconsistent?
    constr
  end

private

  def add_indexed_constraint(terms_indexed, op, constr_rhs, name, tags)
    constr = create_indexed_constraint(terms_indexed, op, constr_rhs, name, tags)
    @constraints.add(constr) if constr
    constr
  end

  SLACK = 10_000_000
  BIGM = 10_000_000
  def diagnose_unbounded(problem, _freqmap)
    debug(options, :ilp) { "#{problem} PROBLEM - starting diagnosis" }
    @do_diagnose = false
    variables.each do |v|
      add_constraint([[v,1]],"less-equal",BIGM,"__debug_upper_bound_v#{index(v)}",:debug)
    end
    @eps = 1.0
    cycles,freq = solve_max
    unbounded = freq.map do |v,k|
      k >= BIGM - 1.0 ? v : nil
    end.compact
    unbounded_functions, unbounded_loops = Set.new, Set.new
    unbounded.each do |v|
      next unless v.kind_of?(IPETEdge) && v.source.kind_of?(Block)
      unbounded_functions.add(v.source.function) if v.source == v.source.function.blocks.first
    end
    unbounded.each do |v|
      next unless v.kind_of?(IPETEdge) && v.source.kind_of?(Block)
      unbounded_loops.add(v.source) if !unbounded_functions.include?(v.source.function) && v.source.loopheader?
    end
    if unbounded_functions.empty? && unbounded_loops.empty?
      warn("ILP: Unbounded variables: #{unbounded.join(", ")}")
    else
      warn("ILP: Unbounded functions: #{unbounded_functions.to_a.join(", ")}") unless unbounded_functions.empty?
      warn("ILP: Unbounded loops: #{unbounded_loops.to_a.join(", ")}") unless unbounded_loops.empty?
      unbounded_loops.each do |l|
        warn("Unbounded hint [#{l}]: #{l.src_hint}") unless l.src_hint.empty?
      end
    end
    @do_diagnose = true
    [unbounded, freq]
  end

  def diagnose_infeasible(problem, _freqmap)
    $stderr.puts "#{problem} PROBLEM - starting diagnosis"
    @do_diagnose = false
    old_constraints, slackvars = @constraints, []
    reset_constraints
    variables.each do |v|
      add_constraint([[v,1]],"less-equal",BIGM,"__debug_upper_bound_v#{index(v)}",:debug)
    end
    old_constraints.each do |constr|
      n = constr.name
      next if n =~ /__positive_/
      # only relax flow facts, assuming structural constraints are correct
      if constr.name =~ /^ff/
        v_lhs = add_variable("__slack_#{n}",:slack)
        add_cost("__slack_#{n}", -SLACK)
        constr.set(v_lhs, -1)
        if constr.op == "equal"
          v_rhs = add_variable("__slack_#{n}_rhs",:slack)
          add_cost("__slack_#{n}_rhs", -SLACK)
          constr.set(v_rhs, 1)
        end
      end
      add_indexed_constraint(constr.lhs,constr.op,constr.rhs,"__slack_#{n}",Set.new([:slack]))
    end
    @eps = 1.0
    # @constraints.each do |c|
    #   puts "Slacked constraint #{n}: #{c}"
    # end
    cycles,freq = solve_max
    freq.each do |v,k|
      $stderr.puts "SLACK: #{v.to_s.ljust(40)} #{k.to_s.rjust(8)}" if v.to_s =~ /__slack/ && k != 0
    end
    $stderr.puts "Finished diagnosis with objective #{cycles}"
    @do_diagnose = true
  end
end

end # module PML
