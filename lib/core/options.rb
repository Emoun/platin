# typed: false
#
# PLATIN tool set
#
# Option handling facilities
#
require 'ostruct'
require 'optparse'
require 'English'

module PML
  def needs_options(ostruct,*opts)
    opts.each do |opt|
      internal_error("Option #{opt} not set") unless ostruct.send(opt)
    end
  end

  # rubocop:disable Metrics/LineLength
  class OptionParser < ::OptionParser
    attr_reader :options, :checks

    def initialize(options, &block)
      @options, @checks, @help_topics = options, [], {}
      super(&block)
    end

    def register_help_topic(topic, &printer)
      assert("OptionParser: duplicate help topic") { !@help_topics[topic] }
      @help_topics[topic] = printer
    end

    def help_topics
      @help_topics.keys
    end

    def has_help_topic(topic)
      !@help_topics[topic].nil?
    end

    def show_help_topic(topic,io = $stderr)
      assert("OptionParser: non-existant help topic #{topic}") { @help_topics[topic] }
      @help_topics[topic].call(io)
    end

    def add_check(&block)
      @checks.push(block)
    end

    def needs(option_name, msg)
      add_check { |options| die_usage(msg) unless options.send(option_name) }
    end

    # tool needs input PML option
    def needs_pml
      reads_pml
      needs(:input, "No input PML file specified")
    end

    # tool can have input PML option
    def reads_pml
      on("-i", "--input FILE", "PML input files (can be specified multiple times)") do |f|
        (options.input ||= []).push(f)
      end
      on("--qualify-machinecode", "Qualifies machinecodenames by the filename") do |v|
        options.qualify_machinecode = v
      end
      on("--link", "Link duplicate symbols on pmlfile level") do |v|
        options.run_linker = v
      end
    end

    # tool writes PML file (if output is specified)
    def writes_pml
      on("-o", "--output FILE", "PML output file (allowed to be equivalent to an input file)") { |f| options.output = f }
    end

    # tool writes report (stdout or machinereadble)
    def writes_report
      on("--report [FILE]", "generate report") { |f| options.report = f || "-" }
      on("--append-report [KEYVALUELIST]", "append to existing report") do |kvlist|
        options.report_append = if kvlist
                                  Hash[kvlist.split(/,/).map { |s| s.split(/=/) }]
                                else
                                  {}
                                end
      end
    end

    # tool calculates flowfacts
    def generates_flowfacts
      on("--flow-fact-output NAME", "name for set of generated flow facts") { |n| options.flow_fact_output = n }
    end

    # tool generates WCET results
    def timing_output(default_name = nil); calculates_wcet(default_name); end

    def calculates_wcet(default_name = nil)
      on("--timing-output NAME", "name or prefix for set of calculated WCETs") { |n| options.timing_output = n }
      import_block_timing
      add_check { |options| options.timing_output = default_name unless options.timing_output } if default_name
    end

    # import WCET of basic blocks
    def import_block_timing
      on("--[no-]import-block-timing", "import timing and WCET frequency of basic blocks (=true)") do |b|
        options.import_block_timing = b
      end
      add_check { |options| options.import_block_timing = true if options.import_block_timing.nil? }
    end

    # tool uses call strings and allows the user to specify a custom length
    def callstring_length
      on("--callstring-length INTEGER", "default callstring length used in recorders (=0)") do |cl|
        options.callstring_length = cl.to_i
      end
      add_check do |options|
        options.callstring_length = 0 unless options.callstring_length
      end
    end

    # XXX: we need to think about this again
    # user should specify selection of flow facts
    def flow_fact_selection
      on("--flow-fact-input SOURCE,..", "flow fact sets to use (=all)") do |srcs|
        options.flow_fact_srcs = srcs.split(/\s*,\s*/)
      end
      on("--flow-fact-selection PROFILE,...", "flow fact filter (=all,minimal,local,rt-support-{all,local})") do |ty|
        options.flow_fact_selection = ty
      end
      on("--use-relation-graph", "use bitcode flowfacts via relation graph") do
        options.use_relation_graph = true
      end
      add_check do |options|
        options.flow_fact_selection = "all" unless options.flow_fact_selection
        options.flow_fact_srcs = "all" unless options.flow_fact_srcs
      end
    end

    def accept_corrected_rgs
      on("--accept-corrected-rgs", "Accect corrected relation graphs for flow fact transformation") do
        options.accept_corrected_rgs = true
      end
    end

    # ELF binaries
    def binary_file(mandatory = false)
      on("-b", "--binary FILE", "binary file to analyze") { |f| options.binary_file = f }
      needs(:binary_file, "Option --binary is mandatory") if mandatory
    end

    # Trace entry
    def trace_entry
      on("--trace-entry FUNCTION", "name/label of function to trace (=main)") { |f| options.trace_entry = f }
      add_check { |options| options.trace_entry = "main" unless options.trace_entry }
    end

    # Analysis entry
    def analysis_entry(set_default = true)
      on("-e", "--analysis-entry FUNCTION", "name/label of function to analyse (=main)") do |f|
        options.analysis_entry = f
      end
      add_check { |options| options.analysis_entry = "main" unless options.analysis_entry || !set_default }
    end

    def model_file
      on("--modelfile FILE", "Peaches program file describing the current model") do |modelfile|
        options.modelfile = modelfile
      end
    end

    def stack_cache_analysis
      on("--use-sca-graph", "use SCA graph for stack-cache analysis") do
        options.use_sca_graph = true
      end
    end

    def target_callret_costs
      on("--[no-]target-call-return-costs", "Account for call and/or return miss costs for the target call. Beware, simulation and analysis can count costs differently.") do |b|
        options.target_callret_costs = b
      end
    end

    # Run argument checks
    def check!(arg_range = nil)
      if arg_range.kind_of?(Array)
        die_usage "Wrong number of positional arguments" unless arg_range.length == ARGV.length
        arg_range.zip(ARGV).each do |option, arg|
          options.send("#{option}=".to_sym, arg)
        end
      elsif arg_range.kind_of?(Range)
        die_usage "Wrong number of positional arguments" unless arg_range.cover?(ARGV)
      end
      checks.each { |check| check.call(options) }
    end
  end

  # common option parser
  def optparse(arg_range, arg_descr, synopsis)
    options = OpenStruct.new
    parser = PML::OptionParser.new(options) do |opts|
      opts.banner = "Usage: platin #{File.basename($PROGRAM_NAME,'.rb')} OPTIONS #{arg_descr}\n\n#{synopsis}\n"
      opts.separator("Options:")
      yield opts if block_given?
      opts.separator("")
      opts.on("--stats", "print statistics") do
        options.print_stats = true
        options.stats = true
      end
      opts.on("--dref-stats <FILE>", "save statistics to file") do |v|
        File.unlink(v) if File.exists?(v)
        options.stats = true
        options.dref_stats = v
      end

      opts.on("--verbose", "verbose output") do
        options.verbose = true
        options.verbosity_level = (options.verbosity_level  || 0) + 1
      end
      opts.on("--debug [TYPE]", Array, "debug output (trace,ilp,ipet,costs,wca,ait,sweet,visualize,=all)") do |d|
        options.debug_type = d ? d.map{ |s| s.to_sym } : [:all]
      end
      opts.on_tail("-h", "--help [TOPIC]", "Show help / help on topic (#{opts.help_topics.join(", ")})") do |topic|
        if topic.nil?
          $stderr.puts opts
        elsif !opts.has_help_topic(topic)
          $stderr.puts("Unknown help topic '#{topic}' (available: #{opts.help_topics.inspect})\n\n#{opts}")
        else
          opts.show_help_topic(topic, $stderr)
        end
        exit 0
      end
    end
    parser.parse!
    parser.check!(arg_range)
    if ENV.key?("VERBOSE")
      options.verbose = true
      options.verbosity_level = (ENV["VERBOSE"] || "1").to_i
    end
    [options, ARGV]
  end

  # rubocop:enable Metrics/LineLength
end
