# typed: ignore
#
# platin toolchain: pkg-config
#
# small tool to configure clang and pasim with the right machine configuration
#
require 'platin'
require 'ext/ait'
require 'English'
include PML

# rubocop:disable Style/GlobalVars
$available_tools = ["clang", "pasim", "ait"]
# rubocop:enable Style/GlobalVars

class ToolConfigTool
  def self.add_options(opts)
    opts.on("-t","--tool TOOL", "tool to configure (=clang)") { |t| opts.options.tool = t }
    opts.on("-m","--mode MODE", "configuration mode (tool specific)") { |m| opts.options.mode = m }
    opts.on("--sca BOUNDS:SOLVER", "stack cache analysis options (required to enable analysis in clang") do |s|
      sopts = s.split(':')
      opts.options.sca = { 'bounds' => sopts[0], 'solver' => sopts[1] }
    end
    opts.add_check do |options|
      die("Option --tool is mandatory") unless options.tool
    end
  end

  def self.run(pml, options)
    needs_options(options, :tool)

    case options.tool
    when 'clang'
      opts = pml.arch.config_for_clang(options)
      roots = pml.analysis_configurations.map { |cs| cs.program_entry }.each_with_object(Set.new) { |v,s| s.add(v) if v;  }.to_a
      opts.push("-mserialize=#{options.output.to_s}") if options.output
      opts.push("-mserialize-roots=#{roots.join(",")}") unless roots.empty?
      tc = pml.tool_configurations.by_name('clang')
      opts.concat(tc.options || []) if tc
      # TODO: add all analysis_configation tool options for analysis 'default'
      puts opts.map { |opt| escape(opt) }.join(" ")
    when 'pasim'
      # TODO: move the arch-specific tool configs into arch and call something like
      #      pml.arch.config_for(options.tool), and get the available_tools list from arch.
      die("Cannot use #{options.tool} for an architecture other than Patmos!")\
        unless pml.arch.instance_of?(Patmos::Architecture)
      opts = pml.arch.config_for_simulator
      tc = pml.tool_configurations.by_name(options.tool)
      opts.concat(tc.options || []) if tc
      # TODO: add all analysis_configation tool options for analysis 'default'
      puts opts.map { |opt| escape(opt) }.join(" ")
    when 'ait'
      AISExporter.new(pml,$stdout,options).export_header
    else
      # rubocop:disable Style/GlobalVars
      die("platin tool configuration: Unknown tool specified: #{options.tool}" \
          " (#{$available_tools.join(", ")})")
      # rubocop:enable Style/GlobalVars
    end
  end

  # The nicest way to use tool-config is like this
  #   patmos-clang $(platin tool-config -t clang -i config.pml) config.c -o config
  # However, it is not possible (as far as i know), to probably deal with spaces (or
  # mor generally, the IFS character) this way.
  # We thus escape using single quotes, but only if necessary
  def self.escape(str)
    if str =~ /[\t ]/
      "'" + str.gsub(/[\\']/) { |c| "\\#{c}" } + "'"
    else
      str
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  # rubocop:disable Style/GlobalVars
  synopsis = <<-EOF
    Configure external tools to use the correct hardware (timing) model.
    Similar to pkg-config, this tool writes the arguments to be passed to $stdout. It uses
    architecture specific implementations, and is typically used like this:

      patmos-clang $(platin tool-config -t clang -i config.pml) -o myprogram myprogram.c

    Supported Tools: #{$available_tools.join(", ")}
  EOF
  # rubocop:enable Style/GlobalVars
  options, args = PML::optparse([], "", synopsis) do |opts|
    opts.needs_pml
    ToolConfigTool.add_options(opts)
  end
  ToolConfigTool.run(PMLDoc.from_files(options.input, options), options)
end
