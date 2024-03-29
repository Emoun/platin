# typed: false
#
# PLATIN tool set
#
# Common utilities
#
require 'yaml'
require 'set'
require 'tsort'
require 'core/options'
require 'English'

module PML

  def dquote(str)
    '"' + str + '"'
  end

  def time(descr)
    t1 = Time.now
    val = yield
    t2 = Time.now
    info("Finished #{descr.ljust(35)} in #{((t2 - t1) * 1000).to_i} ms")
    val
  end

  def div_ceil(num, denom)
    raise Exception, "div_ceil: negative numerator or denominator" unless num >= 0 && denom > 0
    (num + denom - 1) / denom
  end

  def merge_ranges(r1,r2 = nil)
    assert("first argument is nil") { r1 }
    r1 = Range.new(r1,r1) unless r1.kind_of?(Range)
    return r1 unless r2
    [r1.min,r2.min].min..[r1.max,r2.max].max
  end

  #
  # Process items managed in queue
  # Each item resides in the queue exactly once
  #
  class WorkList
    def initialize(queue = nil)
      @todo = queue || []
      @enqueued  = Set.new
      @processed = Set.new
    end

    #
    # add item to the queue, if not present already
    # and mark item as queued
    #
    def enqueue(item)
      @todo.push(item) unless @enqueued.include?(item)
      @enqueued.add(item)
    end

    #
    # process queue until empty
    #
    def process
      until @todo.empty?
        item = @todo.pop
        @enqueued.delete(item)
        yield item
        @processed.add(item)
      end
    end

    #
    # set of all items processed
    #
    def processed_items
      @processed.to_a
    end
  end

  # adapter to perform topological sort and scc formation on graphs
  class TSortAdapter
    include TSort
    def initialize(nodelist, excluded_edge_targets = [])
      @nodelist = nodelist
      @excluded_edge_targets = Set[*excluded_edge_targets]
      @nodeset = Set[*nodelist]
    end

    def tsort_each_node
      @nodelist.each { |node| yield node }
    end

    def tsort_each_child(node)
      node.successors.each do |succnode|
        yield succnode if @nodeset.include?(succnode) && !@excluded_edge_targets.include?(succnode)
      end
    end
  end

  # Topological sort for connected, acyclic graph
  # Concise implementation of a beautiful algorithm (Kahn '62)
  #
  # This implementation performs a yopological sort of nodes that
  # respond to +successors+ and +predecessors+.
  # If nodes have a different interface, the
  # second parameter can be used to provide
  # an object that responds to +successors(node)+
  # and +predecessors(node)+.
  #
  def topological_sort(entry, graph_trait = nil)
    topo = []
    worklist = WorkList.new([entry])
    vpcount = Hash.new(0)
    worklist.process do |node|
      topo.push(node)
      succs = graph_trait ? graph_trait.successors(node) : node.successors
      succs.each do |succ|
        vc = (vpcount[succ] += 1)
        preds = graph_trait ? graph_trait.predecessors(succ) : succ.predecessors
        if vc == preds.length
          vpcount.delete(succ)
          worklist.enqueue(succ)
        end
      end
    end
    assert("topological_order: not all nodes marked") { vpcount.empty? }
    topo
  end

  # calculate the reachable set from entry,
  # where the provided block needs to compute
  # the successors of an item
  def reachable_set(entry, entry_seq = nil)
    reachable = Set.new
    if entry_seq
      todo = entry_seq.dup
    else
      todo = [entry]
    end
    until todo.empty?
      item = todo.pop
      next if reachable.include?(item)
      reachable.add(item)
      successors = yield item
      successors.each do |succ|
        todo.push(succ)
      end
    end
    reachable
  end

  #
  # `which` replacement
  # credits go to: http://stackoverflow.com/questions/2108727/which-in-ruby-checking-if-program-exists-in-path-from-ruby
  #
  def which(cmd)
    return nil unless cmd && !cmd.empty?
    if cmd.include?(File::SEPARATOR)
      return cmd if File.executable? cmd
    end
    ENV['PATH'].split(File::PATH_SEPARATOR).each do |path|
      binary = File.join(path, cmd.to_s)
      return binary if File.executable? binary
    end
    nil
  end

  class MissingToolException < Exception
    def initialize(msg)
      super(msg)
    end
  end

  def file_open(path,mode = "r")
    internal_error "file_open: nil" unless path
    if path == "-"
      case mode
      when "r" then yield $stdin
      when "w" then yield $stdout
      when "a" then yield $stdout
      else; die "Cannot open stdout in mode #{mode}"
      end
    else
      File.open(path,mode) do |fh|
        yield fh
      end
    end
  end

  def safe_system(*args)
    # make sure spawned process get killed at exit
    # hangs if subprocess refuses to terminate
    pids = []  # holds the spawned pids
    trap(0) do # kill spawned pid(s) when terminating
      pids.each do |pid|
        next unless pid
        begin
          Process.kill("TERM",pid)
          $stderr.puts("Terminated spawned child with PID #{pid}")
        rescue SystemCallError
          # killed in the meantime
        end
      end
    end
    begin
      pids.push(spawn(*args))
    rescue SystemCallError
      return nil
    end
    Process.wait(pids.first)
    trap(0, "DEFAULT")
    $CHILD_STATUS == 0
  end

  def assert(msg)
    unless yield
      pnt = Thread.current.backtrace[1]
      $stderr.puts "#{$PROGRAM_NAME}: Assertion failed in #{pnt}: #{msg}"
      puts "    " + Thread.current.backtrace[1..-1].join("\n    ")
      raise Exception, "Assertion Error"
    end
  end

  def internal_error(msg)
    raise Exception, format_msg("INTERNAL ERROR", msg)
  end

  def die(msg)
    pos = Thread.current.backtrace[1]
    $stderr.puts(format_msg("FATAL","At #{pos}"))
    $stderr.puts(format_msg("FATAL",msg))
    # $stderr.puts Thread.current.backtrace
    raise Exception, "I desire to die"
  end

  def die_usage(msg)
    $stderr.puts(format_msg("USAGE","#{msg}. Try --help"))
    exit 1
  end

  #
  # output debug message(s)
  #  type               ... the debug type for the message(s) (e.g., 'ipet')
  #  options.debug_type ... array of debug types to print; either :all or a specific debug type
  #  block              ... either returns one message, or yields several ones
  # Usage 1:
  #  debug(@options,'ipet') { "number of constraint: #{constraints.length}" }
  # Usage 2:
  #  debug(@options,'ipet') { |&msgs| constraints.each { |c| msgs.call("Constraint: #{c}") } }
  #
  def debug(options, *type, &block)
    return unless (options.debug_type || []).any? { |t| t == :all || type.include?(t) }
    msgs = []
    r = block.call { |m| msgs.push(m) }
    msgs.push(r) if msgs.empty?
    msgs.compact.each do |msg|
      $stderr.puts(format_msg("DEBUG",msg))
    end
  end

  class DebugIO
    def initialize(io = $stderr)
      @io = io
    end

    def puts(str)
      @io.puts(format_msg("DEBUG",str))
    end
  end

  def warn(msg)
    $stderr.puts(format_msg("WARNING",msg))
  end

  # rubocop:disable Style/GlobalVars
  def warn_once(msg,detail = nil)
    $warn_once ||= {}
    return if $warn_once[msg]
    detail = ": #{detail}" if detail
    warn(msg + detail.to_s)
    $warn_once[msg] = true
  end
  # rubocop:enable Style/GlobalVars

  def info(msg)
    $stderr.puts(format_msg("INFO",msg))
  end

  def statistics(mod,vs,align=47)
    def recursive(prefix, vs, &block)
      vs.each { |k,v|
        if v.kind_of?(Hash)
          recursive("#{prefix}/#{k}", v, &block)
        else
          yield "#{prefix}/#{k}", v
        end
      }
    end

    if @options.print_stats
      recursive("", vs) do |key, value|
        $stderr.puts(format_msg("STAT", "#{mod}: #{key.ljust(align)} #{value}"))
      end
    end
    if @options.dref_stats
      File.open(@options.dref_stats, "a+") { |fh|
        recursive("", vs) do |key, value|
          fh.write("\\drefset{/#{mod}#{key}}{#{value}}\n")
        end
      }
    end

  end

  def format_msg(tag,msg,_align = -1)
    "[platin] #{tag}: #{msg}"
  end

  # Deeply copy a given object which has to be serializeable
  #
  # @param obj [Object] object to clone
  # @returns [Object] the copied object
  def deep_copy(obj)
    Marshal.load(Marshal.dump(obj))
  end

  # Deeply compare two objects a and b, which must be serializeable
  #
  # @param a [Object] First object to compare
  # @param b [Object] Second object to compare
  # @return [Bool] whether both objects are equal
  def deep_compare(a, b)
    Marshal.dump(a) == Marshal.dump(b)
  end

end

class String
  # Count number of spaces before the first non-space,
  # and decrease the indent of the text by this amount.
  #
  # Convenient for indented HEREDOC help messages
  #
  # Inspired by ActiveSupport's strip_heredoc.
  def strip_heredoc
    first_indent = 0
    sub(/\A(\s*)/) do
      first_indent = $1.length
      $2
    end.gsub!(/^[ \t]{0,#{first_indent}}/,'')
  end
end

# 1.8 compat
if RUBY_VERSION =~ /^1\.8\.?/
  class Range
    def cover?(v)
      v >= min && v <= max
    end
  end
end

# Development helpers
class Hash
  def dump(_io = $DEFAULT_OUTPUT)
    each do |k,v|
      puts "#{k.to_s.ljust(24)} #{v}"
    end
  end
end
