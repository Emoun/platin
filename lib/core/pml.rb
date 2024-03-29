# typed: false
#
# PLATIN tool set
#
# PML data format classes
#
require 'core/utils'
require 'core/pmlbase'
require 'core/arch'
require 'core/configuration'
require 'core/context'
require 'core/program'
require 'core/programinfo'

require 'pathname'
require 'set'
require 'English'

module PML

# class providing convenient accessors and additional program information derived
# from PML files
class PMLDoc
  attr_reader :data, :triple, :arch, :analysis_configurations
  attr_reader :bitcode_functions,:machine_functions,:relation_graphs,:global_cfgs
  attr_reader :flowfacts,:valuefacts,:timing
  attr_reader :tool_configurations
  attr_reader :sca_graph
  attr_accessor :text_symbols,:modelfacts

  # constructor expects a YAML document or a list of YAML documents
  def initialize(stream, options = OpenStruct.new)
    stream = [stream] unless stream.kind_of?(Array)
    if stream.length == 1 && stream[0][1].length == 1 && !options.qualify_machinecode
      @data = stream[0][1][0]
    else
      @data = PMLDoc.merge_stream(stream)
    end

    # read-only sections
    if @data['triple']
      @triple = @data['triple'].split('-')
      machine_config = nil
      if @data['machine-configuration']
        machine_config = MachineConfig.from_pml(self, @data['machine-configuration'])
      end
      @arch = Architecture.from_triple(triple, machine_config)
    else
      @triple = nil
      @arch = nil
    end

    retag_machinefunctions(@data) if options.qualify_machinecode

    run_linker(@data) if options.run_linker

    @bitcode_functions = FunctionList.new(@data['bitcode-functions'] || [], labelkey: 'name')
    @machine_functions = FunctionList.new(@data['machine-functions'] || [], labelkey: 'mapsto')
    @relation_graphs   = RelationGraphList.new(@data['relation-graphs'] || [],
                                               @bitcode_functions, @machine_functions)
    @global_cfgs       = GCFGList.new(@data['global-cfgs'] || [], self)

    # usually read-only sections, but might be modified by pml-config
    @data['analysis-configurations'] ||= []
    @analysis_configurations = AnalysisConfigList.from_pml(self, @data['analysis-configurations'])
    @data['tool-configurations'] ||= []
    @tool_configurations = ToolConfigList.from_pml(self, @data['tool-configurations'])

    # read-write sections
    @data['flowfacts'] ||= []
    @flowfacts = FlowFactList.from_pml(self, @data['flowfacts'])
    @data['valuefacts'] ||= []
    @valuefacts = ValueFactList.from_pml(self, @data['valuefacts'])
    @data['modelfacts'] ||= []
    @modelfacts = ModelFactList.from_pml(self, @data['modelfacts'])
    @data['timing'] ||= []
    @timing = TimingList.from_pml(self, @data['timing'])
    @sca_graph = SCAGraph.new(self, @data['sca-graph']) if @data.include?('sca-graph')
    @sca_graph ||= nil
    @text_symbols ||= nil
  end

  attr_reader :valuefacts

  # Name generation scheme
  def qualify_machinefunction_name(file, name)
    # cleanup the path (removes leading './' and intrapath '..' patterns
    file = Pathname.new(file).cleanpath.to_s
    # Remove the trailing .pml if any
    file.sub!(/\.pml$/, '')
    # Mangle the slashes (necessary, as qname relies on the following format:
    # fun/block/instr
    file.gsub!(/\//, '_')
    file + ":" + name
  end

  def retag_machinefunctions(data)
    # Machinefunctionnames are actually counters. Those are unique only for each
    # individual pmlfile. Therefore we qualify them via filename.
    (data['machine-functions'] || []).each do |m|
      assert("machine-functions have to be on machinecode level") { m['level'] == "machinecode" }
      m['name'] = qualify_machinefunction_name(m['pmlsrcfile'], m['name']) if m.key?('pmlsrcfile')
    end

    (data['relation-graphs'] || []).each do |m|
      if m.key?('pmlsrcfile')
        mcode = nil
        if m['src']['level'] == 'machinecode'
          mcode = m['src']
        elsif m['dst']['level'] == 'machinecode'
          mcode = m['dst']
        end

        assert("relationship graphs map between bitcode and machinecode level") { mcode != nil }
        mcode['function'] = qualify_machinefunction_name(m['pmlsrcfile'], mcode['function'])
      end
    end

    (data['valuefacts'] || []).each do |v|
      if v['level'] == "machinecode" && v.key?('pmlsrcfile')
        pp = v['program-point']
        assert("valuefacts require a program point") { pp != nil }
        pp['function'] = qualify_machinefunction_name(v['pmlsrcfile'], pp['function'])
      end
    end

    (data['modelfacts'] || []).each do |v|
      if v['level'] == "machinecode" && v.key?('pmlsrcfile')
        pp = v['program-point']
        assert("modelfacts require a program point") { pp != nil }
        pp['function'] = qualify_machinefunction_name(v['pmlsrcfile'], pp['function'])
      end
    end
  end

  class LinkerInfo
    attr_reader :name, :file, :linkage

    # We expect a to be a representation of `llvm::GlobalValue::LinkageTypes
    # This Enum consists of:
    #  - ExternalLinkage
    #      Externally visible function.
    #  - AvailableExternallyLinkage
    #      Available for inspection, not emission.
    #  - LinkOnceAnyLinkage
    #      Keep one copy of function when linking (inline)
    #  - LinkOnceODRLinkage
    #      Same, but only replaced by something equivalent.
    #  - WeakAnyLinkage
    #      Keep one copy of named function when linking (weak)
    #  - WeakODRLinkage
    #      Same, but only replaced by something equivalent.
    #  - AppendingLinkage
    #      Special purpose, only applies to global arrays.
    #  - InternalLinkage
    #      Rename collisions when linking (static functions).
    #  - PrivateLinkage
    #      Like Internal, but omit from symbol table.
    #  - ExternalWeakLinkage
    #      ExternalWeak linkage description.
    #  - CommonLinkage
    #      Tentative definitions.

    def initialize(name, file, linkage)
      @name    = name
      @file    = file
      @linkage = linkage
    end

    def is_external?
      (@linkage == "ExternalLinkage")
    end

    def is_weak?
      # FIXME: What is ExternalWeakLinkage
      (@linkage == "WeakAnyLinkage" || @linkage == "WeakODRLinkage")
    end

    def to_s
      "#{@name}(#{@file}, #{@linkage})"
    end
  end

  def purge_unlinked_symbols(data, resolved)
    # Parameters:
    #    data:     the yaml-data array
    #    resolved: Hash mapping symbol names to the file holiding the selected
    #              instance

    # Purging is an multistep process:
    # 1. Purge bitcode functions (trivial)
    # 2. Purge machinecode functions that map to obsolete function
    #    Collect a list of purged machineinfo functions
    # 3. Purge relationship graphs for both functions and machinefunctions
    # 4. Purge flowfacts based on both
    # 5. Purge valuefacts based on both

    # Step 1: bit-code
    (data['bitcode-functions'] || []).select! do |fun|
      symname = fun['name']
      assert("Insufficient data for bitcode-function: #{symname}") do
        fun.key?('name') && resolved.key?(symname) && fun.key?('pmlsrcfile')
      end
      resolved[symname] == fun['pmlsrcfile']
    end

    # Step 2: machine-code
    pruned_machinefunctions = Set.new # Collection of mf to prune
    (data['machine-functions'] || []).reject! do |fun|
      mapped = fun['mapsto']
      assert("Insufficient data for machine-function: #{fun['name']} -> mapped") do
        fun.key?('mapsto') && resolved.key?(mapped) && fun.key?('pmlsrcfile')
      end
      if resolved[mapped] != fun['pmlsrcfile']
        # prune
        pruned_machinefunctions.add(fun['name'])
        true
      else
        false
      end
    end

    # Step 3: relation-graphs
    (data['relation-graphs'] || []).reject! do |graph|
      prune = false
      ["src", "dst"].each do |locdesc|
        loc = graph[locdesc]
        assert("Insufficient data for relation-graph(#{locdesc}): #{graph['src']} <-> #{graph['dst']}") do
          graph.key?(locdesc) && loc.key?('level') &&
            loc.key?('function') && graph.key?('pmlsrcfile')
        end
        case loc['level']
        when 'bitcode'
          assert("Unresolved function #{loc['function']}") { resolved.key?(loc['function']) }
          prune ||= resolved[loc['function']] != graph['pmlsrcfile']
        when 'machinecode'
          prune ||= pruned_machinefunctions.include?(loc['function'])
        else
          assert("No such level: #{loc['level']}") { false }
        end
      end
      prune
    end

    # Step 4: flowfacts
    (data['flowfacts'] || []).reject! do |ff|
      assert("Incomplete flowfact: #{ff}") do
        ff.key?('scope') && ff['scope'].key?('function') && ff.key?('level')
      end

      prune = false
      fun = ff['scope']['function']

      case ff['level']
      when 'bitcode'
        assert("No such function: #{fun}") { resolved.key?(fun) && ff.key?('pmlsrcfile') }
        prune ||= resolved[fun] != ff['pmlsrcfile']
      when 'machinecode'
        prune ||= pruned_machinefunctions.include?(fun)
      else
        assert("No such level: #{ff['level']}") { false }
      end

      prune
    end

    # Step 5: valuefacts
    (data['valuefacts'] || []).reject! do |vf|
      assert("Incomplete valuefacts: #{vf}") do
        vf.key?('program-point') && vf['program-point'].key?('function') && vf.key?('level')
      end

      prune = false
      fun = vf['program-point']['function']

      case vf['level']
      when 'bitcode'
        assert("No such function: #{fun}") { resolved.key?(fun) && vf.key?('pmlsrcfile') }
        prune ||= resolved[fun] != vf['pmlsrcfile']
      when 'machinecode'
        prune ||= pruned_machinefunctions.include?(fun)
      else
        assert("No such level: #{vf['level']}") { false }
      end

      prune
    end

    (data['modelfacts'] || []).reject! do |mf|
      assert("Incomplete modelfacts: #{mf}") do
        mf.key?('program-point') && mf['program-point'].key?('function') && mf.key?('level')
      end

      prune = false
      fun = mf['program-point']['function']

      case mf['level']
      when 'bitcode'
        assert("No such function: #{fun}") { resolved.key?(fun) && mf.key?('pmlsrcfile') }
        prune ||= resolved[fun] != mf['pmlsrcfile']
      when 'machinecode'
        prune ||= pruned_machinefunctions.include?(fun)
      else
        assert("No such level: #{mf['level']}") { false }
      end

      prune
    end

    data
  end

  # The linker operates on pmlfile level. Therefore it assumes that each pml
  # file in the input represents a complete compilation unit that comprises
  # bitcode-functions, machine-functions, relation-graphs, flowfacts and
  # valuefacts.  Linking discards unlinked units at this level.
  def run_linker(data)
    # Collect LinkerInfos for all functions
    symbols = {}
    data['bitcode-functions'].each do |mf|
      assert("#{mf}: Can only link when linkage info is provided") { mf.key?('linkage') }
      (symbols[mf['name']] ||= []) << LinkerInfo.new(mf['name'], mf['pmlsrcfile'], mf['linkage'])
    end

    # Now the actual linking
    resolved = {}
    symbols.each do |k,v|
      r = nil
      if v.length == 1
        r = v[0]
      else
        # Our algorithm here is rather basic and currently merely handles the
        # special case of weak symbols vs strong symbols
        #   The strong symbols dominate weak symbols
        # This misses other valid, but undecideable linking situations, e.g.
        # multiple weak symbols or LinkOnces.
        # In those cases, one of the symbols would be chosen (based on link
        # order), which we cannot know on pml level
        #  -> Die and let the user resolve it in accordance to the binary
        strong_symbols = v.select { |s| s.is_external? }
        assert("Cannot link \"#{k}\" automatically: #{v}") { strong_symbols.length == 1 }
        r = strong_symbols[0]
      end
      resolved[k] = r.file
    end

    # Purge obsolete information from data
    purge_unlinked_symbols(data, resolved)

    data
  end

  def analysis_gcfg(options)
    gcfg_name = options.analysis_entry.dup
    if gcfg_name.slice!(/^GCFG:/)
      global_cfgs.by_name(gcfg_name)
    elsif global_cfgs.by_name(options.analysis_entry)
      global_cfgs.by_name(options.analysis_entry)
    else
      machine_functions.by_label(options.analysis_entry)
      entry = GCFG.new({'level'=>'bitcode',
                        'name'=> options.analysis_entry,
                        'entry-nodes'=>[0],
                        'exit-nodes'=>[0],
                        'nodes'=> [{'index'=>0,  'function'=>options.analysis_entry}]},
                       self)
      @global_cfgs.push(entry)
      entry
    end
  end

  def toplevel_objects_for_level(level)
    if level == 'gcfg'
      global_cfgs
    elsif level == 'bitcode'
      bitcode_functions
    elsif level == 'machinecode'
      machine_functions
    else
      raise Exception, "Unsupported representation level: #{level}"
    end
  end

  def clone_empty
    data = {}
    data['format'] = @data['format']
    data['triple'] = @data['triple']
    PMLDoc.new(data)
  end

  #
  # used if some modifications to the PML database should not become permanent
  # saves the specified sections before yielding, and restores them afterwards
  def with_temporary_sections(temporary_sections = [:flowfacts, :valuefacts, :timing])
    backup = temporary_sections.map { |s| send(s) }
    begin
      temporary_sections.map do |s|
        instance_variable_set("@#{s}", Marshal.load(Marshal.dump(send(s))))
      end
      r = yield
    ensure
      temporary_sections.zip(backup).each do |s,b|
        instance_variable_set("@#{s}",b)
      end
    end
    r
  end

  def to_s
    format("PMLDoc{bitcode-functions: |%d|, machine-functions: |%d|" \
            ", flowfacts: |%s|, valuefacts: |%d|, modelfacts: |%d|" \
            ", timings: |%d|, gcfgs:|%d|",
            bitcode_functions.length, machine_functions.length,
            flowfacts.length,valuefacts.length,modelfacts.length,timing.length,global_cfgs.length)
  end

  def dump_to_file(filename, write_config = false)
    if filename.nil? || filename == '-'
      dump($DEFAULT_OUTPUT, write_config)
    else
      File.open(filename, "w") do |fh|
        dump(fh, write_config)
      end
    end
  end

  def to_pml(write_config = false)
    @data["bitcode-functions"] = @bitcode_functions.to_pml
    @data["machine-functions"] = @machine_functions.to_pml
    @data["relation-graphs"]   = @relation_graphs.to_pml

    final = deep_data_clone # eliminate sharing to enable YAML import in LLVM

    # Remove the autogenerated pmlsrcfile member from output
    final.each do |_k,v|
      if v.kind_of? Array
        v.map! do |elem|
          elem.delete('pmlsrcfile') if elem.kind_of? Hash
          elem
        end
      end
    end

    # XXX: we do not export machine-configuration and analysis-configurations by default for now
    # The trouble is that we first need to mirror those sections for LLVM's yaml-io :(
    final.delete("machine-configuration") if (@data["machine-configuration"] == []) || !write_config
    final.delete("analysis-configurations") if (@data["analysis-configurations"] == []) || !write_config
    final.delete("tool-configurations") if (@data["tool-configurations"] == []) || !write_config
    final.delete("flowfacts") if @data["flowfacts"] == []
    final.delete("valuefacts") if @data["valuefacts"] == []
    final.delete("timing") if @data["timing"] == []
    final.delete("modelfacts") if @data["modelfacts"] == []
    final
  end

  def dump(io, write_config = false)
    final = to_pml(write_config)
    io.write(YAML::dump(final))
  end

  def deep_data_clone
    self.class.deep_data_clone(@data)
  end

  def self.deep_data_clone(data)
    cloned_data = data.dup
    worklist = [cloned_data]
    until worklist.empty?
      d = worklist.pop
      if d.kind_of?(Hash)
        d.each do |k,v|
          # compounds are always sequences (Array) or mappings (Hash)
          if v.kind_of?(Hash) || v.kind_of?(Array)
            d[k] = v_copy = v.dup
            worklist.push(v_copy)
          end
        end
      elsif d.kind_of?(Array)
        d.each_with_index do |v,k|
          if v.kind_of?(Hash) || v.kind_of?(Array)
            d[k] = v_copy = v.dup
            worklist.push(v_copy)
          end
        end
      else
        assert("Internal error in deep_data_clone: non-compound in worklist") { false }
      end
    end
    cloned_data
  end

  def machine_code_only_functions
    %w{_start _exit exit abort __ashldi3 __adddf3 __addsf3 __divsi3 __udivsi3 __divdf3 __divsf3 __eqdf2 __eqsf2} +
      %w{__extendsfdf2 __fixdfdi __fixdfsi __fixsfdi __fixsfsi __fixunsdfdi __fixunsdfsi __fixunssfdi __fixunssfsi} +
      %w{__floatdidf __floatdisf __floatsidf __floatsisf __floatundidf __floatundisf __floatunsidf __floatunsisf} +
      %w{__gedf2 __gesf2 __gtdf2 __gtsf2 __ledf2 __lesf2 __lshrdi3 __ltdf2 __ltsf2 __muldf3 __mulsf3 __nedf2} +
      %w{__nesf2 __subdf3 __subsf3 __truncdfsf2 __unorddf2 __unordsf2 memcpy memmove memset}
  end

  def self.from_files(filenames, options)
    time("Parsing PML Files") do
      streams = filenames.inject([]) do |list,f|
        begin
          fm = f + ".bin"

          if File.exists?(fm) and File.stat(fm).mtime > File.stat(f).mtime
            fstream = File.open(fm) do |fhm|
              stream = Marshal.load(fhm.read)
              [[f, stream]]
            end
          else
            fstream = File.open(f) do |fh|
              stream = YAML::load_stream(fh)
              stream.documents if stream.respond_to?(:documents) # ruby 1.8 compat
              File.open(fm, "w+") do |fhm|
                fhm.write(Marshal.dump(stream))
              end
              [[f, stream]]
            end
          end
          list+fstream
        rescue Exception => detail
          die("Failed to load PML document: #{detail}")
        end
      end
      PMLDoc.new(streams, options)
    end
  end

  def self.merge_stream(stream)
    merged_doc = {}
    stream.each do |fstream|
      (fname, content) = fstream
      content.each do |doc|
        doc.each do |k,v|
          if v.kind_of? Array
            v.map! do |elem|
              elem['pmlsrcfile'] = fname if elem.kind_of? Hash
              elem
            end
            (merged_doc[k] ||= []).concat(v)
          elsif !merged_doc[k]
            merged_doc[k] = doc[k]
          elsif merged_doc[k] != doc[k]
            die "Mismatch in non-list attribute #{k}: #{merged_doc[k]} and #{doc[k]}"
          end
        end
      end
    end
    merged_doc
  end
end

end # mdoule PML
