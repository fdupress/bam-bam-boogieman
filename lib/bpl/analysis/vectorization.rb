
module Bpl
  module AST
    
    class Identifier
      def init; bpl "#{@name}.0" end
    end
    
    class VariableDeclaration
      def init; bpl "const #{@names.map{|g| "#{g}.0"} * ", "}: [int] #{@type};" end
    end
    
    class Program

      def vectorize!(rounds,delays)
        
        gs = global_variables.map{|d| d.idents}.flatten        
        return if gs.empty?
        
        @declarations << bpl("const #ROUNDS: int;")
        @declarations << bpl("const #DELAYS: int;")
        @declarations << bpl("axiom #ROUNDS == #{rounds};")
        @declarations << bpl("axiom #DELAYS == #{delays};")
        @declarations += global_variables.map(&:init)
        
        @declarations.each do |decl|
          case decl
          when VariableDeclaration
            decl.type = MapType.new(arguments: [], domain: [Type::Integer], range: decl.type)
            
          when ProcedureDeclaration
            
            if !decl.has_body? && !decl.modified_vars.empty?
              decl.parameters << bpl("#k: int")
              decl.modified_vars.each do |x|
                decl.specifications << 
                  bpl("ensures (forall k: int :: k != #k ==> #{x}[k] == old(#{x})[k]);")
              end
              decl.specifications.each do |spec|
                case spec
                when EnsuresClause, RequiresClause
                  spec.replace do |elem|
                    
                    if elem.is_a?(Identifier) && elem.is_variable? && elem.is_global? then
                      next bpl("#{elem}[#k]")
                    end
                    elem
                  end
                end
              end

            elsif decl.has_body? then
              decl.specifications << bpl("modifies #d;")
                  
              if decl.attributes.include? :entrypoint
                decl.body.declarations << bpl("var #k: int;")

              else
                decl.parameters << bpl("#k.0: int")
                decl.returns << bpl("#k: int")
                decl.body.statements.unshift bpl("call boogie_si_record_int(#k);")
                decl.body.statements.unshift bpl("#k := #k.0;")
              end

              decl.body.declarations << bpl("var #j: int;") \
                if decl.body.any?{|e| e.attributes.include? :yield}
                  
              decl.body.replace do |elem|
                case elem            
                when CallStatement
                  next elem unless elem.procedure.declaration
                  if elem.procedure.declaration.has_body?
                    elem.arguments << bpl("#k")
                    elem.assignments << bpl("#k")
                  elsif !elem.procedure.declaration.modified_vars.empty?
                    elem.arguments << bpl("#k")
                  end
                  elem

                when Identifier
                  if elem.is_variable? && elem.is_global? then
                    next bpl("#{elem}[#k]")
                  end

                when AssumeStatement
                  if elem.attributes.include? :yield then
                    
                    next bpl(<<-end
                      if (*) {
                        havoc #j;
                        assume #j >= 1;
                        assume #k + #j < #ROUNDS;
                        assume #d + #j <= #DELAYS;
                        #k := #k + #j;
                        #d := #d + #j;
                        call boogie_si_record_int(#k);
                      }
                    end
                    )
                    
                  elsif elem.attributes.include?(:startpoint)

                    next [ bpl("#d := 0;"),
                      bpl("#k := 0;"),
                      bpl("call boogie_si_record_int(#ROUNDS);"),
                      bpl("call boogie_si_record_int(#DELAYS);") ] +
                    gs.map{|g| bpl("#{g} := #{g.init};")} +
                    [elem]

                  elsif elem.attributes.include?(:endpoint)

                    next [elem] +
                    (1..rounds).map do |i|
                      gs.map{|g| bpl("assume #{g}[#{i-1}] == #{g.init}[#{i}];")}
                    end.flatten

                  end
                end
                elem
              end
            end
          end
        end

        @declarations << bpl("var #d: int;")

      end

    end
  end
end
