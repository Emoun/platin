# typed: ignore
#
# PSK Toolchain
#
# Relation Graph utilities: validate, flow fact transformation
#

require 'platin'
require 'ext/sweet'
require 'English'
include PML

# FIXME: it might happen that calls are moved to other nodes
# This is not a problem for our model, but validation fails (ndes)
class RelationGraphValidation
  SHOW_ERROR_TRACE = 3
  def initialize(pml, options)
    @pml, @options = pml, options
  end

  def validate(pt1, pt2)
    tsrc, tdst = pt1.trace, pt2.trace
    errors = []
    # first, we extract a hierarchical trace
    ix_src, ix_dst = 0,0
    while ix_src < tsrc.length && ix_dst < tdst.length
      while is_machine_only_node(tdst[ix_dst],tsrc[ix_src])
        ix_dst += 1
        if ix_dst == tdst.length
          raise Exception, "RelationGraphValidation failed: ran out of MC entries at #{tsrc[ix1]}"
        end
      end
      p1, p2 = tsrc[ix_src], tdst[ix_dst]
      if p1 != p2
        if SHOW_ERROR_TRACE > 0
          info("Progress Trace Validation Mismatch: #{p1} vs #{p2}")
          info("Trace to SRC:")
          (-SHOW_ERROR_TRACE..SHOW_ERROR_TRACE).each do |off|
            is,id = [[0,ix_src + off].max, tsrc.length - 1].min, [[0,ix_dst + off].max, tdst.length - 1].min
            pt1.internal_preds[is].each do |n|
              $stderr.puts "        #{n}"
            end
            pt2.internal_preds[id].each do |n|
              $stderr.puts "        #{" " * 30} #{n}"
            end
            $stderr.puts "    #{off.to_s.rjust(3)} #{tsrc[is].to_s.ljust(30)} #{tdst[id]}"
          end
        end
        # If we have an off by one error, we try to continue, collecting the errors
        if p1 == tdst[ix_dst + 1]
          errors.push([p1,p2])
          ix_dst += 1
        elsif tsrc[ix_src + 1] == p2
          errors.push([p1,p2])
          ix_src += 1
        else
          raise Exception, "Progress trace validation failed: #{p1} != #{p2}"
        end
      else
        ix_src,ix_dst = ix_src + 1, ix_dst + 1
      end
    end
    raise Exception, "Progress trace validation failed: #{errors.inspect}" unless errors.empty?
    if @options.stats
      statistics("CFRG-VALIDATION",
                 "progress trace length (src)" => pt1.trace.length,
                 "progress trace length (dst)" => pt2.trace.length)
    end
  end

  def is_machine_only_node(dstnode, srcnode)
    return false if dstnode.rg == srcnode.rg
    @pml.machine_code_only_functions.include?(dstnode.get_block(:dst).function.label)
  end
end

class RelationGraphValidationTool
  def self.add_options(opts, mandatory = true)
    Architecture.simulator_options(opts)
    opts.analysis_entry
    opts.trace_entry
    opts.binary_file(mandatory)
    opts.sweet_trace_file(mandatory)
  end

  def self.check_options(options)
    die_usage("Binary file is needed for validation. Try --help") unless options.binary_file
    die_usage("SWEET trace file is needed for validation. Try --help") unless options.sweet_trace_file
  end

  def self.run(pml, options)
    tm1 = MachineTraceMonitor.new(pml, options)
    entry = pml.machine_functions.by_label(options.analysis_entry)
    pt1 = ProgressTraceRecorder.new(pml, entry, true, options)
    tm1.subscribe(pt1)
    mtrace = pml.arch.simulator_trace(options, tm1.watchpoints)
    tm1.run(mtrace)

    tm2 = SWEET::TraceMonitor.new(pml)
    pt2 = ProgressTraceRecorder.new(pml, options.analysis_entry, false, options)
    tm2.subscribe(pt2)
    tm2.run(options.sweet_trace_file)
    RelationGraphValidation.new(pml,options).validate(pt2, pt1)
  end
end

class TransformTool
  TRANSFORM_ACTIONS = %w{up down copy}

  def self.add_options(opts)
    opts.analysis_entry
    opts.flow_fact_selection
    opts.generates_flowfacts
    opts.accept_corrected_rgs
    opts.on("--validate", "Validate relation graph") { opts.options.validate = true }
    opts.on("--transform-action ACTION", "action to perform (=down,up,copy,simplify)") do |action|
      opts.options.transform_action = action
    end
    opts.on("--[no-]transform-eliminate-edges", "eliminate edges in favor of blocks") do |b|
      opts.options.transform_eliminated_edges = b
    end
    RelationGraphValidationTool.add_options(opts, false)
    opts.add_check do |options|
      RelationGraphValidationTool.check_options(options) if options.validate
      if options.transform_action == 'simplify' && options.transform_eliminate_edges.nil?
        options.transform_eliminate_edges = true
      end
    end
  end

  # pml ... PML for the prgoam
  def self.run(pml,options)
    needs_options(options,:flow_fact_selection,:flow_fact_srcs,:transform_action,:analysis_entry, :flow_fact_output)

    RelationGraphValidationTool.run(pml,options) if options.validate

    # Analysis Entry
    gcfg = pml.analysis_gcfg(options)
    unless gcfg
      raise Exception.new("Analysis Entry #{options.analysis_entry} not found")
    end

    # Select flow facts
    flowfacts = pml.flowfacts.filter(pml, options.flow_fact_selection,
                                     options.flow_fact_srcs, ["bitcode","machinecode"])
    # Start transformation
    fft = FlowFactTransformation.new(pml,options)
    if options.transform_action == "copy"
      fft.copy(flowfacts)
    elsif options.transform_action == "up" || options.transform_action == "down"
      source_level, target_level =
        if options.transform_action == "up"
          ["machinecode", "bitcode"]
        else
          ["bitcode", "machinecode"]
        end
      if flowfacts.any? { |ff| ff.level == source_level }
        fft.transform(gcfg, flowfacts, target_level)
      end
    elsif options.transform_action == "simplify"
      # Ignore symbolic loop bounds for now
      # FIXME: USE GCFG
      fft.simplify(gcfg, flowfacts)
    else
      die("Bad transformation action --transform-action=#{options.transform_action}")
    end
    # PerfTools::CpuProfiler.stop
    pml
  end
end

if __FILE__ == $PROGRAM_NAME
  SYNOPSIS = <<-EOF
  Transforms flow facts from IR level to machine code level or simplify set of flow facts
  EOF
  options, args = PML::optparse(0, "", SYNOPSIS) do |opts|
    opts.needs_pml
    opts.writes_pml
    TransformTool.add_options(opts)
  end
  TransformTool.run(PMLDoc.from_files(options.input, options), options).dump_to_file(options.output)
end
