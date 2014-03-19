module Bpl
  module AST
    class Trace
      attr_accessor :src_file
      attr_accessor :steps
      
      def initialize(trace_file, program, model)
        @program = program
        @model = model
        @steps = []

        lines = File.read(trace_file).lines
        lines.shift until lines.first =~ /Execution trace:/

        num_blocks = 0

        while lines.first !~ /Boogie program verifier finished/
          line = lines.shift
          next if line.empty?  
  
          line.match /([^\s]+)\((\d+),(\d+)\): ([^\s]+)/ do |m|
            src_file, line, col, label = m[1], m[2].to_i, m[3].to_i, m[4]
            src_file = File.join(File.dirname(trace_file), src_file)
    
            case label
            when /Entry/, /Return/
            else
              block = get_block(src_file,line-1)
              proc = get_proc(src_file,line-1)
              @steps << {file: src_file, line: line, col: col, proc: proc, label: label, block: block}
            end
          end
        end        
      end
      
      def to_s
        gs = @program.global_variables.map{|g| g.names}.flatten
        num_steps_shown = 0

        ("-" * 80) +
        @model.constants * "\n" + "\n" +
        @model.functions * "\n" + "\n" +
        ("-" * 80) + "\n" +
        steps = @steps.map.with_index do |step,i|
          vars = @model.variables(i).select{|v| gs.include?(v.name)}
          next if vars.empty?
          num_steps_shown += 1
          "step #{i} / line #{step[:line]} / proc #{step[:proc]} / label #{step[:label]}\n" +
          ("-" * 80) + "\n" +
          "#{vars.map{|v| "  var #{v.name} = #{v.value}"} * "\n"}" + "\n" +
          "\n" +
          step[:block].first(10).join +
          (step[:block].count > 10 ? "  ...\n" : "") +
          ("-" * 80)
        end.compact * "\n" +
        "(#{@steps.count - num_steps_shown} steps omitted)"
      end

      def svg_craziness
      end
    end
  end
end

def get_proc(file, line)
  File.read(file).lines.take(line).grep(/\bprocedure\b/).last.sub(/[^\(\)]*\s+([^ \(\){}:]+)\s*\(.*/,'\1').strip
end

def get_block(file, line)
  lines = File.read(file).lines.drop(line)
  lines.take_while{|l| l !~ /^  (goto|return)/} +
  [lines.detect{|l| l =~ /^  (goto|return)/}]
end
