# typed: ignore
#
# platin toolchain: pml-config
#
# small tool to create a machine configuration
#
require 'platin'
require 'ext/ait'
require 'English'
include PML

class PMLConfigTool
  def self.parse_size(size)
    if /^([0-9.]+) *([kmg]?)b?$/ =~ size.downcase
      size = $1.to_f
      case $2
      when "k" then size *= 1024
      when "m" then size *= 1024**2
      when "g" then size *= 1024**3
      end
    elsif /^0x[0-9a-fA-F]+$/ =~ size
      size = Integer(size)
    else
      die("Invalid size argument: #{size}")
    end
    size.to_i
  end

  def self.parse_policy(policy)
    case policy
    when "ideal", "dm", "no"
      { policy: policy, assoc: nil }
    when /^(lru|fifo)(\d+)?$/
      { policy: $1, assoc: ($2 ? $2.to_i : nil) }
    else
      die("Unknown policy: #{policy}")
    end
  end

  def self.add_options(opts)
    opts.on("--target TRIPLE", "Target architecture triple (required if no PML input is given)") do |a|
      opts.options.triple = a
    end

    # TODO: Some (if not all) of the options here may be specific to an
    #       architecture. There are several ways to handle this
    #      - Let pml.arch define and check the options. This requires that at
    #        least the --target option is already parsed or the PML file is
    #        loaded, so that pml.arch is available. Problem: how do we handle
    #        unknown options in the first pass?
    #      - Add all options to the option parser, but only include them in the
    #        help text and check them when an architecture is given, i.e. with
    #        'pml-config --target patmos --help'. Problem: different architectures
    #        may have different definitions (and short names) of the same option
    #        name. Is this a problem?
    #      - Leave it like it is, with a common set of options for all
    #        architectures. This ensures consistency of the options across archs,
    #        but is less nice to maintain and it is very difficult to understand
    #        for the user, which options are actually used for a given architecture.
    #      - Make the options more generic to avoid architecture-specific options
    #        altogether.

    # rubocop:disable Metrics/LineLength
    opts.on("-g", "--gsize SIZE", "Global memory size") do |s|
      opts.options.memory_size = parse_size(s)
    end
    opts.on("-G", "--gtime CYCLES", Integer, "Global memory transfer time per burst in cycles") do |t|
      opts.options.memory_transfer_time = t
    end
    opts.on("-t", "--tdelay CYCLES", Integer, "Delay to global memory per request in cycles") do |t|
      opts.options.memory_delay = t
    end
    opts.on("-r", "--rdelay CYCLES", Integer, "Read delay to global memory per request in cycles (overrides --tdelay") do |t|
      opts.options.memory_read_delay = t
    end
    opts.on("-w", "--wdelay CYCLES", Integer, "Write delay to global memory per request in cycles (overrides --tdelay)") do |t|
      opts.options.memory_write_delay = t
    end
    opts.on("--bsize SIZE", "Transfer size (burst size) of the global memory in bytes") do |b|
      opts.options.memory_transfer_size = parse_size(b)
    end
    opts.on("--psize SIZE", "Maximum request burst size (page burst size) of the global memory in bytes") do |b|
      opts.options.memory_burst_size = parse_size(b)
    end

    opts.on("-d", "--dcsize SIZE", "Data cache size in bytes") do |s|
      opts.options.data_cache_size = parse_size(s)
    end
    opts.on("-D", "--dckind KIND", "Type of data cache (ideal, no, dm, lru<N>, fifo<N>)") do |p|
      opts.options.data_cache_policy = parse_policy(p)
    end
    opts.on("-s", "--scsize SIZE", "Stack cache size in bytes") do |s|
      opts.options.stack_cache_size = parse_size(s)
    end
    opts.on("-S", "--sckind KIND", %w[no ideal block ablock lblock dcache], "Type of the stack cache (no, ideal, block, ablock, lblock, dcache)") do |t|
      opts.options.stack_cache_type = t
    end
    opts.on("-m", "--icsize SIZE", "Size of the instruction/method cache in bytes") do |s|
      opts.options.instr_cache_size = parse_size(s)
    end
    opts.on("-C", "--icache KIND", %w[mcache icache], "Type of instruction cache (mcache, icache)") do |k|
      opts.options.instr_cache_kind = k
    end
    opts.on("-M", "--ickind KIND", "Policy of instruction cache (ideal, no, dm, lru<N>, fifo<N>). 'dm' is not applicable to a method cache.") do |p|
      opts.options.instr_cache_policy = parse_policy(p)
    end
    opts.on("--ibsize SIZE", "Size of an instruction cache line or method cache block in bytes") do |s|
      opts.options.instr_cache_line_size = parse_size(s)
    end

    opts.on("--set-cache-attr CACHE,NAME,VALUE", Array, "Set an attribute with a given value to the given named cache (can be specified multiple times)") do |a|
      die("Missing attribute name in --set-cache-attr #{a}") if a.length < 2
      die("Too many values for --set-cache-attr #{a}") if a.length > 3
      (opts.options.set_cache_attrs ||= []).push(a)
    end
    opts.on("--set-area-attr AREA,NAME,VALUE", Array, "Set an attribute with a given value to the given memory area (can be specified multiple times)") do |a|
      die("Missing attribute name in --set-area-attr #{a}") if a.length < 2
      die("Too many values for --set-area-attr #{a}") if a.length > 3
      (opts.options.set_area_attrs ||= []).push(a)
    end

    opts.on("--update-heap-syms [SIZE,NUM]", Array, "Recalculate heap-end and stack-top attribute values for the new memory size assuming NUM stacks of size SIZE (defaults to 32k,16.") do |a|
      a = [] if a.nil?
      die("Too many values for --update-heap-syms #{a}") if a.length > 2
      a[0] ||= "32k"
      a[1] ||= "16"
      opts.options.update_heap_syms = { stack_size: parse_size(a[0]), num_stacks: a[1].to_i }
    end
    # rubocop:enable Metrics/LineLength

    # TODO: Add options to remove attributes
    # TODO Add options to modify tool-configurations and analysis-configurations.

    opts.add_check do |options|
      die("Option --target is mandatory if no input PML is specified") unless options.triple || options.input
    end
  end

  def self.update_memories(arch, options)
    # TODO: set name of memory to configure, enable configuration of multiple memories?

    # Get or create the main memory
    main = arch.config.memories.by_name('main')
    if main.nil?
      # Create with default values
      main = PML::MemoryConfig.new("main", 0,0, 0,0,0,0)
      arch.config.memories.add(main)
    end

    # NOTE When we change the size of the memory, we might want to change the
    #      address range of the memory areas using the memory as well.. We
    #      could let the pml.arch check function worry about that though (once
    #      it is implemented)

    # Update config
    main.size =          options.memory_size if options.memory_size
    main.transfer_size = options.memory_transfer_size if options.memory_transfer_size

    # Should we add options to configure transfer time for reads and writes differently?
    transfer_time = options.memory_transfer_time
    read_latency  = options.memory_read_delay  || options.memory_delay
    write_latency = options.memory_write_delay || options.memory_delay

    main.read_latency        = read_latency  if read_latency
    main.read_transfer_time  = transfer_time if transfer_time
    main.write_latency       = write_latency if write_latency
    main.write_transfer_time = transfer_time if transfer_time

    main.max_burst_size = options.memory_burst_size if options.memory_burst_size
  end

  def self.set_attributes(list, attrs)
    if attrs
      attrs.each do |name,key,value|
        entry = list.by_name(name)
        # Cache/area must exist by now for us to attach attributes
        next unless entry
        # Clean up value
        if value.nil?
          value = true
        elsif /^\d+$/ =~ value
          value = value.to_i
        elsif /^0x[0-9a-fA-F]+$/ =~ value
          value = Integer(value)
        end
        entry.set_attribute(key, value)
      end
    end
  end

  def self.update_attributes(arch, options)
    set_attributes(arch.config.caches,       options.set_cache_attrs)
    set_attributes(arch.config.memory_areas, options.set_area_attrs)
  end

  def self.run(pml, options)
    arch = pml.arch

    # TODO: call pml.arch to make sure all required memories, caches and areas exist

    # We can handle the main memory ourselves
    update_memories(arch, options)

    # For caches and memory-areas, we need to ask pml.arch, this is too platform specific..
    arch.update_cache_config(options)

    # We can handle the generic cache attributes ourselves, again.
    update_attributes(arch, options)

    # Let the architecture recalculate the heap symbols
    if options.update_heap_syms
      arch.update_heap_symbols(options.update_heap_syms[:stack_size], options.update_heap_syms[:num_stacks])
    end

    # TODO: call pml.arch to check and unify the machine-configuration

    # If machine-config did not exist, the PML data is out of sync now (see PMLDoc::initialize).
    pml.data['machine-configuration'] = pml.arch.config.to_pml

    pml
  end
end

if __FILE__ == $PROGRAM_NAME
  synopsis = <<-EOF
    Create or modify a PML machine configuration. If no input configuration is given, a
    default configuation is generated.
  EOF
  options, args = PML::optparse([], "", synopsis) do |opts|
    opts.reads_pml
    opts.writes_pml
    PMLConfigTool.add_options(opts)
  end
  if options.input
    pml = PMLDoc.from_files(options.input, options)
    if options.triple && (options.triple != pml.data['triple'])
      die("PML triple #{pml.data['triple']} does not match option --target #{options.triple}")
    end
  else
    data = {}
    # TODO: Get the default format from somewhere? a constant? read from pml.yml?
    # TODO For now, we use 'pml-0.1' to be compatible with patmos-llc, otherwise
    #      we get a value mismatch error from platin merge_streams when mixing
    #      generated .pml files from pml-config and patmos-llc.
    data['format'] = "pml-0.1"
    data['triple'] = options.triple
    pml = PMLDoc.new(data, options)
  end
  outpml = PMLConfigTool.run(pml, options)
  outpml.dump_to_file(options.output, true) if options.output
end
