module xerox_loader
(
	input             clk,
	input             reset,
	input             sdram_ready,
	input             restart,

	input             ioctl_download,
	input      [15:0] ioctl_index,
	input             ioctl_wr,
	input      [26:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	output            ioctl_wait,

	output reg [24:0] m_addr,
	output reg [15:0] m_din,
	output reg        m_req,
	input             m_ack,

	output reg        ld_we,
	output reg  [9:0] ld_a,
	output reg [15:0] ld_d,
	output reg [12:0] fw_a,
	output reg [31:0] fw_d,
	output reg        fw_we,
	output reg [12:0] cs_n,

	output reg        z_we,
	output reg [20:0] z_a,

	output reg        booted
);

localparam [26:0] A_SEAT = 27'h08000, A_END = 27'h08244;
localparam  [9:0] SEAT_LAST = 10'h120;

reg [21:0] z_idx;
wire       zeroed = z_idx[21];
reg        busy;

reg        pend;
reg  [7:0] pend_d;
reg [26:0] pend_a;

wire loading = ioctl_download && ioctl_index == 16'd0;
assign ioctl_wait = loading && (!zeroed || pend);

reg  [7:0] hi;
reg        was_loading, dl_done;

reg [15:0] seat_mem[0:511];
reg [15:0] seat_q;
reg  [9:0] rp_i;
reg        replay, rp_ph, restart_q;

always @(posedge clk) begin
	if (ld_we) seat_mem[ld_a] <= ld_d;
	seat_q <= seat_mem[rp_i];
end

always @(posedge clk) begin
	ld_we <= 1'b0;
	fw_we <= 1'b0;
	z_we  <= 1'b0;
	restart_q <= restart;
	if (reset) begin
		m_req       <= 1'b0;
		z_idx       <= 22'd0;
		busy        <= 1'b0;
		pend        <= 1'b0;
		booted      <= 1'b0;
		cs_n        <= 13'd0;
		was_loading <= 1'b0;
		dl_done     <= 1'b0;
		replay      <= 1'b0;
		rp_ph       <= 1'b0;
		rp_i        <= 10'd0;
	end
	else begin
		was_loading <= loading;
		if (was_loading && !loading) dl_done <= 1'b1;
		if (dl_done && zeroed && !pend && !replay) booted <= 1'b1;

		if (restart && !restart_q && booted) begin
			booted <= 1'b0;
			z_idx  <= 22'd0;
			replay <= 1'b1;
			rp_i   <= 10'd0;
			rp_ph  <= 1'b0;
		end
		else if (busy) begin
			if (m_ack) begin busy <= 1'b0; m_req <= 1'b0; end
		end
		else if (!zeroed) begin
			if (sdram_ready) begin
				m_addr <= {3'd0, z_idx[20:0], 1'b0};
				m_din  <= 16'd0;
				m_req  <= 1'b1;
				busy   <= 1'b1;
				z_we   <= 1'b1;
				z_a    <= z_idx[20:0];
				z_idx  <= z_idx + 22'd1;
			end
		end
		else if (pend) begin
			pend <= 1'b0;
			if (pend_a < A_SEAT) begin
				fw_d <= {pend_d, fw_d[31:8]};
				if (pend_a[1:0] == 2'd3) begin
					fw_a  <= pend_a[14:2];
					fw_we <= 1'b1;
				end
			end
			else if (pend_a < A_END) begin
				if (!pend_a[0]) hi <= pend_d;
				else if (pend_a[10:1] < 10'h121) begin
					ld_a  <= pend_a[10:1];
					ld_d  <= {hi, pend_d};
					ld_we <= 1'b1;
				end
				else if (pend_a[10:1] == 10'h121) cs_n <= {hi[4:0], pend_d};
			end
		end
		else if (replay) begin
			if (!rp_ph) rp_ph <= 1'b1;
			else begin
				rp_ph <= 1'b0;
				ld_a  <= rp_i;
				ld_d  <= seat_q;
				ld_we <= 1'b1;
				if (rp_i == SEAT_LAST) replay <= 1'b0;
				else rp_i <= rp_i + 10'd1;
			end
		end

		if (loading && ioctl_wr) begin
			pend   <= 1'b1;
			pend_d <= ioctl_dout;
			pend_a <= ioctl_addr;
		end
	end
end

endmodule
