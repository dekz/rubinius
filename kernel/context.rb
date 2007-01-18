
# Hey! Be careful with this! This is used by backtrace and if it doesn't work,
# you can get recursive exceptions being raise (THATS BAD, BTW).
class MethodContext
  def self.current
    cur = nil
    Ruby.asm "push_context\nset cur\n"
    return cur.sender
  end
  
  def sender
    Ruby.primitive :context_sender
    # We use a primitive here so that the underside is aware that
    # we're pulling a methodcontext into the normal fraw. Currently
    # this means that it can't be reused automatically.
  end
  
  def to_s
    "#<#{self.class}:0x#{self.object_id.to_s(16)} #{receiver}##{name} #{file}:#{line}>"
  end
  
  def file
    return "(unknown)" unless self.method
    method.file
  end
  
  def lines
    return [] unless self.method
    method.lines
  end
  
  def line
    return 0 unless self.method
    # We subtract 1 because the ip is actually set to what it should do
    # next, not what it's currently doing.
    return self.method.line_from_ip(self.ip - 1)
  end
  
  def activate(val)
    Ruby.primitive :activate_context    
  end
  
  def copy(locals=false)
    d = self.dup
    return d unless locals
    
    i = 0
    lc = self.locals
    tot = lc.fields
    nl = Tuple.new(tot)
    while i < tot
      nl.put i, lc.at(i)
      i += 1
    end
    
    # d.put 10, nl
    
    return d
  end
end

class BlockContext
  def activate(val)
    Ruby.primitive :activate_context    
  end
  
  def name
    env.home.name
  end
  
  def receiver
    env.home.receiver
  end
  
  def file
    env.home.file
  end
  
  def line
    return 0 unless self.method
    # We subtract 1 because the ip is actually set to what it should do
    # next, not what it's currently doing.
    return self.method.line_from_ip(self.ip - 1)
  end

  def method
    env.home.method
  end
end

class BlockEnvironment
  def call(*args)
    if args.total == 1
      execute args[0]
    else
      execute args.tuple
    end
  end
  
  def execute(args)
    Ruby.primitive :block_call
  end
  
  # These should be safe since I'm unsure how you'd have a BlockContext
  # and have a nil CompiledMethod (something that can (and has) happened
  # with MethodContexts)
  
  def file
    self.home.method.file
  end
  
  def line
    self.home.method.line_from_ip(self.initial_ip)
  end
end

class Proc
  
  self.instance_fields = 3
  ivar_as_index :__ivars__ => 0, :block => 1, :check_args => 2

  class << self
    def from_environment(env, check_args=false)
      if env.nil?
        nil
      elsif env.respond_to? :to_proc
        env.to_proc
      elsif env.kind_of?(BlockEnvironment)
        obj = allocate()
        obj.put 1, env
        obj.put 2, check_args
        obj
      else
        raise ArgumentError.new("Unable to turn a #{env.inspect} into a Proc")
      end
    end
    
    def new(&block)
      return block
    end
    
    # Return the proc given to the currently running method or 
    # to the given MethodContext/Binding.
    #
    #   def bar(&prc)
    #      a = [prc.nil?, Proc.given.nil?]
    #      a << block_given? == !Proc.given.nil?
    #      if block_given?
    #         a << prc.object_id == Proc.given.object_id
    #         a << prc.block.object_id == Proc.given.block.object_id
    #         a << Proc.given.call(21)
    #      end
    #      a
    #   end
    #   
    #   bar()                 # => [true, true, true]
    #   bar() { |n| n * 2 }   # => [false, false, true, false, true, 42]
    #
    # An example mind trick using MethodContext.
    #
    #   def stormtrooper
    #      yield "Let me see your identification."
    #      obiwan { |reply| puts "Obi-Wan: #{reply}" }
    #   end
    #
    #   def obiwan
    #      yield "[with a small wave of his hand] You don't need to see his identification."
    #      ctx = MethodContext.current.sender
    #      Proc.given(ctx).call("We don't need to see his identification.")
    #   end
    #
    #   stormtrooper { |msg| puts "Stormtrooper: #{msg}" }
    #      
    # produces the following output:
    #
    #   Stormtrooper: Let me see your identification.
    #   Obi-Wan: [with a small wave of his hand] You don't need to see his identification.
    #   Stormtrooper: We don't need to see his identification
    #
    # Using a binging to obtain the given proc where the binding was created
    #
    #   def stormtrooper
    #      binding
    #   end
    #
    #   def obiwan(trick)
    #      yield "These aren't the droids you're looking for."
    #      trick.call("There aren't the droids we're looking for.")
    #      yield "He can go about his business."
    #      trick.call("You can go about your business.")
    #   end
    #
    #   trick = stormtrooper { |msg| puts "Stormtrooper: #{msg}" }
    #   obiwan(Proc.given(trick)) { |msg| puts "Obi-Wan: #{msg}" }
    #
    def given(ctx = nil)
      case ctx
      when nil
        ctx = MethodContext.current.sender.block
      when MethodContext
        ctx = ctx.block
        # when BlockEnvironment
        # when Binding
        # ctx = ctx.context
      end
      from_environment(ctx)
    end
  
  end
  
  def block
    @block
  end
  
  
  def inspect
    "#<#{self.class}:0x#{self.object_id.to_s(16)} @ #{self.block.file}:#{self.block.line}>"
  end

  def to_proc
    self
  end

  
  def call(*args)
    obj = at(1)
    raise "Corrupt proc detected!" unless obj
    obj.call(*args)
  end

end

class Backtrace
  def initialize
    @frames = []
  end
  
  def show
    fr2 = @frames.map do |ent|
      recv = ent[0]
      loc = ent[1]
      "    #{' ' * (@max - recv.size)}#{recv} at #{loc}"
    end
    return fr2.join("\n")
  end
  
  MAX_WIDTH = 40
  
  def fill_from(ctx)
    @max = 0
    while ctx
      if ctx.method
        if MAIN == ctx.receiver
          str = "#{ctx.receiver.to_s}."
        elsif Module === ctx.receiver
          str = "#{ctx.receiver}."
        else
          str = "#{ctx.receiver.class}#"
        end
        if ctx.name == ctx.method.name
          str << "#{ctx.name}"
        else
          str << "#{ctx.name} (#{ctx.method.name})"
        end
        
        if str.size > @max
          @max = str.size
        end
        
        @frames << [str, "#{ctx.file}:#{ctx.line}"]
      end
      ctx = ctx.sender
    end
    @max = MAX_WIDTH if @max > MAX_WIDTH
  end
  
  def self.backtrace(ctx=nil)
    obj = new()
    unless ctx
      ctx = MethodContext.current.sender
    end
    obj.fill_from ctx
    return obj
  end
end
