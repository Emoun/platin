# typed: false
#
# This file is part of platin
#
# The goal of this file is to create (documented) ruby code from
# the PML schema, thus providing both documentation and a scaffold for
# dealing with PML files. It is a replacement for the kwalify ruby
# generator that inspired it, tailored towards our needs.
#

require 'yaml'
require 'kwalify'
require 'optparse'
require 'ostruct'

class String
  # Count number of spaces before the first non-space (+first_line_indent+),
  # and adjust the indent of the text by (+new_indent - first_line_indent+).
  #
  # Convenient for indented HEREDOCs; inspired by ActiveSupport's
  # strip_heredoc.
  def indent_doc(new_indent = 0)
    # let indent_diff = new_indent - first_line_indent
    # if indent_diff < 0 -> delete indent_diff leading spaces
    # if indent_diff > 0 -> add indent_diff leading spaces
    self =~ /\A(\s*)/
    first_line_indent = $1.length
    add_indent = ' ' * [new_indent - first_line_indent, 0].max
    del_indent_count = [new_indent - first_line_indent, 0].min.abs
    gsub(/^([ \t]{0,#{del_indent_count}})(\s*)(\S)/) do
      add_indent + $2.to_s + $3
    end
  end
end

# This class generates documented ruby code from the PML schema
# The rough idea is that all entities in the kwalify schema that are
# documented on multiple lines (and supply a class name), become a
# class on their own. All hyphens in YAML (-) are replaced by underscores
# ('_') in the ruby code.
class PMLGenerator
  attr_reader :options
  def self.default_preamble(schema_file)
    <<-EOF.indent_doc(MODULE_INDENT)
      #
      # This file is part of platin
      #
      # = PML datastructures
      #
      # Autogenerated from #{schema_file} -- DO NOT EDIT

      # == PML - Program Metainfo Language
      #
      # a PML Document stores (meta)-information about a program
      # (e.g., structure, control-flow, analysis results) on
      # *different* representation levels (bitcode and machine code).
      # In addition to analysis results, the PML document also stores
      # the analysis configurations (HW/SW) used for timing and program
      # analysis.
      module PML
    EOF
  end

  def initialize(schema_file,options)
    @schema_file, @options = schema_file,options
    @preamble =
      if options.preamble
        File.read(options.preamble)
      else
        PMLGenerator.default_preamble(@schema_file)
      end
    @klasses = {}
    @io = $stdout
  end

  def generate
    load_schema
    @worklist = [@schema]
    generate_code
  end

private

  MODULE_INDENT = 0
  KLASS_INDENT  = 2
  METHOD_INDENT = 4

  def load_schema
    @schema = YAML.load_file(@schema_file)
  end

  def generate_code
    @io.puts @preamble
    generate_klass(@worklist.pop) until @worklist.empty?
    @io.puts <<-EOF.indent_doc(MODULE_INDENT)
      end # module PML
    EOF
  end

  def generate_klass(entity)
    ty = entity['type']
    doc, attrs = parse_doc(entity['desc'])
    klass = get_klass(entity, attrs)
    raise Exception, "generate_klass: #{entity['desc']} has no 'class' attribute'" unless klass
    return false if @klasses[klass] # already generated

    @io.puts doc.indent_doc(KLASS_INDENT)
    if ty == 'map'
      generate_dict(klass,attrs,entity['mapping'])
    elsif ty == 'seq'
      generate_list(klass,attrs,entity['sequence'])
    else
      raise Exception, "Refusing to generate class for scalar type: #{name}"
    end
    @klasses[klass] = true
    klass
  end

  def get_klass(item, _attrs = nil)
    return item['class'] if item['class']
    if item['type'] == 'seq' && (elemklass = item['sequence'].first['class'])
      elemklass + "List"
    end
  end

  def generate_dict(klass, attrs, fields)
    superklass = attrs[:super] || 'PMLObject'
    @io.puts "  class #{klass} < #{superklass}"
    fields.each do |k,v|
      field = ruby_name(k)
      field_doc, field_attrs = parse_doc(v['desc'])
      field_klass = get_klass(v, field_attrs)
      @io.puts <<-EOF.indent_doc(METHOD_INDENT)
        ##
        # :attr_reader: #{field}
        #
      EOF
      if !field_klass
        @io.puts(field_doc.indent_doc(METHOD_INDENT))
        @io.puts("# * YAML key: +#{k}+".indent_doc(METHOD_INDENT))
        @io.puts("# * Type: <tt>#{yaml_type_descr(v)}</tt>".indent_doc(METHOD_INDENT))
      elsif v['type'] == 'seq'
        ref = v['sequence'].first['class']
        @io.puts(field_doc.indent_doc(METHOD_INDENT))
        @io.puts <<-EOF.indent_doc(METHOD_INDENT)
          # * YAML key: +#{k}+
          # * Type: [ -> #{ref} ]
        EOF
        @worklist.push(v)
      else
        @io.puts <<-EOF.indent_doc(METHOD_INDENT)
          # * YAML key: +#{k}+
          # * Type: -> #{field_klass}
        EOF
        @worklist.push(v)
      end
      @io.puts "attr_reader :#{field}".indent_doc(METHOD_INDENT)
      @io.puts ""
    end
    @io.puts "end # class #{klass}".indent_doc(KLASS_INDENT)
  end

  def generate_list(klass, attrs, elemtypes)
    elemtype = elemtypes.first
    elemklass = get_klass(elemtype)
    raise Exception, "Schema error: element type of list class #{klass} has no 'class' attribute" unless elemklass
    superklass = attrs[:super] || 'PMLList'
    if options.list_classes
      @io.puts <<-EOF.indent_doc(KLASS_INDENT)
        class #{klass} < #{superklass}
          extend PMLList

          ##
          # :attr_reader: list"
          # List of #{elemklass} objects

        end # class #{klass}"
        EOF
    end
    @worklist.push(elemtype)
  end

  def parse_doc(descr)
    return ['', {}] unless descr

    descr =~ / \A (.*?) (?: \[ ([^\[\]]*) \])? \Z /xm
    doc,attrs = $1, $2
    doc_lines = []

    doc.split(/\n/).each do |line|
      line =~ /^(\s*)(.*)/
      indent, rest = $1, $2
      doc_lines.push("##{indent}")
      no_split = (rest =~ /^\s*[\-\*]/) # do not split enumerations
      rest.scan(/\S+/) do |w|
        doc_lines.push("##{indent}") if doc_lines.last.length > 80 - w.length && !no_split
        doc_lines.last << ' ' << w
      end
    end

    attrs = (attrs || "").split(/\s*,\s*/).map do |pair|
      k,v = pair.split(/\s*=\s*/,2)
      v ? [k,v] : [k,true]
    end.flatten

    [doc_lines.join("\n"), Hash[*attrs.flatten]]
  end

  def yaml_type_descr(v)
    if v['type'] == 'seq'
      "[" + v['sequence'].map { |elem| yaml_type_descr(elem) }.join(", ") + "]"
    elsif v['type'] == 'map'
      "{" + v['mapping'].map { |k,v| "#{k}: #{yaml_type_descr(v)}" }.join(", ") + "}"
    elsif v['enum']
      v['enum'].map { |s| s.inspect }.join(" | ")
    else
      v['type']
    end
  end

  def ruby_name(s)
    s.gsub('-','_')
  end
end

options = OpenStruct.new
argv = OptionParser.new do |opts|
  opts.banner = "Usage: gen_pml.rb [options] pml.yml"
  opts.on("--list-classes",
          "Generate list class for objects that have a class attribute") do |_b|
    options.list_classes = true
  end
  opts.on("-v", "--[no-]verbose", "Run verbosely") do |_v|
    options.verbose = true
  end
end.parse!
if argv.empty?
  $stderr.puts("Please specify a schema")
  exit 1
end
PMLGenerator.new(ARGV.first, options).generate
