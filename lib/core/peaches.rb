#!/usr/bin/env ruby
# typed: false

# TODO: Proper ahead of time type inference
#       ADTs
#       Ability to lock scopes in context to prohibit modifications/global exports for expressions

require 'rsec'
require 'pp'
require 'English'
require 'set'

# Define AST-Nodes

## Peaches borrows it syntax heavily from Dhall and therefore haskell
#
# All symbols are actually final. To simplify facts, they can be considered as
# constant functions. The language strives to be total (as in total functional
# programming) and therefore to guarantee termination. To prohibit cross
# recursion, all declarations are therefore implicitly scoped and evaluated top
# down.
# Recursion as such is also illegal (past a set of basic recursive functions in
# the standard lib that are chosen to not break the totalness)
#
# For now, the type system consists of booleans and integers, but uses duck
# typing. This will be fixed in the future, once the featureset has been
# finalized. The plan is to use type inference (most likely HM), but this is not
# yet implemented
#
# Concerning the name:
#   Like Dhall, peaches is a scribe, from the book "The Amacing Maurice and his educated rodents"
#   Unlike Dhall, she is rather good natured, and believes into what you tell her about your program,
#   happy endings, and the universal truths of "Mr Bunnsy has an adventure"

module Peaches

class PeachesError < StandardError
end

class PeachesTypeError < PeachesError
end

class PeachesBindingError < PeachesError
end

class PeachesArgumentError < PeachesError
end

class PeachesUnsupportedError < PeachesError
end

class PeachesInternalError < PeachesError
end

class PeachesRecursionError < PeachesError
end

class Context
  # The difference between a Context and a Map is that a Context lets you have
  # multiple ordered occurrences of the same key and you can query for the nth
  # occurrence of a given key.
  class Entry
    attr_reader :level, :val
    def initialize(level, val)
      @level = level
      @val   = val
    end

    def inspect
      "#{@val}@#{@level}"
    end
  end

  DEBUG = false

  def initialize
    @level     = 0
    @bindings  = {}
    @callstack = []
  end

  def enter_scope
    @level += 1
  end

  def leave_scope
    @level -= 1

    @bindings.each do |_k,v|
      v.select! { |e| e.level <= @level }
    end
  end

  def insert(label, val)
    list  = (@bindings[label] ||= [])
    entry = Entry.new(@level, val)
    if !list.empty? && (list.last.level >= @level)
      raise PeachesBindingError, "Variable #{label} already bound at same scope #{@level}"
    end
    list << entry

    puts to_s + "\n" if DEBUG
  end

  def lookup(label, index = :last)
    entry = nil
    list  = @bindings[label]
    raise PeachesBindingError, "Unknown variable #{label}" if list.nil?
    if index == :last
      entry = list.last
    else
      list.each { |e| entry = e if e.level == index }
    end
    raise PeachesBindingError, "No binding for variable #{label} on level #{level}" if entry.nil?
    entry.val
  end

  def to_s
    s = "Context(level = #{@level})\n"
    @bindings.each do |key, val|
      s += "  #{key} = #{val}\n"
    end
    s
  end

  def push_call(call, decl)
    @active_decls ||= {}

    throw PeachesRecursionError.new "Recursion detected: #{decl} already contained in callstack" if @active_decls[decl]

    @callstack.push([call, decl])
    @active_decls[decl] = true
    enter_scope
  end

  def pop_call
    leave_scope
    raise "pop_call: Callstack is empty" if @callstack.empty?
    _, decl = @callstack.pop
    @active_decls.delete(decl)
  end
end

class ASTNode
  MESS = "SYSTEM ERROR: method missing"

  # Typecheck a variable
  def evaluate(_context)
    raise MESS
  end

  def to_s
    raise MESS
  end

  def inspect
    to_s
  end

  def to_bool
    raise PeachesTypeError, "No known conversion from #{self.class.name} to boolean"
  end

  def to_num
    raise PeachesTypeError, "No known conversion from #{self.class.name} to number"
  end

  def visit(visitor)
    visitor.visit_pre self
    visitor.visit self
  end
end # class ASTNode

class ASTDecl < ASTNode
  attr_reader :ident, :params, :expr

  def initialize(ident, params, expr)
    @ident  = ident
    @params = params
    @params ||= []
    @expr = expr
  end

  def evaluate(context)
    ident = @ident.label
    if params.empty?
      # Performance optimization: calculate constants now
      expr = @expr.evaluate(context)
      rhs = ASTDecl.new(@ident, @params, expr)
    else
      rhs = self
    end

    # Binding the variable here mitigates recursion
    context.insert(ident, rhs)
  end

  def to_s
    "#{@ident} #{@params.join(' ')} = #{@expr}"
  end

  def visit(visitor)
    visitor.visit_pre self
    @ident = @ident.visit(visitor)
    @params.each_with_index do |p,i|
      @params[i] = p.visit(visitor)
    end
    @expr = @expr.visit(visitor)
    visitor.visit self
  end

  def curry(scopeupdates)
    if scopeupdates.length > @params.length
      raise "Too few parameters: cannot curry #{amount} of #{@params.length} parameters"
    end
    p = @params.take(scopeupdates.length)

    p.each do |param|
      raise "No mapping for param #{param}" unless scopeupdates[param]
    end

    e = ASTScope.new(scopeupdates, @expr)
    new(@ident, @params.drop(scopeupdates.length), e)
  end
end

class ASTProgram
  attr_reader :decls

  def initialize(decls)
    @decls = decls
  end

  def evaluate(context = Context.new)
    @decls.each do |decl|
      decl.evaluate(context)
    end
    context
  end

  def inspect
    to_s
  end

  def to_s
    @decls.join("\n")
  end

  def visit(visitor)
    visitor.visit_pre self
    @decls.each_with_index do |d, i|
      @decls[i] = d.visit(visitor)
    end
    visitor.visit self
  end
end

class ASTLiteral < ASTNode
  attr_reader :value

  def initialize(value)
    @value = value
  end

  def evaluate(_context)
    # Is already fully evaluated
    self
  end

  def to_s
    @value.to_s
  end

  def visit(visitor)
    visitor.visit_pre self
    visitor.visit self
  end
end

class ASTValueLiteral < ASTLiteral
  def ==(o)
    eql?(o)
  end

  def eql?(o)
    o.class == self.class && o.unbox == value
  end

  def hash
    value.hash
  end

  def unbox
    value
  end
end

class ASTBoolLiteral < ASTValueLiteral
  def to_s
    @value.to_s.capitalize
  end

  def to_bool
    value
  end
end

class ASTNumberLiteral < ASTValueLiteral
  def to_num
    value
  end
end

class ASTSymbolListLiteral < ASTValueLiteral
  def to_symbollist
    value
  end
end

class ASTSetLiteral < ASTValueLiteral
  def to_set
    value
  end
end

class ASTSpecialLiteral < ASTLiteral
end

class ASTUndefinedLiteral < ASTSpecialLiteral
end

class ASTErrorLiteral < ASTSpecialLiteral
end

class ASTIdentifier < ASTNode
  attr_reader :label

  def initialize(label)
    @label = label
  end

  def evaluate(context)
    context.lookup(@label).evaluate(context)
  end

  def to_s
    @label.to_s
  end

  def visit(visitor)
    visitor.visit_pre self
    visitor.visit self
  end
end

class ASTScope < ASTNode
  attr_reader :bindings, :expr

  def initialize(bindings, expr)
    @bindings = bindings
    @expr     = expr
  end

  def evaluate(context)
    context.enter_scope

    @bindings.each do |label,decl|
      context.insert(label, decl)
    end

    context.leave_scope
  end

  def to_s
    "let (#{@bindings.map { |b| b.to_s }.join(',')}) in (#{@expr})"
  end

  def visit(visitor)
    visitor.visit_pre self
    @bindings.each do |k, v|
      @bindings[k] = v.visit(visitor)
    end
    @expr = @expr.visit(visitor)
    visitor.visit self
  end
end

class ASTCall < ASTNode
  attr_reader :label, :args

  DEBUG = false

  def initialize(label, args = [], decl = nil)
    @label   = label
    @args    = args
    @decl    = decl
  end

  def evaluate(context)
    puts "#{self.class.name}#Call: Evaluating #{self}: Args: #{@args}" if DEBUG

    @decl ||= context.lookup(@label)

    # Error handling
    if @decl.params.length < args.length
      raise PeachesArgumentError, "Argument number mismatch for #{self}:" \
        "expected #{@decl.params.length}, got #{args.length}"
    end

    # Ok, we are all setup, now evaluate
    scopeupdates = {}
    args.each_with_index do |argument,idx|
      expr = argument.evaluate(context)

      if expr.respond_to?(:decl)
        paramdecl = ASTDecl.new(@decl.params[idx], expr.decl.params, expr.decl.expr)
      else
        paramdecl = ASTDecl.new(@decl.params[idx], [], expr)
      end
      scopeupdates[@decl.params[idx].label] = paramdecl
    end

    # Check if all necessary arguments were passed
    if @decl.params.length > args.length
      # Nope, we still need some curry
      puts "Currying call #{self}: Too few arguments: expecting #{@decl.params}, found #{@args}" if DEBUG
      if !args.empty?
        # Adopt curry: Take args, return decl pointing to ASTScopeupdate -> Bodyexpr
        #              This eliminates scopeupdates
        # TODO
        newdecl = @decl.curry(scopeupdates)
        return ASTCall.new(@label, [], newdecl)
      else
        return self
      end
    end

    puts "#{self.class.name}#Call: Finished argument-expansion #{self}: Args: #{@args}" if DEBUG

    # Push ourself on the callstack. This errors if @decl is already contained in
    # the callstack, breaking potential recursions
    # Also opens a new scope
    puts "#{self.class.name}#Pushcall: #{self} with decl #{@decl}" if DEBUG
    context.push_call(self, @decl)
    scopeupdates.each do |label, decl|
      context.insert(label, decl)
    end

    puts "#{self.class.name}##{self}: \\#{scopeupdates} -> #{@decl.expr}" if DEBUG
    res = @decl.expr.evaluate(context)

    # Cleanup callstack and leave current scope
    context.pop_call

    puts "#{self.class.name}#Call: Evaluated #{self}: Args: #{@args} Result: #{res}" if DEBUG
    res
  end

  def to_s
    "#{self.class.name}#(#{@label} #{@args.map { |a| a.to_s }.join(' ')})"
  end

  def visit(visitor)
    visitor.visit_pre self
    @args.each_with_index do |expr, i|
      @args[i] = expr.visit(visitor)
    end
    visitor.visit self
  end

  def decl
    @decl || context.lookup(@label)
  end
end

class ASTExpr < ASTNode
  def self.assert_full_eval(node, context, types)
    val = node.evaluate(context)
    raise "Expression #{node} is not of a terminal value type: #{val}" unless val.is_a?(ASTValueLiteral)

    typecheck = types.map do |type|
      match = false
      case type
      when :boolean
        match = true if val.is_a?(ASTBoolLiteral)
      when :number
        match = true if val.is_a?(ASTNumberLiteral)
      when :symbollist
        match = true if val.is_a?(ASTSymbolListLiteral)
      when :set
        match = true if val.is_a?(ASTSetLiteral)
      else
        raise PeachesInternalError, "Unknown type: #{type}"
      end
      match
    end.inject(false) { |x,y| x || y }

    raise PeachesTypeError, "Expression #{node.class.name}:#{node} is no instance of #{types}" unless typecheck

    val
  end
end

class ASTIf < ASTExpr
  attr_reader :cond, :if_expr, :else_expr
  def initialize(cond, if_expr, else_expr)
    @cond      = cond
    @if_expr   = if_expr
    @else_expr = else_expr
  end

  def evaluate(context)
    cond = ASTExpr.assert_full_eval(@cond, context, [:boolean])
    if cond.to_bool
      return @if_expr.evaluate(context)
    else
      return @else_expr.evaluate(context)
    end
  end

  def to_s
    "if #{@cond} then #{if_expr} else #{else_expr}"
  end

  def visit(visitor)
    visitor.visit_pre self
    @cond      = @cond.visit(visitor)
    @if_expr   = @if_expr.visit(visitor)
    @else_expr = @else_expr.visit(visitor)
    visitor.visit self
  end
end

class ASTArithmeticOp < ASTExpr
  def initialize(lhs, op, rhs)
    @op, @lhs, @rhs = op, lhs, rhs
  end

  OP_MAP = {
    "+" => { op: :+, types: [:number] },
    "-" => { op: :-, types: [:number] },
    "*" => { op: :*, types: [:number] },
    "/" => { op: :/, types: [:number] },
    "%" => { op: :%, types: [:number] },
  }

  def evaluate(context)
    desc = OP_MAP[@op]
    raise PeachesInternalError, "Unknown arithmetic operator: #{@op}" if desc.nil?

    lhs = ASTExpr.assert_full_eval(@lhs, context, desc[:types])
    rhs = ASTExpr.assert_full_eval(@rhs, context, desc[:types])

    ASTNumberLiteral.new(Integer(lhs.value.public_send(desc[:op], rhs.value)))
  end

  def to_s
    "(#{@lhs} #{@op} #{@rhs})"
  end

  def visit(visitor)
    visitor.visit_pre self
    @lhs = @lhs.visit(visitor)
    @rhs = @rhs.visit(visitor)
    visitor.visit self
  end
end

class ASTLogicalOp < ASTExpr
  def initialize(lhs, op, rhs)
    @op, @lhs, @rhs = op, lhs, rhs
  end

  def evaluate(context)
    lhs = ASTExpr.assert_full_eval(@lhs, context, [:boolean])
    # Only evaluate rhs when required
    if (lhs.to_bool && @op == '&&') || (!lhs.to_bool && @op == '||')
      return ASTExpr.assert_full_eval(@rhs, context, [:boolean])
    end

    lhs
  end

  def to_s
    "(#{@lhs} #{@op} #{@rhs})"
  end

  def visit(visitor)
    visitor.visit_pre self
    @lhs = @lhs.visit(visitor)
    @rhs = @rhs.visit(visitor)
    visitor.visit self
  end
end

class ASTCompareOp < ASTExpr
  def initialize(lhs, op, rhs)
    @op, @lhs, @rhs = op, lhs, rhs
  end

  OP_MAP = {
    '<'  => { op: "<".to_sym,  types: [:number] },
    '<=' => { op: "<=".to_sym, types: [:number] },
    '>'  => { op: ">".to_sym,  types: [:number] },
    '>=' => { op: ">=".to_sym, types: [:number] },
    '==' => { op: "==".to_sym, types: [:number, :boolean] },
    '/=' => { op: "!=".to_sym, types: [:number, :boolean] },
  }

  def evaluate(context)
    desc = OP_MAP[@op]
    raise PeachesInternalError, "Unknown compare operator: #{@op}" if desc.nil?

    lhs = ASTExpr.assert_full_eval(@lhs, context, desc[:types])
    rhs = ASTExpr.assert_full_eval(@rhs, context, desc[:types])

    ASTBoolLiteral.new(lhs.value.send(desc[:op], rhs.value))
  end

  def to_s
    "(#{@lhs} #{@op} #{@rhs})"
  end

  def visit(visitor)
    visitor.visit_pre self
    @lhs = @lhs.visit(visitor)
    @rhs = @rhs.visit(visitor)
    visitor.visit self
  end
end

class ASTBuiltinOperation < ASTExpr
  DEBUG = false

  def initialize(id, params, param_types, lambdaarg)
    @id, @params, @paramtypes, @lambdaarg = id, params, param_types, lambdaarg
  end

  def evaluate(context)
    puts "#{self.class.name}#Call: Evaluating #{self}: Args: #{@params}, Context: #{context}" if DEBUG
    params = @params.zip(@paramtypes).map do |param, type|
      val    = context.lookup(param.label).expr
      # Only typechecks here. Evaluation of parameters already happend in the
      # ASTCall
      evaled = ASTExpr.assert_full_eval(val, context, [type])
      # Unbox the literal
      evaled.unbox
    end
    res = @lambdaarg.call(*params)
    puts "#{self.class.name}#Call: Evaluated #{self}: Result (#{res.class.name}) #{res}" if DEBUG
    res
  end

  def to_s
    "builtin:#{@id}(#{@params})"
  end

  def visit(visitor)
    visitor.visit_pre self
    visitor.visit self
  end
end

class ASTVisitor
  def visit(node)
    node
  end

  def visit_pre(node)
    node
  end
end

class ReferenceCheckingVisitor < ASTVisitor
  def initialize(context = Context.new)
    @context = context
    @current = nil
  end

  def check_references(astprogram)
    astprogram.decls.each do |decl|
      @current = decl # Better error reporting

      @context.enter_scope
      decl.params.each do |id|
        @context.insert(id.label, true)
      end

      decl.expr.visit self
      @context.leave_scope

      @context.insert(decl.ident.label, true)
    end
  end

  def visit_pre(node)
    # TODO: if we ever support a let ... in style construct, enter context and declare locals here

    begin
      @context.lookup(node.label) if node.is_a?(ASTIdentifier) || node.is_a?(ASTCall)
    rescue PeachesBindingError
      raise PeachesBindingError, "Unbound variable #{node.label} on right side of decl #{@current}"
    end

    node
  end
end

# IF
# Declaration
# Literal
#   - Boolean
#   - Number
# Identifier
# Error
# Undef
# Operator
#   - LogicalOp
#   - CompareOp
#   - ArithmeticOp

class Parser
  include Rsec::Helpers
  extend Rsec::Helpers

  DEBUG_PARSER = false

  SPACE      = /[\ \t]*/.r
  COMMENT    = (seq_('{-', /((?!-}).)+/, '-}') \
               | seq(SPACE.maybe, /--((?!([\r\n]|$)).)+/.r) & (/[\r\n]/.r | ''.r.eof) \
               )
  CSPACE = (seq(SPACE, COMMENT, SPACE) | SPACE)

  # Specialisation of symbol that does not allow '\n'
  def self.symbol_(pattern, &p)
    symbol(pattern, CSPACE, &p)
  end

  NUM = prim :int64 do |(num)|
    ASTNumberLiteral.new Integer(num)
  end
  # Magic here: negative lookahead to prohibit keyword/symbol ambiguity
  IDENTIFIER  = seq((''.r ^ lazy { KEYWORD }), symbol_(/[a-zA-Z]\w*/)) do |(_,id)|
                  ASTIdentifier.new(id)
                end.expect('identifier')
  IF          = word('if').expect 'keyword_if'
  THEN        = word('then').expect 'keyword_then'
  ELSE        = word('else').expect 'keyword_else'
  CMP_OP      = symbol_(/(\<=|\<|\>=|\>|==|\/=)/).fail 'compare operator'
  LOGIC_OP    = symbol_(/(&&|\|\|)/).fail 'logical operator'
  MULT_OP     = symbol_(/[*\/%]/).fail 'multiplication operator'
  ADD_OP      = symbol_(/[\+]/).fail 'addition operator'
  SUB_OP      = symbol_(/[\-]/).fail 'subtraction operator'
  BOOLEAN     = (symbol_('True')  { |_| ASTBoolLiteral.new(true) } |
                 symbol_('False') { |_| ASTBoolLiteral.new(false) }).fail 'boolean'
  UNDEF       = symbol_('undefined')
  ERROR       = symbol_('error')
  LIST_BEGIN  = symbol_('[')
  LIST_END    = symbol_(']')
  SET_BEGIN   = symbol_('{')
  SET_END     = symbol_('}')
  SET_ELEMENT = NUM.fail "set_element"

  # A function name must begin with an alphabetic letter or the underscore _
  # character, but the other characters in the name can be chosen from the
  # following groups:
  # Any lower-case letter from a to z
  # Any upper-case letter from A to Z
  # Any digit from 0 to 9
  # The underscore character _
  FUNCTION_SYMBOL = symbol(/[^,\s\]]+/) do |(sym)|
    # If we have a qualified identifier, perform patmos-clang-style
    # namemangling (only for static identifiers)
    puts "sym #{sym}" if DEBUG_PARSER
    sym.sub(/^([^:]+):(.+)$/) do
      fname = $2; # because, well, fuck you, we are using global variables
                  # for our regex matching. scoping is for loosers.
      $1.gsub(/[^0-9A-Za-z]/, '_') + '_' + fname
    end
  end

  KEYWORD    = IF | THEN | ELSE | BOOLEAN | UNDEF | ERROR

  def space
    CSPACE
  end

  def comment
    COMMENT
  end

  # Specialisation of seq_ that does not allow '\n'
  def seq__(*xs,&p)
    seq_(*xs, skip: CSPACE, &p)
  end

  def arith_expr
    if @ARITH_EXPR.nil?
      arith_expr = (seq__(lazy { sub_term }, ADD_OP, lazy { arith_expr }) do |(lhs, op, rhs)|
                        puts "arith_expr: (#{lhs}) #{op} (#{rhs})" if DEBUG_PARSER
                        ASTArithmeticOp.new(lhs, op, rhs)
                      end \
                   | lazy { sub_term } \
                   )
      sub_term   = (seq__(lazy { term }, SUB_OP, lazy { sub_term }) do |(lhs, op, rhs)|
                        puts "arith_expr: (#{lhs}) #{op} (#{rhs})" if DEBUG_PARSER
                        ASTArithmeticOp.new(lhs, op, rhs)
                      end \
                   | lazy { term } \
                   )
      term       = (seq__(lazy { factor }, MULT_OP, lazy { term }) do |(lhs, op, rhs)|
                        puts "term: (#{lhs}) #{op} (#{rhs})" if DEBUG_PARSER
                        ASTArithmeticOp.new(lhs, op, rhs)
                      end\
                   | lazy { factor } \
                   )
      factor     = (seq__('(', arith_expr, ')')[1] \
                   | lazy { call } \
                   | NUM \
                   )
      _ = factor   # Silence warning
      _ = sub_term # Silence warning
      @ARITH_EXPR = arith_expr.fail "arithmetic expression"
    end
    @ARITH_EXPR
  end

  def cond_expr
    if @COND_EXPR.nil?
      cond_expr = (seq__(lazy { ao_expr }, LOGIC_OP, lazy { cond_expr }) do |(lhs, op, rhs)|
                       puts "cond_expr: (#{lhs}) #{op} (#{rhs})" if DEBUG_PARSER
                       ASTLogicalOp.new(lhs, op, rhs)
                     end \
                  | seq__(lazy { ao_expr }, CMP_OP, lazy { cond_expr }) do |(lhs, op, rhs)|
                      puts "cond_expr: (#{lhs}) #{op} (#{rhs})" if DEBUG_PARSER
                      ASTCompareOp.new(lhs, op, rhs)
                    end \
                  | lazy { ao_expr } \
                  )
      ao_expr   = (seq__(lazy { arith_expr }, CMP_OP, lazy { arith_expr }) do |(lhs, op, rhs)|
                       puts "ao_expr: (#{lhs}) #{op} (#{rhs})" if DEBUG_PARSER
                       ASTCompareOp.new(lhs, op, rhs)
                     end \
                  | seq__('(', cond_expr, ')')[1] \
                  | lazy { arith_expr } \
                  | BOOLEAN \
                  )
      _ = ao_expr # Silence warning
      @COND_EXPR = cond_expr.fail "conditional expression"
    end
    @COND_EXPR
  end

  def expr
    if @EXPR.nil?
      expr = (seq__(IF, lazy { cond_expr }, THEN, lazy { expr }, ELSE, lazy { expr }) do |(_,cond,_,e1,_,e2)|
                      puts "IF #{cond} then {#{e1}} else {#{e2}}" if DEBUG_PARSER
                      ASTIf.new(cond, e1, e2)
                    end \
             | lazy { cond_expr } \
             | lazy { symbollist } \
             | lazy { setliteral } \
             | UNDEF \
             | ERROR \
             )
      @EXPR = expr.fail "expression"
    end
    @EXPR
  end

  # We declare a var decl because this will make it easier to add
  # type annotations if required
  def var_decl
    IDENTIFIER.fail "vardecl"
  end

  def call
    if @CALL.nil?
      arg_list = (seq__(lazy { expr }, lazy { arg_list }) \
                 | lazy { expr } \
                 )
      callsite =  (seq__(IDENTIFIER, arg_list) \
                  | IDENTIFIER \
                  )
      @CALL = seq(''.r, callsite).cached do |(_,xs)|
        id, args = *xs
        puts "CALL: #{id}(#{listify(args).join(',')})" if DEBUG_PARSER
        ASTCall.new(id.label, listify(args))
      end
    end
    @CALL
  end

  def decl
    if @DECL.nil?
      par_list    = (seq__(var_decl, lazy { par_list }) \
                    | var_decl \
                    ).fail "parameterlist"
      declaration = (seq__(var_decl, par_list) \
                    | var_decl \
                    ).fail "function declaration"
      definition  = expr

      @DECL = seq__(declaration, '=', definition, comment.maybe) do |(decl,_,expr)|
        id, params = decl
        puts "decl: #{id} #{params} = (#{expr})" if DEBUG_PARSER
        ASTDecl.new(id, listify(params), expr)
      end
    end
    @DECL
  end

  def symbollist
    if @SYMBOLLIST.nil?
      symbols = (seq_(FUNCTION_SYMBOL, /,/.r, lazy { symbols }) { |(x,_,xs)| [x,xs] } \
                | FUNCTION_SYMBOL \
                )
      symbol_list = ( seq_(LIST_BEGIN, symbols, LIST_END, skip: CSPACE._?) { |(_,l,_)|
                        list = listify(l)
                        puts "Symbollist:[#{list.join(',')}]" if DEBUG_PARSER
                        ASTSymbolListLiteral.new(list)
                      } \
                    | seq__(LIST_BEGIN, LIST_END) { |(_,_)|
                        puts "Symbollist:[]" if DEBUG_PARSER
                        ASTSymbolListLiteral.new([])
                      } \
                    )
      @SYMBOLLIST = symbol_list.fail "symbol_list"
    end
    @SYMBOLLIST
  end

  def setliteral
    if @SETLITERAL.nil?
      setliterals = (seq__(SET_ELEMENT, /,/.r, lazy { setliterals }) { |(x,_,xs)| [x,xs] } \
                | SET_ELEMENT \
                )
      set = ( seq_(SET_BEGIN, setliterals, SET_END, skip: CSPACE._?) { |(_,l,_)|
                list = listify(l).to_set
                puts "Set:{#{list.to_a.join(',')}}" if DEBUG_PARSER
                ASTSetLiteral.new(list)
              } \
            | seq__(SET_BEGIN, SET_END) { |(_,_)|
                puts "Set:{}" if DEBUG_PARSER
                ASTSetLiteral.new([].to_set)
              } \
            )
      @SETLITERAL = set.fail "set_literal"
    end
    @SETLITERAL
  end

  def listify(astlist)
    if astlist.nil?
      astlist = []
    elsif !astlist.respond_to?(:flatten)
      astlist = [astlist]
    else
      astlist = astlist.flatten
    end
    astlist
  end

  def program
    program = (seq_(comment, lazy { program }, skip: /[\r\n]+/.r) { |(_,p,_)|
                  puts "Program variant 1: comment + program" if DEBUG_PARSER
                  p
                } \
              | seq_(decl, lazy { program }, skip: /[\r\n]+/.r) { |(d,p)|
                  puts "Program variant 2: decl + program" if DEBUG_PARSER
                  [d,p]
                } \
              | seq_(decl, /[\r\n]+/.r.maybe) { |(d, _)|
                  puts "Program variant 3: plain decl: #{d}" if DEBUG_PARSER
                  [d]
                } \
              )
    seq(/[\r\n]+/.r.maybe, program, /[\r\n]+/.r.maybe).eof { |(_,p,_)|
          ASTProgram.new(p.flatten)
        } \
      | /[\r\n]*/.r.maybe.eof { ASTProgram.new([]) }
  end
end # class Parser

def self.define_builtins(context)
  build_decl = lambda do |id, types, code|
    params   = types.each_with_index.map {|t,i| Peaches::ASTIdentifier.new("tmp#{t}#{i}")}
    expr     = Peaches::ASTBuiltinOperation.new(id, params, types, code)
    decl     = Peaches::ASTDecl.new(Peaches::ASTIdentifier.new(id), params, expr)
    context.insert(id, decl)
  end
  build_decl.call("set_min", [:set], lambda { |(set)|
    if set.empty?
      raise Peaches::PeachesArgumentError, "set_min called on empty set"
    else
      min = set.map{|(x)| x.unbox}.min
      ASTNumberLiteral.new(min)
    end
  })
  build_decl.call("set_max", [:set], lambda { |(set)|
    if set.empty?
      raise Peaches::PeachesArgumentError, "set_max called on empty set"
    else
      max = set.map{|(x)| x.unbox}.max
      ASTNumberLiteral.new(max)
    end
  })
  context
end

def self.build_context(program)
  # Parse the program
  parser = Peaches::Parser.new
  ast = parser.program.eof.parse! program
  Rsec::Fail.reset

  # Build the default context (with builtins)
  context = Peaches::Context.new
  define_builtins(context)

  # Check references
  rfv = Peaches::ReferenceCheckingVisitor.new(context = context)
  # Errors if recursion is found. Ensures termination
  rfv.check_references(ast)

  # Rebuild the default context (with builtins)
  context = Peaches::Context.new
  define_builtins(context)
  # Evaluate the context as far as possible
  context = ast.evaluate(context)
  context
end

def self.evaluate_expression(context, expr, type)
  case type
  when :boolean
    types      = [:boolean]
    exprparser = :expr
  when :number
    types      = [:number]
    exprparser = :expr
  else
    raise Peaches::PeachesTypeError, "Unknown expression type: #{type}"
  end
  parser = Peaches::Parser.new
  ast    = parser.send(exprparser).eof.parse!(expr)
  Rsec::Fail.reset
  ASTExpr.assert_full_eval(ast, context, types).unbox
end

end # module Peaches

if __FILE__ == $PROGRAM_NAME
  parser = Peaches::Parser.new

  assert_literal_context = lambda { |var, value, context|
    decl = context.lookup(var)
    unless decl.is_a?(Peaches::ASTDecl) &&
           decl.expr.is_a?(Peaches::ASTLiteral) &&
           decl.expr.unbox == value
      raise <<-EOF
        ############## TEST FAILURE ##############
        #{program}
        ##########################################
        #{decl.expr} /= #{value}
        ##########################################
      EOF
    end
  }

  assert_literal = lambda { |program, var, value, context=Peaches::Context.new|
    bindings = program.evaluate(context)
    assert_literal_context.call(var, value, bindings)
  }

  puts "Running Tests..."
  # rubocop:disable Layout/EmptyLinesAroundArguments
  parser.expr.eof.parse! "[]"
  parser.expr.eof.parse! "[ a ]"
  parser.expr.eof.parse! "[a]"
  parser.expr.eof.parse! "[a, b]"
  parser.expr.eof.parse! "[a,b]"
  parser.expr.eof.parse! "[sched.c:endless]"

  parser.setliteral.eof.parse! "{}"
  parser.setliteral.eof.parse! "{1}"
  parser.setliteral.eof.parse! "{1,23, 4}"
  parser.setliteral.eof.parse! "{123,2,123,1}"
  parser.expr.eof.parse! "{1, 2, 3, 4, 42}"
  parser.program.eof.parse! "s = {1, 2, 3, 4, 42}"
  parser.decl.eof.parse! "s = {1, 2, 3, 4, 42}"
  parser.program.eof.parse! %[
s = {1, 2, 3, 4, 42}
y = set_min s
]

  parser.expr.eof.parse! "ASDF > 0 || True"

  parser.expr.eof.parse! "a * b"
  parser.program.eof.parse! "f a b = a * b"
  parser.program.eof.parse! "f a b = if 2 /= 4 then a * b else b"

  parser.arith_expr.eof.parse! "f"

  parser.arith_expr.eof.parse! "hugo4"
  parser.arith_expr.eof.parse! "42 - 8 * 4*25 + 20 - 32"
  parser.arith_expr.eof.parse! "2*42 - 8 * 4*25 + 20 - 32"
  parser.arith_expr.eof.parse! "4 + 25 * 8"

  parser.cond_expr.eof.parse! "(32 - 1) /= 42"
  parser.cond_expr.eof.parse! "(4 /= 5)"
  parser.cond_expr.eof.parse! "(4 /= 5) && ((32 - 1) /= 42)"
  parser.cond_expr.eof.parse! "4 /= 5 && 32 - 1 /= 42"

  parser.expr.eof.parse! "if 4 /= 5 then 42 else 21"
  parser.expr.eof.parse! "BUFSIZE >= 10"

  parser.decl.eof.parse! "x = if 4 /= 5 then 42 else 21"
  parser.decl.eof.parse! "f x y = if 4 /= 5 then 42 else 21"

  parser.program.eof.parse! %[x = 4
y = 10 * x + 20
f a b = if 2 /= 4 || (10 / 2 == 5) then a + b else a * b
]

  parser.program.eof.parse! %[x = 4
y = 10 * x + 20
f a b = if 2 /= 4 || (10 / 2 == 5) then a + b else a * b]

  parser.program.eof.parse! %[x = 4
y = 10 * x + 20 {-
  ASDF
-}
f a b = if 2 /= 4 || (10 / 2 == 5) then a + b else a * b]

  parser.comment.parse! "{- asdf -}"
  parser.comment.parse! "-- ASDF ASDF"
  parser.comment.eof.parse! "-- ASDF ASDF"
  parser.space.parse! " {- asdf -}"

  parser.program.eof.parse! "x = 1 + {- asdf -} 4"
  parser.program.eof.parse! "x = 1 +{- asdf -}4"
  parser.program.eof.parse! "x = 1 + 4 -- asdf"

  program = parser.program.parse! %[x = 4
y = 10 * x + 20
z = if y > 10 && 1 /= 2 then x else y]
  assert_literal.call(program, "z", 4)

  program = parser.call.parse! "f 4*5 42"
  program = parser.call.parse! "f"

  program = parser.program.parse! %[-- Full size comment
x ={- "ASDF" -} 4
y = 10 * x + 20 -- ASDF 4 + 5
z = if y > 10 && 1 /= 2 then{-ASDF-} x else y]
  assert_literal.call(program, "z", 4)

  program = parser.program.parse! %[-- Full size comment
x ={- "ASDF" -} 4
y = 10 * x + 20 -- ASDF 4 + 5
z = if y > 10 && 1 /= 2 then x else f y]
  assert_literal.call(program, "z", 4)

  parser.program.parse! %[-- Full size comment
x ={- "ASDF" -} 4


y = 10 * x + 20 -- ASDF 4 + 5


z = if y > 10 && 1 /= 2 then x else f y

]

  program = parser.program.parse! %[-- Full size comment
x ={- "ASDF" -} 4
y = 10 * x + 20 -- ASDF 4 + 5
f = f x]
  rfv = Peaches::ReferenceCheckingVisitor.new
  begin
    rfv.check_references(program)
    raise "#{program}\nFailed to trigger an exception"
  rescue Peaches::PeachesBindingError => pbe
  end

  parser.program.parse! "z = if y > 10 && 1 /= 2 then x else (f (y) z)"

  parser.program.parse! %[x = 4
y = 10 * x + 20
z = if y > 10 && 1 /= 2 then x else f + 4
a = 3
]

  parser.program.parse! %[z = f x
a = 3]

  program = parser.program.parse! %[f x = x + 4
y = f 5
]
  assert_literal.call(program, "y", 9)

  program = parser.program.parse! %[
f x = x + 4
y = f 5
]
  assert_literal.call(program, "y", 9)

  program = parser.program.parse! %[
not x = if x == 0 then 1 else 0
y = not 1
]
  assert_literal.call(program, "y", 0)

  program = parser.program.parse! %[
f g a b = g (a) b
max x y = if x < y then y else x
y = f (max) 4 5
]
  assert_literal.call(program, "y", 5)

  program = parser.program.parse! %[
not x = if x == True then False else True
y = not True
]
  assert_literal.call(program, "y", false)

  program = parser.program.parse! "y = 4 - 3 + 3 - 3*4 + 8"
  assert_literal.call(program, "y", 0)

  program = parser.program.parse! "y = [a, b, sched.c:endless]"
  assert_literal.call(program, "y", ["a", "b", "sched_c_endless"])

  program = parser.program.parse! "y = {1, 42}"
  assert_literal.call(program, "y", \
        [Peaches::ASTNumberLiteral.new(1),Peaches::ASTNumberLiteral.new(42)].to_set)

  context = Peaches::build_context("y = set_min {1, 42}")
  assert_literal_context.call("y", 1, context=context)

  context = Peaches::build_context("y = set_max {1, 42}")
  assert_literal_context.call("y", 42, context=context)

  #context = Peaches::build_context("s = {1, 2, 3, 4, 42}\ny = set_max s")
  #assert_literal_context.call("y", 42, context=context)
 # rubocop:enable Layout/EmptyLinesAroundArguments

  puts "All tests were successful"
end
