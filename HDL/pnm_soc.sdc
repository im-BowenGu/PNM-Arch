## =============================================================================
## SDC Timing Constraints for the PNM Router SBC SoC
##
## Target: 100 MHz reference clock (10 ns period)
## Tool: Synopsys Design Constraints / Cadence SDC / Yosys read_sdc
##
## This is a template: pin assignments and IO delays must be filled in
## after floorplanning.  The clock definitions and false paths below
## are correct for the RTL as-is.
## =============================================================================

## -----------------------------------------------------------------------------
## Primary clock
## -----------------------------------------------------------------------------
create_clock -name clk -period 10.0 [get_ports clk]

## -----------------------------------------------------------------------------
## Derived clocks (if any PLL/DLL instantiated)
## Uncomment when a PLL is added:
## create_generated_clock -name clk_200 -source [get_ports clk] \
##     -divide_by 1 -multiply_by 2 [get_pins u_pll/clk_out]
## -----------------------------------------------------------------------------

## -----------------------------------------------------------------------------
## Input / Output delays (placeholders — fill after IO planning)
## -----------------------------------------------------------------------------

# UART (slow, asynchronous)
set_input_delay  -clock clk 5.0 [get_ports uart_rx]
set_output_delay -clock clk 5.0 [get_ports uart_tx]

# Fabric links (source-synchronous, 1 GHz forwarded clock)
# Actual values depend on board trace length
set_input_delay  -clock clk 1.0 [get_ports {spine_inject_data[*]}]
set_output_delay -clock clk 1.0 [get_ports {spine_extract_data[*]}]

# External interrupts (slow sideband)
set_input_delay  -clock clk 8.0 [get_ports {ext_irq[*]}]

## -----------------------------------------------------------------------------
## Clock-domain crossings (async resets, optical link Gray-code synchronizers)
## -----------------------------------------------------------------------------

# rst_n is async — assert async, deassert sync via rst_sync (2 stages)
set_false_path -from [get_ports rst_n]

# Optical link Gray-code synchronizers (optical_link.v)
# When optical links are instantiated, mark the crossing:
# set_false_path -from [get_clocks clk] -to [get_clocks clk_optical_rx]

## -----------------------------------------------------------------------------
## False paths — combinational paths that should not be timed
## -----------------------------------------------------------------------------

# Boot ROM is combinational read (rom[addr[15:2]])
set_false_path -from [get_pins {u_rom/rom_reg[*]/Q}] -to [get_pins {mux_rdata_reg[*]/D}]

# SRAM combinational read
set_false_path -from [get_pins {sram_mem_reg[*][*]/Q}] -to [get_pins {sram_rdata_reg[*]/D}]

## -----------------------------------------------------------------------------
## Multicycle paths
## None — all logic is single-cycle at 100 MHz.
## The FP32 ALU's 25-cycle divider is pipelined (fp32_alu.v),
## not a combinational multicycle path.
## -----------------------------------------------------------------------------

## -----------------------------------------------------------------------------
## Max fanout / max transition (optional, for synthesis)
## -----------------------------------------------------------------------------
set_max_fanout 32 [get_ports clk]
set_max_transition 0.5 [all_inputs]
