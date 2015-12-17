module Bpl
  class Extraction < Pass

    depends :loop_identification
    switch "--extraction", "Extract annotated loops."

    def fresh_id
      @id ||= 0
      @id += 1
    end

    def extract(condition, invariants, blocks, params, locals)
      id = fresh_id

      accs = blocks.collect do |b|
        b.select {|x| x.is_a?(StorageIdentifier)}
      end.flatten.uniq(&:name)

      mods = blocks.collect do |b|
        b.collect do |s|
          Modification.stmt_modifies(s) if s.is_a?(Statement)
        end.flatten
      end.flatten.compact.uniq(&:name)

      local_mods, global_mods = mods.partition {|x| locals.include?(x.name)}
      local_accs = accs.
        reject {|x| mods.any? {|y| x.name == y.name}}.
        select {|x| params.include?(x.name) || locals.include?(x.name)}

      exits = blocks.collect do |b|
        b.select do |x|
          x.is_a?(LabelIdentifier) &&
          blocks.none? {|bb| bb.names.include?(x.name)}
        end
      end.flatten.uniq(&:name)

      decl = bpl("procedure $loop.#{id}();")
      local_accs.each do |x|
        decl.append_children(:parameters,
          StorageDeclaration.new(names: [x.name], type: x.type))
      end
      local_mods.each do |x|
        decl.append_children(:parameters,
          StorageDeclaration.new(names: [x.name + ".0"], type: x.type))
        decl.append_children(:returns,
          StorageDeclaration.new(names: [x.name], type: x.type))
      end
      unless global_mods.empty?
        decl.append_children(:specifications,
          bpl("modifies #{global_mods.map(&:name) * ", "};"))
      end
      invariants.each do |i|
        decl.append_children(:specifications,
          bpl("requires #{i.expression};"),
          bpl("ensures #{i.expression};")
        )
      end
      decl.append_children(:specifications, bpl("ensures !#{condition};"))
      decl.append_children(:body, Body.new(locals: [], blocks: []))
      decl.body.append_children(:blocks,
        bpl("$entry: goto #{blocks.first.name};")) if blocks.first.name
      decl.body.append_children(:blocks,
        *blocks.map(&:copy))
      decl.body.blocks.first.prepend_children(:statements,
        *local_mods.map{|x| bpl("#{x.name} := #{x.name}.0;")})
      decl.body.append_children(:blocks,
        *exits.map {|l| bpl("#{l}: assume !#{condition}; return;")})

      stmt = bpl %{
        call #{local_mods.map(&:name) * ", "} #{":=" unless local_mods.empty?}
        $loop.#{id}(#{(local_accs + local_mods).map(&:name) * ", "});
      }

      return decl, stmt
    end

    def run! program
      program.declarations.each do |proc|
        next unless proc.is_a?(ProcedureDeclaration)
        next unless proc.body
        params = Set.new(proc.parameters.map(&:names).flatten)
        locals = Set.new((proc.returns + proc.body.locals).map(&:names).flatten)
        proc.each(preorder: false) do |stmt|
          next unless stmt.is_a?(WhileStatement)
          next if stmt.invariants.empty?

          info "EXTRACTING WHILE LOOP"
          info
          info stmt.to_s.indent
          info

          block = Block.new(names: [], statements: [stmt.copy])
          decl, call = extract(
            stmt.condition, stmt.invariants, [block], params, locals)
          program.append_children(:declarations, decl)
          stmt.replace_with(call)
          invalidates :all
        end
      end
      loop_identification.loops.each do |head,body|
        proc = head.parent.parent
        params = Set.new(proc.parameters.map(&:names).flatten)
        locals = Set.new((proc.returns + proc.body.locals).map(&:names).flatten)

        # NOTE filter out previously-removed blocks from nested loops
        body = body.select{|b| b.parent}

        ls = head.select {|l| l.is_a?(LabelIdentifier)}.map(&:name)
        exits = ls.select {|l| body.none? {|b| b.names.include?(l)}}
        entry = body.
          collect {|b| b.statements.first if !(b.names & (ls-exits)).empty?}.
          compact
        fail "Unexpected loop condition." unless
          entry.count == 1 && entry.first.is_a?(AssumeStatement)

        condition = entry.first.expression
        invariants = []
        head.statements.each do |stmt|
          case stmt
          when AssertStatement
            invariants << stmt
          when AssumeStatement

          else
            break
          end
        end
        next if invariants.empty?

        info "EXTRACTING LOOP"
        info
        info "#{(body.to_a * "\n\n").indent}"
        info

        decl, call = extract(
          condition, invariants, body.map(&:copy), params, locals)
        program.append_children(:declarations, decl)

        head.replace_children(:statements,
          call,
          bpl("goto #{exits * ", "};"))
        body.each {|b| b.remove if b != head}
        invalidates :all
      end
    end
  end
end
