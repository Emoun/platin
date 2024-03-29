# typed: false
#
# platin tool set
#
# Fourier-Motzkin Elimination and Flow-Fact Transformation
#
require 'core/utils'
require 'core/pml'
require 'analysis/ilp'
require 'analysis/ipet'
require 'set'
module PML

# constraint reference for FM elimination
#
class ConstraintRef
  # id, referenced constraint, variables to eliminate
  attr_reader :cid, :constraint, :elim_vars

  # number of variables to eliminate; used as measure for equation selection
  attr_reader :num_elim_vars, :num_unaffected_vars

  # Status is one out of :active, :garbage
  attr_accessor :status
  def initialize(cid, constraint, all_elim_vars)
    @cid, @constraint = cid, constraint
    @num_elim_vars = 0
    @elim_vars = Set.new
    @constraint.lhs.keys.each do |v|
      @elim_vars.add(v) if all_elim_vars.include?(v)
    end
    @num_elim_vars = @elim_vars.size
    @num_unaffected_vars = @constraint.lhs.keys.size - @num_elim_vars
    @elim_vars.freeze
    @status = :active
  end

  # number of referenced variables
  def num_vars
    constraint.lhs.size
  end

  # compare by [number of elimination variables references, id]
  def <=>(other)
    c = num_elim_vars <=> other.num_elim_vars
    return c unless c == 0
    @cid <=> other.cid
  end

  def to_s
    assert("num_elim_vars inconsistent") { @num_elim_vars == @elim_vars.size }
    "CR#<cid=#{cid},num_vars=#{num_vars},elim_vars=#{@elim_vars.to_a},constr=#{@constraint},status=#{status}>"
  end

  def ==(other)
    @cid == other.cid
  end

  def eql?(other)
    @cid == other.cid
  end

  def hash
    cid
  end
end

# set of constraint refs ordered by elim_vars size first and by unaffected_vars
# size second. This decreases the probability that information like
# infeasibility annotations (i.e. constraints of the form v_x <= 0) are
# considered for elimination, which would lead to loss of information.
# efficient drop-in replacement for SortedSet
#
class RefSet
  def initialize
    @store = {}
  end

  def add(cref)
    sz = cref.num_elim_vars
    list = (@store[sz] ||= [])
    list.push(cref)
    list.sort! { |a, b| a.num_unaffected_vars <=> b.num_unaffected_vars }
    @minsz = sz if !@minsz || sz < @minsz
  end

  def empty?
    @minsz.nil?
  end

  def pop
    return nil if empty?
    list = @store[@minsz]
    v = list.pop
    assert("RefSet#pop: wrong bucket") { @minsz == v.num_elim_vars }
    if list.empty?
      @store.delete(@minsz)
      @minsz = @store.keys.min
    end
    v
  end

  def dump(io = $stdout)
    io.puts "RefSet"
    @store.each do |sz,vs|
      io.puts " #{sz} variables to eliminate:"
      vs.each do |v|
        io.puts " - #{v}"
      end
    end
  end
end

class VariableElimination
  attr_reader :options, :elim_steps

  def initialize(ilp, options)
    @ilp, @options = ilp, options
    @elim_steps = 0
  end

  # eliminate set of variables (which must have no cost assigned in the ILP)
  #
  def eliminate_set(vars)
    # set of variable ids left to eliminate
    elim_vids = Set.new
    # map of known constraints to constraint references
    known_constraints = {}
    # set of unaffected constraints
    unaffected = Set.new
    # map from variable index to equalities/inequalities it is involved in
    eq_constraints, bound_constraints = {}, {}
    # equations that hold a variable to eliminate
    elim_eqs = RefSet.new

    # initialize set of variables to eliminate
    vars.each do |v|
      if @ilp.get_cost(v) > 0
        raise Exception, "VariableElimination: variable #{v} has cost assigned and cannot be eliminated"
      end
      vid = @ilp.index(v)
      elim_vids.add(@ilp.index(v))
      eq_constraints[vid] = Set.new
      bound_constraints[vid] = Set.new
    end

    # setup initial constraints
    @ilp.constraints.each do |constr|
      cref = ConstraintRef.new(known_constraints.size, constr, elim_vids)
      known_constraints[constr] = cref
      if constr.lhs.all? { |v,_c| !elim_vids.include?(v) }
        unaffected.add(cref)
      else
        dict = constr.op == "equal" ? eq_constraints : bound_constraints
        elimeq_list = []
        constr.lhs.each do |vid,_c|
          dict[vid].add(cref) if dict[vid]
        end
        elim_eqs.add(cref) if constr.op == "equal" && cref.num_elim_vars > 0
      end
    end

    # eliminate all variables
    until elim_vids.empty?
      elimvar, elimeq = nil, nil
      until elim_eqs.empty?
        tmpeq = elim_eqs.pop
        if tmpeq.status == :active
          elimeq = tmpeq
          elimvar = elimeq.elim_vars.first
          break
        end
      end
      elimvar ||= elim_vids.first

      # "Eliminating #{var_by_index(elimvar)}: #{eq_constraints[elimvar].size}/#{bound_constraints[elimvar].size}"

      # Information provided by, for example, platina guards, may be deleted
      # during the flow fact transformation, when the constraint is considered
      # for elimination. The variable elimination is to make it unlikely, that
      # this actually occurs. If this  assertion is triggered, this could mean
      # one of the following:
      # a) The assertion is too broad.
      # b) The variable elimination is broken.
      # c) A wrong constraint was introduced somewhere.
      assert("Eliminating constraint #{elimeq.constraint}, which is of form v = 0! This may lead to loss of information provided by annotations!") {
        !(elimeq.constraint.rhs == 0 && elimeq.constraint.op == 'equal' && elimeq.constraint.lhs.size == 1) } unless elimeq.nil?

      if elimeq # Substitution
        # mark equation as garbage and remove it from all eq_constraints
        elimeq.status = :garbage
        elimeq.elim_vars.each do |v|
          tmp = eq_constraints[v].delete(elimeq)
          raise Exception, "Internal Error: inconstinstent eq_constraints dictionary" unless tmp
        end

        # substitute in all constraints referenced by elimvar
        [eq_constraints,bound_constraints].each do |dict|
          dict[elimvar].each do |subst_constr|
            # mark old constraint as garbage and remove it from dict
            subst_constr.status = :garbage
            subst_constr.elim_vars.each do |v|
              tmp = dict[v].delete(subst_constr)
              raise Exception, "Internal Error: inconsistent constraint dictionary" unless tmp
            end

            # substitute
            @elim_steps += 1
            neweq = constraint_substitution(elimvar, elimeq.constraint, subst_constr.constraint)

            # create new constraint reference, if necessary
            if neweq && !known_constraints[neweq]
              cref = known_constraints[neweq] = ConstraintRef.new(known_constraints.size, neweq, elim_vids)
              cref.elim_vars.each do |v|
                dict[v].add(cref)
              end
              elim_eqs.add(cref) if neweq.op == "equal" && cref.num_elim_vars > 0
            end
          end
        end
      else # FM elimination
        raise Exception, "Internal error: equations left" unless eq_constraints[elimvar].empty?
        l, u = [], []
        bound_constraints[elimvar].each do |cref|
          coeff = cref.constraint.get_coeff(elimvar)
          if coeff < 0
            l.push(cref)
          else
            u.push(cref)
          end
          cref.status = :garbage
          # remove from all bound_constraints
          cref.elim_vars.each do |v|
            tmp = bound_constraints[v].delete(cref)
            raise Exception, "Internal Error: inconstinstent bound_constraints dictionary" unless tmp
          end
        end
        l.each do |l_constr|
          u.each do |u_constr|
            @elim_steps += 1
            newconstr = transitive_constraint(elimvar, l_constr.constraint, u_constr.constraint)
            if newconstr && !known_constraints[newconstr]
              cref = known_constraints[newconstr] = ConstraintRef.new(known_constraints.size, newconstr, elim_vids)
              cref.elim_vars.each do |v|
                bound_constraints[v].add(cref)
              end
            end
          end
        end
      end
      elim_vids.delete(elimvar)
    end
    new_constraints = []
    known_constraints.values.reject do |cref|
      cref.status == :garbage
    end.map do |cref|
      cref.constraint
    end
  end

  # Given constraints
  #  (A)   e_coeff e_var + e_rterms = e_rhs               | e_constr.lhs = e_coeff e_var + e_rtterms
  #  (B)   c_coeff * e_var + c_rterms <=> c_rhs (constr)  | c_constr.lhs = c_coeff e_var + c_rterms
  # NB: As we must not multiply (B) by a negative number (in case of an inequality), we implicitly negate
  # (A) if e_coeff is negative by multiplying e_coeff, e_rterms and e_rhs by e_coeff.signum
  # multiply constraints by c_coeff and e_coeff, respectively
  #  (A')  c_coeff e_coeff e_var + c_coeff e_rterms = c_ceoff e_rhs
  #  (B')  e_coeff c_coeff e_var + e_coeff c_rterms <=> e_coeff c_rhs
  # and substitute
  #  (B'') e_coeff c_term - c_coeff e_rterms <=> e_coeff c_rhs - c_ceoff e_rhs
  #
  def constraint_substitution(e_var, e_constr, c_constr)
    signed_e_coeff = e_constr.get_coeff(e_var)
    e_sign  = signed_e_coeff <=> 0
    e_coeff = signed_e_coeff * e_sign
    e_rhs   = e_constr.rhs * e_sign
    c_coeff = c_constr.get_coeff(e_var)
    terms = c_constr.lhs

    c_rterms = terms.merge(terms) { |_v,c| e_coeff * c }              # multiply by e_coeff
    e_constr.lhs.each { |v,c| c_rterms[v] -= c_coeff * (e_sign * c) } # subtract c_coeff * e_terms
    c_rhs = c_constr.rhs * e_coeff - e_rhs * c_coeff                  # substract e_rhs * e_coeff

    if c_rterms[e_var] != 0
      raise Exception, "Internal error in constraint_substitution: #{e_var},#{e_constr},#{c_constr}"
    end

    @ilp.create_indexed_constraint(c_rterms, c_constr.op, c_rhs, c_constr.name, e_constr.tags + c_constr.tags)
  end

  # Given constraints
  #  (A) l_coeff e_var + l_rterms <= l_rhs  | l_coeff < 0
  #  (B) u_coeff e_var + u_rterms <= u_rhs  | u_coeff > 0
  # multiply constraints by u_coeff and - l_coeff, respectively
  #  (A') u_coeff l_coeff e_var  + u_coeff l_rterms <= u_coeff l_rhs
  #  (B') -l_coeff u_coeff e_var + -l_coeff u_rterms <= -l_coeff u_rhs
  # and apply transitivty lemma to get
  #  (C)  u_coeff l_rterms - l_coeff u_rterms <= u_coeff l_rhs - l_coeff u_rhs
  #
  def transitive_constraint(e_var, l_constr, u_constr)
    terms = Hash.new(0)
    l_coeff = l_constr.get_coeff(e_var)
    u_coeff = u_constr.get_coeff(e_var)
    assert("Not a lower bound for #{e_var}: #{l_constr.inspect}") { l_coeff < 0 }
    assert("Not an upper bound for #{e_var}: #{u_constr.inspect}") { u_coeff > 0 }

    l_constr.lhs.each do |v,c|
      terms[v] += u_coeff * c
    end
    u_constr.lhs.each do |v,c|
      terms[v] -= l_coeff * c
    end
    rhs = u_coeff * l_constr.rhs - l_coeff * u_constr.rhs

    assert("Variable #{e_var} not eliminated as it should be") { terms[e_var] == 0 }
    t_constr = @ilp.create_indexed_constraint(terms, l_constr.op,
                                              rhs,
                                              l_constr.name + "<>" + u_constr.name,
                                              l_constr.tags + u_constr.tags)
    t_constr
  end
end

class FlowFactTransformation
  attr_reader :pml, :options

  def initialize(pml,options)
    @pml, @options = pml, options
  end

  # Copy flowfacts
  def copy(flowfacts)
    copied = pml.flowfacts.add_copies(flowfacts, options.flow_fact_output)
    statistics("IPET","Flowfacts copied (=>#{options.flow_fact_output})" => copied.length) if options.stats
  end

  # Simplify
  def simplify(machine_entry, flowfacts)
    builder_opts = { use_rg: false }
    if options.transform_eliminate_edges
      builder_opts[:mbb_variables] = true
    else
      warn("TransformTool#simplify: no simplifications enabled")
    end

    # Filter flow facts that need to be simplified
    copy, simplify = [], []
    flowfacts.each do |ff|
      if ff.symbolic_bound?
        copy.push(ff)
      elsif options.transform_eliminate_edges && ff.references_edges? && !ff.get_calltargets
        simplify.push(ff)
      elsif options.transform_eliminate_edges && ff.references_empty_block?
        simplify.push(ff)
      elsif options.transform_eliminate_edges && !ff.loop_bound? && ff.loop_scope?
        # replace loop scope by function scope
        simplify.push(ff)
      else
        copy.push(ff)
      end
    end
    copied = pml.flowfacts.add_copies(copy, options.flow_fact_output)

    # Build ILP for transformation
    entry = { 'machinecode' => machine_entry, 'bitcode' => pml.bitcode_functions.by_name(machine_entry.label) }
    ipet = build_model(entry, copied, builder_opts)
    simplify.each { |ff| ipet.add_flowfact(ff, :simplify) }

    # Elimination
    ilp = ipet.ilp
    constraints_before = ilp.constraints.length
    elim_set = []
    ilp.variables.each do |var|
      if var.kind_of?(Instruction)
        elim_set.push(var)
      elsif options.transform_eliminate_edges && var.kind_of?(IPETEdge) # && var.cfg_edge?
        # FIXME: for now, we also eliminated call edges, because we cannot represent them in aiT
        elim_set.push(var)
      elsif options.transform_eliminate_edges && var.kind_of?(Block) && var.instructions.empty?
        debug(options,:transform) { "Eliminating empty block: #{var}" }
        elim_set.push(var)
      end
    end
    ve = VariableElimination.new(ilp, options)
    new_constraints = ve.eliminate_set(elim_set)

    # Extract and add new flow facts
    new_ffs = extract_flowfacts(new_constraints, entry, 'machinecode', [:simplify])
    new_ffs.each { |ff| pml.flowfacts.add(ff) }
    if options.stats
      statistics("TRANSFORM",
                 "Constraints after 'simplify' FM-elimination (#{constraints_before} =>)" =>
                 new_constraints.length,
                 "Unsimplified flowfacts copied (=>#{options.flow_fact_output})" =>
                 copied.length,
                 "Simplified flowfacts (#{options.flow_fact_srcs} => #{options.flow_fact_output})" =>
                 new_ffs.length)
    end
  end

  def transform(gcfg, flowfacts, target_level)
    rs, unresolved = gcfg.reachable_functions(target_level)
    target_analysis_entries = gcfg.get_entry[target_level]

    # partition local flow-facts by entry (if possible), rest is transformed in global scope
    flowfacts_by_entry = {}
    flowfacts.each do |ff|
      next if ff.symbolic_bound? # skip symbolic flow facts
      transform_entry = nil
      if ff.local?
        transform_entry = ff.scope.function
        if ff.level == 'machinecode' && target_level == "bitcode"
          transform_entry = pml.bitcode_functions.by_name(transform_entry.name)
        elsif ff.level == 'bitcode' &&  target_level == "machinecode"
          transform_entry = pml.machine_functions.by_label(transform_entry.name)
        end
        next unless rs.include?(transform_entry)
      end
      transform_entry ||= target_analysis_entry
      (flowfacts_by_entry[transform_entry] ||= []).push(ff)
    end
    selected_flowfacts = flowfacts_by_entry.values.flatten(1)

    debug(options, :transform) { "Transforming #{selected_flowfacts.length} flow facts to #{target_level}" }

    info "Running transformer to level #{target_level}" if options.verbose
    stats_num_constraints_before, stats_num_constraints_after, stats_elim_steps = 0,0,0
    new_ffs = []

    flowfacts_by_entry.each do |entry,ffs|
      begin
        # Build ILP for transformation
        debug(options, :transform) { "Transforming #{ffs.length} flowfacts in scope #{entry} to #{target_level}" }
        debug(options, :transform) do |&msgs|
          ffs.each do |ff|
              msgs.call(" - Adding flow fact #{ff}")
            end
        end
        entries =
          if target_level == "machinecode"
            { 'machinecode' => entry, 'bitcode' => pml.bitcode_functions.by_name(entry.label) }
          else
            { 'bitcode' => entry, 'machinecode' => pml.machine_functions.by_label(entry.name) }
          end
        ilp = build_model(entries, ffs, use_rg: true).ilp

        # If direction up/down, eliminate all vars but dst/src
        elim_set = ilp.variables.select { |var|
          if var.kind_of?(ConstantProgramPoint)
            false # ConstantProgramPoints must live!
          elsif var == entry
            p var
            false # Do not eliminate the entry
          elsif ilp.vartype[var] != target_level.to_sym
            true
          elsif ! var.kind_of?(IPETEdge) || ! var.cfg_edge?
            true
          else
            false
          end
        }
        ve = VariableElimination.new(ilp, options)
        new_constraints = ve.eliminate_set(elim_set)
        # Extract and add new flow facts
        new_ffs += extract_flowfacts(new_constraints, entries, target_level).select do |ff|
          # FIXME: for now, we do not export interprocedural
          # flow-facts relative to a function other than the entry,
          # because this is not supported by any of the WCET analyses
          if ff.local?
            debug(options, :transform) {
              "Transformed flowfact #{ff}"
            }
            true
          else
            debug(options, :transform) { "Skipping unsupported flow fact scope of transformed flow fact #{ff}: "+
                                         "(function: #{ff.scope.function}, local: #{ff.local? or ff.on_function_level?})" }
            false
          end
        end

        stats_num_constraints_before += ilp.constraints.length
        stats_num_constraints_after += new_constraints.length
        stats_elim_steps += ve.elim_steps
      rescue Exception => ex
        warn("Failed to transform flowfacts for entry #{entry}: #{ex}")
        raise ex
      end
    end
    new_ffs.each { |ff| pml.flowfacts.add(ff) }

    # direct translation of loop bounds and symbolic bounds (FM difficult and not implemented)
    sbt = SymbolicBoundTransformation.new(pml,options)
    directly_transformed_facts = sbt.transform(selected_flowfacts, target_level)
    directly_transformed_facts.each { |ff| pml.flowfacts.add(ff) }

    if options.stats
      statistics("TRANSFORM",
                 "#local IPET problems" => flowfacts_by_entry.length,
                 "generated flowfacts" => new_ffs.length,
                 "directly translated flowfacts" => directly_transformed_facts.length,
                 "constraints before FM eliminations" => stats_num_constraints_before,
                 "constraints after FM eliminations" => stats_num_constraints_after,
                 "elimination steps" => stats_elim_steps)
    end
  end

private

  #
  # Parameters:
  # +entry+::  <tt>{ 'machine-code' => Function, 'bitcode' => Function } </tt>
  # +flowfacts+:: a +FlowFact+ list
  #
  # Options (+opts+):
  #  +:use_rg+::        whether to enable relation graphs
  #  +:mbb_variables+:: add variables representing basic blocks
  #
  def build_model(entry, flowfacts, opts = { use_rg: false })
    # ILP for transformation
    ilp = ILP.new(@options)

    # IPET builder
    builder_opts = options.dup
    builder_opts.use_relation_graph = opts[:use_rg]
    ipet = IPETBuilder.new(pml,builder_opts,ilp)

    # Build IPET (no cost) and add flow facts
    ffs = flowfacts.reject { |ff| ff.symbolic_bound? }
    ipet.build(entry, ffs) { |_edge| 0 }
    ipet
  end

  def extract_flowfacts(constraints, entry, target_level, tags = [:flowfact, :callsite, :infeasible])
    new_flowfacts = []
    attrs = { 'origin' =>  options.flow_fact_output,
              'level'  =>  target_level }
    constraints.each do |constr|
      name = constr.name
      lhs = constr.named_lhs
      rhs = constr.rhs

      # debug(options, :transform) { "Inspecting constraint for extraction: #{constr.tags.to_a} => #{constr}" }

      # Constraint is boring if it was derived from positivity and structural constraints only
      next unless constr.tags.any? { |tag| tags.include?(tag) }

      # Constraint is boring if it is a positivity constraint (a x <= 0, with a < 0)
      next if constr.lhs.all? { |_,coeff| coeff <= 0 } && constr.op == "less-equal" && constr.rhs == 0

      # Simplify: edges->block if possible (lossless; see eliminate_edges for potentially lossy transformation)
      unless lhs.any? { |var,_| !var.kind_of?(IPETEdge) }
        # (1) get all referenced outgoing blocks
        out_blocks = {}
        lhs.each { |edge,_coeff| out_blocks[edge.source] = 0 }
        # (2) for each block, find minimum coeff for all of its outgoing edges
        #     and replace min_coeff * outgoing-edges by min_coeff * block
        out_blocks.keys.each do |b|
          edges = b.successors.map { |b2| IPETEdge.new(b,b2,target_level) }
          edges = [IPETEdge.new(b,:exit,target_level)] if b.may_return?
          min_coeff = edges.map { |e| lhs[e] }.min
          if min_coeff != 0
            edges.each do |e|
              lhs[e] -= min_coeff
              lhs.delete(e) if lhs[e] == 0
            end
            lhs[b] += min_coeff
          end
        end
      end

      # replace reference to entry block by constant
      scope = entry[target_level]
      entry_block = scope.blocks.first
      rhs -= lhs[entry_block]
      lhs[entry_block] = 0

      # Create flow-fact (with dealing different IPET edges)
      terms = lhs.reject { |_v,c| c == 0 }.map do |v,c|
        pp = if v.kind_of?(IPETEdge)
               if v.cfg_edge?
                 v.cfg_edge
               elsif v.call_edge?
                 ctx = Context.from_list([CallContextEntry.new(v.source)])
                 ContextRef.new(v.target, ctx)
               else
                 assert("FlowFactTransformation: relation graph edge not eliminated") { !v.relation_graph_edge? }
                 raise Exception, "Bad IPETEdge: #{v}"
               end
             else
               v
             end
        Term.new(pp, c)
      end
      termlist = TermList.new(terms)
      debug(options, :transform) do
        "Adding transformed constraint #{name} #{constr.tags.to_a}: #{constr} -> in #{scope} :" \
        "#{termlist} #{constr.op} #{rhs}"
      end
      ff = FlowFact.new(scope, termlist, constr.op, rhs, attrs.dup)
      new_flowfacts.push(ff)
    end
    new_flowfacts
  end
end

class SymbolicBoundTransformation
  attr_reader :pml, :options
  def initialize(pml, options)
    @pml, @options = pml, options
  end

  def transform(flowfacts, target_level)
    new_ffs = []
    level_source = target_level == "bitcode" ? "machinecode" : "bitcode"

    # select all loop bounds at the level we are transforming from
    ffs = {}
    flowfacts.each do |ff|
      next unless ff.level == level_source
      next if ff.context_sensitive?
      s,b = ff.get_loop_bound
      next unless s
      (ffs[s.programpoint.function] ||= []).push(ff)
    end

    # resolve CHRs
    # translate blocks and arguments
    ffs.each do |_f,lbs|
      # resolve CHR on bitcode level, out loops first
      lbs_resolved = []
      loop_bounds = {}
      lbs.sort_by do |ff|
        if ff.scope.programpoint.kind_of?(Loop)
          ff.scope.programpoint.loops.length
        else
          1024 # loops first
        end
      end.map do |ff|
        # resolve CHR on bitcode level
        ff_r, ff_triangle = resolve_chr(ff, loop_bounds)
        unless ff_r
          debug(options, :transform) { "Failed to resolve CHR for #{ff}" }
          next
        end
        lbs_resolved.push(ff_r)
        lbs_resolved.push(ff_triangle) if ff_triangle
        loopscope, loopbound = ff_r.get_loop_bound
        loop_bounds[loopscope.programpoint] = loopbound if loopscope
      end

      # translate
      lbs_resolved.each do |ff|
        debug(options, :transform) { "Attempting to transform: #{ff}" }
        # translate blocks and variables
        ff_t = translate_blocks_and_variables(ff, target_level)
        if ff_t
          debug(options, :transform) { "Translated flow fact:    #{ff_t}" }
        else
          debug(options, :transform) { "Failed to translate blocks for #{ff}" }
          next
        end
        new_ffs.push(ff_t)
      end
    end
    new_ffs
  end

  def translate_blocks_and_variables(ff, target_level)
    # get relation graph
    function = ff.scope.function
    rg_src_level    = ff.level == 'bitcode' ? :src : :dst
    rg_target_level = ff.level == 'bitcode' ? :dst : :src
    if ff.context_sensitive?
      debug(options, :transform) { "Cannot transform context-sensitive symbolic flow fact" }
      return nil
    elsif !ff.local?
      debug(options, :transform) { "Cannot transform non-local symbolic flow fact" }
      return nil
    elsif (non_block_ref = ff.lhs.find { |t| !t.programpoint.kind_of?(Block) })
      debug(options, :transform) { "Cannot transform symbolic flow fact referencing edges: #{non_block_ref}" }
      return nil
    elsif !pml.relation_graphs.has_named?(function.name, rg_src_level)
      debug(options, :transform) { "Cannot transform symbolic flow fact without relation graph" }
      return nil
    end
    rg = @pml.relation_graphs.by_name(function.name, rg_src_level)
    return nil unless rg.accept?(@options)

    # Simple Strategy:
    # for all referenced blocks B (including the loop block and loops
    # in CHR expressions, if applicable):
    #   if all relation graph nodes in involving B are progress nodes (B,B'),
    #   map B to B' (note there is only one such progress node for each B)
    #
    blockmap = {}
    loopblock = ff.scope.programpoint.loopheader if ff.scope.programpoint.kind_of?(Loop)
    blocks = ff.lhs.map { |t| t.programpoint }
    blocks.push(loopblock) if loopblock
    blocks.concat(ff.rhs.referenced_loops.map { |lref| lref.loopheader })
    blocks.each do |b|
      ns = rg.nodes.by_basic_block(b, rg_src_level)
      return nil if ns.length != 1
      n = ns.first
      return nil if n.unmapped?
      # find (unique) progress node for B
      nb = n.get_block(rg_target_level)
      blockmap[b] = nb
    end
    scope_ref_mapped =
      if loopblock
        mapped_loopblock = blockmap[loopblock]
        unless mapped_loopblock.loopheader?
          debug(options, :transform) do
            "SymbolicBoundTransformation: not a loop header mapping: #{loopblock} -> #{mapped_loopblock}"
          end
          # Note: The frequency of the header of the loop nb is member of
          # provides an upper bound to the frequency of nb
          mapped_loopblock = mapped_loopblock.loops.first.loopheader
          unless mapped_loopblock
            debug(options, :transform) { "SymbolicBoundTransformation: loop header maps to non-loop node" }
            return nil
          end
        end
        mapped_loopblock.loop
      else
        rg.get_function(rg_target_level)
      end
    lhs_mapped = ff.lhs.map do |t|
      Term.new(ContextRef.new(blockmap[t.programpoint], Context.empty),t.factor)
    end
    rhs_mapped = ff.rhs.map_names do |ty,n|
      if ty == :variable
        if ff.level == 'machinecode'
          warn("Mapping of registers to bitcode variables is not available")
          return nil
        end
        mf = rg.get_function(rg_target_level)
        argument = mf.arguments.by_name(n)
        unless argument
          warn("No function argument #{n} for function #{mf.label}")
          return nil
        end
        if argument.registers.length != 1
          warn("Argument #{n} of #{mf.label} is not mapped to one register but #{argument.registers.inspect}")
          return nil
        end
        argument.registers.first
      elsif ty == :loop
        blockmap[n.loopheader].loop
      end
    end
    attrs = { 'origin' =>  options.flow_fact_output,
              'level'  =>  target_level }
    scope_mapped = ContextRef.new(scope_ref_mapped, Context.empty)
    FlowFact.new(scope_mapped, TermList.new(lhs_mapped), ff.op, rhs_mapped, attrs)
  end

  # resolve chain of recurrences
  def resolve_chr(ff, loop_bounds)
    ff_triangle = nil
    return [ff,ff_triangle] unless ff.symbolic_bound?

    s, b = ff.get_loop_bound
    return [ff,ff_triangle] if b.referenced_loops.empty?

    rb =
      begin
        b.resolve_loops(loop_bounds)
      rescue NoLoopBoundAvailableException => ex
        debug(options, :transform) do
          "Failed to resolve loop CHR, because outer loop bound for (#{ex.loop}) is not available"
        end
        return nil
      end
    ff_new = FlowFact.loop_bound(s,rb,ff.attributes)
    debug(options,:transform) { "CHR      loop bound: #{ff}" }
    debug(options,:transform) { "Resolved loop bound: #{ff_new}" }

    if b.kind_of?(SEAffineRec)
      referenced_loop = b.loopheader
      parent_loops = s.programpoint.loops[1..-1]
      refd_loop_bound = loop_bounds[referenced_loop.loopheader]
      sum = b.loop_bound_sum(refd_loop_bound)
      while parent_loops.first != referenced_loop
        ind_bound = loop_bounds[parent_loops.shift.loopheader]
        debug(options,:transform) do
          "A loop different from the parent loop is referenced in a CHR " \
            "- multiplying sum by indepent bound #{ind_bound}"
        end
        sum = ind_bound * sum
      end
      ff_triangle = FlowFact.inner_loop_bound(ContextRef.new(b.loopheader, s.context),
                                              ContextRef.new(s.programpoint.loopheader, Context.empty),
                                              sum,
                                              ff.attributes)
      debug(options, :transform) do
        "Triangle loop bound: #{ff_triangle} #{ff_triangle.symbolic_bound? ? '(ignored)' : ''}"
      end
      # HACK: Symbolic triangle bounds are not yet supported
      ff_triangle = nil if ff_triangle.symbolic_bound?
    end
    [ff_new, ff_triangle]
  end
end

end # module PML
