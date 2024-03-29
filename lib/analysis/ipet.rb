# typed: false
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
  attr_reader :src_hint, :callsite
  def initialize(callsite)
    info = callsite.inspect.to_s
    if callsite.respond_to?(:block)
      info << " in block " << callsite.block.qname << " at " << callsite.block.src_hint
      @src_hint = callsite.block.src_hint
    end
    super("Unresolved Indirect Call: #{info}")
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
    add_calltargets(ContextRef.new(cs.instruction, scope.context), targets.map { |t| t.function }) if scope
    # set infeasible blocks
    infeasibleblocks = flowfact.get_block_infeasible
    infeasibleblocks.each do |scope,bref|
      set_infeasible(ContextRef.new(bref.block, scope.context)) if scope
    end
  end

  # returns true if +block+ is infeasible in the given +context+
  # XXX: use context trees
  def infeasible_block?(block, context = Context.empty)
    dict = @infeasible[block]
    return false unless dict
    dict[Context.empty] || (!context.empty? && dict[context])
  end

  # returns the set of possible calltargets for +callsite+ in +context+
  # XXX: use context trees
  def calltargets(callsite, context = Context.empty)
    static_fs  = callsite.called_functions
    static_set = Set[*static_fs] if static_fs

    dict = @calltargets[callsite]
    global_set = @calltargets[callsite][Context.empty] if dict
    ctx_set    = @calltargets[callsite][context] if dict && !context.empty?
    sets = [ctx_set,global_set,static_set].compact
    raise UnresolvedIndirectCall, callsite if sets.empty?
    sets.inject { |a,b| a.intersection(b) }
  end

  def dump(io = $stderr)
    io.puts "INFEASIBLE"
    io.puts
    @infeasible.each do |ref,val|
      io.puts "#{ref.inspect} #{val.inspect}"
    end
    io.puts "CALLTARGETS"
    io.puts
    @calltargets.each do |cs,ts|
      io.puts "#{cs}: #{ts}"
    end
  end

private

  def add_calltargets(callsite_ref, targets)
    add_refinement(callsite_ref, Set[targets], @calltargets) do |oldval,newval|
      oldval.intersection(newval)
    end
  end

  # set block infeasible, and propagate infeasibility
  # XXX: ad-hoc propagation, does not consider loop contexts
  def set_infeasible(block_ref)
    block, ctx = block_ref.programpoint, block_ref.context
    worklist = [block]
    until worklist.empty?
      block = worklist.pop
      add_refinement(ContextRef.new(block, ctx), true, @infeasible) { |_oldval, _| true }
      block.successors.each do |bsucc|
        next if infeasible_block?(bsucc, ctx)
        if bsucc.predecessors.all? { |bpred| infeasible_block?(bpred, ctx) || bsucc.backedge_target?(bpred) }
          worklist.push(bsucc)
        end
      end
      block.predecessors.each do |bpred|
        next if infeasible_block?(bpred, ctx)
        worklist.push(bpred) if bpred.successors.all? { |bsucc| infeasible_block?(bsucc, ctx) }
      end
    end
  end

  def add_refinement(reference, value, dict)
    pp_dict    = (dict[reference.programpoint] ||= {})
    ctx        = reference.context
    newval = if (oldval = pp_dict[ctx])
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
  attr_reader :qname,:source,:target,:level
  attr_writer :static_context
  attr_accessor :power_state

  def initialize(edge_source, edge_target, level, power_state = nil)
    @source,@target,@level = edge_source, edge_target, level.to_sym
    @power_state = nil
    arrow = {:bitcode => "~>", :machinecode => "->", :gcfg=>"+>"}[@level]
    fname, tname = [@source, @target].map {|n|
      n.kind_of?(Symbol) ? n.to_s : n.qname
    }
    @qname = "#{fname}#{arrow}#{tname}||#{power_state}"
    # The context is a object that has a static_context attribute (e.g., an Atomic Basic Block)
    @static_context = nil
    assert ("Not a real GCFG edge #{self}") { gcfg_edge? } if @level == :gcfg
  end

  def backedge?
    return false if target == :exit
    # If we look at a GCFG edge, the backedge property is defined by
    # the underlying machine basic block structure
    if gcfg_edge?
      t = target.abb.get_region(:dst).entry_node
      s = source.abb.get_region(:dst).exit_node
      return t.backedge_target?(s)
    end
    target.backedge_target?(source)
  end

  def cfg_edge?
    return false unless source.kind_of?(Block)
    return false unless :exit == target || target.kind_of?(Block)
    true
  end
  def gcfg_edge?
    if (source == :entry || source.kind_of?(GCFGNode)) and (target == :exit || target.kind_of?(GCFGNode))
      return true
    end
  end
  # function of source
  def function
    source.function
  end

  def cfg_edge
    assert("IPETEdge#cfg_edge: not a edge between blocks") { cfg_edge? }
    :exit == target ? source.edge_to_exit : source.edge_to(target)
  end
  def gcfg_edge
    assert("IPETEdge#cfg_edge: not a edge between blocks #{self}") { gcfg_edge? }
    (:exit == target) ? source.edge_to_exit : source.edge_to(target)
  end
  def call_edge?
    source.kind_of?(Instruction) || target.kind_of?(Function)
  end

  def relation_graph_edge?
    source.kind_of?(RelationNode) || target.kind_of?(RelationNode)
  end
  def static_context(key = nil)
    return @static_context.static_context[key] if @static_context and key
    return @static_context.static_context if @static_context
    return nil
  end
  def is_entry_in_static_context(key)
    if key == "function" and not self.source.kind_of?(Symbol)
      return self.source == self.function.entry_block if function
    elsif key == "abb"
      return gcfg_edge?
    end

  end

  def to_s
    arrow = { bitcode: "~>", machinecode: "->", gcfg: "+>" }[@level]
    "#{@source}#{arrow}#{:exit == @target ? 'exit' : @target}"
  end

  def inspect
    to_s
  end

  def hash; @qname.hash; end

  def ==(other); qname == other.qname; end

  def eql?(other); self == other; end
end

class IPETModel
  attr_reader :builder, :ilp, :level
  def initialize(builder, ilp, level)
    @builder, @ilp, @level = builder, ilp, level
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
    [[lhs,1],[rhs,-1]].each do |ts,sgn|
      ts.to_a.each do |pp, c|
        case pp
        when Instruction
          block_frequency(pp.block, c * sgn).each { |k,v| terms[k] += v }
        when Block
          block_frequency(pp, c * sgn).each { |k,v| terms[k] += v }
        when Edge
          edge_frequency(pp, c * sgn).each { |k,v| terms[k] += v }
        when Function
          function_frequency(pp, c * sgn).each { |k,v| terms[k] += v }
        when Loop
          sum_loop_entry(pp,c * sgn).each { |k,v| terms[k] += v }
        when Integer
          rhs_const += pp * -sgn
        else
          terms[pp] += c * sgn
        end
      end
    end
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
    lhs = [[callsite, -1]]
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
    lhs = [[instruction,1]] + block_frequency(instruction.block,-1)
    ilp.add_constraint(lhs, "equal", 0, "instruction_#{instruction.qname}",:instruction)
  end

  # frequency of analysis entry is 1
  def add_entry_constraint(entry_function)
    ilp.add_constraint(function_frequency(entry_function),"equal",1,"structural_entry",:structural)
  end

  # frequency of function is equal to sum of all callsite frequencies
  def add_function_constraint(function, calledges)
    lhs = calledges.map { |e| [e,-1] }
    lhs.concat(function_frequency(function,1))
    ilp.add_constraint(lhs,"equal",0,"callers_#{function}",:callsite)
  end

  # add cost to basic block
  def add_block_cost(block, cost)
    block_frequency(block).each do |edge,c|
      ilp.add_cost(edge, c * cost)
    end
  end

  # Add a variable that represents the block
  def add_block(block)
    return if ilp.has_variable?(block)
    ilp.add_variable(block)
  end


  # This function adds THE cfg flow constraints for a basic block. We
  # always relate the flow to the block variable. Incoming and
  # outgoing edges are calculated with sum_{incoming,outgoing}, iff
  # not overriden by the arguments
  def add_block_constraint(block, incoming=nil, outgoing=nil)
    # Incoming Flow
    if not incoming
      incoming = sum_incoming(block)
    end
    if incoming.length > 0
      lhs = incoming + [[block, -1]]
      ilp.add_constraint(lhs,"equal",0,"block_inflow_#{block.qname}", :structural)
    end

    # Outgoing Flow
    if not outgoing
      outgoing = sum_outgoing(block)
      outgoing.push [IPETEdge.new(block,:exit,level),1] if block.may_return?
    end
    if outgoing.length > 0
      lhs = outgoing + [[block, -1]]
      ilp.add_constraint(lhs,"equal",0,"block_outflow_#{block.qname}",:structural)
    end
  end

  # frequency of incoming is frequency of outgoing edges is 0
  def add_infeasible_block_constraint(block)
    add_block_constraint(block)
    ilp.add_constraint(block_frequency(block),"equal",0,"structural_#{block.qname}_infeasible",:infeasible)
  end

  def function_frequency(function, factor = 1)
    block_frequency(function.blocks.first, factor)
  end

  def block_frequency(block, factor=1)
    return [[block, factor]]
  end

  def edge_frequency(edge, factor = 1)
    [[IPETEdge.new(edge.source, edge.target ? edge.target : :exit, level), factor]]
  end

  def sum_incoming(block, factor=1)
    block.predecessors.map do |pred|
      [IPETEdge.new(pred,block,level), factor]
    end
  end

  def sum_outgoing(block, factor=1)
    block.successors.map do |succ|
      [IPETEdge.new(block,succ,level), factor]
    end
  end

  def sum_loop_entry(loop, factor = 1)
    sum_incoming(loop.loopheader,factor).reject do |edge,_factor|
      edge.backedge?
    end
  end


  # returns all edges, plus all return blocks
  def each_edge(function)
    function.blocks.each_with_index do |bb,ix|
      next if ix != 0 && bb.predecessors.empty? # data block
      bb.successors.each do |bb2|
        yield IPETEdge.new(bb,bb2,level)
      end
      yield IPETEdge.new(bb,:exit,level) if bb.may_return?
    end
  end

end # end of class IPETModel


class GCFGIPETModel
  attr_reader :builder, :ilp, :level, :wcet_variable
  def initialize(builder, ilp, mc_model, level = :gcfg)
    @builder, @ilp, @level = builder, ilp, level
    @mc_model = mc_model
    @entry_edges = []
    @loops = Hash.new {|hsh, key| hsh[key] = {'entries' => [], 'backedges' => []} }
  end

  def assert_equal(lhs, rhs, name, tag)
    @mc_model.assert_equal(lhs, rhs, name, tag)
  end

  ################################################################
  # SSTG (static state transition graph) nodes
  ################################################################

  # Return successor nodes of the given SSTG node. Each return value
  # is [edge, :local_or_:global]. :global means dispatching to another
  # thread.
  def each_edge(sstg_node)
    [:local, :global].each {|level|
      sstg_node.successors(level).each do |n_sstg_node|
        yield [IPETEdge.new(sstg_node,n_sstg_node,:gcfg), level]
      end
    }
    if sstg_node.is_sink
      yield [IPETEdge.new(sstg_node,:exit,:gcfg), :global]
    end
  end

  def edge_costs(sstg_ipet_edge, cost_block)
    # Costs for the Edge between two SSTG Nodes
    src, dst = sstg_ipet_edge.source, sstg_ipet_edge.target
    cost = 0
    cost += src.cost if src.cost
    # Microstructure edges add no additional costs
    return cost if src.microstructure

    if src.abb
      sstg_ipet_edge.static_context = src.abb

      source_block = src.abb.get_region(:dst).exit_node
      target_block = if dst == :exit
                       :exit
                     elsif dst.abb
                       dst.abb.get_region(:dst).entry_node
                     else
                       :idle
                     end
      if not builder.options.ignore_instruction_timing
        mc_edge = IPETEdge.new(source_block, target_block, :machinecode)
        cost += cost_block.call(mc_edge)
      end
    end
    return cost
  end

  def add_entry_constraint(sstg)
    @wcet_variable = GlobalProgramPoint.new(sstg.name)
    @ilp.add_variable(@wcet_variable, :gcfg)

    # Entry variables must add up to 1
    lhs = @entry_edges.map {|e| [e, 1]}
    @ilp.add_constraint(lhs, "equal", 1, "structural_gcfg_entry", :structural)
  end

  def add_loop_contraints
    @loops.each {|loop_idx, data|
      # p loop_idx, data['entries'], data['backedges']
      # for each loop in the nodes, set a sufficiently large upper bound
      lhs = data['entries'].map {|e| [e, -10000 / data['entries'].length]}
      # / this is unexplainable, but it works with gurobi/lp_solve
      rhs = data['backedges'].map {|e| [e, 1]}
      @ilp.add_constraint(rhs+lhs, "less-equal", 0,
                                  "gcfg_loop_#{loop_idx}", :structural)
    }
  end

  def add_node(node)
    @ilp.add_variable(node, :gcfg)

    # Frequency variables are aliases for nodes
    if node.frequency_variable
      @ilp.add_variable(node.frequency_variable, :gcfg)
      @ilp.add_constraint([[node.frequency_variable, -1], [node, 1]],
                         "equal",0,"frequency_variable_#{node.frequency_variable}_#{node.qname}",
                         :structural)
    end
  end

  def add_node_constraint(node)
    # Calculate all flows that go into this node
    incoming = node.predecessors.map { |p| [IPETEdge.new(p,node,level), 1] }
    # Some nodes have an additional input edge, if they are input nodes
    if node.is_source
      e = IPETEdge.new(:entry, node, level)
      debug(builder.options, :ipet_global) {"Added entry edge #{e}"}
      @ilp.add_variable(e)
      @entry_edges.push(e)
      incoming.push([e, 1]) if node.is_source
    end

    # Add the flow constraint
    lhs = incoming + [[node, -1]]
    ilp.add_constraint(lhs,"equal",0,"sstg_structural_inflow_#{node.qname}",:structural)

    # Flow out of the Node
    outgoing = node.successors.map { |s| [IPETEdge.new(node, s, level), 1] }
    outgoing.push [IPETEdge.new(node,:exit, level),1] if node.is_sink
    lhs = outgoing + [[node, -1]]
    ilp.add_constraint(lhs,"equal",0,"sstg_structural_outflow_#{node.qname}",:structural)

    # Loop Handling: Finding Headers; Finding backedges
    node.loops.each { |loop_id|
      header = false
      backedges = []
      entries = []
      incoming.each { |ipet_edge, _|
        loop_src = ipet_edge.source.kind_of?(Symbol) ? [] : ipet_edge.source.loops
        assert("...") { ipet_edge.target == node }
        if loop_src.member?(loop_id)
          backedges.push(ipet_edge)
        else
          entries.push(ipet_edge)
          header = true
        end
      }
      if header
        @loops[loop_id]['entries'] += entries
        @loops[loop_id]['backedges'] += backedges
      end
    }
  end

  ################################################################
  # Atomic Basic Blocks
  ################################################################
  def add_abb(abb)
    debug(builder.options, :ipet) {"Add ABB: #{abb}"}
    ilp.add_variable(abb)
  end

  def each_intra_abb_edge(abb)
    region = abb.get_region(:dst)
    region.nodes.each do |mbb|
      # Followup Blocks within
      mbb.successors.each {|mbb2|
        if mbb == region.exit_node and mbb2 == region.exit_node
          next
        end
        if region.nodes.member?(mbb2)
          yield IPETEdge.new(mbb, mbb2, :machinecode)
        end
      }
      if mbb == region.exit_node
        yield IPETEdge.new(mbb, :exit, :machinecode)
      end
    end
  end

  def add_abb_contents(abb, cost_block)
    # Add Edge variables and their cost
    each_intra_abb_edge(abb) do |ipet_edge|
      # create a new variable in the overall ILP
      @ilp.add_variable(ipet_edge)
      # Edges to the ABB-Exit are not assigned a cost, since the cost is added on the ABB/State level:
      cost = 0
      # FIXME nobody really knows why we needed the option ignore_instruction_timing
      if not builder.options.ignore_instruction_timing and ipet_edge.target != :exit
        cost = cost_block.call(ipet_edge)
        @ilp.add_cost(ipet_edge, cost)
      end

      debug(builder.options, :ipet) {"Intra-ABB Edge: #{ipet_edge} = #{cost}"}
    end

    basic_block_region = abb.get_region(:dst)
    basic_block_region.nodes.each do |mbb|
      if mbb == basic_block_region.entry_node
        # ABB freq overrides incoming of ABB n
        incoming = [[abb, 1]]
      else
        incoming = nil
      end
      if mbb == basic_block_region.exit_node
        outgoing = [[IPETEdge.new(mbb, :exit, :machinecode), 1]]
      else
        outgoing = nil
      end

      @mc_model.add_block(mbb)
      @mc_model.add_block_constraint(mbb, incoming, outgoing)
    end
  end

  def flow_into_abb(abb, nodes, prefix="", factor = 1)
    incoming, irq_activations = [], []

    def find_resume_edges(current_node, stop_abb, result_set, visited)
      current_node.successors.each { |successor|
        next if visited.member?(successor)
        visited.add(current_node)

        if successor.abb == stop_abb
          result_set.add([current_node, successor])
        else
          find_resume_edges(successor, stop_abb, result_set, visited)
        end
      }
      return result_set
    end


    irq_resume_nodes = Set.new

    nodes.each do |node|
      # Per se a node is activated, as often, as one of its states is
      # activated. Either by a local predecessor, by a
      # global/dispatching predecessor, or by an concrete input edge
      incoming += node.predecessors.map {|p|
        [IPETEdge.new(p, node, :gcfg), factor]
      }
      incoming.push([IPETEdge.new(:entry, node, :gcfg), factor]) if node.is_source

      # Suspend and Return Edges (especially IRQ returns) This is a
      # tricky one!. The Problem with our ABB super structure is, that
      # interrupts generate loops at computation blocks, where the
      # resumes are additional edges into the computation block.
      ##
      # We remove this double accounting, by applying a quite complex
      # construction. So here is the general outline:
      # 1) Detect IRQ Activation Loops:
      node.successors(:global).each {|successor|
        #   1.1) The successor is a irq_entry node
        next if not successor.isr_entry?
        #   1.3) Find all possible resume edges
        resumes = find_resume_edges(successor, node.abb, Set.new, Set.new)
        next if resumes.length == 0
        irq_resume_nodes.merge(resumes)
        #   1.4) We will substract the number of irq activations
        irq_activations.push([IPETEdge.new(node, successor, :gcfg),1])
      }
    end
    irq_resumes = irq_resume_nodes.map {|pred, node|
      [IPETEdge.new(pred, node, :gcfg), 1]
    }

    var = "#{prefix}#{abb.to_s}_in_state".to_sym
    @ilp.add_variable(var)
    assert_equal(incoming, [[var,1]], "abb_#{prefix}#{abb.qname}_in_state", :gcfg)

    if irq_activations.length > 0
      assert("There should always be a resume, if we detected an activation") {
        irq_resumes.length > 0
      }
      debug(builder.options, :ipet_global) {
        "Add IRQ Resume edges: #{abb.name} => irqs: #{irq_activations}, possible resumes: #{irq_resumes} "
      }

      sos_name = "#{prefix}#{abb.to_s}"
      neg = (sos_name + "_additional_resumes").to_sym
      pos = (sos_name + "_additional_interrupts").to_sym
      ilp.add_sos1(sos_name, [pos, neg])

      # pos - neg = (resumes - irqs) = 0;
      irq_activations_var = "#{prefix}#{abb.to_s}_irq_activations".to_sym
      @ilp.add_variable(irq_activations_var)
      assert_equal(irq_activations, [[irq_activations_var,1]], "abb_#{prefix}#{abb.qname}_in_state", :gcfg)

      irq_resumes_var = "#{prefix}#{abb.to_s}_irq_resumes".to_sym
      @ilp.add_variable(irq_resumes_var)
      assert_equal(irq_resumes, [[irq_resumes_var,1]], "abb_#{prefix}#{abb.qname}_in_state", :gcfg)

      assert_equal([[pos, 1], [neg, -1]],
                   [[irq_activations_var, 1], [irq_resumes_var, -1]],
                   "resume_#{prefix}#{abb.qname}", :structural)
      # Sometimes LP Solve is an unhappy beast
      if @ilp.kind_of?(LpSolveILP)
        ilp.add_constraint([[irq_resumes_var, -1], [pos, 1]], "less-equal", 0,
                           "resume_ilp_happy_#{prefix}#{abb.qname}", :structural)
      end
      # 2. We substract all interrupt activations, BUT add all
      # interrupt activations, that have no corresponding resume, i.e.
      # extra interrupts

      incoming += [[irq_activations_var, -1 * factor], [pos, factor]]
    end

    incoming
  end

  ################################################################
  # Global Program Points and Timing
  ################################################################

  def add_total_time_variable(costs=nil)
    # The gcfg_wcet_constraint assigns the global worst case response
    # time to the @wcet_variable, this variable will hold the maximal
    # cost for this ILP.
    lhs = [[@wcet_variable, -1]]
    # either use the costs (array of WCETs from WCEC analysis) or the ilp.costs
    rhs = (costs || @ilp.costs).map {|e, f| [e, f] }

    @ilp.add_constraint(lhs+rhs, "equal", 0, "global_wcet_equality", :gcfg)
  end

  def global_program_point(pp, factor=1)
    [[pp, factor]]
  end

end # end of class GCFGIPETModel

class IPETBuilder
  attr_reader :ilp, :mc_model, :bc_model, :gcfg_model, :refinement, :call_edges, :options, :abb_to_power_states

  def initialize(pml, options, ilp = nil)
    @ilp = ilp
    @mc_model = IPETModel.new(self, @ilp, 'machinecode')
    @gcfg_model = GCFGIPETModel.new(self, @ilp, @mc_model, 'gcfg')

    if options.use_relation_graph
      @bc_model = IPETModel.new(self, @ilp, 'bitcode')
      @pml_level = { src: 'bitcode', dst: 'machinecode' }
      @relation_graph_level = { 'bitcode' => :src, 'machinecode' => :dst }
    end

    @ffcount = 0
    @pml, @options = pml, options

    @abb_to_power_states = Hash.new { |hsh, key| hsh[key] = Set.new}
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
      mf_function.callsites.each do |cs|
        next if @mc_model.infeasible?(cs.block)
        @mc_model.calltargets(cs).each do |f|
          assert("calltargets(cs) is nil") { !f.nil? }
          succs.add(f)
        end
      end
      succs
    end
  end

  # Build Fragment: Ugly as fuck, used by blocking-time
  def build_fragment(entries, exits, blocks, flow_facts, cost_function)
    @cost_function = cost_function # == edge_cost
    entries = entries.dup
    exits = exits.dup
    incoming = {}
    outgoing = {}
    entry_frequency = {}
    exit_frequency = {}


    blocks.each {|mbb|
      incoming[mbb] = []
      outgoing[mbb] = []
    }
    entry_edges = []
    exit_edges = []
    blocks.each { |mbb|
      mbb.successors.each {|mbb2|
        if ! blocks.member?(mbb2)
          next
        end
        edge = IPETEdge.new(mbb, mbb2, :machinecode)
        @ilp.add_variable(edge)
        outgoing[mbb].push(edge)
        incoming[mbb2].push(edge)
      }

      freq, freq_idx = mbb, 0
      @ilp.add_variable(freq)
      entry_frequency[mbb] = freq
      exit_frequency[mbb] = freq

      mbb.callsites.each { |cs|
        call_edges = []
        return_edges = []
        assert("Return Pad for call site must reside in same block") {
          cs.next.block == cs.block
        }
        cs.callees.each { |mf|
          mf = @pml.machine_functions.by_label(mf)
          next if incoming[mf.blocks.first].nil?

          e = IPETEdge.new(freq, mf.blocks.first, :machinecode)
          @ilp.add_variable(e)
          incoming[mf.blocks.first].push(e)
          call_edges.push(e)
          # Find all return edges of target function
          rets = mf.blocks.select {|b| b.must_return? }
          rets.each { |ret|
            next if ! blocks.member?(ret)
            e = IPETEdge.new(ret, cs, :machinecode)
            @ilp.add_variable(e)
            outgoing[ret].push(e)
            return_edges.push(e)
          }
        }
        next if call_edges.length == 0
        # Call is Executed as often as the last instruction frequency
        @ilp.add_variable(cs)
        cost = cost_function.call(mbb.instructions[freq_idx], cs)
        @ilp.add_cost(cs, cost)
        @ilp.add_constraint([[cs, 1], [freq, -1]], "equal", 0, "callsite_#{cs}", :callsite)
        rhs = [[cs, -1]]
        lhs = call_edges.map { |e| [e, 1] }
        @ilp.add_constraint(lhs + rhs, "less-equal", 0, "call_#{cs}", :callsite)

        # Call is Executed as often as the last instruction frequency
        @ilp.add_variable(cs.next)
        rhs = [[cs.next, 1]]
        lhs = return_edges.map { |e| [e, -1] }
        if exits.member?(cs)
          exit_edges += return_edges
          exits.delete(cs)
        end
        @ilp.add_constraint(lhs + rhs, "less-equal", 0, "returnsite_#{cs}", :callsite)

        # Cant return more often than activated
        @ilp.add_constraint([[cs, -1], [cs.next, 1]], "less-equal", 0, "call_ret_#{cs}", :callsite)
        freq, freq_idx = cs.next, cs.next.index
        exit_frequency[mbb] = cs.next
      }

      if mbb.instructions.last
        cost = cost_function.call(mbb.instructions[freq_idx], mbb.instructions.last)
        @ilp.add_cost(freq, cost)
      end
    }
    entry_edges += entries.map { |mi|
      e = IPETEdge.new(:entry, mi.block, :machinecode)
      @ilp.add_variable(e)
      incoming[mi.block].push(e)
      e
    }
    exit_edges += exits.map { |mi|
      e = IPETEdge.new(mi.block, :exit, :machinecode)
      @ilp.add_variable(e)
      outgoing[mi.block].push(e)
      e
    }
    @ilp.add_constraint(entry_edges.map{|e| [e, 1]}, "equal", 1, "entry_constraint", :structural)
    @ilp.add_constraint(exit_edges.map{|e| [e, 1]}, "equal", 1, "exit_constraint", :structural)

    blocks.each {|mbb|
      lhs = incoming[mbb].map{|e| [e, 1]}
      rhs = [[entry_frequency[mbb], -1]]
      @ilp.add_constraint(lhs+rhs, "equal", 0, "block_entry_#{mbb}", :structural)
      lhs = outgoing[mbb].map{|e| [e, 1]}
      rhs = [[exit_frequency[mbb], -1]]
      @ilp.add_constraint(lhs+rhs, "equal", 0, "block_exit_#{mbb}", :structural)
    }

  end

  # Build basic IPET structure.
  # yields basic blocks, so the caller can compute their cost
  # This Function is only used in the flow fact transformation
  # entry = {'machinecode'=> foo/1, 'bitcode'=> foo}
  def build(entry, flowfacts, opts = { }, &cost_block)
    assert("IPETBuilder#build called twice") { ! @entry }
    @entry = entry
    @markers = {}
    @call_edges = []
    @mf_function_callers = Hash.new {|hsh, key| hsh[key] = [] }

    # build refinement to prune infeasible blocks and calls
    build_refinement(@entry, flowfacts)

    mf_functions = get_functions_reachable_from_function(@entry['machinecode'])
    mf_functions.each do |mf_function|
      add_function_with_blocks(mf_function, cost_block)
    end

    mf_functions.each do |f|
      add_bitcode_constraints(f) if @bc_model
      add_calls_in_function(f)
    end

    @mc_model.add_entry_constraint(@entry['machinecode'])

    add_global_call_constraints

    flowfacts.each do |ff|
      debug(@options,:ipet) { "adding flowfact #{ff}" }
      add_flowfact(ff)
    end
  end

  def add_function_with_blocks(mf_function, cost_block)
    # machinecode variables + cost
    @mc_model.each_edge(mf_function) do |ipet_edge|
      @ilp.add_variable(ipet_edge, :machinecode)
      if not @options.ignore_instruction_timing
        cost = cost_block.call(ipet_edge)
        @ilp.add_cost(ipet_edge, cost)
      end
      ipet_edge.static_context = mf_function
    end

    # bitcode variables and markers
    add_bitcode_variables(mf_function) if @bc_model

    # Add block constraints
    mf_function.blocks.each_with_index do |block, ix|
      next if block.predecessors.empty? && ix != 0 # exclude data blocks (for e.g. ARM)
      @mc_model.add_block(block)
      if @mc_model.infeasible?(block)
        @mc_model.add_infeasible_block_constraint(block)
        next
      end
      @mc_model.add_block_constraint(block)
    end

    # Return number of added basic blocks
    mf_function.blocks.length
  end

  ################################################################
  # Function Calls
  ################################################################
  def add_calls_in_function(mf_function, forbidden_targets = nil)
    mf_function.blocks.each do |block|
      add_calls_in_block(block, forbidden_targets)
    end
  end

  def add_calls_in_block(mbb, forbidden_targets = nil)
    forbidden_targets = Set.new(forbidden_targets || [])
    mbb.callsites.each do |cs|
      call_targets = @mc_model.calltargets(cs)
      call_targets -= forbidden_targets

      current_call_edges = @mc_model.add_callsite(cs, call_targets)
      current_call_edges.each do |ce|
        ce.static_context = cs.function
        @mf_function_callers[ce.target].push(ce) unless @mc_model.infeasible?(mbb)
      end
      @call_edges += current_call_edges
    end
  end

  def add_global_call_constraints
    @mf_function_callers.each do |f,ces|
      @mc_model.add_function_constraint(f, ces)
    end
  end

  # Build basic IPET Structure, when a SSTG is present
  # TODO: all references to gcfg need to be renamed to stg
  # (all states are present in this structure, nothing is grouped by next ABB)
  def build_sstg(sstg, flowfacts, opts = {}, &cost_block)
    # TODO WCEC: we ignore modelling of function calls for now! (duplication discriminating power states necessary)

    assert("IPETBuilder#build called twice") { !@entry }
    @call_edges = []
    @mf_function_callers = Hash.new { |hsh, key| hsh[key] = [] }

    # Build refinement to prune infeasible blocks and calls
    build_refinement(sstg, flowfacts)

    # Build SSTG super structure
    sstg_edges, abb_to_nodes, function_to_nodes = build_sstg_structure(sstg)

    sstg_edges.each do |ipet_edge|
      edge_cost = @gcfg_model.edge_costs(ipet_edge, cost_block)
      @ilp.add_cost(ipet_edge, edge_cost)
      debug(@options, :ipet_global) { "Added edge #{ipet_edge} with cost #{edge_cost}" }
    end

    # 3. Put the executed objects into place
    #    3.1 All ABBs from nodes that are _not_ marked as microstructure
    #    3.2 Collect functions called from the superstructure ABBs
    #    3.3 Collect functions called from GCFG nodes
    #    3.4 Add functions
    full_mfs = Set.new # To be added
    sstg_mfs = Set.new
    sstg_mbbs = Set.new
    toplevel_abb_count = 0 # statistics

    abb_to_nodes.each do |abb, nodes|
      @gcfg_model.add_abb(abb)

      # 3.1 All ABBs from nodes that are _not_ marked as microstructure
      microstructure = nodes.map { |x| x.microstructure }
      next if microstructure.all?

      assert("Microstructure state of #{abb} is inconsistent") { microstructure.none? }
      toplevel_abb_count += 1

      # Add blocks within the ABB
      # TODO WCEC: give add_abb_contents the STG nodes
      # TODO WCEC: implement duplication for each power state
      @gcfg_model.add_abb_contents(abb, cost_block)

      # ABB Freq is the list of edges that have ABB.entry_node as source
      # If this node has an ABB attached, the block frequency of the
      region = abb.get_region(:dst)
      debug(@options, :ipet_global) { "Added contents: #{abb} (#{region.nodes.length} basic blocks)" }

      sstg_mfs.add(abb.function)

      # 3.2 What functions are called from this ABB?
      region.nodes.each do |bb|
        sstg_mbbs.add(bb)
        bb.callsites.each do |cs|
          next if @mc_model.infeasible?(cs.block)

          @mc_model.calltargets(cs).each do |f|
            assert("calltargets(cs) is nil") { !f.nil? }
            full_mfs += get_functions_reachable_from_function(f)
          end
        end
      end
    end

    # 3.3 Collect functions called from GCFG nodes
    function_to_nodes.each do |mf, nodes|
      microstructure = nodes.map { |x| x.microstructure }
      next if microstructure.all?

      assert("Microstructure state of #{mf} is inconsistent") { microstructure.none? }
      full_mfs += get_functions_reachable_from_function(mf)
    end

    ## Interlude: Sanity Check: No function that is called from the
    ## superstructure can be a ABB function
    assert("Functions #{(full_mfs & sstg_mfs).to_a} part of superstructure and called function") do
      (full_mfs & sstg_mfs).empty?
    end

    # 3.4 Add functions
    full_mfs.each do |mf|
      basic_blocks = add_function_with_blocks(mf, cost_block)
      debug(@options, :ipet_global) { "Added contents: #{mf} (#{basic_blocks} blocks)" }
    end

    ##############################################
    # All structures/objects/functions are in place

    # 4. Connect the node frequencies to the underlying object
    #    4.1 to ABB frequencies
    #    4.2 to function frequencies
    abb_to_nodes.each do |abb, nodes|
      mc_entry_block = abb.get_region(:dst).entry_node
      lhs = @mc_model.block_frequency(mc_entry_block)
      # the folowing creates SOSs:
      rhs = @gcfg_model.flow_into_abb(abb, nodes)

      @gcfg_model.assert_equal(lhs, rhs, "abb_influx_#{abb.qname}", :gcfg)

      # set abb frequency to 1
      @gcfg_model.assert_equal(lhs, [[abb, 1]], "abb_#{abb.qname}", :gcfg)
      if abb.frequency_variable
        @ilp.add_variable(abb.frequency_variable, :gcfg)
        @gcfg_model.assert_equal([[abb.frequency_variable, 1]],
                                 [[abb, 1]],
                                 "abb_copy_to_var_#{abb.qname}", :gcfg)
      end
    end
    #    4.2 to function frequencies
    # (happens in our case for IRQs: function entry is ABB entry)
    function_to_nodes.each do |mf, nodes|
      mc_entry_block = mf.entry_block
      lhs = @mc_model.block_frequency(mc_entry_block)
      rhs = @gcfg_model.flow_into_abb(mf, nodes)
      @gcfg_model.assert_equal(lhs, rhs, "abb_influx_#{mf.qname}", :gcfg)
    end

    # 5. Add missing super-structure connections
    #    5.1 Calls from embedded functions
    #    5.2 Calls from super-structure ABBs
    #    5.3 Add call constraints
    #    5.4 Global timimg variable

    full_mfs.each do |mf|
      add_calls_in_function(mf, sstg_mfs)
    end
    #    5.2 Calls from super-structure ABBs
    sstg_mbbs.each do |bb|
      add_calls_in_block(bb)
    end
    #    5.3 Add call constraints
    add_global_call_constraints

    #    5.4 Global timimg variable
    @gcfg_model.add_total_time_variable

    flowfacts.each do |ff|
      debug(@options, :ipet) { "adding flowfact #{ff}" }
      add_flowfact(ff)
    end

    if !@options.wcec && @options.stats
      statistics("WCA",
                 "gcfg nodes" => sstg.nodes.length,
                 "gcfg transitions" => sstg.nodes.inject(0) { |acc, n| acc + n.successors.length },
                 "abbs toplevel" => toplevel_abb_count,
                 "abbs microstructure" => abb_to_nodes.length - toplevel_abb_count)
    end

    die("Bitcode contraints are not implemented yet") if @bc_model
  end

  # IPET Structure for WCEC
  # @param the complete STG (no state fragments)
  # @param {abb => wcet} AND {node => wcet} in ONE hash
  #        abb => wcet: WCET for non-interrupt blocks
  #        node=> wcet: WCET of ISR activation collapsed into the irq_entry node
  #                     All nodes that are within the ISR activation are microstructural
  # @param flowfacts
  def build_wcec_analysis(sstg, wcet, flowfacts)
    assert("IPETBuilder#build called twice") { ! @entry }

    # the multiplication with 3.3V needs to be done done later on
    baseline_index = sstg.device_list.length
    sstg.device_list.push(
      {"energy_stay_off" => @pml.arch.cpu_current_consumption["energy_stay_off"],
       "energy_stay_on"  => @pml.arch.cpu_current_consumption["energy_stay_on"],
       "energy_turn_off" => 0,
       "energy_turn_on"  => 0,
       "index"           => baseline_index,
       "name"=>"Baseline"
      }
    ) unless sstg.device_list.any? { |dev| dev["name"] == "Baseline" }



    # 0. setup mapping abb_to_power_states
    sstg.nodes.each do |node|
      node.devices.push(baseline_index)
      abb_to_power_states[node.abb].add(node.devices)
    end

    # 1. SSTG Super structure
    edges, abb_to_nodes, function_to_nodes = build_sstg_structure(sstg)

    # 2. Add Turn-on and Turn-off costs to SSTG edges
    edges.each do |edge|
      # Add Turn-On and Turn-off costs to the State->State edges
      next if edge.source.kind_of?(Symbol) or edge.target.kind_of?(Symbol)
      sstg.device_list.each do |device|
        before = edge.source.devices.member?(device['index'])
        after = edge.target.devices.member?(device['index'])
        if before and not after
          @ilp.add_cost(edge, device['energy_turn_off'])
        end
        if not before and after
          @ilp.add_cost(edge, device['energy_turn_on'])
        end
      end
    end


    # 2.2 Sanitiy Chack
    toplevel_abb_count = 0 # statistics
    abb_to_nodes.each { |abb, nodes|
      # 2.3 All ABBs from nodes that are _not_ marked as microstructure
      microstructure = nodes.map { |x| x.microstructure }
      next if microstructure.all?
      assert("Microstructure state of #{abb} is inconsistent") { not microstructure.any? }
      toplevel_abb_count += 1
    }

    ##############################################
    # All structures/objects/functions are in place
    # 4. Connect the node frequencies to the underlying object
    #    4.1 to ABB frequencies
    #    4.2 to function frequencies

    # Get the maximum power consumption per cycle for a given device list
    def power_consumption(sstg, power_state)
      ret = 0
      label = []
      sstg.device_list.each do |device|
        if power_state.member?(device['index'])
          ret += device['energy_stay_on']
          label.push(device['name'])
        else
          ret += device['energy_stay_off']
        end
      end
      [ret, label.sort.join(",")]
    end

    # Add the power consumptions
    abb_to_nodes.each {|abb, nodes|
      @gcfg_model.add_abb(abb)

      # The ABB frquency is distributed over many powerstates
      abb_lhs = []

      abb_to_power_states[abb].each do |power_state|
        per_cycle, label = power_consumption(sstg, power_state)
        power_state_nodes = nodes.select { |n| n.devices == power_state }

        abb_in_power_state = [abb, label]
        @ilp.add_variable(abb_in_power_state)

        rhs = @gcfg_model.flow_into_abb(abb, power_state_nodes, label)
        @gcfg_model.assert_equal([[abb_in_power_state, 1]], rhs,
                                 "abb_influx_#{label}_#{abb.qname}", :gcfg)


        abb_lhs.push([abb_in_power_state, 1])

        # If an ABB is an microstructural ABB, we do not add a cost
        if wcet.member?(abb)
          time, _ = wcet[abb]
          abb_energy = time * per_cycle

          @ilp.add_cost(abb_in_power_state, abb_energy)
          debug(@options, :ipet_global) { "Added #{abb_in_power_state} with cost #{abb_energy}" }
        else
          debug(@options, :ipet_global) { "Added #{abb_in_power_state} without cost" }
        end
      end

      # All SSTG nodes
      nodes.each do |node|
        next unless wcet.member?(node)
        assert ("Only IRQ Entry nodes can have a WCET") { node.isr_entry? }
        # FIXME Power consumption for IRQ. We execute the ISR with the highest power configuration
        time, power_states = wcet[node]
        # For an IRQ we use the maximal power consumption of all blocks in the interruption
        per_cycle, label = [0, ""]
        power_states.each do |power_state|
          a, b = power_consumption(sstg, power_state)
          if a > per_cycle
            per_cycle, label = [a, b]
          end
        end
        debug(@options, :ipet_global) { "IRQ state #{node} use per_cycle=#{per_cycle} #{label}" }

        @ilp.add_cost(node, time * per_cycle)
      end


      # set abb factor to 1 (ride-hand side constraint)
      # left hand side is all incoming flow to abb on all possible power states
      @gcfg_model.assert_equal(abb_lhs, [[abb, 1]], "abb_#{abb.qname}", :gcfg)
      if abb.frequency_variable
        @ilp.add_variable(abb.frequency_variable, :gcfg)
        @gcfg_model.assert_equal([[abb.frequency_variable, 1]],
                                 [[abb, 1]],
                                 "abb_copy_to_var_#{abb.qname}", :gcfg)
      end
    }
    # 4.2 to function frequencies
    # (happens in our case for IRQs: function entry is ABB entry)
    assert("Should not happen") {function_to_nodes.length == 0}


    # 5.4 Global timimg variable from WCET (NOT ENERGY COSTS)
    wcet_times = Hash.new
    wcet.each { |var, data| wcet_times[var] = data[0] }
    @gcfg_model.add_total_time_variable(wcet_times)


    flowfacts.each { |ff|
      debug(@options, :ipet) { "adding flowfact #{ff}" }
      add_flowfact(ff)
    }

#    statistics("WCA",
#               "gcfg nodes" => gcfg.nodes.length,
#               "gcfg transitions" => gcfg.nodes.inject(0) {|acc, n| acc + n.successors.length},
#               "abbs toplevel" => toplevel_abb_count,
#               "abbs microstructure" => abb_to_nodes.length - toplevel_abb_count
#               ) if @options.stats


    die("Bitcode contraints are not implemented yet") if @bc_model
 end

  #
  # Add flowfacts
  #
  def add_flowfact(ff, tag = :flowfact)
    model = {'machinecode'=> @mc_model, 'bitcode'=> @bc_model, 'gcfg'=> @gcfg_model}[ff.level]
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
    lhs, rhs = [], []
    operator = ff.op
    const = 0

    ff.lhs.each do |term|
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
      elsif term.programpoint.kind_of?(ConstantProgramPoint)
        # Constant Program Points can be used without declaration.
        # They are used as mere constant within the flowfact
        # expression. They are not eliminated in the flowfact transformation.
        pp = term.programpoint
        if not @ilp.has_variable?(pp)
          @ilp.add_variable(pp)
          @ilp.add_constraint([[pp, 1]], "equal", pp.value, pp.qname, :constant)
        end
        lhs += [[pp, term.factor]]
      elsif term.programpoint.kind_of?(FrequencyVariable)
        lhs += [[term.programpoint, term.factor]]
      elsif term.programpoint.kind_of?(Instruction)
        # XXX: exclusively used in refinement for now
        warn("IPETBuilder#add_flowfact: references instruction, not block or edge: #{ff}")
        return false
      else
        raise Exception, "IPETBuilder#add_flowfact: Unknown programpoint type: #{term.programpoint.class}"
      end
    end
    scope = ff.scope
    unless scope.context.empty?
      warn("IPETBUilder#add_flowfact: context sensitive scopes not supported: #{ff}")
      return false
    end
    if scope.programpoint.kind_of?(Function)
      rhs += model.function_frequency(scope.programpoint, -ff.rhs.to_i)
    elsif scope.programpoint.kind_of?(Block)
      lhs += model.block_frequency(scope.programpoint, -ff.rhs.to_i)
    elsif scope.programpoint.kind_of?(Loop)
      rhs += model.sum_loop_entry(scope.programpoint, -ff.rhs.to_i)
    elsif scope.programpoint.kind_of?(GlobalProgramPoint)
      rhs += model.global_program_point(scope.programpoint, -1)
    else
      raise Exception, "IPETBuilder#add_flowfact: Unknown scope type: #{scope.programpoint.class}"
    end

    begin
      name = "ff_#{@ffcount+=1}"
      # Additional Flow Fact Transformations: Minimal/Maximal Interarrival Time
      if ff.op.end_with?("interarrival-time")
        # The Interarrival time is the right hand side constant
        iat = ff.rhs.to_i
        maximal = {"maximal-interarrival-time"=>true,
                   "minimal-interarrival-time"=> false}[ff.op]
        # The LHS for arrival times are arrival counts, therefore, we
        # multiply them with the interrarrival time. For MAXIAT we
        # need the negative sum:
        # K * vec(LHS) - SPAN <= K  (MINIAT)
        # SPAN - K * vec(LHS) <= K  (MAXIAT)

        lhs = lhs.map {|v, f| [v, (maximal ? -iat : iat) * f]}
        rhs = rhs.map {|v, f| [v, (maximal ? -1   : 1  ) * f]}
        debug(@options, :ipet_global) {"#{maximal ? "Maximal" : "Minimal"} IAT: #{lhs+rhs} <= #{const}" }
        operator = 'less-equal'
        const += maximal ? 0 : iat
      end
      ilp.add_constraint(lhs + rhs, operator, const, name, tag)
      name
    rescue UnknownVariableException => detail
      debug(@options,:transform, :ipet, :ipet_global) {
        " ... skipped constraint: #{detail} "
      }
    end
  end

  # build the control-flow refinement (which provides additional
  # flow information used to prune the callgraph/CFG)
  def build_refinement(gcfg_or_hash, ffs)
    @refinement = {}

    entry = gcfg_or_hash.kind_of?(Hash) ? gcfg_or_hash: gcfg_or_hash.get_entry

    entry.each do |level,functions|
      cfr = ControlFlowRefinement.new(functions[0], level)
      ffs.each do |ff|
        next if ff.level != level
        cfr.add_flowfact(ff)
      end
      @refinement[level] = cfr
    end
  end


  def build_sstg_structure(sstg)
    # For each function and each ABB we collect the nodes that activate it.
    abb_to_nodes = Hash.new {|hsh, key| hsh[key] = [] }
    function_to_nodes = Hash.new {|hsh, key| hsh[key] = [] }
    edges = []

    # 1. Pass over all states to create the super structure
    #  1.1 Add node variables
    #  1.2 Add edge variables
    #  1.3 Collect activated artifacts
    sstg.nodes.each do |node|
      @gcfg_model.add_node(node)

      # 1.2 Every Super-structure edge has a variable
      @gcfg_model.each_edge(node) { |ipet_edge, level|
        @ilp.add_variable(ipet_edge, :gcfg)
        ipet_edge.static_context = node.abb if node.abb
        edges.push(ipet_edge)
      }

      # 1.3 Collect activated artifacts
      abb_to_nodes[node.abb].push(node) if node.abb
      function_to_nodes[node.function].push(node) if node.function
    end

    # 2. Flow constraints for SST structure
    sstg.nodes.each do |node|
      @gcfg_model.add_node_constraint(node)
    end
    @gcfg_model.add_entry_constraint(sstg)
    @gcfg_model.add_loop_contraints

    [edges, abb_to_nodes, function_to_nodes]
  end

private

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
    bitcode_function.blocks.each do |bb|
      bb.instructions.each do |i|
        (@markers[i.marker] ||= []).push(i) if i.marker
      end
    end
  end

  # replace markers by instructions
  def replace_markers(ff)
    new_lhs = TermList.new([])
    ff.lhs.each do |term|
        if term.programpoint.kind_of?(Marker)
          factor = term.factor
          unless @markers[term.programpoint.name]
            raise Exception, "No instructions corresponding to marker #{term.programpoint.name.inspect}"
          end
          @markers[term.programpoint.name].each do |instruction|
              new_lhs.push(Term.new(instruction.block, factor))
            end
        else
          new_lhs.push(term)
        end
      end
    FlowFact.new(ff.scope, new_lhs, ff.op, ff.rhs, ff.attributes)
  end

  # add constraints for bitcode basic blocks and relation graph
  # (only if relation graph is available)
  def add_bitcode_constraints(machine_function)
    return unless @pml.relation_graphs.has_named?(machine_function.name, :dst)
    rg = @pml.relation_graphs.by_name(machine_function.name, :dst)
    return unless rg.accept?(@options)

    bitcode_function = rg.get_function(:src)
    bitcode_function.blocks.each do |block|
      @bc_model.add_block(block)
      @bc_model.add_block_constraint(block)
    end
    # Our LCTES 2013 paper describes 5 sets of constraints referenced below
    # map from src/dst edge to set of corresponding relation edges (constraint set (3) and (4))
    rg_edges_of_edge = { src: {}, dst: {} }
    # map from progress node to set of outgoing src/dst edges (constraint set (5))
    rg_progress_edges = {}
    each_relation_edge(rg) do |edge|
      rg_level = relation_graph_level(edge.level.to_s)
      source_block = edge.source.get_block(rg_level)
      target_block = edge.target.type == :exit ? :exit : edge.target.get_block(rg_level)

      assert("Bad RG: #{edge}") { source_block && target_block }
      # (3),(4)
      (rg_edges_of_edge[rg_level][IPETEdge.new(source_block,target_block,edge.level)] ||= []).push(edge)
      # (5)
      if edge.source.type == :entry || edge.source.type == :progress
        rg_progress_edges[edge.source] ||= { src: [], dst: [] }
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
    rg.nodes.each do |node|
      [:src,:dst].each do |rg_level|
        next unless node.get_block(rg_level)
        node.successors(rg_level).each do |node2|
          yield IPETEdge.new(node,node2,pml_level(rg_level)) if node2.type == :exit || node2.get_block(rg_level)
        end
      end
    end
  end
end # IPETModel

end # module PML
