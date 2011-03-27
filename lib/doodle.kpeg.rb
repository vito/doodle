class Doodle::Parser
# STANDALONE START
    def setup_parser(str, debug=false)
      @string = str
      @pos = 0
      @memoizations = Hash.new { |h,k| h[k] = {} }
      @result = nil
      @failed_rule = nil
      @failing_rule_offset = -1

      setup_foreign_grammar
    end

    def setup_foreign_grammar
    end

    # This is distinct from setup_parser so that a standalone parser
    # can redefine #initialize and still have access to the proper
    # parser setup code.
    #
    def initialize(str, debug=false)
      setup_parser(str, debug)
    end

    attr_reader :string
    attr_reader :result, :failing_rule_offset
    attr_accessor :pos

    # STANDALONE START
    def current_column(target=pos)
      if c = string.rindex("\n", target-1)
        return target - c - 1
      end

      target + 1
    end

    def current_line(target=pos)
      cur_offset = 0
      cur_line = 0

      string.each_line do |line|
        cur_line += 1
        cur_offset += line.size
        return cur_line if cur_offset >= target
      end

      -1
    end

    def lines
      lines = []
      string.each_line { |l| lines << l }
      lines
    end

    #

    def get_text(start)
      @string[start..@pos-1]
    end

    def show_pos
      width = 10
      if @pos < width
        "#{@pos} (\"#{@string[0,@pos]}\" @ \"#{@string[@pos,width]}\")"
      else
        "#{@pos} (\"... #{@string[@pos - width, width]}\" @ \"#{@string[@pos,width]}\")"
      end
    end

    def failure_info
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        "line #{l}, column #{c}: failed rule '#{info.name}' = '#{info.rendered}'"
      else
        "line #{l}, column #{c}: failed rule '#{@failed_rule}'"
      end
    end

    def failure_caret
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      line = lines[l-1]
      "#{line}\n#{' ' * (c - 1)}^"
    end

    def failure_character
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset
      lines[l-1][c-1, 1]
    end

    def failure_oneline
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      char = lines[l-1][c-1, 1]

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        "@#{l}:#{c} failed rule '#{info.name}', got '#{char}'"
      else
        "@#{l}:#{c} failed rule '#{@failed_rule}', got '#{char}'"
      end
    end

    class ParseError < RuntimeError
    end

    def raise_error
      raise ParseError, failure_oneline
    end

    def show_error(io=STDOUT)
      error_pos = @failing_rule_offset
      line_no = current_line(error_pos)
      col_no = current_column(error_pos)

      io.puts "On line #{line_no}, column #{col_no}:"

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        io.puts "Failed to match '#{info.rendered}' (rule '#{info.name}')"
      else
        io.puts "Failed to match rule '#{@failed_rule}'"
      end

      io.puts "Got: #{string[error_pos,1].inspect}"
      line = lines[line_no-1]
      io.puts "=> #{line}"
      io.print(" " * (col_no + 3))
      io.puts "^"
    end

    def set_failed_rule(name)
      if @pos > @failing_rule_offset
        @failed_rule = name
        @failing_rule_offset = @pos
      end
    end

    attr_reader :failed_rule

    def match_string(str)
      len = str.size
      if @string[pos,len] == str
        @pos += len
        return str
      end

      return nil
    end

    def scan(reg)
      if m = reg.match(@string[@pos..-1])
        width = m.end(0)
        @pos += width
        return true
      end

      return nil
    end

    if "".respond_to? :getbyte
      def get_byte
        if @pos >= @string.size
          return nil
        end

        s = @string.getbyte @pos
        @pos += 1
        s
      end
    else
      def get_byte
        if @pos >= @string.size
          return nil
        end

        s = @string[@pos]
        @pos += 1
        s
      end
    end

    def parse
      _root ? true : false
    end

    class LeftRecursive
      def initialize(detected=false)
        @detected = detected
      end

      attr_accessor :detected
    end

    class MemoEntry
      def initialize(ans, pos)
        @ans = ans
        @pos = pos
        @uses = 1
        @result = nil
      end

      attr_reader :ans, :pos, :uses, :result

      def inc!
        @uses += 1
      end

      def move!(ans, pos, result)
        @ans = ans
        @pos = pos
        @result = result
      end
    end

    def external_invoke(other, rule, *args)
      old_pos = @pos
      old_string = @string

      @pos = other.pos
      @string = other.string

      begin
        if val = __send__(rule, *args)
          other.pos = @pos
        else
          other.set_failed_rule "#{self.class}##{rule}"
        end
        val
      ensure
        @pos = old_pos
        @string = old_string
      end
    end

    def apply(rule)
      if m = @memoizations[rule][@pos]
        m.inc!

        prev = @pos
        @pos = m.pos
        if m.ans.kind_of? LeftRecursive
          m.ans.detected = true
          return nil
        end

        @result = m.result

        return m.ans
      else
        lr = LeftRecursive.new(false)
        m = MemoEntry.new(lr, @pos)
        @memoizations[rule][@pos] = m
        start_pos = @pos

        ans = __send__ rule

        m.move! ans, @pos, @result

        # Don't bother trying to grow the left recursion
        # if it's failing straight away (thus there is no seed)
        if ans and lr.detected
          return grow_lr(rule, start_pos, m)
        else
          return ans
        end

        return ans
      end
    end

    def grow_lr(rule, start_pos, m)
      while true
        @pos = start_pos
        @result = m.result

        ans = __send__ rule
        return nil unless ans

        break if @pos <= m.pos

        m.move! ans, @pos, @result
      end

      @result = m.result
      @pos = m.pos
      return m.ans
    end

    class RuleInfo
      def initialize(name, rendered)
        @name = name
        @rendered = rendered
      end

      attr_reader :name, :rendered
    end

    def self.rule_info(name, rendered)
      RuleInfo.new(name, rendered)
    end

    #


    def trim_leading(str, n)
      return str unless n > 0
      str.gsub!(/\n {0,#{n.to_s}}/, "\n")
    end


  def setup_foreign_grammar; end

  # line = { current_line }
  def _line
    @result = begin;  current_line ; end
    _tmp = true
    set_failed_rule :_line unless _tmp
    return _tmp
  end

  # column = { current_column }
  def _column
    @result = begin;  current_column ; end
    _tmp = true
    set_failed_rule :_column unless _tmp
    return _tmp
  end

  # ident_start = < /[a-z_]/ > { text }
  def _ident_start

    _save = self.pos
    while true # sequence
    _text_start = self.pos
    _tmp = scan(/\A(?-mix:[a-z_])/)
    if _tmp
      text = get_text(_text_start)
    end
    unless _tmp
      self.pos = _save
      break
    end
    @result = begin;  text ; end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_ident_start unless _tmp
    return _tmp
  end

  # ident_letters = < /([[:alnum:]\$\+\<=\>\^~!@#%&*\-.\/\?])*/ > { text }
  def _ident_letters

    _save = self.pos
    while true # sequence
    _text_start = self.pos
    _tmp = scan(/\A(?-mix:([[:alnum:]\$\+\<=\>\^~!@#%&*\-.\/\?])*)/)
    if _tmp
      text = get_text(_text_start)
    end
    unless _tmp
      self.pos = _save
      break
    end
    @result = begin;  text ; end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_ident_letters unless _tmp
    return _tmp
  end

  # identifier = < ident_start ident_letters > { text.tr("-", "_") }
  def _identifier

    _save = self.pos
    while true # sequence
    _text_start = self.pos

    _save1 = self.pos
    while true # sequence
    _tmp = apply(:_ident_start)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = apply(:_ident_letters)
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    if _tmp
      text = get_text(_text_start)
    end
    unless _tmp
      self.pos = _save
      break
    end
    @result = begin;  text.tr("-", "_") ; end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_identifier unless _tmp
    return _tmp
  end

  # comment = "{-" in_multi
  def _comment

    _save = self.pos
    while true # sequence
    _tmp = match_string("{-")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_in_multi)
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_comment unless _tmp
    return _tmp
  end

  # in_multi = (/[^\-\{\}]*/ "-}" | /[^\-\{\}]*/ "{-" in_multi /[^\-\{\}]*/ "-}" | /[^\-\{\}]*/ /[-{}]/ in_multi)
  def _in_multi

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = scan(/\A(?-mix:[^\-\{\}]*)/)
    unless _tmp
      self.pos = _save1
      break
    end
    _tmp = match_string("-}")
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save2 = self.pos
    while true # sequence
    _tmp = scan(/\A(?-mix:[^\-\{\}]*)/)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = match_string("{-")
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = apply(:_in_multi)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = scan(/\A(?-mix:[^\-\{\}]*)/)
    unless _tmp
      self.pos = _save2
      break
    end
    _tmp = match_string("-}")
    unless _tmp
      self.pos = _save2
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save

    _save3 = self.pos
    while true # sequence
    _tmp = scan(/\A(?-mix:[^\-\{\}]*)/)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = scan(/\A(?-mix:[-{}])/)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_in_multi)
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_in_multi unless _tmp
    return _tmp
  end

  # content = comment? (chunk(s) | escaped):c comment? { c }
  def _content(s)

    _save = self.pos
    while true # sequence
    _save1 = self.pos
    _tmp = apply(:_comment)
    unless _tmp
      _tmp = true
      self.pos = _save1
    end
    unless _tmp
      self.pos = _save
      break
    end

    _save2 = self.pos
    while true # choice
    _tmp = _chunk(s)
    break if _tmp
    self.pos = _save2
    _tmp = apply(:_escaped)
    break if _tmp
    self.pos = _save2
    break
    end # end choice

    c = @result
    unless _tmp
      self.pos = _save
      break
    end
    _save3 = self.pos
    _tmp = apply(:_comment)
    unless _tmp
      _tmp = true
      self.pos = _save3
    end
    unless _tmp
      self.pos = _save
      break
    end
    @result = begin;  c ; end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_content unless _tmp
    return _tmp
  end

  # chunk = (line:l ((< /[^\\\{\}]/+ > | "\\" < /[\\\{\}]/ >) { text })+:chunk (&"}" | comment)?:c { text = chunk.join                       text.rstrip! if c                       trim_leading(text, s)                       Doodle::AST::Chunk.new(l, text)                     } | nested)
  def _chunk(s)

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _tmp = apply(:_line)
    l = @result
    unless _tmp
      self.pos = _save1
      break
    end
    _save2 = self.pos
    _ary = []

    _save3 = self.pos
    while true # sequence

    _save4 = self.pos
    while true # choice
    _text_start = self.pos
    _save5 = self.pos
    _tmp = scan(/\A(?-mix:[^\\\{\}])/)
    if _tmp
      while true
        _tmp = scan(/\A(?-mix:[^\\\{\}])/)
        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save5
    end
    if _tmp
      text = get_text(_text_start)
    end
    break if _tmp
    self.pos = _save4

    _save6 = self.pos
    while true # sequence
    _tmp = match_string("\\")
    unless _tmp
      self.pos = _save6
      break
    end
    _text_start = self.pos
    _tmp = scan(/\A(?-mix:[\\\{\}])/)
    if _tmp
      text = get_text(_text_start)
    end
    unless _tmp
      self.pos = _save6
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save4
    break
    end # end choice

    unless _tmp
      self.pos = _save3
      break
    end
    @result = begin;  text ; end
    _tmp = true
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    if _tmp
      _ary << @result
      while true
    
    _save7 = self.pos
    while true # sequence

    _save8 = self.pos
    while true # choice
    _text_start = self.pos
    _save9 = self.pos
    _tmp = scan(/\A(?-mix:[^\\\{\}])/)
    if _tmp
      while true
        _tmp = scan(/\A(?-mix:[^\\\{\}])/)
        break unless _tmp
      end
      _tmp = true
    else
      self.pos = _save9
    end
    if _tmp
      text = get_text(_text_start)
    end
    break if _tmp
    self.pos = _save8

    _save10 = self.pos
    while true # sequence
    _tmp = match_string("\\")
    unless _tmp
      self.pos = _save10
      break
    end
    _text_start = self.pos
    _tmp = scan(/\A(?-mix:[\\\{\}])/)
    if _tmp
      text = get_text(_text_start)
    end
    unless _tmp
      self.pos = _save10
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save8
    break
    end # end choice

    unless _tmp
      self.pos = _save7
      break
    end
    @result = begin;  text ; end
    _tmp = true
    unless _tmp
      self.pos = _save7
    end
    break
    end # end sequence

        _ary << @result if _tmp
        break unless _tmp
      end
      _tmp = true
      @result = _ary
    else
      self.pos = _save2
    end
    chunk = @result
    unless _tmp
      self.pos = _save1
      break
    end
    _save11 = self.pos

    _save12 = self.pos
    while true # choice
    _save13 = self.pos
    _tmp = match_string("}")
    self.pos = _save13
    break if _tmp
    self.pos = _save12
    _tmp = apply(:_comment)
    break if _tmp
    self.pos = _save12
    break
    end # end choice

    @result = nil unless _tmp
    unless _tmp
      _tmp = true
      self.pos = _save11
    end
    c = @result
    unless _tmp
      self.pos = _save1
      break
    end
    @result = begin;  text = chunk.join
                      text.rstrip! if c
                      trim_leading(text, s)
                      Doodle::AST::Chunk.new(l, text)
                    ; end
    _tmp = true
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    _tmp = apply(:_nested)
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_chunk unless _tmp
    return _tmp
  end

  # escaped = line:l "\\" identifier:n argument*:as { Doodle::AST::Send.new(l, n, as) }
  def _escaped

    _save = self.pos
    while true # sequence
    _tmp = apply(:_line)
    l = @result
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("\\")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_identifier)
    n = @result
    unless _tmp
      self.pos = _save
      break
    end
    _ary = []
    while true
    _tmp = apply(:_argument)
    _ary << @result if _tmp
    break unless _tmp
    end
    _tmp = true
    @result = _ary
    as = @result
    unless _tmp
      self.pos = _save
      break
    end
    @result = begin;  Doodle::AST::Send.new(l, n, as) ; end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_escaped unless _tmp
    return _tmp
  end

  # leading = (&(/\n+/ column:b /\s+/ column:a) { a - b } | { 0 })
  def _leading

    _save = self.pos
    while true # choice

    _save1 = self.pos
    while true # sequence
    _save2 = self.pos

    _save3 = self.pos
    while true # sequence
    _tmp = scan(/\A(?-mix:\n+)/)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_column)
    b = @result
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = scan(/\A(?-mix:\s+)/)
    unless _tmp
      self.pos = _save3
      break
    end
    _tmp = apply(:_column)
    a = @result
    unless _tmp
      self.pos = _save3
    end
    break
    end # end sequence

    self.pos = _save2
    unless _tmp
      self.pos = _save1
      break
    end
    @result = begin;  a - b ; end
    _tmp = true
    unless _tmp
      self.pos = _save1
    end
    break
    end # end sequence

    break if _tmp
    self.pos = _save
    @result = begin;  0 ; end
    _tmp = true
    break if _tmp
    self.pos = _save
    break
    end # end choice

    set_failed_rule :_leading unless _tmp
    return _tmp
  end

  # nested = line:l "{" leading:s content(s)*:cs "}" { case cs[0]                       when Doodle::AST::Chunk                         cs[0].content.sub!(/^\n/, "")                       end                        Doodle::AST::Tree.new(l, cs)                     }
  def _nested

    _save = self.pos
    while true # sequence
    _tmp = apply(:_line)
    l = @result
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("{")
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = apply(:_leading)
    s = @result
    unless _tmp
      self.pos = _save
      break
    end
    _ary = []
    while true
    _tmp = _content(s)
    _ary << @result if _tmp
    break unless _tmp
    end
    _tmp = true
    @result = _ary
    cs = @result
    unless _tmp
      self.pos = _save
      break
    end
    _tmp = match_string("}")
    unless _tmp
      self.pos = _save
      break
    end
    @result = begin;  case cs[0]
                      when Doodle::AST::Chunk
                        cs[0].content.sub!(/^\n/, "")
                      end

                      Doodle::AST::Tree.new(l, cs)
                    ; end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_nested unless _tmp
    return _tmp
  end

  # argument = nested
  def _argument
    _tmp = apply(:_nested)
    set_failed_rule :_argument unless _tmp
    return _tmp
  end

  # root = line:l content(0)*:cs !. { Doodle::AST::Tree.new(l, cs) }
  def _root

    _save = self.pos
    while true # sequence
    _tmp = apply(:_line)
    l = @result
    unless _tmp
      self.pos = _save
      break
    end
    _ary = []
    while true
    _tmp = _content(0)
    _ary << @result if _tmp
    break unless _tmp
    end
    _tmp = true
    @result = _ary
    cs = @result
    unless _tmp
      self.pos = _save
      break
    end
    _save2 = self.pos
    _tmp = get_byte
    _tmp = _tmp ? nil : true
    self.pos = _save2
    unless _tmp
      self.pos = _save
      break
    end
    @result = begin;  Doodle::AST::Tree.new(l, cs) ; end
    _tmp = true
    unless _tmp
      self.pos = _save
    end
    break
    end # end sequence

    set_failed_rule :_root unless _tmp
    return _tmp
  end

  Rules = {}
  Rules[:_line] = rule_info("line", "{ current_line }")
  Rules[:_column] = rule_info("column", "{ current_column }")
  Rules[:_ident_start] = rule_info("ident_start", "< /[a-z_]/ > { text }")
  Rules[:_ident_letters] = rule_info("ident_letters", "< /([[:alnum:]\\$\\+\\<=\\>\\^~!@#%&*\\-.\\/\\?])*/ > { text }")
  Rules[:_identifier] = rule_info("identifier", "< ident_start ident_letters > { text.tr(\"-\", \"_\") }")
  Rules[:_comment] = rule_info("comment", "\"{-\" in_multi")
  Rules[:_in_multi] = rule_info("in_multi", "(/[^\\-\\{\\}]*/ \"-}\" | /[^\\-\\{\\}]*/ \"{-\" in_multi /[^\\-\\{\\}]*/ \"-}\" | /[^\\-\\{\\}]*/ /[-{}]/ in_multi)")
  Rules[:_content] = rule_info("content", "comment? (chunk(s) | escaped):c comment? { c }")
  Rules[:_chunk] = rule_info("chunk", "(line:l ((< /[^\\\\\\{\\}]/+ > | \"\\\\\" < /[\\\\\\{\\}]/ >) { text })+:chunk (&\"}\" | comment)?:c { text = chunk.join                       text.rstrip! if c                       trim_leading(text, s)                       Doodle::AST::Chunk.new(l, text)                     } | nested)")
  Rules[:_escaped] = rule_info("escaped", "line:l \"\\\\\" identifier:n argument*:as { Doodle::AST::Send.new(l, n, as) }")
  Rules[:_leading] = rule_info("leading", "(&(/\\n+/ column:b /\\s+/ column:a) { a - b } | { 0 })")
  Rules[:_nested] = rule_info("nested", "line:l \"{\" leading:s content(s)*:cs \"}\" { case cs[0]                       when Doodle::AST::Chunk                         cs[0].content.sub!(/^\\n/, \"\")                       end                        Doodle::AST::Tree.new(l, cs)                     }")
  Rules[:_argument] = rule_info("argument", "nested")
  Rules[:_root] = rule_info("root", "line:l content(0)*:cs !. { Doodle::AST::Tree.new(l, cs) }")
end
