#!/usr/bin/env ruby

require 'set'
require 'optparse'
require_relative 'c2s/version'

begin
  require 'colorize'
rescue LoadError
  class String
    def yellow; self end
    def red; self end
    def green; self end
    def blue; self end
    def bold; self end
  end
end

$warnings = Set.new
$show_warnings = true
$verbose = false
$quiet = false
$keep = false

module Kernel
  
  alias :old_abort :abort
  
  def abort(str)
    old_abort("Error: #{str}".red)
  end

  def warn(*args)
    return unless $show_warnings
    args.each do |str|
      unless $warnings.include? str
        $stderr.puts "Warning: #{str}".yellow
        $warnings << str
      end
    end
  end

  def boogie
    ['Boogie','boogie','Boogie.exe','boogie.exe'].each do |b|
      return "#{b}" if not `which #{b}`.empty?
    end
    err "cannot find 'Boogie' in executable path."
  end  
  
  def bpl(str) BoogieLanguage.new.parse_str(str) end
  def bpl_type(str) BoogieLanguage.new.parse_type(str) end
end

class String
  def to_range
    case self
    when /\d+\.\.\d+/
      split(/\.\./).inject{|i,j| i.to_i..j.to_i}
    else
      to_i..to_i
    end
  end
end

def timed(desc = nil)
  time = Time.now
  res = yield if block_given?
  time = (Time.now - time).round(2)
  puts "#{desc} took #{time}s." if $verbose && desc
  res
end

OptionParser.new do |opts|
  @output_file = nil
  
  @resolution = true
  @type_checking = true
  @sequentialization = true
  @inspection = false
  @verification = true

  @monitor = nil

  @rounds = nil
  @delays = 0

  @verifier = :boogie_si
  @incremental = false
  @parallel = false
  @boogie_opts = []
  @timeout = nil
  @unroll = nil
  @graph = false

  opts.banner = "Usage: #{File.basename $0} [options] FILE(s)"
  
  opts.separator ""
  opts.separator "Basic options:"
  
  opts.on("-h", "--help", "Show this message") do
    puts opts
    exit
  end

  opts.on("--version", "Show version") do
    puts "#{File.basename $0} version #{C2S::VERSION || "??"}"
    exit
  end

  opts.on("-v", "--[no-]verbose", "Run verbosely? (default #{$verbose})") do |v|
    $verbose = v
    $quiet = !v
  end

  opts.on("-q", "--[no-]quiet", "Run quietly? (default #{$quiet})") do |q|
    $quiet = q
    $verbose = !q
  end

  opts.on("-w", "--[no-]warnings", "Show warnings? (default #{$show_warnings})") do |w|
    $show_warnings = w
  end

  opts.on("-k", "--[no-]keep-files", "Keep intermediate files? (default #{$keep})") do |v|
    $keep = v
  end
  
  opts.on("-o", "--output-file FILENAME") do |f|
    @output_file = f
  end

  opts.separator ""
  opts.separator "Staging options:"
  
  opts.on("--[no-]resolve", "Do identifier resolution? (default #{@resolution})") do |r|
    @resolution = r
  end
  
  opts.on("--[no-]type-check", "Do type checking? (default #{@type_checking})") do |r|
    @type_checking = r
  end
  
  opts.on("--[no-]sequentialize", "Do sequentialization? (default #{@sequentialization})") do |s|
    @sequentialization = s
  end
  
  opts.on("--[no-]verify", "Do verification? (default #{@verification})") do |v|
    @verification = v
  end
  
  opts.on("--[no-]inspect", "Inspect program? (default #{@inspection})") do |i|
    @inspection = i
  end    

  opts.separator ""
  opts.separator "Sequentialization options:"

  opts.on("-r", "--rounds MAX", Integer, "The rounds bound (default #{@delays+1})") do |r|
    @rounds = r 
  end

  opts.on("-d", "--delays MAX", Integer, "The delay bound (default #{@delays})") do |d|
    @delays = d
  end
  
  opts.separator ""
  opts.separator "Verifier options:"

  opts.on("--verifier NAME", [:boogie_si, :boogie_fi], 
          "Select verifier (default #{@verifier})") do |v|
    @verifier = v
  end

  opts.on("-i", "--incremental", "Incremental verification? (default #{@incremental})") do |i|
    @incremental = i
  end

  opts.on("-p", "--parallel", "Parallel verification? (default #{@parallel})") do |p|
    @parallel = p
  end

  opts.on("-t", "--timeout TIME", Integer, "Verifier timeout (default #{@timeout || "-"})") do |t|
    @boogie_opts << "/timeLimit:#{t}"
  end

  opts.on("-u", "--unroll MAX", Integer, "Loop/recursion bound (default #{@unroll || "-"})") do |u|
    @unroll = u
  end

  # TODO is this really a good idea?
  opts.separator ""
  opts.separator "Miscellaneous options:"
  
  opts.on("--monitor FILE", "Instrument with monitor FILE?") do |file|
    @monitor = file
  end
  
  # opts.on("-g", "--graph-of-trace", "generate a trace graph") do |g|
  #   @graph = g
  # end
end.parse!

puts "c2s version #{C2S::VERSION}, copyright (c) 2014, Michael Emmi".bold \
  unless @quiet

abort "Must specify a single source file." unless ARGV.size == 1
src = ARGV[0]
abort "Source file '#{src}' does not exist." unless File.exists?(src)

require_relative 'bpl/parser.tab'
require_relative 'bpl/analysis/resolution'
require_relative 'bpl/analysis/type_checking'
require_relative 'bpl/analysis/normalization'
require_relative 'bpl/analysis/vectorization'
require_relative 'bpl/analysis/df_sequentialization'
require_relative 'bpl/analysis/backend'
require_relative 'bpl/analysis/verification'
require_relative 'bpl/analysis/trace'
require_relative 'c2s/violin'
require_relative 'c2s/frontend'

begin
  require 'eventmachine'
rescue LoadError
  warn "Parallel verification requires the eventmachine gem; disabling."
  @parallel = false
end if @parallel

src = timed 'Front-end' do
  C2S::process_source_file(src)
end

program = timed 'Parsing' do
  BoogieLanguage.new.parse(File.read(src))
end

program.source_file = src

timed 'Resolution' do
  program.resolve!
end if @resolution

timed 'Type-checking' do
  program.type_check
end if @resolution && @type_checking

timed('Normalization') do
  program.normalize!
end if @sequentialization || @verification
 
# TODO is this really a good idea?
timed 'Monitor-instrumentation' do
  abort "Monitor file #{@monitor} does not exist." unless File.exists?(@monitor)
  C2S::violin_instrument! program, @monitor
  program.resolve!
  program.type_check
  program.normalize!
end if @monitor

if @sequentialization
  if program.any?{|e| e.attributes.include? :async}
    timed('Vectorization') {program.vectorize!}
    program.resolve!
    timed('Sequentialization') {program.df_sequentialize!}
  else
    warn "Skipping sequentialization as program does not have async calls."
  end
end

program.prepare_for_backend! @verifier

if @inspection
  timed 'Inspection' do
    program.resolve!
    puts program.inspect
    program.type_check
  end
end

timed('Writing to file') do
  File.write(@output_file,program)
end if @output_file

timed('Verification') do
  program.verify verifier: @verifier, \
    unroll: @unroll, rounds: (@rounds || @delays+1), delays: @delays, \
    incremental: @incremental, parallel: @parallel
end if @verification