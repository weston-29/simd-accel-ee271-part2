      `include "defines.sv"

module buffer (
    // Clock and Reset
    input wire clk,
    input wire rst_n,

    // Input Instruction
    input buf_inst_t    buf_inst,
    input logic         buf_inst_valid,

    // Outputs
    output logic [`MEM0_BITWIDTH-1:0] matrix_data,
    output logic [`MEM1_BITWIDTH-1:0] vector_data,
    input  logic [`MEM2_BITWIDTH-1:0] output_data
);

    // START IMPLEMENTATION

    // ---------------------------------------------------------------
    // execute_instruction(): decode the opcode
    //   if opcode == MI.READ  -> _handle_read
    //   if opcode == MI.WRITE -> _handle_write
    //   if opcode == MI.NOP   -> nothing (neither signal is set)
    // ---------------------------------------------------------------
    logic is_read, is_write;
    assign is_read  = buf_inst_valid && (buf_inst.opcode == `BUF_READ);
    assign is_write = buf_inst_valid && (buf_inst.opcode == `BUF_WRITE);

    // ---------------------------------------------------------------
    // _handle_read(), MEM0:
    //   self._mem0_output_port = self._mem0[a_offset]
    // ---------------------------------------------------------------
    array #(
        .DW(`MEM0_BITWIDTH),
        .NW(`MEM0_DEPTH),
        .AW(`MEM0_ADDR_WIDTH)
    ) u_matrix_mem (
        .clk(clk),
        .cen(~is_read),                 // only read on a READ (active-low enable)
        .wen('1),                       // never written
        .gwen('1),
        .a(buf_inst.mema_offset),       // [a_offset]
        .d('0),
        .q(matrix_data)                 // -> _mem0_output_port
    );

    // ---------------------------------------------------------------
    // _handle_read(), MEM1 address:
    //   word = self._mem1[b_offset // lanes]
    //   // 4 = drop 2 bits, // 2 = drop 1 bit, // 1 = drop none
    // ---------------------------------------------------------------
    logic [`MEM1_ADDR_WIDTH-1:0] mem1_addr;
    always_comb begin
        case (buf_inst.mode)
            `MODE_INT8:  mem1_addr = buf_inst.memb_offset[`BUF_MEMB_OFFSET_BITWIDTH-1:2];
            `MODE_INT16: mem1_addr = buf_inst.memb_offset[`BUF_MEMB_OFFSET_BITWIDTH-2:1];
            default:     mem1_addr = buf_inst.memb_offset[`MEM1_ADDR_WIDTH-1:0];
        endcase
    end

    logic [`MEM1_BITWIDTH-1:0] mem1_q;      // this is "word"
    array #(
        .DW(`MEM1_BITWIDTH),
        .NW(`MEM1_DEPTH),
        .AW(`MEM1_ADDR_WIDTH)
    ) u_vector_mem (
        .clk(clk),
        .cen(~is_read),
        .wen('1),
        .gwen('1),
        .a(mem1_addr),
        .d('0),
        .q(mem1_q)
    );

    // ---------------------------------------------------------------
    // _handle_read(), MEM1 lane select:
    //   select = b_offset % lanes      (the low bits of MemBOffset)
    // The SRAM answers one cycle later, so remember select and mode
    // for one cycle so they line up with mem1_q.
    // ---------------------------------------------------------------
    logic [`BUF_MODE_BITWIDTH-1:0] mode_q;
    logic [1:0]                    select_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_q   <= `MODE_INT32;
            select_q <= '0;
        end else if (is_read) begin
            mode_q   <= buf_inst.mode;
            select_q <= buf_inst.memb_offset[1:0];
        end
    end

    // ---------------------------------------------------------------
    // _handle_read(), MEM1 slice + broadcast:
    //   piece = word[start : start + lane_width]
    //   self._mem1_output_port = piece * lanes
    // In Verilog bit 0 is the LSB, so lane k is simply [k*w +: w].
    // ---------------------------------------------------------------
    always_comb begin
        case (mode_q)
            `MODE_INT8:  vector_data = {4{mem1_q[select_q    * 8  +: 8 ]}};
            `MODE_INT16: vector_data = {2{mem1_q[select_q[0] * 16 +: 16]}};
            default:     vector_data = mem1_q;
        endcase
    end

    // ---------------------------------------------------------------
    // _handle_write():
    //   self._mem2[a_offset] = self._mem2_input_port
    // ---------------------------------------------------------------
    logic write_control_n;
    assign write_control_n = ~is_write;     // active-low: 0 means "write now"

    array #(
        .DW(`MEM2_BITWIDTH),
        .NW(`MEM2_DEPTH),
        .AW(`MEM2_ADDR_WIDTH),
        .INITIALIZE_MEMORY(1)
    ) u_output_mem (
        .clk(clk),
        .cen('0),
        .wen('0),
        .gwen(write_control_n),
        .a(buf_inst.mema_offset),           // [a_offset]
        .d(output_data),                    // _mem2_input_port
        .q()                                // never read by the buffer
    );

    // END IMPLEMENTATION


endmodule
