`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// InstructionMemory
//
// PURPOSE
//   Read-only instruction store, initialised from a $readmemb image produced by
//   asm/assembler.py. Inferred as Block RAM.
//
// INTERFACE
//   clk          core clock
//   addr         [31:0] program counter (byte-oriented)
//   instruction  [31:0] REGISTERED output -- valid the cycle AFTER addr
//   en           enable
//
// TIMING CONTRACT -- THE IMPORTANT PART
//   The read is SYNCHRONOUS. instruction is valid one cycle after addr is
//   presented, which is why S_FETCH exists as a separate state: the address
//   goes out in S_FETCH and the word is consumed in S_EXEC.
//
//   Do not convert this to a combinational read. Vivado cannot map an
//   asynchronous read to Block RAM because BRAM primitives register their
//   output port. It falls back to distributed LUTRAM plus a mux tree:
//
//       64K x 32 async = (65536 / 64) x 32 = 32,768 RAM64X1S primitives
//       XC7S50 LUTRAM-capable LUTs        = ~9,600
//
//   Synthesis will pass -- synthesis only estimates -- and implementation will
//   fail with DRC resource errors and F7/F8 mux overflow.
//
// DEPTH
//   parameter AW = 10 -> 2^AW words.
//   Declared at the depth the programs need, not at the full address space.
//   Indexing uses the low bits only:
//       wire [AW-1:0] idx = addr[AW+1:2];   // byte-addressed PC
//
//   Do NOT declare reg [31:0] mem [0:65535]. The depth is what caused the
//   original resource overflow as much as the read style did.
//
// INITIALISATION
//   initial $readmemb("instruction.mem", mem);
//   Vivado reads this at elaboration and bakes the contents into the bitstream.
//
//   IF THE FILE IS MISSING, the ROM synthesises as all-zeros. Every instruction
//   then decodes as ADD R0,R0,R0, no branch depends on memory, the datapath
//   becomes unobservable, and Vivado prunes the entire design to a counter and
//   a few LUTs - reporting success. If utilisation collapses unexpectedly,
//   check that the .mem file is in the project directory before anything else.
//
// VERIFYING BRAM INFERENCE
//   After synthesis, LUT-as-memory must read ZERO and BRAM tile count must be
//   non-zero. Non-zero LUTRAM means something reverted to distributed memory.
//
// CHANGE HISTORY
//   - Read converted from asynchronous to registered; this is what allowed BRAM
//     inference and cleared the placement failure.
//   - Depth reduced from the full 64K address space to 1K words.
//////////////////////////////////////////////////////////////////////////////////

module InstructionMemory #(
    parameter AW       = 10,
    parameter MEM_FILE = "instruction_mac4.mem"
)(
    input               clk,
    input               en,
    input      [31:0]   addr,                // BYTE address from PC
    output reg [31:0]   instruction
);

    (* ram_style = "block" *)
    reg [31:0] mem [0:(1<<AW)-1];

    integer i;
    initial begin
        // Zero-fill first so unwritten locations are 0 rather than X in
        // simulation. This is an initial block, not a reset, so it does not
        // block BRAM inference.
        for (i = 0; i < (1<<AW); i = i + 1)
            mem[i] = 32'b0;
        $readmemb(MEM_FILE, mem);
        if (mem[0] === 32'b0)
            $display("WARNING: %s appears empty or unreadable", MEM_FILE);
    end

    always @(posedge clk) begin
        if (en)
            instruction <= mem[addr[AW+1:2]];
    end

    // synthesis translate_off
    always @(posedge clk) if (en)
        $display("[IF] t=%0t pc=%h word=%0d instr=%b",
                 $time, addr, addr[AW+1:2], mem[addr[AW+1:2]]);
    // synthesis translate_on

endmodule
