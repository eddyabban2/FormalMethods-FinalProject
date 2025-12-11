# Formal Verification of Ibex Load-Store Unit (LSU)

This project performs formal verification of the Load-Store Unit (LSU) from the Ibex RISC-V Core. It utilizes SymbiYosys (SBY) and Boolector to prove Observational Correctness, verifying that the LSU strictly adheres to bus protocols and maintains data integrity under all possible memory latency scenarios.

## Project Structure

This directory (`ibex_lsu`) is designed to sit within the `formal/` directory of the Ibex repository to resolve relative paths to the RTL.

```text
ibex/
├── rtl/
│   ├── ibex_load_store_unit.sv  <-- DUT (Modified with debug ports)
│   └── ...
├── vendor/                      <-- LowRISC primitives (prim_pkg, etc.)
└── formal/
    └── ibex_lsu/
        ├── ibex_lsu.sby         <-- SymbiYosys Configuration
        ├── ibex_lsu_harness.sv  <-- The "Gold Standard" Test Harness
        └── README.md            <-- This file
````

## Prerequisites

  * **SymbiYosys (SBY):** Front-end driver for Yosys-based formal flows.
  * **Yosys:** Open-source synthesis suite.
  * **Boolector:** SMT Solver (highly recommended for bit-vector logic).
  * **GTKWave:** For viewing counter-example traces.

## Setup & Reproduction

### 1\. Prepare the Ibex Source

Clone the Ibex repository if you haven't already.

```bash
git clone https://github.com/lowRISC/ibex.git
cd ibex
```

### 2\. Instrument the RTL (Debug Ports)

To verify internal states (like the FSM state `ls_fsm_cs` or the misaligned flag), we need to expose them to the harness.

Open `rtl/ibex_load_store_unit.sv` and add these output ports to the module definition:

```systemverilog
module ibex_load_store_unit #( ... ) (
  // ... existing ports ...

  // === FORMAL VERIFICATION DEBUG PORTS ===
  output logic [2:0]   fsm_state_debug_o,
  output logic         data_we_q_debug_o,
  output logic [31:0]  data_rdata_ext_debug_o,
  output logic         misaligned_q_debug_o
);
```

Then, assign them at the end of the module:

```systemverilog
  // ... end of module logic ...

  // === FORMAL VERIFICATION DEBUG ASSIGNMENTS ===
  assign fsm_state_debug_o      = ls_fsm_cs;
  assign data_we_q_debug_o      = data_we_q;
  assign data_rdata_ext_debug_o = data_rdata_ext;
  assign misaligned_q_debug_o   = handle_misaligned_q;
endmodule
```

### 3\. Run the Verification

Navigate to this folder and run SBY.

```bash
cd formal/ibex_lsu
sby -f ibex_lsu.sby
```

**Expected Result:**

```text
SBY ... summary: successful proof by k-induction.
SBY ... DONE (PASS, rc=0)
```

This confirms the LSU logic is correct for all time (unbounded proof).

-----

## How to Reproduce "Mutation Testing"

To prove the testbench is capable of finding bugs, perform Mutation Testing by intentionally breaking the RTL.

### Case 1: Forced Alignment Error

1.  Open `rtl/ibex_load_store_unit.sv`.
2.  Find the line: `assign data_addr_o = data_addr_w_aligned;`
3.  Change it to:
    ```systemverilog
    // BUG: randomly force LSB to 1 -> violates alignment
    assign data_addr_o = {data_addr_w_aligned[31:1], 1'b1}; 
    ```
4.  Run `sby -f ibex_lsu.sby`.
5.  **Result:** `FAIL`. The tool will report a trace showing the address violation.

### Case 2: Protocol Violation (Fake Valid)

1.  Open `rtl/ibex_load_store_unit.sv`.
2.  Modify `lsu_rdata_valid_o` assignment:
    ```systemverilog
    // BUG: Allow valid response even when state is IDLE/Error
    assign lsu_rdata_valid_o = 1'b1; 
    ```
3.  Run `sby -f ibex_lsu.sby`.
4.  **Result:** `FAIL`. The harness detects a protocol violation immediately.

-----

## Debugging Traces

If a proof fails (or you run in `cover` mode), SBY generates a VCD trace file.

1.  Run with cover mode (optional, requires editing `.sby` file to `mode cover`):
    ```bash
    sby -f ibex_lsu.sby
    ```
2.  Open the trace:
    ```bash
    gtkwave ibex_lsu/engine_0/trace.vcd
    ```
3.  **What to look for:**
      * **`fsm_state`**: Watch the transition `0 (IDLE) -> 1 (WAIT_GNT_MIS) -> 2 (WAIT_RVALID_MIS)`.
      * **`is_misaligned`**: See it go high when `adder_result_ex_i` crosses a word boundary (e.g., ends in `0x3`).
      * **`busy_o`**: Verify it stays high during the entire split transaction.

## Harness Features

  * **Shadow Modeling:** Captures CPU inputs (`lsu_type`, `lsu_we`) at the start of a transaction and forces them to remain stable using `assume` properties, mimicking a real pipeline.
  * **Symbolic Memory:** Uses `(* anyseq *)` input wires to simulate a memory that can have arbitrary latency (0 to infinity) and return arbitrary data.
  * **Whitebox Assertions:** Verifies internal data-path logic by checking that output pins (`data_wdata_o`) match the internal mux logic (`dut.data_wdata`).

