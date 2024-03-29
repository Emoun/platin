#!/usr/bin/env ruby
# typed: false
#
# PLATIN tool set
#
# Simple visualizer (should be expanded to do proper report generation)
#
require 'set'
require 'platin'
require 'analysis/scopegraph'
require 'English'

require 'core/pml'
require 'core/program'
require 'core/programinfo'
require 'analysis/ipet'


begin
  require 'rubygems'
  require 'graphviz'
rescue Exception => details
  warn "Failed to load library graphviz"
  info "  ==> gem1.9.1 install ruby-graphviz"
  die "Failed to load required ruby libraries"
end

class Visualizer
  attr_reader :options
  def generate(g,outfile)
    debug(options, :visualize) { "Generating #{outfile}" }
    g.output(options.graphviz_format.to_sym => outfile.to_s)
    info("#{outfile} ok") if options.verbose
  end

protected

  def digraph(label)
    g = GraphViz.new(:G, type: :digraph)
    g.node[:shape] = "rectangle"
    g[:label] = label
    g
  end
end

class CallGraphVisualizer < Visualizer
  include PML

  def initialize(pml, options); @pml, @options = pml, options; end

  def visualize_callgraph(function)
    g = digraph("Callgraph for #{function}")
    refinement = ControlFlowRefinement.new(function, 'machinecode')
    cg = ScopeGraph.new(function, refinement, @pml, @options).callgraph
    nodes, nids = {}, {}
    cg.nodes.each_with_index { |n,i| nids[n] = i }
    cg.nodes.each do |node|
      nid = nids[node]
      label = node.to_s
      nodes[node] = g.add_nodes(nid.to_s, label: label)
    end
    cg.nodes.each do |n|
      n.successors.each do |s|
        g.add_edges(nodes[n],nodes[s])
      end
    end
    g
  end
end

class PlainCallGraphVisualizer < Visualizer
  def initialize(entry, functions, mcmodel)
    @entry, @functions, @mc_model = entry, functions, mcmodel
  end

  def visualize_callgraph
    g = digraph("Callgraph for #{@entry}")
    nodes, nids = {}, {}
    @functions.each_with_index { |n,i| nids[n] = i }
    @functions.each do |node|
      nid = nids[node]
      src_hint = node.blocks.first.src_hint
      src_hint = src_hint ? '<BR/>' + src_hint : ''
      label = '<' + node.to_s + '<BR/><B>' + node.label.to_s + '</B>' + src_hint + '>'
      nodes[node] = g.add_nodes(nid.to_s, label: label)
    end
    @functions.each do |mf|
      mf.callsites.each do |cs|
        next if @mc_model.infeasible?(cs.block)
        @mc_model.calltargets(cs).each do |callee|
          g.add_edges(nodes[mf],nodes[callee]) if nodes[mf] && nodes[callee]
        end
      end
    end
    g
  end
end

class ScopeGraphVisualizer < Visualizer
  include PML

  def initialize(pml, options); @pml, @options = pml, options; end

  def visualize_scopegraph(function, level)
    g = digraph("Scopegraph #{level} for #{function}")
    refinement = ControlFlowRefinement.new(function, level)
    sg = ScopeGraph.new(function, refinement, @pml, @options)
    nodes, nids = {}, {}
    sg.nodes.each_with_index { |n,i| nids[n] = i }
    sg.nodes.each do |node|
      nid = nids[node]
      label = node.to_s
      nodes[node] = g.add_nodes(nid.to_s, label: label)
    end
    sg.nodes.each do |n|
      n.successors.each do |s|
        g.add_edges(nodes[n],nodes[s])
      end
    end
    g
  end
end

class FlowGraphVisualizer < Visualizer
  include PML

  def initialize(pml, options); @pml, @options = pml, options; end

  def extract_timing(function, timing)
    Hash[
      timing.select { |t| t.profile }.map do |t|
        profile = {}
        t.profile.select do |e|
          e.reference.function == function
        end.each do |e|
          next unless e
          edge = e.reference.programpoint
          # We only keep edge profiles here
          next unless edge.kind_of?(Edge)
          profile[edge.source] ||= []
          profile[edge.source].push(e)
        end
        [t.origin, profile]
      end.reject { |_k,v| v.empty? }
    ]
  end

  def get_vblocks(node, adjacentcy)
    [*node].map do |n|
      n.block || get_vblocks(n.send(adjacentcy), adjacentcy)
    end.flatten
  end

  def find_vnode_timing(profile, node)
    if node.block
      profile[node.block] || []
    else
      find_vedge_timing(profile, node.predecessors, node.successors)
    end
  end

  def find_vedge_timing(profile, node, succ)
    start = Set.new(get_vblocks(node, :predecessors))
    targets = Set.new(get_vblocks(succ, :successors))
    if (start == targets) && [*succ].none? { |s| s.kind_of?(CfgNode) && s.block_start? }
      [*node].map { |n| find_vnode_timing(profile, n) }.flatten
    elsif succ.kind_of?(ExitNode)
      start.map { |b| profile[b] || [] }.flatten.select do |t|
        t.reference.programpoint.exitedge?
      end
    else
      start.map { |b| profile[b] || [] }.flatten.select do |t|
        targets.include?(t.reference.programpoint.target)
      end
    end
  end

  def visualize_vcfg(function, arch, timing = nil)
    g = GraphViz.new(:G, type: :digraph)
    g.node[:shape] = "rectangle"
    vcfg = VCFG.new(function, arch)
    name = function.name.to_s
    name << "/#{function.mapsto}" if function.mapsto
    g[:label] = "CFG for " + name
    nodes = {}
    block_timing = extract_timing(function, timing)
    sf_headers = function.subfunctions.map { |sf| sf.entry }
    vcfg.nodes.each do |node|
      nid = node.nid
      label = "" # "[#{nid}] "
      if node.kind_of?(EntryNode)
        label += "START"
      elsif node.kind_of?(ExitNode)
        label += "END"
      elsif node.kind_of?(CallNode)
        label += "CALL #{node.callsite.callees.map { |c| "#{c}()" }.join(",")}"
      elsif node.kind_of?(BlockSliceNode)
        block = node.block
        instr = block.instructions[node.first_index]
        addr = instr ? instr.address : block.address
        label += format("0x%x: ",addr) if addr
        label += block.name.to_s
        label << "(#{block.mapsto})" if block.mapsto
        label << " [#{node.first_index}..#{node.last_index}]"
        if @options.show_instructions
          node.instructions.each do |ins|
            label << "\\l#{ins.opcode} #{ins.size}"
          end
          label << "\\l"
        end
      elsif node.kind_of?(LoopStateNode)
        label += "LOOP #{node.action} #{node.loop.name}"
      end
      options = { label: label }
      if node.block_start? && sf_headers.include?(node.block)
        # Mark subfunction headers
        options["fillcolor"] = "#ffffcc"
        options["style"] = "filled"
      elsif !node.block || node.kind_of?(CallNode)
        options["style"] = "rounded"
      end
      if block_timing.any? { |_o,profile| find_vnode_timing(profile, node).any? { |e| e.wcetfreq > 0 } }
        # TODO: visualize criticality < 1
        options["color"] = "#ff0000"
        options["penwidth"] = 2
      end
      nodes[nid] = g.add_nodes(nid.to_s, options)
    end
    vcfg.nodes.each do |node|
      node.successors.each do |s|
        options = {}
        # Find WCET results for edge
        # TODO It can be the case that there are multiple edges from different slices
        #      of the same block to the same target. This is actually just a single edge
        #      in PML, but we annotate all edges here, making it look as we would count
        #      them twice. No easy way to fix this tough.. If we choose to annotate only
        #      one of those edges here, it should be edge with the longest path through
        #      the block at least.
        t = block_timing.map do |origin,profile|
          [origin, find_vedge_timing(profile, node, s).select { |e| e.wcetfreq > 0 }]
        end.reject { |_o,p| p.empty? }
        unless t.empty?
          # TODO: visualize criticality < 1
          options["color"] = "#ff0000"
          options["penwidth"] = 2
          # Annotate frequency and cycles only to 'real' edges between blocks
          # These are edges from a block node to either a different block, a self loop,
          # or edges to virtual nodes (assuming the VCFG does not insert virtual nodes
          # within a block)
          if node.block && ((node.block != s.block) || s.block_start?)
            options["label"] = ""
            t.each do |origin, profile|
              # TODO: We need a way to merge results from different contexts properly.
              #      aiT returns multiple loop context results, frequencies must
              #      be merged properly for sub-contexts.
              #      Merging timing results should go into core library functions.
              #      We might need to merge differently depending on origin!!
              #      In that case, ask the ext plugins (aiT,..) to do the work.
              freq, cycles, wcet, crit = profile.inject([0,0,0,0]) do |v,e|
                # rubocop:disable Layout/MultilineArrayBraceLayout
                freq, cycles, wcet, crit = v
                [freq + e.wcetfreq,
                 [cycles, e.cycles].max,
                 wcet + e.wcet_contribution,
                 [crit, e.criticality || 1].max
                ]
                # rubocop:enable Layout/MultilineArrayBraceLayout
              end
              # Avoid overlapping of the first character and the edge by starting
              # the label with a space
              options["label"] += "\\l" if options["label"] != ""
              options["label"] += " -- #{origin} --" if block_timing.length > 1
              options["label"] += "\\l" if options["label"] != ""
              options["label"] += " f = #{freq}"
              options["label"] += "\\l max = #{cycles} cycles"
              options["label"] += "\\l sum = #{wcet} cycles"
              options["label"] += "\\l crit = #{crit}" if crit < 1
            end
            options["label"] += "\\l"
          end
        end
        g.add_edges(nodes[node.nid],nodes[s.nid],options)
      end
    end
    g
  end

  def visualize_cfg(function)
    g = GraphViz.new(:G, type: :digraph)
    g.node[:shape] = "rectangle"
    name = function.name.to_s
    name << "/#{function.mapsto}" if function.mapsto
    g[:label] = "CFG for " + name
    nodes = {}
    function.blocks.each do |block|
      bid = block.name
      label = block.name.to_s
      label << " (#{block.mapsto})" if block.mapsto
#      label << " L#{block.loops.map {|b| b.loopheader.name}.join(",")}" unless block.loops.empty?
      label << " |#{block.instructions.length}|"
      if @options.show_calls
        block.instructions.each do |ins|
          label << "\\l call " << ins.callees.map { |c| "#{c}()" }.join(",") unless ins.callees.empty?
        end
      end
      if @options.show_instructions
        block.instructions.each do |ins|
          label << "\\l#{ins.opcode} #{ins.size}"
        end
        label << "\\l"
      end
      nodes[bid] = g.add_nodes(bid.to_s, label: label,
                                         peripheries: block.loops.length + 1)
    end
    function.blocks.each do |block|
      block.successors.each do |s|
        g.add_edges(nodes[block.name],nodes[s.name])
      end
    end
    g
  end
end
class RelationGraphVisualizer < Visualizer
  include PML

  def initialize(options); @options = options; end

  def visualize(rg)
    nodes = {}
    g = GraphViz.new(:G, type: :digraph)
    g.node[:shape] = "rectangle"

    # XXX: update me
    rg = rg.data if rg.kind_of?(RelationGraph)

    name = "#{rg['src'].inspect}/#{rg['dst'].inspect}"
    rg['nodes'].each do |node|
      bid = node['name']
      label = "#{bid} #{node['type']}"
      label << " #{node['src-block']}" if node['src-block']
      label << " #{node['dst-block']}" if node['dst-block']
      nodes[bid] = g.add_nodes(bid.to_s, label: label)
    end
    rg['nodes'].each do |node|
      bid = node['name']
      (node['src-successors'] || []).each do |sid|
        g.add_edges(nodes[bid],nodes[sid])
      end
      (node['dst-successors'] || []).each do |sid|
        g.add_edges(nodes[bid],nodes[sid], style: 'dotted')
      end
    end
    g
  end
end

class ILPVisualisation < Visualizer
  include PML

  INFEASIBLE_COLOUR = 'red'
  INFEASIBLE_FILL   = '#e76f6f'
  WORST_CASE_PATH_COLOUR = '#f00000'

  attr_reader :ilp

  def initialize(ilp, levels)
    @ilp = ilp
    @levels = levels
    @graph = nil
    @mapping = {}
    @subgraph = {}
    @functiongraphs = {}
    @srchints = {}
  end

  def get_subgraph(variable)
    level = get_level(variable)
    graph = subgraph_by_level(level)

    if variable.respond_to?(:function) && variable.function
      fun = variable.function
      if @functiongraphs.key?(fun)
        graph = @functiongraphs[fun]
      else
        sub = graph.subgraph("cluster_function_#{@functiongraphs.size}")
        @functiongraphs[fun] = sub
        sub[:label] = fun.inspect
        graph = sub
      end
    end
    graph
  end

  def subgraph_by_level(level)
    entry = @subgraph[level]
    return entry if entry
    sub = @graph.subgraph("cluster_#{level}")
    @subgraph[level] = sub
    sub[:label] = level
    sub
  end

  def get_level(var)
    if var.respond_to?(:level)
      var.level
    elsif var.respond_to?(:function) && var.function.respond_to?(:level)
      var.function.level
    else
      STDERR.puts "Cannot infer level for #{var}"
      "unknown"
    end
  end

  def get_srchint(variable)
    if variable.respond_to?(:src_hint)
      src_hint = variable.src_hint
      return nil if src_hint.nil?

      file, _, line = src_hint.rpartition(':')
      assert("Failed to parse src_hint #{src_hint}, expecting file:line") { file && line }
      hint = {
        file: file,
        line: line,
      }

      hint[:function] = variable.function.to_s if variable.respond_to?(:function)

      return hint
    end
    nil
  end

  def add_srchint(id, var)
    # sourcehints
    unless @srchints.key?(id)
      hint = get_srchint(var)
      @srchints[id] = hint unless hint.nil?
    end

    hint
  end

  def get_srchints
    @srchints
  end

  def to_label(var)
    l = []
    l << "<U>#{var.qname}</U>" if var.respond_to?(:qname)
    l << "<B>#{var.mapsto}</B>" if var.respond_to?(:mapsto)
    l << var.src_hint if var.respond_to?(:src_hint)
    l << '<I>loopheader</I>' if var.respond_to?(:loopheader?) && var.loopheader?
    str = l.join("<BR/>")
    return var.to_s if str.empty?
    '<' + str + '>'
  end

  def add_node(variable)
    key = variable
    node = @mapping[key]
    return node if node

    g = get_subgraph(variable)

    nname = "n" + @mapping.size.to_s
    node = g.add_nodes(nname, id: nname, label: to_label(variable), tooltip: variable.to_s)
    @mapping[key] = node

    add_srchint(nname, variable)

    case variable
    when Function
      node[:shape] = "cds"
      entry = add_node(variable.entry_block)
      @graph.add_edges(node, entry, style: 'bold')
    when Block
      node[:shape] = "box"
    when Instruction
      node[:shape] = "ellipse"
      block = add_node(variable.block)
      @graph.add_edges(block, node, style: 'dashed')
    else
      node[:shape] = "Mdiamond"
    end

    node
  end

  def add_edge(edge, cost = nil)
    key = edge
    node = @mapping[key]
    return node if node

    assert("Not an IPETEdge") { edge.is_a?(IPETEdge) }

    src = add_node(edge.source)
    dst = add_node(edge.target)

    ename = "n" + @mapping.size.to_s
    e = @graph.add_edges(src, dst, id: ename, tooltip: edge.to_s, labeltooltip: edge.to_s)
    @mapping[key] = e

    e[:label] = cost.to_s if cost

    if edge.cfg_edge?
      e[:style] = "solid"
    elsif edge.call_edge?
      e[:style] = "bold"
    elsif edge.relation_graph_edge?
      e[:style] = "dashed"
    else
      e[:style] = "dotted"
    end

    e
  end

  def mark_unbounded(vars)
    vars.each do |v|
      @mapping[v][:color]     = INFEASIBLE_COLOUR
      @mapping[v][:style]     = "filled"
      @mapping[v][:fillcolor] = INFEASIBLE_FILL
    end
  end

  def annotate_freqs(freqmap, colorizeworstcase = false)
    freqmap.each do |v,f|
      if v.is_a?(IPETEdge)
        # Labelstrings are an own class... Therefore, we have to do strange type
        # conversions here...
        s = @mapping[v][:label]
        s = s ? s.to_ruby.gsub(/(^"|"$)/, "") : ""
        @mapping[v][:label] = "#{f} \u00d7 #{s}"
        if f.to_i > 0 && colorizeworstcase
          @mapping[v][:color] = WORST_CASE_PATH_COLOUR
          @mapping[v][:fillcolor] = WORST_CASE_PATH_COLOUR
          @mapping[v][:style] = "filled"
        end
      end
    end
  end

  def collect_variables(term)
    vars = Set.new
    term.lhs.each do |vi,_c|
      v = @ilp.var_by_index(vi)
      vars.add(v)
    end
    vars
  end

  def get_constraints
    constraints = []
    # Mapping of constraints to ILP-Vars (== IPETEdges)
    c2v         = []
    # Inverse mapping
    v2c         = {}

    ilp.constraints.each do |c|
      next if c.name =~ /^__debug_upper_bound/

      index = constraints.length
      constraints << { formula: c.to_s, name: c.name }
      vals = []
      # If this assertion breaks: merge left and right side
      assert("We only deal with constant rhs") { c.rhs.is_a?(Fixnum) }
      collect_variables(c).each do |v|
        next unless @mapping.key?(v)
        node = add_node(v)
        id = node[:id].to_ruby
        vals << { id: id, name: v.to_s }
        (v2c[id] ||= []) << index
      end
      c2v << vals
    end

    {
      constraints: constraints,
      c2v: c2v,
      v2c: v2c,
    }
  end

  def generate_graph(opts)
    @graph = GraphViz.digraph(:ILP)
    @graph[:overlap] = 'compress'

    ilp.variables.each do |v|
      if v.is_a?(IPETEdge)
        add_edge(v, ilp.get_cost(v))
      else
        add_node(v)
      end
    end

    mark_unbounded(opts[:unbounded]) if opts[:unbounded]

    annotate_freqs(opts[:freqmap], opts[:colorizeworstcase]) if opts[:freqmap]

    @graph
  end

  def output(opts)
    format = opts[:format]
    format ||= :svg

    assert("Graph has to be drawn first drawn") { !@graph.nil? }
    @graph.output(format => String)
  end

  def visualize(_title, opts = {})
    begin
      require 'graphviz'
    rescue LoadError => e
      STDERR.puts "Failed to load graphviz, disabling ILPVisualisation"
      return nil
    end

    generate_graph(opts) if @graph.nil?

    output(opts)
  end
end

# HTML Index Pages for convenient debugging
# XXX: quick hack
class HtmlIndexPages
  def initialize
    @targets, @types = {}, Set.new
  end

  def add(target,type,image)
    (@targets[target] ||= {})[type] = image
    @types.add(type)
  end

  def generate(outdir)
    @targets.each do |target,images|
      images.each do |type,image|
        File.open(File.join(outdir,link(target,type)),"w") do |fh|
          fh.puts("<html><head><title>#{target} #{type}</title></head><body>")
          type_index(target,type,fh)
          target_index(target,type,fh)
          image_display(File.basename(image), fh)
          fh.puts("</body></html>")
        end
      end
    end
  end

private

  def link(target,type)
    "#{target}.#{type}.html"
  end

  def type_index(selected_target, selected_type, io)
    io.puts("<div>")
    @targets[selected_target].each do |type,_image|
      style = type == selected_type ? "background-color: lightblue;" : ""
      io.puts("<span style=\"#{style}\"><a href=\"#{link(selected_target,type)}\">#{type}</a></span>")
    end
    io.puts("</div>")
  end

  def target_index(selected_target, selected_type, io)
    io.puts("<div>")
    @targets.each do |target,images|
      type, image = images.find { |type,_image| type == selected_type } || images.to_a.first
      style = target == selected_target ? "background-color: lightblue;" : ""
      io.puts("<span style=\"#{style}\"><a href=\"#{link(target,type)}\">#{target}</a></span>")
    end
    io.puts("</div>")
  end

  def image_display(ref, io)
    io.puts("<image src=\"#{ref}\"/>")
  end
end
class VisualizeTool
  # use either GraphViz::Constants::FORMATS or Constants::FORMATS, depending on which
  # of those is defined by ruby-graphviz
  #                                                        graphviz >= 1.2.2              graphviz < 1.2.2
  VALID_FORMATS = defined?(GraphViz::Constants::FORMATS) ? GraphViz::Constants::FORMATS : Constants::FORMATS

  def self.default_targets(pml)
    entry = pml.machine_functions.by_label("main")
    pml.machine_functions.reachable_from(entry.name).first.reject do |f|
      f.label =~ /printf/
    end.map do |f|
      f.label
    end
  end

  def self.run(pml, options)
    targets = options.functions || VisualizeTool.default_targets(pml)
    outdir = options.outdir || "."
    options.graphviz_format ||= "png"
    suffix = "." + options.graphviz_format
    html = HtmlIndexPages.new if options.html
    targets.each do |target|
      # Visualize call graph
      cgv = CallGraphVisualizer.new(pml, options)
      begin
        mf = pml.machine_functions.by_label(target)
        graph = cgv.visualize_callgraph(mf)
        file = File.join(outdir, target + ".cg" + suffix)
        cgv.generate(graph, file)
        html.add(target,"cg",file) if options.html
      rescue Exception => detail
        puts "Failed to visualize callgraph for #{target}: #{detail}"
        puts detail.backtrace
        raise detail if options.raise_on_error
      end
      # Visualize Scope Graph
      sgv = ScopeGraphVisualizer.new(pml,options)
      begin
        {'bitcode'     => ["bc", pml.bitcode_functions.by_name(target)],
         'machinecode' => ["mc", pml.machine_functions.by_label(target)]}.each_pair do |level, params|
          tag, function = *params
          graph = sgv.visualize_scopegraph(function, level)
          file = File.join(outdir, target + "." + tag + ".sg" + suffix)
          sgv.generate(graph, file)
          html.add(target,"#{tag}.sg",file) if options.html
        end
      rescue Exception => detail
        puts "Failed to visualize scopegraph for #{target}: #{detail}"
        puts detail.backtrace
        raise detail if options.raise_on_error
      end
      # Visualize CFG (bitcode)
      fgv = FlowGraphVisualizer.new(pml, options)
      begin
        bf = pml.bitcode_functions.by_name(target)
        file = File.join(outdir, target + ".bc" + suffix)
        fgv.generate(fgv.visualize_cfg(bf),file)
        html.add(target,"bc",file) if options.html
      rescue Exception => detail
        puts "Failed to visualize bitcode function #{target}: #{detail}"
        raise detail
      end
      # Visualize VCFG (machine code)
      begin
        mf = pml.machine_functions.by_label(target)
        t = pml.timing.select do |t|
          t.level == mf.level && options.show_timings &&
            (options.show_timings.include?(t.origin) || options.show_timings.include?("all"))
        end
        graph = fgv.visualize_vcfg(mf, pml.arch, t)
        file = File.join(outdir, target + ".mc" + suffix)
        fgv.generate(graph, file)
        html.add(target,"mc",file) if options.html
      rescue Exception => detail
        puts "Failed to visualize machinecode function #{target}: #{detail}"
        puts detail.backtrace
        raise detail if options.raise_on_error
      end
      # Visualize relation graph
      begin
        rgv = RelationGraphVisualizer.new(options)
        rg = pml.data['relation-graphs'].find { |f| (f['src']['function'] == target) || (f['dst']['function'] == target) }
        raise Exception, "Relation Graph not found" unless rg
        file = File.join(outdir, target + ".rg" + suffix)
        rgv.generate(rgv.visualize(rg),file)
        html.add(target,"rg",file) if options.html
      rescue Exception => detail
        puts "Failed to visualize relation graph of #{target}: #{detail}"
        raise detail if options.raise_on_error
      end
    end
    html.generate(outdir) if options.html
    statistics("VISUALIZE","Generated bc+mc+rg graphs" => targets.length) if options.stats
  end

  def self.add_options(opts)
    # rubocop:disable Metrics/LineLength
    opts.on("--[no-]html","Generate HTML index pages") { |b| opts.options.html = b }
    opts.on("-f","--function FUNCTION,...","Name of the function(s) to visualize") do |f|
      opts.options.functions = f.split(/\s*,\s*/)
    end
    opts.on("--show-calls", "Visualize call sites") { opts.options.show_calls = true }
    opts.on("--show-instr", "Show instructions in basic block nodes") { opts.options.show_instructions = true }
    opts.on("--show-timings [ORIGIN]", Array, "Show timing results in flow graphs (=all; can be a list of origins))") do |o|
      opts.options.show_timings = o ? o : ["all"]
    end
    opts.on("-O","--outdir DIR","Output directory for image files") { |d| opts.options.outdir = d }
    opts.on("--graphviz-format FORMAT", "GraphViz output format (=png,svg,...)") do |format|
      opts.options.graphviz_format = format
    end
    opts.add_check do |options|
      options.graphviz_format ||= "png"
      unless VisualizeTool::VALID_FORMATS.include?(options.graphviz_format)
        info("Valid GraphViz formats: #{VisualizeTool.VALID_FORMATS.join(", ")}")
        die("Bad GraphViz format: #{options.graphviz_format}")
      end
    end
    # rubocop:enable Metrics/LineLength
  end
end

if __FILE__ == $PROGRAM_NAME
  SYNOPSIS = <<-EOF
  Visualize bitcode and machine code CFGS, and the control-flow relation
  graph of the specified set of functions
  EOF
  include PML
  options, _args = PML::optparse([],"", SYNOPSIS) do |opts|
    opts.needs_pml
    opts.callstring_length
    VisualizeTool.add_options(opts)
  end
  VisualizeTool.run(PML::PMLDoc.from_files(options.input, options), options)
end
