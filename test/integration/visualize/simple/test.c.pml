---
format:          pml-0.1
triple:          armv7-none-none-eabi
bitcode-functions: 
  - name:            _exit
    level:           bitcode
    hash:            '0'
    blocks:          
      - name:            entry
        predecessors:    [  ]
        successors:      [  ]
        src-hint:        'test.c:1'
        instructions:    
          - index:           '0'
            opcode:          alloca
          - index:           '1'
            opcode:          store
            memmode:         store
          - index:           '2'
            opcode:          call
            intrinsic:       true
          - index:           '3'
            opcode:          unreachable
    linkage:         ExternalLinkage
  - name:            main
    level:           bitcode
    hash:            '0'
    blocks:          
      - name:            entry
        predecessors:    [  ]
        successors:      [  ]
        src-hint:        'test.c:2'
        instructions:    
          - index:           '0'
            opcode:          alloca
          - index:           '1'
            opcode:          store
            memmode:         store
          - index:           '2'
            opcode:          call
            callees:         [ _exit ]
          - index:           '3'
            opcode:          unreachable
    linkage:         ExternalLinkage
  - name:            choosy
    level:           bitcode
    hash:            '0'
    blocks:          
      - name:            entry
        predecessors:    [  ]
        successors:      [ if.then, if.else ]
        src-hint:        'test.c:4'
        instructions:    
          - index:           '0'
            opcode:          alloca
          - index:           '1'
            opcode:          alloca
          - index:           '2'
            opcode:          store
            memmode:         store
          - index:           '3'
            opcode:          call
            intrinsic:       true
          - index:           '4'
            opcode:          load
            memmode:         load
          - index:           '5'
            opcode:          icmp
          - index:           '6'
            opcode:          br
      - name:            if.then
        predecessors:    [ entry ]
        successors:      [ return ]
        src-hint:        'test.c:6'
        instructions:    
          - index:           '0'
            opcode:          load
            memmode:         load
          - index:           '1'
            opcode:          sub
          - index:           '2'
            opcode:          store
            memmode:         store
          - index:           '3'
            opcode:          br
      - name:            if.else
        predecessors:    [ entry ]
        successors:      [ return ]
        src-hint:        'test.c:8'
        instructions:    
          - index:           '0'
            opcode:          load
            memmode:         load
          - index:           '1'
            opcode:          store
            memmode:         store
          - index:           '2'
            opcode:          br
      - name:            return
        predecessors:    [ if.else, if.then ]
        successors:      [  ]
        src-hint:        'test.c:10'
        instructions:    
          - index:           '0'
            opcode:          load
            memmode:         load
          - index:           '1'
            opcode:          ret
    linkage:         ExternalLinkage
  - name:            bar
    level:           bitcode
    hash:            '0'
    blocks:          
      - name:            entry
        predecessors:    [  ]
        successors:      [  ]
        src-hint:        'test.c:12'
        instructions:    
          - index:           '0'
            opcode:          alloca
          - index:           '1'
            opcode:          store
            memmode:         store
          - index:           '2'
            opcode:          call
            intrinsic:       true
          - index:           '3'
            opcode:          load
            memmode:         load
          - index:           '4'
            opcode:          add
          - index:           '5'
            opcode:          ret
    linkage:         ExternalLinkage
  - name:            loopy
    level:           bitcode
    hash:            '0'
    blocks:          
      - name:            entry
        predecessors:    [  ]
        successors:      [ for.cond ]
        src-hint:        'test.c:16'
        instructions:    
          - index:           '0'
            opcode:          alloca
          - index:           '1'
            opcode:          alloca
          - index:           '2'
            opcode:          alloca
          - index:           '3'
            opcode:          store
            memmode:         store
          - index:           '4'
            opcode:          call
            intrinsic:       true
          - index:           '5'
            opcode:          call
            intrinsic:       true
          - index:           '6'
            opcode:          load
            memmode:         load
          - index:           '7'
            opcode:          store
            memmode:         store
          - index:           '8'
            opcode:          call
            intrinsic:       true
          - index:           '9'
            opcode:          store
            memmode:         store
          - index:           '10'
            opcode:          br
      - name:            for.cond
        predecessors:    [ for.inc, entry ]
        successors:      [ for.body, for.end ]
        loops:           [ for.cond ]
        src-hint:        'test.c:18'
        instructions:    
          - index:           '0'
            opcode:          load
            memmode:         load
          - index:           '1'
            opcode:          icmp
          - index:           '2'
            opcode:          br
      - name:            for.body
        predecessors:    [ for.cond ]
        successors:      [ for.inc ]
        loops:           [ for.cond ]
        src-hint:        'test.c:18'
        instructions:    
          - index:           '0'
            opcode:          call
            intrinsic:       true
          - index:           '1'
            opcode:          load
            memmode:         load
          - index:           '2'
            opcode:          call
            callees:         [ bar ]
          - index:           '3'
            opcode:          load
            memmode:         load
          - index:           '4'
            opcode:          add
          - index:           '5'
            opcode:          store
            memmode:         store
          - index:           '6'
            opcode:          br
      - name:            for.inc
        predecessors:    [ for.body ]
        successors:      [ for.cond ]
        loops:           [ for.cond ]
        src-hint:        'test.c:18'
        instructions:    
          - index:           '0'
            opcode:          load
            memmode:         load
          - index:           '1'
            opcode:          add
          - index:           '2'
            opcode:          store
            memmode:         store
          - index:           '3'
            opcode:          br
      - name:            for.end
        predecessors:    [ for.cond ]
        successors:      [  ]
        src-hint:        'test.c:22'
        instructions:    
          - index:           '0'
            opcode:          load
            memmode:         load
          - index:           '1'
            opcode:          ret
    linkage:         ExternalLinkage
  - name:            c_entry
    level:           bitcode
    hash:            '0'
    blocks:          
      - name:            entry
        predecessors:    [  ]
        successors:      [  ]
        src-hint:        'test.c:25'
        instructions:    
          - index:           '0'
            opcode:          alloca
          - index:           '1'
            opcode:          alloca
          - index:           '2'
            opcode:          store
            memmode:         store
          - index:           '3'
            opcode:          call
            intrinsic:       true
          - index:           '4'
            opcode:          call
            intrinsic:       true
          - index:           '5'
            opcode:          load
            memmode:         load
          - index:           '6'
            opcode:          call
            callees:         [ choosy ]
          - index:           '7'
            opcode:          store
            memmode:         store
          - index:           '8'
            opcode:          load
            memmode:         load
          - index:           '9'
            opcode:          call
            callees:         [ loopy ]
          - index:           '10'
            opcode:          ret
    linkage:         ExternalLinkage
modelfacts:      
  - program-point:   
      function:        loopy
      block:           for.cond
    origin:          platina.bc
    level:           bitcode
    type:            lbound
    expression:      '42'
...
---
format:          pml-0.1
triple:          armv7-none-none-eabi
relation-graphs: 
  - src:             
      function:        _exit
      level:           bitcode
    dst:             
      function:        '0'
      level:           machinecode
    nodes:           
      - name:            '0'
        type:            entry
        src-block:       entry
        dst-block:       '0'
        src-successors:  [ '1' ]
        dst-successors:  [ '1' ]
      - name:            '1'
        type:            exit
    status:          valid
  - src:             
      function:        main
      level:           bitcode
    dst:             
      function:        '1'
      level:           machinecode
    nodes:           
      - name:            '0'
        type:            entry
        src-block:       entry
        dst-block:       '0'
        src-successors:  [ '1' ]
        dst-successors:  [ '1' ]
      - name:            '1'
        type:            exit
    status:          valid
  - src:             
      function:        choosy
      level:           bitcode
    dst:             
      function:        '2'
      level:           machinecode
    nodes:           
      - name:            '0'
        type:            entry
        src-block:       entry
        dst-block:       '0'
        src-successors:  [ '2', '3' ]
        dst-successors:  [ '2', '3' ]
      - name:            '1'
        type:            exit
      - name:            '2'
        type:            progress
        src-block:       if.else
        dst-block:       '2'
        src-successors:  [ '4' ]
        dst-successors:  [ '4' ]
      - name:            '3'
        type:            progress
        src-block:       if.then
        dst-block:       '1'
        src-successors:  [ '4' ]
        dst-successors:  [ '4' ]
      - name:            '4'
        type:            progress
        src-block:       return
        dst-block:       '3'
        src-successors:  [ '1' ]
        dst-successors:  [ '1' ]
    status:          valid
  - src:             
      function:        bar
      level:           bitcode
    dst:             
      function:        '3'
      level:           machinecode
    nodes:           
      - name:            '0'
        type:            entry
        src-block:       entry
        dst-block:       '0'
        src-successors:  [ '1' ]
        dst-successors:  [ '1' ]
      - name:            '1'
        type:            exit
    status:          valid
  - src:             
      function:        loopy
      level:           bitcode
    dst:             
      function:        '4'
      level:           machinecode
    nodes:           
      - name:            '0'
        type:            entry
        src-block:       entry
        dst-block:       '0'
        src-successors:  [ '2' ]
        dst-successors:  [ '2' ]
      - name:            '1'
        type:            exit
      - name:            '2'
        type:            progress
        src-block:       for.cond
        dst-block:       '1'
        src-successors:  [ '3', '4' ]
        dst-successors:  [ '3', '4' ]
      - name:            '3'
        type:            progress
        src-block:       for.body
        dst-block:       '2'
        src-successors:  [ '5' ]
        dst-successors:  [ '5' ]
      - name:            '4'
        type:            progress
        src-block:       for.end
        dst-block:       '4'
        src-successors:  [ '1' ]
        dst-successors:  [ '1' ]
      - name:            '5'
        type:            progress
        src-block:       for.inc
        dst-block:       '3'
        src-successors:  [ '2' ]
        dst-successors:  [ '2' ]
    status:          valid
  - src:             
      function:        c_entry
      level:           bitcode
    dst:             
      function:        '5'
      level:           machinecode
    nodes:           
      - name:            '0'
        type:            entry
        src-block:       entry
        dst-block:       '0'
        src-successors:  [ '1' ]
        dst-successors:  [ '1' ]
      - name:            '1'
        type:            exit
    status:          valid
...
---
format:          pml-0.1
triple:          armv7-none-none-eabi
machine-functions: 
  - name:            '0'
    level:           machinecode
    mapsto:          _exit
    hash:            '0'
    blocks:          
      - name:            '0'
        mapsto:          entry
        predecessors:    [  ]
        successors:      [  ]
        instructions:    
          - { index: '0', opcode: tSUBspi, size: 2 }
          - { index: '1', opcode: tMOVr, size: 2 }
          - { index: '2', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '3', opcode: tSTRspi, size: 2, memmode: store }
    linkage:         ExternalLinkage
  - name:            '1'
    level:           machinecode
    mapsto:          main
    hash:            '0'
    blocks:          
      - name:            '0'
        mapsto:          entry
        predecessors:    [  ]
        successors:      [  ]
        src-hint:        'test.c:2'
        instructions:    
          - { index: '0', opcode: tPUSH, size: 2, memmode: store }
          - { index: '1', opcode: tMOVr, size: 2 }
          - { index: '2', opcode: tSUBspi, size: 2 }
          - { index: '3', opcode: tMOVi8, size: 2 }
          - { index: '4', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '5', opcode: tMOVi8, size: 2 }
          - { index: '6', opcode: tBL, callees: [ _exit ], size: 4, branch-type: call }
    linkage:         ExternalLinkage
  - name:            '2'
    level:           machinecode
    mapsto:          choosy
    hash:            '0'
    blocks:          
      - name:            '0'
        mapsto:          entry
        predecessors:    [  ]
        successors:      [ '1', '2' ]
        src-hint:        'test.c:5'
        instructions:    
          - { index: '0', opcode: tSUBspi, size: 2 }
          - { index: '1', opcode: tMOVr, size: 2 }
          - { index: '2', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '3', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '4', opcode: tCMPi8, size: 2 }
          - { index: '5', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '6', opcode: tBcc, size: 2, branch-type: conditional }
          - { index: '7', opcode: tB, size: 2, branch-type: unconditional }
      - name:            '1'
        mapsto:          if.then
        predecessors:    [ '0' ]
        successors:      [ '3' ]
        src-hint:        'test.c:6'
        instructions:    
          - { index: '0', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '1', opcode: tRSB, size: 2 }
          - { index: '2', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '3', opcode: tB, size: 2, branch-type: unconditional }
      - name:            '2'
        mapsto:          if.else
        predecessors:    [ '0' ]
        successors:      [ '3' ]
        src-hint:        'test.c:8'
        instructions:    
          - { index: '0', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '1', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '2', opcode: tB, size: 2, branch-type: unconditional }
      - name:            '3'
        mapsto:          return
        predecessors:    [ '2', '1' ]
        successors:      [  ]
        src-hint:        'test.c:10'
        instructions:    
          - { index: '0', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '1', opcode: tADDspi, size: 2 }
          - { index: '2', opcode: tBX_RET, size: 2, branch-type: return }
    linkage:         ExternalLinkage
  - name:            '3'
    level:           machinecode
    mapsto:          bar
    hash:            '0'
    blocks:          
      - name:            '0'
        mapsto:          entry
        predecessors:    [  ]
        successors:      [  ]
        src-hint:        'test.c:13'
        instructions:    
          - { index: '0', opcode: tSUBspi, size: 2 }
          - { index: '1', opcode: tMOVr, size: 2 }
          - { index: '2', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '3', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '4', opcode: tADDi8, size: 2 }
          - { index: '5', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '6', opcode: tADDspi, size: 2 }
          - { index: '7', opcode: tBX_RET, size: 2, branch-type: return }
    linkage:         ExternalLinkage
  - name:            '4'
    level:           machinecode
    mapsto:          loopy
    hash:            '0'
    blocks:          
      - name:            '0'
        mapsto:          entry
        predecessors:    [  ]
        successors:      [ '1' ]
        src-hint:        'test.c:17'
        instructions:    
          - { index: '0', opcode: tPUSH, size: 2, memmode: store }
          - { index: '1', opcode: tMOVr, size: 2 }
          - { index: '2', opcode: tSUBspi, size: 2 }
          - { index: '3', opcode: tMOVr, size: 2 }
          - { index: '4', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '5', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '6', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '7', opcode: tMOVi8, size: 2 }
          - { index: '8', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '9', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '10', opcode: tB, size: 2, branch-type: unconditional }
      - name:            '1'
        mapsto:          for.cond
        predecessors:    [ '0', '3' ]
        successors:      [ '2', '4' ]
        loops:           [ '1' ]
        src-hint:        'test.c:18'
        instructions:    
          - { index: '0', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '1', opcode: tCMPi8, size: 2 }
          - { index: '2', opcode: tBcc, size: 2, branch-type: conditional }
          - { index: '3', opcode: tB, size: 2, branch-type: unconditional }
      - name:            '2'
        mapsto:          for.body
        predecessors:    [ '1' ]
        successors:      [ '3' ]
        loops:           [ '1' ]
        src-hint:        'test.c:20'
        instructions:    
          - { index: '0', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '1', opcode: tBL, callees: [ bar ], size: 4, branch-type: call }
          - { index: '2', opcode: t2LDRi12, size: 4, memmode: load }
          - { index: '3', opcode: tADDhirr, size: 2 }
          - { index: '4', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '5', opcode: tB, size: 2, branch-type: unconditional }
      - name:            '3'
        mapsto:          for.inc
        predecessors:    [ '2' ]
        successors:      [ '1' ]
        loops:           [ '1' ]
        src-hint:        'test.c:18'
        instructions:    
          - { index: '0', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '1', opcode: tADDi8, size: 2 }
          - { index: '2', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '3', opcode: tB, size: 2, branch-type: unconditional }
      - name:            '4'
        mapsto:          for.end
        predecessors:    [ '1' ]
        successors:      [  ]
        src-hint:        'test.c:22'
        instructions:    
          - { index: '0', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '1', opcode: tADDspi, size: 2 }
          - { index: '2', opcode: tPOP_RET, size: 2, branch-type: return }
    linkage:         ExternalLinkage
  - name:            '5'
    level:           machinecode
    mapsto:          c_entry
    hash:            '0'
    blocks:          
      - name:            '0'
        mapsto:          entry
        predecessors:    [  ]
        successors:      [  ]
        src-hint:        'test.c:27'
        instructions:    
          - { index: '0', opcode: tPUSH, size: 2, memmode: store }
          - { index: '1', opcode: tMOVr, size: 2 }
          - { index: '2', opcode: tSUBspi, size: 2 }
          - { index: '3', opcode: tMOVr, size: 2 }
          - { index: '4', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '5', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '6', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '7', opcode: tBL, callees: [ choosy ], size: 4, branch-type: call }
          - { index: '8', opcode: tSTRspi, size: 2, memmode: store }
          - { index: '9', opcode: tLDRspi, size: 2, memmode: load }
          - { index: '10', opcode: tBL, callees: [ loopy ], size: 4, branch-type: call }
          - { index: '11', opcode: tADDspi, size: 2 }
          - { index: '12', opcode: tPOP_RET, size: 2, branch-type: return }
    linkage:         ExternalLinkage
...
