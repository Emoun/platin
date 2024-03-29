# typed: false
#
# PLATIN tool set
#
# ARMv7m specific functionality
#

require 'English'

module ARMv7m

#
# Class to (lazily) read m5 simulator trace
# yields [program_counter, cycles] pairs
#
class M5SimulatorTrace
  TIME_PER_TICK = 500

  attr_reader :stats_num_items
  def initialize(elf, options)
    @elf, @options = elf, options
    @stats_num_items = 0
  end

  def each
    die("No M5 trace file specified") unless @options.trace_file
    file_open(@options.trace_file) do |fh|
      fh.each_line do |line|
        yield parse(line)
        @stats_num_items += 1
      end
    end
  end

private

  def parse(line)
    return nil unless line
    time,event,pc,rest = line.split(/\s*:\s*/,4)
    return nil unless event =~ /system\.cpu/
    [Integer(pc), time.to_i / TIME_PER_TICK, @stats_num_items]
  end
end


class ExtractSymbols
  OP_CONSTPOOL = 121
  OP_IMPLICIT_DEF = 8
  OPCODE_NAMES = { 233 => /mov/ }
  def self.run(cmd,extractor,pml,options)
    r = IO.popen("#{cmd} -d '#{options.binary_file}'") do |io|
      current_label, current_ix, current_function = nil, 0, nil
      in_inline_asm, addr_after_inline_asm = false, 0
      in_jumptable, addr_after_jumptable = false, 0
      pml_ix = 0
      io.each_line do |line|
        if line =~ RE_FUNCTION_LABEL
          current_label, current_ix = $2, 0
          pml_ix = 0
          in_inline_asm, addr_after_inline_asm = false, 0
          current_function = pml.machine_functions.by_label(current_label, false)
          extractor.add_symbol(current_label,Integer("0x#{$1}"))
        elsif line =~ RE_INS_LABEL
          addr, rawins, insname = $1, $2, $3
          size = rawins.delete(' ').size / 2
          next unless current_function
          if in_inline_asm && addr.to_i(16) == addr_after_inline_asm
            in_inline_asm, addr_after_inline_asm = false, 0
            pml_ix += 1
          end
          next if in_jumptable && addr.to_i(16) <= addr_after_jumptable
          in_jumptable, addr_after_jumptable = false, 0

          instruction = current_function.instructions[pml_ix]
          if instruction.nil?
            if insname[0] != "." && insname != "nop"
              warn "No instruction found at #{current_function}+#{pml_ix} instructions (#{insname} #{addr})"
            end
            next
          end
          if instruction.opcode == "INLINEASM"
            current_addr = addr.to_i(16)
            if not in_inline_asm
              addr_after_inline_asm = current_addr + instruction.size
              extractor.add_instruction_address(current_label,current_ix, Integer("0x#{addr}"))
              current_ix +=1
            end

            instr = build_instruction(addr.to_i(16), size, instruction.opcode, insname)
            extractor.add_instruction(current_label, addr.to_i(16), instr) if instr
            in_inline_asm = true
            next
          elsif instruction.opcode == "JUMPTABLE_TBB"
            extractor.add_instruction_address(current_label,current_ix, Integer("0x#{addr}"))
            instr = build_instruction(addr.to_i(16), size, instruction.opcode, insname)
            extractor.add_instruction(current_label, addr.to_i(16), instr) if instr
            current_addr = addr.to_i(16)
            in_jumptable = true
            addr_after_jumptable = current_addr + instruction.size
            current_ix += 1
            pml_ix += 1
            next
          end
          next if instruction.opcode == OP_IMPLICIT_DEF # not in disassembly
          # FIXME: We cannot reliably extract addresses of data ATM, because the disassembler
          # is not able to distinguish them. 'Data Instructions' (opcode 121) with a size
          # different from 4 will thus get incorrected addresses. We partially try to address
          # this issue by skipping data entries if the opcode is not 121
          next if insname[0] == "." && instruction.opcode != OP_CONSTPOOL
          extractor.add_instruction_address(current_label,current_ix, Integer("0x#{addr}"))
          instr = build_instruction(addr.to_i(16), size, instruction.opcode, insname)
          extractor.add_instruction(current_label, addr.to_i(16), instr) if instr

          # SANITY CHECK (begin)
          if (re = OPCODE_NAMES[instruction.opcode])
            die "Address extraction heuristic probably failed at #{addr}: #{insname} not #{re}" if insname !~ re
          end
          # SANITY CHECK (end)

          current_ix += 1
          pml_ix += 1
        end
      end
    end
    die "The objdump command '#{cmd}' exited with status #{$CHILD_STATUS.exitstatus}" unless $CHILD_STATUS.success?
  end
  def self.build_instruction(addr, size, opcode, objdump_name)
    ret = { 'address' => addr, 'size' => size, 'source' => 'objdump', 'opcode' => opcode }
    # TODO Maybe check for pc in the arguments for mov and add
    # TODO Maybe split of condition and size flags.
    case opcode
    when "INLINEASM"
      ret['opcode'] = case objdump_name
                      when "cpsie", "cpsid"
                        "tCPS"
                      when "nop"
                        "tMOVr" # Just assume 'mov r8, r8' for nop
                      when "dsb"
                        "t2DSB" # invalid in analysis
                      when "isb"
                        "t2ISB" # invalid in analysis
                      when "mrs", "mrsne"
                        "t2MRS_M"
                      when "msr"
                        "t2MSR_M"
                      when "wfi"
                        "tWFI" # invalid in analysis
                      when "str", "stmdbne", "strne.w"
                        "tSTRi"
                      when "ldr", "ldr.w", "ldmia.w"
                        "tLDRi"
                      when "bne.n", "bl", "blt.n"
                        "tBcc"
                      when "b.n"
                        "tB"
                      when "bx"
                        "tBX"
                      when "cmp"
                        "tCMPr"
                      when "bkpt"
                        "tBKPT" # invalid in analysis
                      when "svc"
                        "tSVC" # invalid in analysis
                      when "adds"
                        "tADDi8"
                      when "itt", "it"
                        "t2IT"
                      when "movw", "movs", "movt"
                        "tMOVr"
                      else
                        die "UNKNOWN INLINE ASM OPCODE #{addr.to_s(16)} #{objdump_name}"
                      end
    end
    ret
  end
  RE_HEX = /[0-9A-Fa-f]/
  RE_FUNCTION_LABEL = %r{ ^
    ( #{RE_HEX}{8} ) \s # address
    <([^>]+)>:          # label
  }x
  RE_INS_LABEL = %r{ ^ \s+
    ( #{RE_HEX}+ ): \s* # address
    ( #{RE_HEX}{4}\ ?#{RE_HEX}{4}? ) \s* # raw instruction
    ( \S+ )             # instruction
    # rest
  }x
end

class Architecture < PML::Architecture
  attr_reader :triple, :config
  def initialize(triple, config)
    @triple, @config = triple, config
    @config ||= self.class.default_config
  end

  def self.default_config
  # TODO: FIXME dummy values
    memories = PML::MemoryConfigList.new([PML::MemoryConfig.new('main',2 * 1024 * 1024,16,0,21,0,21)])
    caches = PML::CacheConfigList.new([Architecture.default_instr_cache('method-cache'),
                                       PML::CacheConfig.new('stack-cache','stack-cache','block',nil,4,2048),
                                       PML::CacheConfig.new('data-cache','set-associative','dm',nil,16,2048)])
    full_range = PML::ValueRange.new(0,0xFFFFFFFF,nil)
    memory_areas =
      PML::MemoryAreaList.new([PML::MemoryArea.new('code','code',caches.list[0], memories.first, full_range),
                               PML::MemoryArea.new('data','data',caches.list[2], memories.first, full_range)])
    PML::MachineConfig.new(memories,caches,memory_areas)
  end

  def update_cache_config(options)
  # FIXME: dummy stub
  end

  def self.default_instr_cache(type)
  # TODO: FIXME dummy values
    if type == 'method-cache'
      PML::CacheConfig.new('method-cache','method-cache','fifo',16,8,4096)
    else
      PML::CacheConfig.new('instruction-cache','instruction-cache','dm',1,16,4096)
    end
  end

  def self.simulator_options(opts)
  # FIXME: dummy stub
  end

  def config_for_clang(options)
  # FIXME: dummy stub
  end

  def config_for_simulator
  # FIXME: dummy stub
  end

  def simulator_trace(options, _watchpoints)
    M5SimulatorTrace.new(options.binary_file, self, options)
  end

  def objdump_command
    "arm-none-eabi-objdump"
  end

  def extract_symbols(extractor, pml, options)
    # prefix="armv6-#{@triple[2]}-#{@triple[3]}"
    # cmd = "#{prefix}-objdump"
  # FIXME hard coded tool name
    cmd = objdump_command
    ExtractSymbols.run(cmd, extractor, pml, options)
  end

# found out through reading register on hardware:
  FLASH_WAIT_CYCLES = 3
#
# FLASH_WAIT_CYCLES=15 # the actual worst case

# xmc4500_um.pdf 8-41
# WAIT_CYCLES_FLASH_ACCESS=3
  def path_wcet(ilist)
    cost = ilist.reduce(0) do |cycles, instr|
      # TODO: flushes for call??
      if instr.callees[0] =~ /__aeabi_.*/ || instr.callees[0] =~ /__.*div.*/
        cycles + cycle_cost(instr) + lib_cycle_cost(instr.callees[0]) + FLASH_WAIT_CYCLES
      else
        cycles + cycle_cost(instr) + FLASH_WAIT_CYCLES # access instructions
      end
    end
    cost
  end

  def edge_wcet(_ilist,_branch_index,_edge)
    # control flow is for free
    0
  end

  def lib_cycle_cost(func)
    die("Unknown library function: #{func}")
#    case func
#    when "__aeabi_uidivmod"
#      845 + 16
#    when "__aeabi_idivmod"
#      922 + 16#
#    when "__udivsi3"
#      820
#    when "__udivmodsi4"
#      845
#    when "__divsi3"
#      897
#    when "__divmodsi4"
#      922
#    else
#      die("Unknown library function: #{func}")
#    end
  end

  NUM_REGISTERS = 10
  PIPELINE_REFILL = 3

  # Floating-point arithmetic data processing instructions, such as add,
  # subtract, multiply, divide, square-root, all forms of multiply with
  # accumulate, as well as conversions of all types take one cycle longer if
  # their result is consumed by the following instruction.
  FPU_PIPELINE_STALL_CYCLES = 1

  def cycle_cost(instr)
    case instr.opcode
    # addsub
    when 'tADDi3', 'tSUBi3'
      1

    # assume same costs for 3 registers as for 2 registers and immediate
    when 'tADDrr', 'tSUBrr'
      1

    # addsubsp
    when 'tSUBspi', 'tADDspi', 'tADDrSPi'
      1

    # alu
    when 'tAND', 'tEOR', 'tADC', 'tSBC', 'tROR', 'tTST', 'tRSB', 'tCMPr',
         'tCMNz', 'tLSLrr', 'tLSRrr', 'tASRrr', 'tORR', 'tBIC', 'tMVN'
      1

    # branchcond (requires pipeline refill)
    # 1 + P (P \in {1,..,3})
    when 'tBcc', 'tCBNZ', 'tCBZ'
      1 + PIPELINE_REFILL

    # branchuncond (requires pipeline refill)
    # 1 + P
    when 'tB'
      1 + PIPELINE_REFILL

    # pseudo instruction mapping to 'bx lr'
    # 1 + P
    when 'tBX_RET'
      1 + PIPELINE_REFILL

    # extend
    when 'tSXTB', 'tSXTH', 'tUXTB', 'tUXTH'
      1

    # hireg
    when 'tADDhirr', 'tMOVr', 'tCMPhir'
      1

    # immediate
    when 'tMOVi8', 'tADDi8', 'tSUBi8', 'tCMPi8'
      1

    # branch and link: BL = inst32
    when 'tBL', 'tBLXi', 'tBLXr'
      1 + PIPELINE_REFILL

    # NOTE: pseudo instruction that maps to tBL
    # branchuncond
    # 1 + P
    when 'tBfar'
      1 + PIPELINE_REFILL

    # lea
    when 'tADR'
      1

    # NOTE pseduo instruction that maps to 'add rA, pc, #i'
    # probably lea
    when 'tLEApcrelJT'
      1

    # memimmediate
    when 'tSTRi', 'tLDRi'
      2 + FLASH_WAIT_CYCLES

    # NOTE: not directly considered in NEO's classes
    # ldrh r, [r, #i] same as ldr r, [r, #i]??
    # memimmediate
    when 'tSTRHi', 'tLDRHi'
      2 + FLASH_WAIT_CYCLES

    # ldrb r, [r, #i] same as ldr r, [r, #i]??
    # memmimmediate
    when 'tSTRBi', 'tLDRBi'
      2 + FLASH_WAIT_CYCLES

    # ldrsb r, [r, #i] same as ldr r, [r, #i]??
    # memimmediate
    when 'tLDRSB', 'tLDRSH'
      2 + FLASH_WAIT_CYCLES

    # memmultiple
    when 'tLDMIA', 'tLDMIA_UDP', 'tSTMIA_UDP'
      1 + (NUM_REGISTERS * FLASH_WAIT_CYCLES)

    # mempcrel
    when 'tLDRpci'
      2 + FLASH_WAIT_CYCLES

    # memreg
    when 'tSTRBr', 'tLDRBr', 'tLDRr', 'tSTRr', 'tLDRHr', 'tSTRHr'
      2 + FLASH_WAIT_CYCLES

    # memsprel
    when 'tSTRspi', 'tLDRspi'
      2 + FLASH_WAIT_CYCLES

    # pushpop
    when 'tPUSH', 'tPOP'
      1 + (NUM_REGISTERS * FLASH_WAIT_CYCLES)

    # pseudo instruction mapping to pop
    when 'tPOP_RET'
      1 + (NUM_REGISTERS * FLASH_WAIT_CYCLES) + PIPELINE_REFILL

    # shift
    when 'tLSLri', 'tLSRri', 'tASRri'
      1

    # single-cycle multiplication
    when 'tMUL'
      1

    # pseudo instruction translated to a 'mov pc, r2'
    when 'tBR_JTr'
      1 + PIPELINE_REFILL

    # ARMv7M support (thumb2)
    # http://infocenter.arm.com/help/index.jsp?topic=/com.arm.doc.ddi0439b/CHDDIGAC.html
    #
    # STMFD is s synonym for STMDB, and refers to its use for pushing data onto Full Descending stacks
    # Store Multiple: 1 + N: (Number of registers: N = NUM_REGISTERS)
    when 't2STMDB_UPD'
      1 + FLASH_WAIT_CYCLES * NUM_REGISTERS
    when 't2MOVi16', 't2MOVTi16', 't2MOVi'
      1

    # move not, test
    when 't2MVNi', 't2MVNr', 't2TSTri'
      1
    when 't2Bcc', 't2B'
      1 + PIPELINE_REFILL
    when 't2LDMIA_RET', 't2LDMIA', 't2STRi8', 't2STRBi8', 't2STRHi8', 't2STRBi12', 't2STRHi12', 't2STR_POST', 't2STRHs'
      2 + FLASH_WAIT_CYCLES
    when 't2LDRi8', 't2LDRBi8', 't2LDRi12', 't2LDRBi12', 't2LDRSBi12', 't2LDRSHi8',
         't2LDRSHi12', 't2LDRSHi12', 't2LDRs', 't2LDR_POST', 't2LDR_PRE', 't2LDRSHs', 't2LDRHs'
      2 + FLASH_WAIT_CYCLES
    when /^t2LDRHi[0-9]+$/
      2 + FLASH_WAIT_CYCLES
    when 't2LDRDi8', 't2STRDi8', 't2STMIA', 't2STRs'
      1 + FLASH_WAIT_CYCLES * NUM_REGISTERS
    when 'PSEUDO_LOOPBOUND'
      0
    # page 31:
    when 't2MUL', 't2SMMUL', 't2MLA', 't2MLS', 't2SMULL', 't2UMULL', 't2SMMLA', 't2SMLAL', 't2UMLAL'
      1
    when 't2ADDrs', 't2ADDri', 't2ADDrr', 't2ADCrs', 't2ADCri', 't2ADCrr', 't2ADDri12'
      1
    # logical operations
    when 't2ANDrr', 't2ANDrs', 't2ANDri', 't2EORrr', 't2EORri', 't2ORRrr', 't2ORRrs', 't2ORRri',
         't2ORNrr', 't2BICrr', 't2MVNrr', 't2TSTrr', 't2TEQrr', 't2EORrs', 't2BICri', 't2ORNri'
      1
    # bitwise shifts
    when 't2LSLri', 't2LSLrr', 't2LSRri', 't2LSRrr', 't2ASRri', 't2ASRrr'
      1
    # subtract
    when 't2SUBrr', 't2SUBri', 't2SUBrs', 't2SBCrr', 't2SBCri', 't2RSBrs', 't2RSBri', 't2SUBri12'
      1
    # store instructions
    when 't2STRi12'
      2 + FLASH_WAIT_CYCLES
    when 't2CMPri', 't2CMPrs', 't2CMNri'
      1
    # extend
    when 't2SXTH', 't2SXTB', 't2UXTH', 't2UXTB', 't2UXTAB'
      1
    # bit field, extract unsigned, extract signed, clear, insert
    when 't2UBFX', 't2SBFX', 't2BFC', 't2BFI'
      1
    # If-then-else
    when 't2IT'
      1
    when 't2UDIV'
      12
    when 'VMOVSR', 'VMOVRS', 'VMOVS'
      1
    # Floating point support
    when 'VTOUIZS', 'VTOSIZS', 'VSITOS', 'VUITOS'
      1 + FPU_PIPELINE_STALL_CYCLES
    when 'VLDRS'
      2 + FLASH_WAIT_CYCLES
    when 'VSTRS'
      2 + FLASH_WAIT_CYCLES
    when 'VMULS'
      1 + FPU_PIPELINE_STALL_CYCLES
    when 'VMLAS', 'VMLSS', 'VNMLSS'
      3 + FPU_PIPELINE_STALL_CYCLES
    when 'VSUBS', 'VADDS'
      1 + FPU_PIPELINE_STALL_CYCLES
    when 'VCMPES', 'VCMPEZS'
      1
    when 'VNEGS'
      1 + FPU_PIPELINE_STALL_CYCLES
    when 'VDIVS'
      14 + FPU_PIPELINE_STALL_CYCLES
    when 'FCONSTS'
      1
    when 'FMSTAT'
      # Internally compiled to VMRS
      1
    else
      die("Unknown opcode: #{instr.opcode} at #{instr.qname}")
    end
  end

  def method_cache
  # FIXME: dummy stub
    nil
  end

  def instruction_cache
  # FIXME: dummy stub
    nil
  end

  def stack_cache
  # FIXME: dummy stub
    nil
  end

  def data_cache
  # FIXME: dummy stub
    nil
  end

  def data_memory
  # FIXME: dummy stub
    dm = @config.memory_areas.by_name('data')
    dm.memory if dm
  end

  def local_memory
  # FIXME: dummy stub
    # used for local scratchpad and stack cache accesses
    @config.memories.by_name("local")
  end

  # Return the maximum size of a load or store in bytes.
  def max_data_transfer_bytes
  # FIXME: dummy stub
    4
  end

  def data_cache_access?(_instr)
  # FIXME: dummy stub
    false
  end

  def time_per_cycle
    # XMC4500 uses freq of 120MHz: 1/120MHz -> 8.3ns
    8.33e-9
  end

  def cpu_current_consumption
    # XMC4500 data sheet: 115 mA with peripherals disabled
    {"energy_stay_off" => 115,
     "energy_stay_on"  => 115,
    }
  end
end

end # module ARMv7m

# Extend PML
module PML

# Register architecture
Architecture.register("armv7m",   ARMv7m::Architecture)
Architecture.register("thumbv7m", ARMv7m::Architecture)

end # module PML
