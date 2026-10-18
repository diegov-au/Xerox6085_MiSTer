module xerox_machine
(
	input             clk,
	input             reset,

	input             ld_we,
	input       [9:0] ld_a,
	input      [15:0] ld_d,
	input      [12:0] fw_a,
	input      [31:0] fw_d,
	input             fw_we,
	input      [12:0] cs_n,

	output reg [24:0] m_addr,
	output reg [15:0] m_din,
	output reg        m_we,
	output reg        m_req,
	input             m_ack,
	input      [15:0] m_dout,

	output reg        w_stb,
	output reg [20:0] w_a,
	output reg [15:0] w_d,

	input             vsync,

	output     [31:0] disk_lba,
	output      [4:0] disk_cmd,
	output            disk_go,
	input             disk_done,
	input             disk_ok,
	input      [31:0] disk_sectors,
	input       [8:0] sb_a,
	input      [15:0] sb_wd,
	input             sb_we,
	output     [15:0] sb_rd,

	input      [31:0] mouse_xy,
	input     [143:0] keys,
	input      [31:0] unix_time,
	input      [63:0] clock_rtc,
	input      [31:0] fdd_info,
	input             boot_floppy,
	input             legacy_clock,

	output     [31:0] dispatches,
	output            running,
	output     [31:0] cursor_xy,
	output    [255:0] cursor_pat,
	output            beep,
	output            beep_on
);

wire [15:0] beep_div;

wire        iop_hold;
reg         ev_vsync, ev_vsync_safe, ev_input;
wire        freeze = iop_hold | ev_vsync | ev_input;
wire        mem_c2, mem_wr;
reg         eng_done;
wire        en_mem = ~mem_c2 | eng_done;
wire        cp_en  = en_mem & ~freeze;
assign      running = cp_en;

wire [20:0] mrd_md_a, mwr_a;
wire [15:0] mwr_d;
wire        mwr_en;
reg  [15:0] eng_q;
wire [23:0] io_rd_a, io_ref_a, io_a;
wire [15:0] io_d;
wire        io_we, io_ref_stb;
wire        mpint_set, mpint_clr, dispatching, cp_mint, cp_clr_int, cp_wdc0;
wire        tmr_int;
reg         iop_int;
wire        tick_fire;
wire [11:0] cs_a;
wire [47:0] cs_d;
wire        cs_we;

xerox_cp48 cpu
(
	.clk(clk), .reset(reset), .en(cp_en),
	.cs_a(cs_a), .cs_d(cs_d), .cs_we(cs_we),
	.mrd_md_a(mrd_md_a), .mrd_md_d(eng_q),
	.mwr_a(mwr_a), .mwr_d(mwr_d), .mwr_en(mwr_en),
	.mem_c2(mem_c2), .mem_wr(mem_wr),
	.ld_we(ld_we), .ld_a(ld_a), .ld_d(ld_d),
	.io_rd_a(io_rd_a), .io_q(io_q), .io_hit(io_hit),
	.io_ref_a(io_ref_a), .io_ref_stb(io_ref_stb),
	.io_ref_q(io_ref_q), .io_ref_hit(io_ref_hit),
	.io_a(io_a), .io_d(io_d), .io_we(io_we),
	.ext_stat(16'd0), .ext_debb(16'd0),
	.timer_int(tmr_int | tick_fire),
	.iop_int(iop_int),
	.dispatching(dispatching), .mint_o(cp_mint), .wdc_zero(cp_wdc0),
	.cs_n(cs_n),
	.mpint_set(mpint_set), .mpint_clr(mpint_clr), .clr_int(cp_clr_int),
	.dbg_pc(), .dbg_phase()
);

reg [31:0] disp_n;
always @(posedge clk)
	if (reset) disp_n <= 32'd0;
	else if (dispatching) disp_n <= disp_n + 32'd1;
assign dispatches = disp_n;

reg [15:0] io_val[0:255];
reg [15:0] io_tag[0:255];
reg        io_vld[0:255];

wire [15:0] io_q   = io_val[io_rd_a[7:0]];
wire        io_hit = io_vld[io_rd_a[7:0]] && (io_tag[io_rd_a[7:0]] == io_rd_a[23:8]);
wire [15:0] tmr_q;
wire        tmr_sel;
wire [15:0] io_ref_q   = tmr_sel ? tmr_q : io_val[io_ref_a[7:0]];
wire        io_ref_hit = tmr_sel ? 1'b1
                       : (io_vld[io_ref_a[7:0]] && (io_tag[io_ref_a[7:0]] == io_ref_a[23:8]));

integer j;
always @(posedge clk) begin
	if (reset) begin
		for (j = 0; j < 256; j = j + 1) io_vld[j] <= 1'b0;
	end
	else if (io_we) begin
		io_val[io_a[7:0]] <= io_d;
		io_tag[io_a[7:0]] <= io_a[23:8];
		io_vld[io_a[7:0]] <= 1'b1;
	end
end

xerox_timer8254 #(.DIV_N(512), .FREE(1)) timer
(
	.clk(clk), .reset(reset), .en(cp_en),
	.rd_a(io_ref_a), .rd_stb(io_ref_stb), .rd_q(tmr_q), .sel(tmr_sel),
	.wr_a(io_a), .wr_d(io_d), .wr_en(io_we),
	.intr(tmr_int)
);

localparam [20:0] TICK_CYCLES = 21'd1638400;
reg [20:0] tick_cnt;
reg        tick_pend;
assign tick_fire = tick_pend & ~cp_mint & cp_en & cp_wdc0;

always @(posedge clk) begin
	if (reset) begin
		tick_cnt  <= 21'd0;
		tick_pend <= 1'b0;
	end
	else begin
		if (tick_cnt == TICK_CYCLES - 21'd1) begin
			tick_cnt  <= 21'd0;
			tick_pend <= 1'b1;
		end
		else tick_cnt <= tick_cnt + 21'd1;
		if (tick_fire) tick_pend <= 1'b0;
	end
end

localparam [20:0] MAILBOX_WAKE = 21'h050301;
reg         vs_pend, in_pend, in_svc;
reg   [6:0] svc_age;
reg  [31:0] mouse_q;
reg [143:0] keys_q;
wire        svc_now = in_svc | cp_clr_int;
wire        safe_vs = cp_en & ~cp_mint & ~svc_now;
wire        safe_in = cp_en;

always @(posedge clk) begin
	if (reset) begin in_svc <= 1'b0; svc_age <= 7'd0; end
	else if (cp_clr_int) begin in_svc <= 1'b1; svc_age <= 7'd0; end
	else if (dispatching || (mwr_en && mwr_a == MAILBOX_WAKE)
	         || (in_svc && cp_en && svc_age == 7'd127)) in_svc <= 1'b0;
	else if (in_svc && cp_en) svc_age <= svc_age + 7'd1;
end

localparam [15:0] VS_HELD_CYCLES = 16'd32768;
reg         vs_curdone;
reg  [15:0] vs_age;

always @(posedge clk) begin
	if (reset) begin
		vs_pend  <= 1'b0;
		in_pend  <= 1'b0;
		ev_vsync <= 1'b0;
		ev_vsync_safe <= 1'b0;
		ev_input <= 1'b0;
		vs_curdone <= 1'b0;
		vs_age   <= 16'd0;
		mouse_q  <= mouse_xy;
		keys_q   <= keys;
	end
	else begin
		ev_vsync <= 1'b0;
		ev_input <= 1'b0;
		if (vsync) begin vs_pend <= 1'b1; vs_curdone <= 1'b0; vs_age <= 16'd0; end
		else if (vs_pend && vs_age != 16'hFFFF) vs_age <= vs_age + 16'd1;
		if (mouse_xy != mouse_q || keys != keys_q) begin
			in_pend <= 1'b1;
			mouse_q <= mouse_xy;
			keys_q  <= keys;
		end
		if (safe_vs && vs_pend) begin
			ev_vsync <= 1'b1; ev_vsync_safe <= 1'b1; vs_pend <= 1'b0;
		end
		else if (cp_en && vs_pend && !vs_curdone && vs_age >= VS_HELD_CYCLES) begin
			ev_vsync <= 1'b1; ev_vsync_safe <= 1'b0; vs_curdone <= 1'b1;
		end
		if (safe_in && in_pend) begin ev_input <= 1'b1; in_pend <= 1'b0; end
	end
end

wire [20:0] iop_cpm_a;
wire [15:0] iop_cpm_wd, iop_wake_mask;
wire        iop_cpm_we, iop_cpm_req, iop_wake_stb;
reg         iop_rdy;
reg  [15:0] iop_q;
reg  [31:0] usec;
reg   [5:0] usec_div;

xerox_iop iop
(
	.clk(clk), .reset(reset),
	.fw_a(fw_a), .fw_d(fw_d), .fw_we(fw_we),
	.cpm_a(iop_cpm_a), .cpm_wd(iop_cpm_wd), .cpm_we(iop_cpm_we),
	.cpm_req(iop_cpm_req), .cpm_rd(iop_q), .cpm_ready(iop_rdy),
	.ev_notify(mpint_set),
	.ev_lockrel(mwr_en & (mwr_a == 21'h052000)),
	.ev_vsync(ev_vsync), .ev_vsync_safe(ev_vsync_safe), .ev_input(ev_input),
	.wake_mask(iop_wake_mask), .wake_stb(iop_wake_stb), .hold(iop_hold),
	.disk_lba(disk_lba), .disk_cmd(disk_cmd), .disk_go(disk_go),
	.disk_done(disk_done), .disk_ok(disk_ok), .disk_sectors(disk_sectors),
	.sb_a(sb_a), .sb_wd(sb_wd), .sb_we(sb_we), .sb_rd(sb_rd),
	.mouse_xy(mouse_xy), .keys(keys), .usec(usec), .unix_time(unix_time), .clock_rtc(clock_rtc),
	.fdd_info(fdd_info),
	.cfg_boot(1'b1), .cfg_free_clock(1'b1), .cfg_boot_floppy(boot_floppy), .cfg_legacy_clock(legacy_clock), .cs_a(cs_a), .cs_d(cs_d), .cs_we(cs_we),
	.cursor_xy(cursor_xy), .cursor_pat(cursor_pat), .beep_div(beep_div)
);

always @(posedge clk) iop_int <= reset ? 1'b0 : iop_wake_stb;

always @(posedge clk) begin
	if (reset) begin usec <= 32'd0; usec_div <= 6'd0; end
	else if (usec_div == 6'd31) begin usec_div <= 6'd0; usec <= usec + 32'd1; end
	else usec_div <= usec_div + 6'd1;
end

reg eng_pend, iop_pend;

always @(posedge clk) begin
	w_stb   <= 1'b0;
	iop_rdy <= 1'b0;
	if (reset) begin
		m_req    <= 1'b0;
		m_we     <= 1'b0;
		eng_pend <= 1'b0;
		eng_done <= 1'b0;
		iop_pend <= 1'b0;
	end
	else begin
		if (eng_done && cp_en) eng_done <= 1'b0;

		if (m_req) begin
			if (m_ack) begin
				m_req <= 1'b0;
				if (eng_pend) begin
					eng_pend <= 1'b0;
					eng_done <= 1'b1;
					eng_q    <= m_we ? m_din : m_dout;
				end
				if (iop_pend) begin
					iop_pend <= 1'b0;
					iop_rdy  <= 1'b1;
					iop_q    <= m_dout;
				end
			end
		end
		else if (mem_c2 && !eng_done && !eng_pend && !freeze) begin
			m_req    <= 1'b1;
			m_addr   <= {3'd0, mem_wr ? mwr_a : mrd_md_a, 1'b0};
			m_we     <= mem_wr;
			m_din    <= mwr_d;
			eng_pend <= 1'b1;
			if (mem_wr) begin w_stb <= 1'b1; w_a <= mwr_a; w_d <= mwr_d; end
		end
		else if (iop_cpm_req && !iop_pend && !iop_rdy) begin
			m_req    <= 1'b1;
			m_addr   <= {3'd0, iop_cpm_a, 1'b0};
			m_we     <= iop_cpm_we;
			m_din    <= iop_cpm_wd;
			iop_pend <= 1'b1;
			if (iop_cpm_we) begin w_stb <= 1'b1; w_a <= iop_cpm_a; w_d <= iop_cpm_wd; end
		end
	end
end

localparam [26:0] CLK_HZ  = 27'd32_000_000;
localparam [26:0] BEEP_HZ = 27'd2_764_800;

reg  [26:0] bclk_acc = 27'd0;
reg  [15:0] bcnt     = 16'd0;
reg         beep_q   = 1'b0;
reg  [15:0] bdiv_was = 16'd0;
reg  [25:0] blen     = 26'd0;
wire        blong    = blen == 26'd63_999_999;
wire [26:0] bclk_nx  = bclk_acc + BEEP_HZ;
wire        btick    = bclk_nx >= CLK_HZ;
assign beep    = beep_q;
assign beep_on = beep_div != 16'd0 && !blong;

always @(posedge clk) begin
	bdiv_was <= beep_div;
	if (beep_div != bdiv_was) blen <= 26'd0;
	else if (beep_div != 16'd0 && !blong) blen <= blen + 26'd1;
end

always @(posedge clk) begin
	bclk_acc <= btick ? bclk_nx - CLK_HZ : bclk_nx;
	if (reset || beep_div == 16'd0 || blong) begin
		beep_q <= 1'b0;
		bcnt   <= 16'd0;
	end
	else if (btick) begin
		if (bcnt == 16'd0) begin
			bcnt   <= (beep_div[15:1] == 15'd0) ? 16'd0 : {1'b0, beep_div[15:1]} - 16'd1;
			beep_q <= ~beep_q;
		end
		else bcnt <= bcnt - 16'd1;
	end
end

endmodule
