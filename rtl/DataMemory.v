`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// DataMemory - Block RAM version
//
// Changes vs the original:
//   * depth 131072 -> 32768 words  (INT8-packed weights fit in 28,502)
//   * asynchronous read -> registered (synchronous) read
//     This is what allows Vivado to infer BRAM instead of building
//     65,536 RAM64X1S primitives out of LUTs.
//   * added 'en' so the surrounding FSM controls when a read is launched.
//
// TIMING CONTRACT: assert en (and addr) during state S_EXEC.
//                  read_data is valid during the FOLLOWING state (S_WB).
//
// Resource cost: 32768 x 32 = 1024 Kb = 32 BRAM36 tiles of the 75 on XC7S50.
//////////////////////////////////////////////////////////////////////////////////

module DataMemory #(
    parameter AW       = 15,                 // 2^15 = 32768 words
    parameter MEM_FILE = "data_mac4.mem"
)(
    input               clk,
    input               en,                  // launch an access this cycle
    input               mem_write,
    input      [31:0]   addr,                // WORD address (matches packer)
    input      [31:0]   write_data,
    output reg [31:0]   read_data
);

    (* ram_style = "block" *)
    reg [31:0] mem [0:(1<<AW)-1];

    wire [AW-1:0] word_index = addr[AW-1:0];

    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = 32'b0;
        $readmemb(MEM_FILE, mem);
    end

    // Single always block, no reset, no initialisation loop.
    // Any of those three would break BRAM inference.
    always @(posedge clk) begin
        if (en) begin
            if (mem_write)
                mem[word_index] <= write_data;
            read_data <= mem[word_index];    // read-first
        end
    end

endmodule
