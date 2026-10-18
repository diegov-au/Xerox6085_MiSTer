module sdram #(
	parameter CLK_HZ = 96_000_000
) (
	input             clk,
	input             init,

	output reg [12:0] SDRAM_A,
	output reg  [1:0] SDRAM_BA,
	input      [15:0] SDRAM_DQ_IN,
	output     [15:0] SDRAM_DQ_OUT,
	output            SDRAM_DQ_OE,
	output            SDRAM_DQML,
	output            SDRAM_DQMH,
	output reg        SDRAM_nCS,
	output reg        SDRAM_nRAS,
	output reg        SDRAM_nCAS,
	output reg        SDRAM_nWE,
	output            SDRAM_CKE,
	output            SDRAM_CLK,

	input      [24:0] p0_addr,
	input      [15:0] p0_din,
	input             p0_wide,
	input             p0_mask_all,
	input             p0_we,
	input             p0_req,
	output reg        p0_ack,
	output reg  [7:0] p0_dout,

	input      [24:0] p1_addr,
	input      [15:0] p1_din,
	input             p1_we,
	input             p1_req,
	output reg        p1_ack,
	output reg [15:0] p1_dout,

	input      [24:0] p2_addr,
	input             p2_req,
	output reg        p2_ack,
	output reg [15:0] p2_dout,
	output reg [31:0] dbg_p2_stall,

	input      [24:0] p3_addr,
	input             p3_req,
	output reg        p3_ack,
	output reg  [7:0] p3_dout,

	output reg        ready
);

localparam int INIT_WAIT   = (CLK_HZ / 1_000_000) * 200;
localparam int REFRESH_INT = (CLK_HZ / 1_000_000) * 7;
localparam     CAS_LATENCY = 3'd2;
localparam int RC_CYCLES   = 6;

localparam [3:0] CMD_INHIBIT     = 4'b1111;
localparam [3:0] CMD_NOP         = 4'b0111;
localparam [3:0] CMD_ACTIVE      = 4'b0011;
localparam [3:0] CMD_READ        = 4'b0101;
localparam [3:0] CMD_WRITE       = 4'b0100;
localparam [3:0] CMD_PRECHARGE   = 4'b0010;
localparam [3:0] CMD_AUTOREFRESH = 4'b0001;
localparam [3:0] CMD_LOADMODE    = 4'b0000;

assign SDRAM_CKE = 1'b1;
assign SDRAM_CLK = clk;

reg [15:0] dq_out;
reg        dq_oe;
assign SDRAM_DQ_OUT = dq_out;
assign SDRAM_DQ_OE  = dq_oe;

task automatic cmd(input [3:0] c);
	begin
		SDRAM_nCS  <= c[3];
		SDRAM_nRAS <= c[2];
		SDRAM_nCAS <= c[1];
		SDRAM_nWE  <= c[0];
	end
endtask

wire        sel_p0    = p0_req;
wire        sel_p1    = ~p0_req & p1_req;
wire        sel_p2    = ~p0_req & ~p1_req & p2_req;
wire        sel_p3    = ~p0_req & ~p1_req & ~p2_req & p3_req;

wire        sel_we    = sel_p0 ? p0_we : sel_p1 ? p1_we : 1'b0;

wire [24:0] sel_addr  = sel_p0 ? p0_addr :
                        sel_p1 ? p1_addr :
                        sel_p2 ? p2_addr : p3_addr;

wire [15:0] sel_din   = sel_p1 ? p1_din
                                : (p0_wide ? p0_din : {p0_din[7:0], p0_din[7:0]});

wire [23:0] word_addr = sel_addr[24:1];
wire  [8:0] a_col     = word_addr[8:0];
wire [12:0] a_row     = word_addr[21:9];
wire  [1:0] a_bank    = word_addr[23:22];

reg  [24:0] cur_addr;
wire [23:0] cur_word = cur_addr[24:1];
wire  [8:0] cur_col  = cur_word[8:0];

localparam [3:0] S_INIT      = 0,
                 S_INIT_PRE  = 1,
                 S_INIT_REF  = 2,
                 S_INIT_MODE = 3,
                 S_IDLE      = 4,
                 S_ACTIVE    = 5,
                 S_RW        = 6,
                 S_READ_WAIT = 7,
                 S_DONE      = 8,
                 S_REFRESH   = 9;

reg  [3:0] state;
reg [31:0] wait_ctr;
reg [15:0] refresh_ctr;
reg  [3:0] init_refs;
reg        pending_we;
reg        pending_p1;
reg        pending_p2;
reg        pending_p3;
reg        pending_lane;
reg  [2:0] cas_ctr;

reg [15:0] dq_in_r;
always @(posedge clk) dq_in_r <= SDRAM_DQ_IN;

wire dq_oe_next = pending_we & ((state == S_ACTIVE) | (state == S_DONE));
always @(posedge clk) dq_oe <= dq_oe_next;

reg [1:0] dqm;

assign {SDRAM_DQMH, SDRAM_DQML} = SDRAM_A[12:11];

initial begin
	state       = S_INIT;
	wait_ctr    = 0;
	refresh_ctr = 0;
	init_refs   = 0;
	ready       = 0;
	p0_ack      = 0;
	p1_ack      = 0;
	p2_ack      = 0;
	p3_ack      = 0;
	dbg_p2_stall = 0;
	dq_oe       = 0;
	dqm         = 2'b11;
end

always @(posedge clk) begin
	p0_ack     <= 1'b0;
	p1_ack     <= 1'b0;
	p2_ack     <= 1'b0;
	p3_ack     <= 1'b0;

	if (p2_req && !p2_ack && !(state == S_IDLE && sel_p2))
		dbg_p2_stall <= dbg_p2_stall + 1'b1;
	cmd(CMD_NOP);

	if (refresh_ctr != 16'hFFFF) refresh_ctr <= refresh_ctr + 1'b1;

	if (init) begin
		state       <= S_INIT;
		wait_ctr    <= 0;
		init_refs   <= 0;
		ready       <= 1'b0;
		cmd(CMD_INHIBIT);
	end
	else case (state)

	S_INIT: begin
		cmd(CMD_INHIBIT);
		if (wait_ctr >= INIT_WAIT) begin wait_ctr <= 0; state <= S_INIT_PRE; end
		else wait_ctr <= wait_ctr + 1'b1;
	end

	S_INIT_PRE: begin
		cmd(CMD_PRECHARGE);
		SDRAM_A[10] <= 1'b1;
		wait_ctr    <= 0;
		init_refs   <= 0;
		state       <= S_INIT_REF;
	end

	S_INIT_REF: begin
		if (wait_ctr >= RC_CYCLES) begin
			wait_ctr <= 0;
			cmd(CMD_AUTOREFRESH);
			if (init_refs >= 8) state <= S_INIT_MODE;
			else init_refs <= init_refs + 1'b1;
		end
		else wait_ctr <= wait_ctr + 1'b1;
	end

	S_INIT_MODE: begin
		if (wait_ctr >= RC_CYCLES) begin
			cmd(CMD_LOADMODE);
			SDRAM_BA <= 2'b00;
			SDRAM_A  <= {3'b000, 1'b1, 2'b00, CAS_LATENCY, 1'b0, 3'b000};
			wait_ctr <= 0;
			state    <= S_IDLE;
			ready    <= 1'b1;
		end
		else wait_ctr <= wait_ctr + 1'b1;
	end

	S_IDLE: begin
		if (refresh_ctr >= REFRESH_INT) begin
			cmd(CMD_AUTOREFRESH);
			refresh_ctr <= 0;
			wait_ctr    <= 0;
			state       <= S_REFRESH;
		end
		else if (p1_req || p2_req || p3_req || p0_req) begin
			cmd(CMD_ACTIVE);
			SDRAM_A      <= a_row;
			SDRAM_BA     <= a_bank;
			pending_p1   <= sel_p1;
			pending_p2   <= sel_p2;
			pending_p3   <= sel_p3;
			pending_we   <= sel_we;
			pending_lane <= sel_addr[0];
			dqm          <= !sel_we      ? 2'b00
			                : sel_p1     ? 2'b00
			                : p0_mask_all ? 2'b11
			                : p0_wide     ? 2'b00
			                              : {~sel_addr[0], sel_addr[0]};
			cur_addr     <= sel_addr;
			dq_out       <= sel_din;
			wait_ctr     <= 0;
			state        <= S_ACTIVE;
		end
	end

	S_REFRESH: begin
		if (wait_ctr >= RC_CYCLES) state <= S_IDLE;
		else wait_ctr <= wait_ctr + 1'b1;
	end

	S_ACTIVE: begin
		if (wait_ctr >= 1) begin
			SDRAM_A    <= {dqm, 2'b10, cur_col};
			if (pending_we) begin
				cmd(CMD_WRITE);
				wait_ctr <= 0;
				state    <= S_DONE;
			end
			else begin
				cmd(CMD_READ);
				cas_ctr <= 0;
				state   <= S_READ_WAIT;
			end
		end
		else wait_ctr <= wait_ctr + 1'b1;
	end

	S_READ_WAIT: begin
		if (cas_ctr >= CAS_LATENCY + 1) begin
			if (pending_p1) begin
				p1_dout <= dq_in_r;
				p1_ack  <= 1'b1;
			end
			else if (pending_p2) begin
				p2_dout <= dq_in_r;
				p2_ack  <= 1'b1;
			end
			else if (pending_p3) begin
				p3_dout <= pending_lane ? dq_in_r[15:8] : dq_in_r[7:0];
				p3_ack  <= 1'b1;
			end
			else begin
				p0_dout <= pending_lane ? dq_in_r[15:8] : dq_in_r[7:0];
				p0_ack  <= 1'b1;
			end
			wait_ctr <= 0;
			state    <= S_DONE;
		end
		else cas_ctr <= cas_ctr + 1'b1;
	end

	S_DONE: begin
		if (pending_we) begin
			if (pending_p1) p1_ack <= 1'b1;
			else            p0_ack <= 1'b1;
			pending_we <= 1'b0;
		end
		if (wait_ctr >= 2) state <= S_IDLE;
		else wait_ctr <= wait_ctr + 1'b1;
	end

	default: state <= S_IDLE;
	endcase
end

endmodule
