#
# platin tool set
#
# IPET module
#
require 'core/utils'
require 'core/pml'
require 'analysis/ilp'
require 'set'
module PML

# This exception is raised if indirect calls could not be resolved
# during analysis
class UnresolvedIndirectCall < Exception
  def initialize(callsite)
    super("Unresolved Indirect Call: #{callsite.inspect}")
    @callsite = callsite
  end
end

#
# A control-flow refinement provides additional,
# context-sensitive information about the control-flow,
# that is useful to prune callgraphs, CFGs etc.
#
# Currently, two refinements are implement
#
# (1) in scope main or locally, frequency==0 => dead code (infeasible)
# (2) in scope main or locally, cs calls one of targets => refine calltarget sets
#
# +entry+:: analysis entry (a Function)
# +flowfacts+:: a list of flowfacts to process
# +level+:: either machinecode or bitcode
#
class ControlFlowRefinement
  def initialize(entry, level)
    @entry, @level = entry, level
    @infeasible, @calltargets = {}, {}
  end

  def add_flowfact(flowfact)
    return unless flowfact.level == @level
    return unless flowfact.globally_valid?(@entry)
    # add calltargets
    scope,cs,targets = flowfact.get_calltargets
    if scope
      add_calltargets(ContextRef.new(cs.instruction, scope.context), targets.map { |t| t.function})
    end
    # set infeasible blocks
    scope,bref = flowfact.get_block_infeasible
    if scope
      set_infeasible(ContextRef.new(bref.block, scope.context))
    end
  end

  # returns true if +block+ is infeasible in the given +context+
  # XXX: use context trees
  def infeasible_block?(block, context = Context.empty)
    dict = @infeasible[block]
    return false unless dict
    dict[Context.empty] || (! context.empty? && dict[context])
  end

  # returns the set of possible calltargets for +callsite+ in +context+
  # XXX: use context trees
  def calltargets(callsite, context = Context.empty)
    static_fs  = callsite.called_functions
    static_set = Set[*static_fs] if static_fs

    dict = @calltargets[callsite]
    global_set = @calltargets[callsite][Context.empty] if dict
    ctx_set    = @calltargets[callsite][context] unless context.empty? if dict
    sets = [ctx_set,global_set,static_set].compact
    raise UnresolvedIndirectCall.new(callsite) if sets.empty?
    sets.inject { |a,b| a.intersection(b) }
  end

  def dump(io=$stderr)
    io.puts "INFEASIBLE"
    io.puts
    @infeasible.each { |ref,val|
      io.puts "#{ref.inspect} #{val.inspect}"
    }
    io.puts "CALLTARGETS"
    io.puts
    @calltargets.each { |cs,ts|
      io.puts "#{cs}: #{ts}"
    }
  end

private

  def add_calltargets(callsite_ref, targets)
    add_refinement(callsite_ref, Set[targets], @calltargets) { |oldval,newval|
      oldval.intersection(newval)
    }
  end

  # set block infeasible, and propagate infeasibility
  # XXX: ad-hoc propagation, does not consider loop contexts
  def set_infeasible(block_ref)
    block, ctx = block_ref.programpoint, block_ref.context
    worklist = [block]
    while ! worklist.empty?
      block = worklist.pop
      add_refinement(ContextRef.new(block, ctx), true, @infeasible) { |oldval, _| true }
      block.successors.each { |bsucc|
        next if infeasible_block?(bsucc, ctx)
        if bsucc.predecessors.all? { |bpred| infeasible_block?(bpred, ctx) || bsucc.backedge_target?(bpred) }
          worklist.push(bsucc)
        end
      }
      block.predecessors.each { |bpred|
        next if infeasible_block?(bpred, ctx)
        if bpred.successors.all? { |bsucc| infeasible_block?(bsucc, ctx) }
          worklist.push(bpred)
        end
      }
    end
  end

  def add_refinement(reference, value, dict)
    pp_dict    = (dict[reference.programpoint] ||= {})
    ctx        = reference.context
    newval = if oldval = pp_dict[ctx]
               yield [oldval, value]
             else
               value
             end
    pp_dict[ctx] = newval
  end

end

#
# IPETEdges are either:
# - edges beween CFG blocks
# - call edges
# - edges between relation graph nodes
class IPETEdge
  attr_reader :qname,:source,:target, :level
  def initialize(edge_source, edge_target, level)
    @source,@target,@level = edge_source, edge_target, level.to_sym
    arrow = {:bitcode => "~>", :machinecode => "->", :gcfg=>"+>"}[@level]
    @qname = "#{@source.qname}#{arrow}#{:exit == @target ? 'exit' : @target.qname}"
  end
  def backedge?
    return false if target == :exit
    target.backedge_target?(source)
  end
  def cfg_edge?
    return false unless source.kind_of?(Block)
    return false unless :exit == target || target.kind_of?(Block)
    true
  end
  def gcfg_edge?
    if source.kind_of?(GCFGNode) and (target == :exit || target.kind_of?(GCFGNode))
      return true
    end
  end
  # function of source
  def function
    source.function
  end
  def cfg_edge
    assert("IPETEdge#cfg_edge: not a edge between blocks") { cfg_edge? }
    (:exit == target) ? source.edge_to_exit : source.edge_to(target)
  end
  def gcfg_edge
    assert("IPETEdge#cfg_edge: not a edge between blocks") { gcfg_edge? }
    (:exit == target) ? source.edge_to_exit : source.edge_to(target)
  end
  def call_edge?
    source.kind_of?(Instruction) || target.kind_of?(Function)
  end
  def relation_graph_edge?
    source.kind_of?(RelationNode) || target.kind_of?(RelationNode)
  end
  def to_s
    arrow = {:bitcode => "~>", :machinecode => "->", :gcfg=>"+>"}[@level]
    "#{@source}#{arrow}#{:exit == @target ? 'exit' : @target}"
  end
  def inspect
    to_s
  end
  def hash;  @qname.hash ; end
  def ==(other); qname == other.qname ; end
  def eql?(other); self == other; end
end


class IPETModel
  attr_reader :builder, :ilp, :level
  attr_accessor :sum_incoming_override, :sum_outgoing_override
  def initialize(builder, ilp, level)
    @builder, @ilp, @level = builder, ilp, level
    @sum_incoming_override = {}
    @sum_outgoing_override = {}
  end

  def infeasible?(block, context = Context.empty)
    builder.refinement[@level].infeasible_block?(block, context)
  end

  def calltargets(cs, context = Context.empty)
    builder.refinement[@level].calltargets(cs, context)
  end

  # high-level helpers
  def assert_less_equal(lhs, rhs, name, tag)
    assert(lhs, "less-equal", rhs, name, tag)
  end
  def assert_equal(lhs, rhs, name, tag)
    assert(lhs, "equal", rhs, name, tag)
  end
  def assert(lhs, op, rhs, name, tag)
    terms = Hash.new(0)
    rhs_const = 0
    [[lhs,1],[rhs,-1]].each { |ts,sgn|
      ts.to_a.each { |pp, c|
        case pp
        when Instruction
          block_frequency(pp.block, c*sgn).each { |k,v| terms[k]+=v }
        when Block
          block_frequency(pp, c*sgn).each { |k,v| terms[k]+=v }
        when Edge
          edge_frequency(pp, c*sgn).each { |k,v| terms[k] += v }
        when Function
          function_frequency(pp, c*sgn).each { |k,v| terms[k] += v}
        when Loop
          sum_loop_entry(pp,c*sgn).each { |k,v| terms[k] += v }
        when Integer
          rhs_const += pp*(-sgn)
        else
          terms[pp] += c*sgn
        end
      }
    }
    c = ilp.add_constraint(terms, op, rhs_const, name, tag)
  end

  # FIXME: we do not have information on predicated calls ATM.
  # Therefore, we use <= instead of = for call equations
  def add_callsite(callsite, fs)
    # variable for callsite
    add_instruction(callsite)

    # create call edges (callsite -> f) for each called function f
    # the sum of all calledge frequencies is (less than or) equal to the callsite frequency
    # Note: less-than in the presence of predicated calls
    calledges = []
    lhs = [ [callsite, -1] ]
    fs.each do |f|
      calledge = IPETEdge.new(callsite, f, level)
      ilp.add_variable(calledge, level.to_sym)
      calledges.push(calledge)
      lhs.push([calledge, 1])
    end
    ilp.add_constraint(lhs,"less-equal",0,"calledges_#{callsite.qname}",:callsite)

    # return call edges
    calledges
  end

  def add_instruction(instruction)
    return if ilp.has_variable?(instruction)
    # variable for instruction
    ilp.add_variable(instruction, level.to_sym)
    # frequency of instruction = frequency of block
    lhs = [ [instruction,1] ] + block_frequency(instruction.block,-1)
    ilp.add_constraint(lhs, "equal", 0, "instruction_#{instruction.qname}",:instruction)
  end

  # frequency of analysis entry is 1
  def add_entry_constraint(entry_function)
    ilp.add_constraint(function_frequency(entry_function),"equal",1,"structural_entry",:structural)
  end

  def add_gcfg_entry_constraint()
    @ilp.add_variable(:gcfg_entry, :gcfg)
    @ilp.add_constraint([[:gcfg_entry, 1]], "equal", 1, "structural_gcfg_entry", :structural)
  end

  # frequency of function is equal to sum of all callsite frequencies
  def add_function_constraint(function, calledges)
    lhs = calledges.map { |e| [e,-1] }
    lhs.concat(function_frequency(function,1))
    ilp.add_constraint(lhs,"equal",0,"callers_#{function}",:callsite)
  end

  # add cost to basic block
  def add_block_cost(block, cost)
    block_frequency(block).each { |edge,c|
      ilp.add_cost(edge, c * cost)
    }
  end

  # frequency of incoming is frequency of outgoing edges
  def add_block_constraint(block)
    return if block.predecessors.empty?
    lhs = sum_incoming(block,-1) + sum_outgoing(block)
    lhs.push [IPETEdge.new(block,:exit,level),1] if block.may_return?
    ilp.add_constraint(lhs,"equal",0,"structural_#{block.qname}",:structural)
  end

  # frequency of incoming is frequency of outgoing GCFG edges,
  # furthermore, there are the GCFG sources flow variables
  def add_gcfg_node_constraint(node)
    # Calculate all flows that go into this node
    ## The normal Node +> Node Connection
    incoming = sum_incoming(node,-1)
    ## Frequency variables can be connected as sources
    incoming += node.sources.map {|v| [v, -1] }
    ## All source blocks (entry nodes) share one variable
    incoming += [[:gcfg_entry, -1]] if node.is_source

    outgoing = sum_outgoing(node)
    outgoing.push [IPETEdge.new(node,:exit,level),1] if node.is_sink

    ilp.add_constraint(incoming+outgoing,"equal",0,"gcfg_structural_#{node.qname}",:structural)

    if node.frequency_variable
      ilp.add_constraint([[node.frequency_variable, -1]] + outgoing,
                         "equal",0,"frequency_variable_#{node.frequency_variable}_#{node.qname}",
                         :structural)

      ilp.add_constraint([[node.frequency_variable, 1]], "equal", 1, "adsadas", :debug)

    end
  end

  # frequency of incoming is frequency of outgoing edges is 0
  def add_infeasible_block_constraint(block)
    add_block_constraint(block)
    unless block.predecessors.empty?
      ilp.add_constraint(sum_incoming(block),"equal",0,"structural_#{block.qname}_0in",:infeasible)
    end
    unless block.successors.empty?
      ilp.add_constraint(sum_outgoing(block),"equal",0,"structural_#{block.qname}_0out",:infeasible)
    end
  end

  # frequency of incoming edges is frequency of block
  def add_block(block)
    return if ilp.has_variable?(block)
    ilp.add_variable(block)
    lhs = block_frequency(block) + [[block, -1]]
    ilp.add_constraint(lhs,"equal",0,"block_#{block.qname}", :structural)
  end

  def function_frequency(function, factor = 1)
    block_frequency(function.blocks.first, factor)
  end

  def block_frequency(block, factor=1)
    if block.successors.empty? # return exit edge
      [[IPETEdge.new(block,:exit,level),factor]]
    else
      sum_outgoing(block,factor)
    end
  end

  def edge_frequency(edge, factor = 1)
    [[IPETEdge.new(edge.source, edge.target ? edge.target : :exit, level), factor ]]
  end

  def sum_incoming(block, factor=1)
    if @sum_incoming_override[block]
      return @sum_incoming_override[block].map {|e| [e, factor] }
    end
    block.predecessors.map { |pred|
      [IPETEdge.new(pred,block,level), factor]
    }
  end

  def sum_outgoing(block, factor=1)
    if @sum_outgoing_override[block]
      return @sum_outgoing_override[block].map {|e| [e, factor] }
    end

    block.successors.map { |succ|
      [IPETEdge.new(block,succ,level), factor]
    }
  end

  def sum_loop_entry(loop, factor=1)
    sum_incoming(loop.loopheader,factor).reject { |edge,factor|
      edge.backedge?
    }
  end

  # returns all edges, plus all return blocks
  def each_edge(function)
    function.blocks.each_with_index do |bb,ix|
      next if ix != 0 && bb.predecessors.empty? # data block
      bb.successors.each do |bb2|
        yield IPETEdge.new(bb,bb2,level)
      end
      if bb.may_return?
        yield IPETEdge.new(bb,:exit,level)
      end
    end
  end

  # returns all edges, plus all return blocks
  def each_gcfg_edge(gcfg_node)
    die("not a gcfg") if level != "gcfg"
    gcfg_node.successors.each do |n_gcfg_node|
      yield IPETEdge.new(gcfg_node,n_gcfg_node,level)
    end
    if gcfg_node.is_sink
      yield IPETEdge.new(gcfg_node,:exit,level)
    end
  end

  def each_intra_abb_edge(abb)
    region = abb.get_region(:dst)
    region.nodes.each do |mbb|
      # Followup Blocks within
      mbb.successors.each {|mbb2|
        if region.nodes.member?(mbb2)
          yield IPETEdge.new(mbb, mbb2, level)
        end
      }
      if mbb == region.exit_node
        yield IPETEdge.new(mbb, :exit, level)
      end
    end
  end
end # end of class IPETModel

class IPETBuilder
  attr_reader :ilp, :mc_model, :bc_model, :refinement, :call_edges

  def initialize(pml, options, ilp = nil)
    @ilp = ilp
    @mc_model = IPETModel.new(self, @ilp, 'machinecode')
    if options.use_relation_graph
      @bc_model = IPETModel.new(self, @ilp, 'bitcode')
      @pml_level = { :src => 'bitcode', :dst => 'machinecode' }
      @relation_graph_level = { 'bitcode' => :src, 'machinecode' => :dst }
    end
    if options.gcfg_analysis
      @gcfg_model = IPETModel.new(self, @ilp, 'gcfg')
    end

    @ffcount = 0
    @pml, @options = pml, options
  end

  def pml_level(rg_level)
    @pml_level[rg_level]
  end

  def relation_graph_level(pml_level)
    @relation_graph_level[pml_level]
  end

  def get_functions_reachable_from_function(function)
    # compute set of reachable machine functions
    reachable_set(function) do |mf_function|
      # inspect callsites in the current function
      succs = Set.new
      mf_function.callsites.each { |cs|
        next if @mc_model.infeasible?(cs.block)
        @mc_model.calltargets(cs).each { |f|
          assert("calltargets(cs) is nil") { ! f.nil? }
          succs.add(f)
        }
      }
      succs
    end
  end

  # Build basic IPET structure.
  # yields basic blocks, so the caller can compute their cost
  def build(entry, flowfacts, opts = { :mbb_variables =>  false }, &cost_block)
    assert("IPETBuilder#build called twice") { ! @entry }
    @entry = entry
    @markers = {}
    @call_edges = []
    @mf_function_callers = {}
    @options[:mbb_variables] = opts[:mbb_variables]

    # build refinement to prune infeasible blocks and calls
    build_refinement(@entry, flowfacts)

    if @options.gcfg_analysis
      build_gcfg(entry, flowfacts, opts, cost_block)
      return
    end

    mf_functions = get_functions_reachable_from_function(@entry['machinecode'])
    mf_functions.each { |mf_function |
      add_function_with_blocks(mf_function, cost_block)
    }

    mf_functions.each do |f|
      add_bitcode_constraints(f) if @bc_model
      add_calls_in_function(f)
    end

    @mc_model.add_entry_constraint(@entry['machinecode'])

    add_global_call_constraints()

    flowfacts.each { |ff|
      debug(@options,:ipet) { "adding flowfact #{ff}" }
      add_flowfact(ff)
    }
  end

  def add_function_with_blocks(mf_function, cost_block)
    # machinecode variables + cost
    @mc_model.each_edge(mf_function) do |edge|
      @ilp.add_variable(edge, :machinecode)
      if not @options.ignore_instruction_timing
	cost = cost_block.call(edge)
	@ilp.add_cost(edge, cost)
      end
    end

    # bitcode variables and markers
    if @bc_model
      add_bitcode_variables(mf_function)
    end

    # Add block constraints
    mf_function.blocks.each_with_index do |block, ix|
      next if block.predecessors.empty? && ix != 0 # exclude data blocks (for e.g. ARM)
      if @mc_model.infeasible?(block)
        @mc_model.add_infeasible_block_constraint(block)
        next
      end
      @mc_model.add_block_constraint(block)
      if @options[:mbb_variables]
        @mc_model.add_block(block)
      end
    end
  end

  ################################################################
  # Function Calls
  ################################################################
  def add_calls_in_function(mf_function, forbidden_targets=nil)
    mf_function.blocks.each do |block|
      add_calls_in_block(block, forbidden_targets)
    end
  end

  def add_calls_in_block(mbb, forbidden_targets=nil)
    forbidden_targets = Set.new(forbidden_targets || [])
    mbb.callsites.each do |cs|
      call_targets = @mc_model.calltargets(cs)
      call_targets -= forbidden_targets

      current_call_edges = @mc_model.add_callsite(cs, call_targets)
      current_call_edges.each do |ce|
        debug(@options, :calls) { "Add function call: #{cs} -> #{ce.target}" }
        (@mf_function_callers[ce.target] ||= []).push(ce)
      end
      @call_edges += current_call_edges
    end
  end

  def add_global_call_constraints()
    @mf_function_callers.each do |f,ces|
      @mc_model.add_function_constraint(f, ces)
    end
  end


  # Build basic IPET Structure, when a GCFG is present
  def build_gcfg(gcfg, flowfacts, opts, cost_block)
    # Super Structure: set of reachable ABBs
    abbs = Set.new
    # For each ABB, we collect two sets of edges.
    # - abb_outgoing_flow:
    #   This ABB->[IPETEdge] mapping collects edges that, in sum, *replace* the outgoing edges
    #   for the ABB Exit/Entry.
    # - abb_frequency_copy:
    #   The ABB frequency copy mapping collects all edges that, in sum, are equal to the
    #   frequency of the block, but do not define it.
    abb_outgoing_flow = Hash.new {|hsh, key| hsh[key] = [] }
    abb_frequency = Hash.new {|hsh, key| hsh[key] = [] }
    abb_is_toplevel = Hash.new

    gcfg.nodes.each do |node|
      if node.frequency_variable
        @ilp.add_variable(node.frequency_variable, :gcfg)
      end

      # Every Super-structure edge has a variable
      @gcfg_model.each_gcfg_edge(node) { |ipet_edge|
        @ilp.add_variable(ipet_edge, :gcfg)
        cost = 0
        cost += node.cost if node.cost
        # Not all GCFG Edges have a cost that stems from its internal
        # structure. There are some exceptions:
        # - GCFG Nodes can reference no block
        # - GCFG Node does not force the control flow, therefore it
        #   does not introduce jumps between two machine basic blocks
        #   -> no extra cost.
        source_abb = ipet_edge.source.abb
        source_block = ipet_edge.source.abb.get_region(:dst).exit_node if source_abb
        target_block = if ipet_edge.target == :exit
          :exit
        elsif ipet_edge.target.abb
          ipet_edge.target.abb.get_region(:dst).entry_node
        else
          :idle
        end
        if not @options.ignore_instruction_timing and \
          source_block and target_block and node.force_control_flow
          cost += cost_block.call(ipet_edge)
        end
        @ilp.add_cost(ipet_edge, cost)
        # Collect all outgoing super structure edges into this abb
        # This is necessary to allow the forcing of the control flow
        # afterwards.
        if source_abb
          assert("ABB cannot be simultaenously part of super-strucutre and micro-structre") {
            if abb_is_toplevel.include?(source_abb)
              abb_is_toplevel[source_abb] == node.force_control_flow
            else
              true
            end
          }
          abb_is_toplevel[source_abb] = node.force_control_flow
          if node.force_control_flow
            abb_outgoing_flow[source_abb].push(ipet_edge)
          else
            abb_frequency[source_abb].push(ipet_edge)
          end
        end
      }
    end

    # Now we have all edge variables on the super level constructed
    @gcfg_model.add_gcfg_entry_constraint()
    gcfg.nodes.each do |node|
      @gcfg_model.add_gcfg_node_constraint(node)
    end

    #################################################
    ## The ABB Super Structure is now fully in place.
    toplevel_abbs = abb_is_toplevel.select { |abb, is_toplevel| is_toplevel }.keys

    # Now, we insert the actual machine code blocks and functions into the ILP.
    # Super Structure: set of reachable machine basic blocks
    abb_mbbs = []
    gcfg_mfs = Set.new # Each ABB is part of a function, this is the set of these functions
    toplevel_abbs.each {|abb|
      # ABB belongs to function
      gcfg_mfs.add(abb.machine_function)

      abb_mbbs += abb.get_region(:dst).nodes
      # Add inner structure of ABB
      build_gcfg_abb(abb, abb_outgoing_flow[abb], flowfacts, opts, cost_block)
    }

    # Super Structure: what functions are activated from the super structure?
    abb_mfs = Set.new
    abb_mbbs.each {|bb|
         bb.callsites.each { |cs|
           next if @mc_model.infeasible?(cs.block)
           @mc_model.calltargets(cs).each { |f|
             assert("calltargets(cs) is nil") { ! f.nil? }
             funcs = get_functions_reachable_from_function(f)
             abb_mfs += get_functions_reachable_from_function(f)
           }
         }
    }

    # Remove all functions that are contained in the super structure from the lower level  functions
    abb_mfs -= gcfg_mfs

    abb_mfs.each do |mf|
      add_function_with_blocks(mf, cost_block)
    end

    abb_mfs.each do |mf|
      add_calls_in_function(mf, forbidden = gcfg_mfs)
    end
    abb_mbbs.each do |bb|
      add_calls_in_block(bb)
    end

    # FIXME: force the ABB micro structure

    # assert("Function calls are not allowed into the super structure") {
    #   (abb_mfs & gcfg_mfs).length == 0
    # }

    add_global_call_constraints()

    die("Bitcode contraints are not implemented yet") if @bc_model
  end

  def build_gcfg_abb(abb, outgoing_abb_flux, flowfacts, opts, cost_block)
    # Restrict the influx of our ABB Region
    region = abb.get_region(:dst)

    # Add all edges within the ABB
    edges = {}
    region.nodes.each {|bb|
      edges[bb] = {:in => [], :out => []}
    }
    edges[:exit] = {:in => [], :out => []}


    @mc_model.each_intra_abb_edge(abb) { |ipet_edge|
      @ilp.add_variable(ipet_edge)
      if not @options.ignore_instruction_timing
	cost = cost_block.call(ipet_edge)
	@ilp.add_cost(ipet_edge, cost)
      end
      # Collect edges
      edges[ipet_edge.source][:out].push(ipet_edge)
      edges[ipet_edge.target][:in].push(ipet_edge)
    }
    # The first block is activated as often, as the ABB is left
    edges[region.entry_node][:in] = outgoing_abb_flux
    edges.each {|bb, e|
      next if bb == :exit
      incoming = e[:in].map {|x| [x, 1]}
      outgoing = e[:out].map {|x| [x, -1]}
      ilp.add_constraint(incoming+outgoing, "equal", 0,
                       "abb_flux_#{bb.qname}", :structural)

      # Override the incoming and outgoing frequencies
      @mc_model.sum_incoming_override[bb] = e[:in]
      @mc_model.sum_outgoing_override[bb] = e[:out]
    }
  end
  #
  # Add flowfacts
  #
  def add_flowfact(ff, tag = :flowfact)
    model = ff.level == "machinecode" ? @mc_model : @bc_model
    raise Exception.new("IPETBuilder#add_flowfact: cannot add bitcode flowfact without using relation graph") unless model
    unless ff.rhs.constant?
      warn("IPETBuilder#add_flowfact: cannot add flowfact with symbolic RHS to IPET: #{ff}")
      return false
    end
    if ff.level == "bitcode"
      begin
        ff = replace_markers(ff)
      rescue Exception => ex
        warn("IPETBuilder#add_flowact: failed to replace markers: #{ex}")
        return false
      end
    end
    lhs, rhs = [], ff.rhs.to_i
    ff.lhs.each { |term|
      unless term.context.empty?
        warn("IPETBuilder#add_flowfact: context sensitive program points not supported: #{ff}")
        return false
      end
      if term.programpoint.kind_of?(Function)
        lhs += model.function_frequency(term.programpoint, term.factor)
      elsif term.programpoint.kind_of?(Block)
        lhs += model.block_frequency(term.programpoint, term.factor)
      elsif term.programpoint.kind_of?(Edge)
        lhs += model.edge_frequency(term.programpoint, term.factor)
      elsif term.programpoint.kind_of?(Instruction)
        # XXX: exclusively used in refinement for now
        warn("IPETBuilder#add_flowfact: references instruction, not block or edge: #{ff}")
        return false
      else
        raise Exception.new("IPETBuilder#add_flowfact: Unknown programpoint type: #{term.programpoint.class}")
      end
    }
    scope = ff.scope
    unless scope.context.empty?
      warn("IPETBUilder#add_flowfact: context sensitive scopes not supported: #{ff}")
      return false
    end
    if scope.programpoint.kind_of?(Function)
      lhs += model.function_frequency(scope.programpoint, -rhs)
    elsif scope.programpoint.kind_of?(Loop)
      lhs += model.sum_loop_entry(scope.programpoint, -rhs)
    else
      raise Exception.new("IPETBuilder#add_flowfact: Unknown scope type: #{scope.programpoint.class}")
    end
    begin
      name = "ff_#{@ffcount+=1}"
      ilp.add_constraint(lhs, ff.op, 0, name, tag)
      name
    rescue UnknownVariableException => detail
      debug(@options,:transform) { "Skipping constraint: #{detail}" }
      debug(@options,:ipet) { "Skipping constraint: #{detail}" }
    end
  end

private

  # build the control-flow refinement (which provides additional
  # flow information used to prune the callgraph/CFG)
  def build_refinement(gcfg, ffs)
    @refinement = {}

    entry = gcfg.get_entry

    entry.each { |level,functions|
      cfr = ControlFlowRefinement.new(functions[0], level)
      ffs.each { |ff|
        next if ff.level != level
        cfr.add_flowfact(ff)
      }
      @refinement[level] = cfr
    }
  end

  # add variables for bitcode basic blocks and relation graph
  # (only if relation graph is available)
  def add_bitcode_variables(machine_function)
    return unless @pml.relation_graphs.has_named?(machine_function.name, :dst)
    rg = @pml.relation_graphs.by_name(machine_function.name, :dst)
    return unless rg.accept?(@options)
    bitcode_function = rg.get_function(:src)
    @bc_model.each_edge(bitcode_function) do |edge|
      @ilp.add_variable(edge, :bitcode)
    end
    each_relation_edge(rg) do |edge|
      @ilp.add_variable(edge, :relationgraph)
    end
    # record markers
    bitcode_function.blocks.each { |bb|
        bb.instructions.each { |i|
            if i.marker
              (@markers[i.marker]||=[]).push(i)
            end
        }
    }
  end

  # replace markers by instructions
  def replace_markers(ff)
    new_lhs = TermList.new([])
    ff.lhs.each { |term|
        if term.programpoint.kind_of?(Marker)
          factor = term.factor
          if ! @markers[term.programpoint.name]
            raise Exception.new("No instructions corresponding to marker #{term.programpoint.name.inspect}")
          end
          @markers[term.programpoint.name].each { |instruction|
              new_lhs.push(Term.new(instruction.block, factor))
            }
        else
          new_lhs.push(term)
        end
      }
    FlowFact.new(ff.scope, new_lhs, ff.op, ff.rhs, ff.attributes)
  end

  # add constraints for bitcode basic blocks and relation graph
  # (only if relation graph is available)
  def add_bitcode_constraints(machine_function)
    return unless @pml.relation_graphs.has_named?(machine_function.name, :dst)
    rg = @pml.relation_graphs.by_name(machine_function.name, :dst)
    return unless rg.accept?(@options)
    bitcode_function = rg.get_function(:src)
    bitcode_function.blocks.each { |block|
      @bc_model.add_block_constraint(block)
    }
    # Our LCTES 2013 paper describes 5 sets of constraints referenced below
    # map from src/dst edge to set of corresponding relation edges (constraint set (3) and (4))
    rg_edges_of_edge   = { :src => {}, :dst => {} }
    # map from progress node to set of outgoing src/dst edges (constraint set (5))
    rg_progress_edges = { }
    each_relation_edge(rg) do |edge|
      rg_level = relation_graph_level(edge.level.to_s)
      source_block = edge.source.get_block(rg_level)
      target_block = (edge.target.type == :exit) ? :exit : (edge.target.get_block(rg_level))

      assert("Bad RG: #{edge}") { source_block && target_block }
      # (3),(4)
      (rg_edges_of_edge[rg_level][IPETEdge.new(source_block,target_block,edge.level)] ||=[]).push(edge)
      # (5)
      if edge.source.type == :entry || edge.source.type == :progress
        rg_progress_edges[edge.source] ||= { :src => [], :dst => [] }
        rg_progress_edges[edge.source][rg_level].push(edge)
      end
    end
    # (3),(4)
    rg_edges_of_edge.each do |_level,edgemap|
      edgemap.each do |edge,rg_edges|
        lhs = rg_edges.map { |rge| [rge,1] } + [[edge,-1]]
        @ilp.add_constraint(lhs, "equal", 0, "rg_edge_#{edge.qname}", :structural)
      end
    end
    # (5)
    rg_progress_edges.each do |progress_node, edges|
      lhs = edges[:src].map { |e| [e,1] } + edges[:dst].map { |e| [e,-1] }
      @ilp.add_constraint(lhs, "equal", 0, "rg_progress_#{progress_node.qname}", :structural)
    end
  end

  # return all relation-graph edges
  def each_relation_edge(rg)
    rg.nodes.each { |node|
      [:src,:dst].each { |rg_level|
        next unless node.get_block(rg_level)
        node.successors(rg_level).each { |node2|
          if node2.type == :exit || node2.get_block(rg_level)
            yield IPETEdge.new(node,node2,pml_level(rg_level))
          end
        }
      }
    }
  end
end # IPETModel

end # module PML
