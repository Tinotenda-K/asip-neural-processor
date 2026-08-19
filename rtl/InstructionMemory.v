`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// InstructionMemory - Block RAM version
//
// The BRAM output register IS the instruction register. Assert en during
// S_FETCH; 'instruction' is valid from S_EXEC onward and holds stable while
// en stays low.
//
// PC is byte-addressed (PC += 4), so the word index is addr[AW+1:2].
// AW = 10 gives 1024 words; the current program uses 155.
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