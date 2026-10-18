`include "xerox_uword48.vh"

module xerox_cp48
(
	input             clk,
	input             reset,
	input             en,

	input      [11:0] cs_a,
	input      [47:0] cs_d,
	input             cs_we,

	output     [20:0] mrd_md_a,
	input      [15:0] mrd_md_d,
	output     [20:0] mwr_a,
	output     [15:0] mwr_d,
	output            mwr_en,
	output            mem_c2,
	output            mem_wr,

	input             ld_we,
	input       [9:0] ld_a,
	input      [15:0] ld_d,

	output     [23:0] io_rd_a,
	input      [15:0] io_q,
	input             io_hit,
	output     [23:0] io_ref_a,
	output            io_ref_stb,
	input      [15:0] io_ref_q,
	input             io_ref_hit,
	output     [23:0] io_a,
	output     [15:0] io_d,
	output            io_we,

	input      [15:0] ext_stat,
	input      [15:0] ext_debb,

	input             timer_int,

	input             iop_int,

	output            dispatching,
	output            mint_o,

	output            wdc_zero,

	input      [12:0] cs_n,

	output            mpint_set,
	output            mpint_clr,
	output            clr_int,

	output     [11:0] dbg_pc,
	output      [1:0] dbg_phase
);

localparam [1:0] IB_EMPTY = 2'd0, IB_BYTE = 2'd1, IB_FULL = 2'd2, IB_WORD = 2'd3;

localparam [3:0] IOX_EXTSTAT = 4'h6, IOX_IO = 4'h7, IOX_DEBB = 4'h8,
                 IOX_INTSTAT = 4'h9, IOX_ERRNIBNSTKP = 4'hA, IOX_RH = 4'hB,
                 IOX_IBNA = 4'hC, IOX_IB = 4'hD, IOX_IBLOW = 4'hE,
                 IOX_IBHIGH = 4'hF;

reg [47:0] cs[0:4095]          /* verilator public_flat_rw */;

reg [11:0] pc                  /* verilator public_flat_rw */;
reg  [1:0] phase               /* verilator public_flat_rw */;
reg [15:0] R[0:15]             /* verilator public_flat_rw */;
reg  [7:0] RH[0:15]            /* verilator public_flat_rw */;
reg [15:0] U[0:255]            /* verilator public_flat_rw */;
reg [15:0] Q                   /* verilator public_flat_rw */;
reg  [3:0] stackP              /* verilator public_flat_rw */;
reg  [3:0] links[0:7]          /* verilator public_flat_rw */;
reg [23:0] MAR                 /* verilator public_flat_rw */;
reg [15:0] MD                  /* verilator public_flat_rw */;
reg        pc16                /* verilator public_flat_rw */;
reg        mint                /* verilator public_flat_rw */;
reg  [2:0] intstat             /* verilator public_flat_rw */;
reg  [1:0] trapcode            /* verilator public_flat_rw */;
reg        click_mar           /* verilator public_flat_rw */;
reg        io_ref              /* verilator public_flat_rw */;
reg  [3:0] pending_or          /* verilator public_flat_rw */;
reg        pend_ibdisp         /* verilator public_flat_rw */;
reg        pend_always         /* verilator public_flat_rw */;
reg        ib_taken_v          /* verilator public_flat_rw */;
reg  [7:0] ib_taken            /* verilator public_flat_rw */;
reg        prev_page_cross     /* verilator public_flat_rw */;
reg [15:0] prev_y              /* verilator public_flat_rw */;
reg        prev_altu           /* verilator public_flat_rw */;
reg  [1:0] ibPtr               /* verilator public_flat_rw */;
reg  [7:0] ibFront             /* verilator public_flat_rw */;
reg  [7:0] IB0                 /* verilator public_flat_rw */;
reg  [7:0] IB1                 /* verilator public_flat_rw */;
reg  [2:0] trap_cd             /* verilator public_flat_rw */;
reg        take_trap0;

reg [31:0] cycles              /* verilator public_flat_rw */;
reg  [7:0] last_op             /* verilator public_flat_rw */;
reg [31:0] ibdisps             /* verilator public_flat_rw */;
reg [31:0] refills             /* verilator public_flat_rw */;
reg [31:0] ib_empty_errors     /* verilator public_flat_rw */;
reg [31:0] rot_loops           /* verilator public_flat_rw */;
reg [31:0] stale_mar           /* verilator public_flat_rw */;
reg [31:0] stale_md            /* verilator public_flat_rw */;
reg [31:0] map_refs            /* verilator public_flat_rw */;
reg [31:0] map_writes          /* verilator public_flat_rw */;
reg [31:0] io_refs             /* verilator public_flat_rw */;
reg [31:0] writes              /* verilator public_flat_rw */;
reg [31:0] pagecross_cancels   /* verilator public_flat_rw */;
reg [31:0] stack_ops           /* verilator public_flat_rw */;
reg [31:0] stackp_loads        /* verilator public_flat_rw */;
reg [31:0] link_reads          /* verilator public_flat_rw */;
reg [31:0] link_writes         /* verilator public_flat_rw */;
reg [31:0] unmodelled          /* verilator public_flat_rw */;

assign dbg_pc    = pc;
assign mint_o    = mint;
assign dispatching = en & ~reset & bump_ibdisp;

reg [15:0] wdc_q               /* verilator public_flat_rw */;
assign wdc_zero = (wdc_q == 16'd0);
assign dbg_phase = phase;

wire [47:0] cur_w = cs[pc];
wire        fy_norm = (`u48_sel_y(cur_w) == 2'd1);
assign mpint_set = en & ~reset & fy_norm & (`u48_fY(cur_w) == FY_SETMPINTIOP);
assign mpint_clr = en & ~reset & fy_norm & (`u48_fY(cur_w) == FY_CLRMPINTIOP);
assign clr_int   = en & ~reset & fy_norm & (`u48_fY(cur_w) == FY_CLRINTERR);

reg [47:0] w;
reg  [3:0] rA, rB, fS, fX, fY, fZ;
reg  [2:0] aS, aF;
reg  [1:0] aD, sel_y, sel_z;
reg        f_cin, f_enU, f_mem;
reg [11:0] inia, nia;

reg  [7:0] uaddr;
reg [15:0] x, yb, aport;
reg [15:0] alu_f;
reg        carry, nibc, pgc, ovr, c15;
reg        cin_eff, n_pc16;
reg        page_cross;
reg        sh, cyc;
reg        shift_right, shift_double, shift_end;

reg [15:0] rr, ss, rop, sop;
reg [16:0] sum16;
reg  [4:0] sum4;
reg  [8:0] sum8;
reg [15:0] sum15;

reg [15:0] rot_r, rot_s, rot_v, rot_a;
reg        rot_cin;
reg  [3:0] rot_amt;

reg  [1:0] ibp_w;
reg  [7:0] ibf_w, ib0_w, ib1_w;
reg  [3:0] sp_w;
reg  [3:0] por_w;
reg        pend_v_w, pend_a_w, taken_v_w;
reg  [7:0] taken_w;
reg [23:0] mar_w;
reg [15:0] md_w;
reg        cmar_w, ioref_w;
reg [23:0] io_ref_a_w;
reg        io_ref_stb_w;
reg  [1:0] trap_w;
reg  [2:0] tcd_w;
reg        mint_w;
reg  [2:0] intstat_w;
reg  [7:0] lastop_w;
reg  [7:0] op_now;

reg        do_map, do_mapa, do_io, map_here, mar_here;
reg [23:0] va;
reg [15:0] map_index;
reg  [3:0] disp_bit;
reg        push_f, pop_f;
reg        u_write, r_write, q_write;
reg [15:0] u_data, r_data, q_data;
reg  [7:0] u_addr_w;
reg        rh_write;
reg  [7:0] rh_data;

reg [20:0] wr_a_w;
reg [15:0] wr_d_w;
reg        wr_en_w;
reg [23:0] io_a_w;
reg [15:0] io_d_w;
reg        io_we_w;

assign mrd_md_a  = MAR[20:0];
assign mwr_a     = wr_a_w;
assign mwr_d     = wr_d_w;
assign mwr_en    = wr_en_w & en & ~reset;
assign mem_c2    = (phase == 2'd1) & click_mar & ~io_ref & ~reset;
assign mem_wr    = wr_en_w & ~reset;
assign io_rd_a   = MAR;
assign io_ref_a   = io_ref_a_w;
assign io_ref_stb = io_ref_stb_w & en & ~reset;
assign io_a      = io_a_w;
assign io_d      = io_d_w;
assign io_we     = io_we_w & en & ~reset;

reg [11:0] n_pc;
reg  [1:0] n_phase;
reg [31:0] n_cycles;

reg bump_ibdisp, bump_refill, bump_ibempty, bump_rotloop, bump_stalemar,
    bump_stalemd, bump_mapref, bump_mapwrite, bump_ioref, bump_write,
    bump_pxcancel, bump_stackop, bump_spload, bump_linkr, bump_linkw,
    bump_unmodelled;

integer i;

always @(*) begin
	w    = cs[pc];
	rA   = `u48_rA(w);
	rB   = `u48_rB(w);
	aS   = `u48_aS(w);
	aF   = `u48_aF(w);
	aD   = `u48_aD(w);
	f_cin= `u48_Cin(w);
	f_enU= `u48_enU(w);
	f_mem= `u48_mem(w);
	fS   = `u48_fS(w);
	fX   = `u48_fX(w);
	fY   = `u48_fY(w);
	fZ   = `u48_fZ(w);
	inia = `u48_inia(w);
	sel_y = `u48_sel_y(w);
	sel_z = `u48_sel_z(w);

	ibp_w = ibPtr;  ibf_w = ibFront;  ib0_w = IB0;  ib1_w = IB1;
	sp_w  = stackP;
	pend_v_w = pend_ibdisp;  pend_a_w = pend_always;
	taken_v_w = ib_taken_v;  taken_w = ib_taken;
	mar_w = MAR;  md_w = MD;  cmar_w = click_mar;  ioref_w = io_ref;
	trap_w = trapcode;  tcd_w = trap_cd;
	mint_w = mint;  intstat_w = intstat;
	lastop_w = last_op;  op_now = 8'd0;
	n_pc16 = pc16;

	bump_ibdisp=0; bump_refill=0; bump_ibempty=0; bump_rotloop=0;
	bump_stalemar=0; bump_stalemd=0; bump_mapref=0; bump_mapwrite=0;
	bump_ioref=0; bump_write=0; bump_pxcancel=0; bump_stackop=0;
	bump_spload=0; bump_linkr=0; bump_linkw=0; bump_unmodelled=0;

	// SYNTHESIS is a latch. `verilator --lint-only -Wall` names all twenty-five
	shift_right = 1'b0; shift_double = 1'b0; shift_end = 1'b0;
	yb = 16'd0; nia = 12'd0; disp_bit = 4'd0; por_w = 4'd0;
	do_map = 1'b0; do_mapa = 1'b0; do_io = 1'b0;
	map_here = 1'b0; mar_here = 1'b0; map_index = 16'd0; va = 24'd0;
	push_f = 1'b0; pop_f = 1'b0;
	rh_write = 1'b0; rh_data = 8'd0;
	u_write = 1'b0; u_addr_w = 8'd0; u_data = 16'd0;
	take_trap0 = 1'b0; n_pc = 12'd0; n_phase = 2'd0; n_cycles = 32'd0;

	wr_a_w = 21'd0; wr_d_w = 16'd0; wr_en_w = 1'b0;
	io_a_w = 24'd0; io_d_w = 16'd0; io_we_w = 1'b0;
	io_ref_a_w = 24'd0; io_ref_stb_w = 1'b0;
	if ({1'b0, pc} >= cs_n) bump_unmodelled = 1'b1;

	uaddr = (sel_z < 2'd2) ? {4'd0, stackP}
	      : prev_altu      ? {rA, prev_y[3:0]}
	      :                  {rA, fZ};

	rot_cin = (fX == FX_CIN_PC16) ? pc16 : f_cin;
	case (aS)
		3'd0: begin rot_r = R[rA];  rot_s = Q;     end
		3'd1: begin rot_r = R[rA];  rot_s = R[rB]; end
		3'd2: begin rot_r = 16'd0;  rot_s = Q;     end
		3'd3: begin rot_r = 16'd0;  rot_s = R[rB]; end
		default: begin rot_r = 16'd0; rot_s = R[rA]; end
	endcase
	case (aF)
		3'd0: rot_v = rot_r + rot_s + {15'd0, rot_cin};
		3'd1: rot_v = rot_s + ~rot_r + {15'd0, rot_cin};
		3'd2: rot_v = rot_r + ~rot_s + {15'd0, rot_cin};
		3'd3: rot_v = rot_r | rot_s;
		3'd4: rot_v = rot_r & rot_s;
		3'd5: rot_v = (~rot_r) & rot_s;
		3'd6: rot_v = rot_r ^ rot_s;
		3'd7: rot_v = ~(rot_r ^ rot_s);
	endcase
	if (aD == 2'd2)      rot_a = R[rA];
	else if (aS >= 3'd5) rot_a = prev_y;
	else                 rot_a = rot_v;

	case (fZ)
		FZ_LROT12: rot_amt = 4'd12;
		FZ_LROT8:  rot_amt = 4'd8;
		FZ_LROT4:  rot_amt = 4'd4;
		default:   rot_amt = 4'd0;
	endcase

	x = 16'd0;
	if (f_mem && phase == 2'd2) begin
		if (!click_mar) bump_stalemd = 1'b1;
		x = md_w;
	end
	else if (sel_z == 2'd3) begin
		case (fZ)
		IOX_INTSTAT:
			x = {8'd0, trapcode, 3'd0, intstat[0], intstat[1], intstat[2]};
		IOX_ERRNIBNSTKP:
			x = {9'd0, trapcode, ~ibPtr, ~stackP};
		IOX_IO:
			x = io_hit ? io_q : 16'd0;
		IOX_EXTSTAT: x = ext_stat;
		IOX_DEBB:    x = ext_debb;
		IOX_RH:      x = {8'd0, RH[rB]};
		IOX_IBNA, IOX_IB: begin
			if (ibp_w == IB_EMPTY) begin
				bump_ibempty = 1'b1;
				trap_w = 2'd3;
				if (tcd_w == 3'd0)
					tcd_w = (phase == 2'd0) ? 3'd2 :
					        (phase == 2'd1) ? 3'd4 : 3'd3;
			end
			x = {8'd0, ibf_w};
			if (fZ == IOX_IB) begin
				ibf_w = ibp_w[0] ? ib1_w : ib0_w;
				ibp_w = (ibp_w == IB_FULL) ? IB_WORD :
				        (ibp_w == IB_WORD) ? IB_BYTE : IB_EMPTY;
			end
		end
		IOX_IBLOW, IOX_IBHIGH: begin
			if (ibp_w == IB_EMPTY) begin
				bump_ibempty = 1'b1;
				trap_w = 2'd3;
				if (tcd_w == 3'd0)
					tcd_w = (phase == 2'd0) ? 3'd2 :
					        (phase == 2'd1) ? 3'd4 : 3'd3;
			end
			x = (fZ == IOX_IBLOW) ? {12'd0, ibf_w[3:0]}
			                      : {12'd0, ibf_w[7:4]};
		end
		default: begin
			x = 16'd0;
			bump_unmodelled = 1'b1;
		end
		endcase
	end
	else if (sel_z == 2'd1)
		x = (sel_y == 2'd3) ? {8'd0, fY, fZ} : {12'd0, fZ};
	else if (sel_z == 2'd2)
		x = U[uaddr];
	else if (f_enU && !f_cin && !(fZ >= FZ_LROT0))
		x = U[uaddr];
	else begin
		x = (rot_amt == 4'd0) ? rot_a
		  : ((rot_a << rot_amt) | (rot_a >> (5'd16 - {1'b0, rot_amt})));
		if (aD != 2'd2 && aS >= 3'd5) bump_rotloop = 1'b1;
	end

	aport = R[rA];
	case (aS)
		3'd0: begin rr = aport;  ss = Q;      end
		3'd1: begin rr = aport;  ss = R[rB];  end
		3'd2: begin rr = 16'd0;  ss = Q;      end
		3'd3: begin rr = 16'd0;  ss = R[rB];  end
		3'd4: begin rr = 16'd0;  ss = aport;  end
		3'd5: begin rr = x;      ss = aport;  end
		3'd6: begin rr = x;      ss = Q;      end
		3'd7: begin rr = x;      ss = 16'd0;  end
	endcase

	cin_eff = f_cin;
	if (fX == FX_CIN_PC16 || (sel_z == 2'd0 && fZ == FZ_CIN_PC16)) begin
		cin_eff = pc16;
		n_pc16  = ~pc16;
	end

	rop = (aF == 3'd1) ? ~rr : rr;
	sop = (aF == 3'd2) ? ~ss : ss;
	sum16 = {1'b0, rop} + {1'b0, sop} + {16'd0, cin_eff};
	sum4  = {1'b0, rop[3:0]}  + {1'b0, sop[3:0]}  + {4'd0,  cin_eff};
	sum8  = {1'b0, rop[7:0]}  + {1'b0, sop[7:0]}  + {8'd0,  cin_eff};
	sum15 = {1'b0, rop[14:0]} + {1'b0, sop[14:0]} + {15'd0, cin_eff};

	if (aF <= 3'd2) begin
		alu_f = sum16[15:0];
		carry = sum16[16];
		nibc  = sum4[4];
		pgc   = sum8[8];
		c15   = sum15[15];
		ovr   = carry ^ c15;
	end
	else begin
		case (aF)
			3'd3: alu_f = rr | ss;
			3'd4: alu_f = rr & ss;
			3'd5: alu_f = (~rr) & ss;
			3'd6: alu_f = rr ^ ss;
			default: alu_f = ~(rr ^ ss);
		endcase
		carry = 1'b0; nibc = 1'b0; pgc = 1'b0; c15 = 1'b0; ovr = 1'b0;
	end

	if (f_mem && phase == 2'd0)
		alu_f = {(aF < 3'd4) ? R[rB][15:8] : ~R[rB][15:8], alu_f[7:0]};

	page_cross = (f_mem && phase == 2'd0 && aF <= 3'd2) ? (pgc ^ aF[0]) : 1'b0;

	cyc  = (fX == FX_CYCLE) || (sel_y == 2'd1 && fY == FY_CYCLE);
	sh   = (fX == FX_SHIFT) || cyc;

	r_write = 1'b0;  r_data = alu_f;
	q_write = 1'b0;  q_data = alu_f;

	if (!sh) begin
		case (aD)
			2'd0: begin q_write = 1'b1; q_data = alu_f; end
			2'd1: ;
			2'd2: begin r_write = 1'b1; r_data = alu_f; end
			2'd3: begin r_write = 1'b1; r_data = alu_f; end
		endcase
	end
	else begin
		shift_right  = ~aD[1];
		shift_double = ~aD[0];
		shift_end = cyc ? cin_eff : carry;
		if (shift_double) begin
			if (shift_right) begin
				q_data = {~alu_f[0], Q[15:1]};
				r_data = {shift_end, alu_f[15:1]};
			end
			else begin
				r_data = {alu_f[14:0], Q[15]};
				q_data = {Q[14:0], ~shift_end};
			end
			q_write = 1'b1;
		end
		else if (shift_right)
			r_data = {cyc ? alu_f[0] : cin_eff, alu_f[15:1]};
		else
			r_data = {alu_f[14:0], cyc ? alu_f[15] : cin_eff};
		r_write = 1'b1;
	end

	yb = (!sh && aD == 2'd2) ? aport : alu_f;

	do_map  = (fX == FX_MAP) || (sel_y == 2'd1 && fY == FY_MAP);
	do_mapa = (sel_y == 2'd1 && fY == FY_MAPA);
	do_io   = (sel_y == 2'd1 && fY == FY_IO);
	va        = {RH[rB], yb};
	map_index = va[23:8];

	if (do_map) begin
		mar_w  = {8'h1E, map_index};
		cmar_w = 1'b1;
		bump_mapref = 1'b1;
	end
	if (do_io) begin
		mar_w  = va;
		ioref_w = 1'b1;
		cmar_w  = 1'b1;
		bump_ioref = 1'b1;
		io_ref_a_w = va; io_ref_stb_w = 1'b1;
		md_w = io_ref_hit ? io_ref_q : 16'd0;
	end
	if (do_mapa) begin
		mar_w  = {8'h1E, map_index};
		cmar_w = 1'b1;
		bump_mapwrite = 1'b1;
	end

	if (f_mem) begin
		if (phase == 2'd0 && !ioref_w) begin
			mar_w   = {3'd0, RH[rB][4:0], yb};
		end
		else if (phase == 2'd1 && ioref_w && cmar_w) begin
			io_a_w = mar_w; io_d_w = yb; io_we_w = 1'b1;
		end
		else if (phase == 2'd1 && cmar_w && !prev_page_cross) begin
			wr_a_w = mar_w[20:0]; wr_d_w = yb; wr_en_w = 1'b1;
			bump_write = 1'b1;
		end
		if (phase != 2'd0 && !click_mar) bump_stalemar = 1'b1;
	end
	if (f_mem && phase == 2'd0) cmar_w = 1'b1;

	if (phase == 2'd1 && cmar_w && !ioref_w)
		md_w = wr_en_w ? wr_d_w : mrd_md_d;

	if (sel_y == 2'd1 && fY == FY_IB) begin
		if (pend_v_w && !taken_v_w
		    && (pend_a_w || (ibp_w == IB_FULL && !mint_w))) begin
			taken_w   = ibf_w;
			taken_v_w = 1'b1;
			ibf_w = ibp_w[0] ? ib1_w : ib0_w;
			ibp_w = (ibp_w == IB_FULL) ? IB_WORD :
			        (ibp_w == IB_WORD) ? IB_BYTE : IB_EMPTY;
		end
		ib0_w = x[15:8];
		ib1_w = x[7:0];
		if (ibp_w == IB_EMPTY) begin
			ibf_w = (sel_z == 2'd0 && fZ == FZ_IBPTR_1) ? ib1_w : ib0_w;
			ibp_w = (sel_z == 2'd0 && fZ == FZ_IBPTR_1) ? IB_BYTE : IB_WORD;
		end
		else ibp_w = IB_FULL;
	end

	if (sel_y == 2'd1 && fY == FY_MESAINTRQ) begin
		mint_w = 1'b1;
		intstat_w = intstat_w | 3'b001;
	end
	else if (sel_y == 2'd1 && fY == FY_CLRINTERR) begin
		mint_w = 1'b0;
		intstat_w = 3'd0;
	end
	if (timer_int) begin
		mint_w = 1'b1;
		intstat_w = intstat_w | 3'b100;
	end
	if (iop_int) begin
		mint_w = 1'b1;
		intstat_w = intstat_w | 3'b010;
	end

	mar_here = f_mem && (phase == 2'd0);
	map_here = do_map;
	rh_write = (fX == FX_RH) && !(mar_here || map_here);
	rh_data  = x[7:0];

	u_write  = f_enU && f_cin;
	u_addr_w = uaddr;
	u_data   = yb;

	nia   = inia | {8'd0, pending_or};
	por_w = 4'd0;

	if (pend_v_w) begin
		pend_v_w = 1'b0;
		if (!pend_a_w && (ibp_w != IB_FULL || mint_w)) begin
			bump_refill = 1'b1;
			nia = {2'b01, mint_w, ibp_w[0], nia[7:0]};
		end
		else begin
			bump_ibdisp = 1'b1;
			if (taken_v_w) op_now = taken_w;
			else begin
				op_now = ibf_w;
				ibf_w = ibp_w[0] ? ib1_w : ib0_w;
				ibp_w = (ibp_w == IB_FULL) ? IB_WORD :
				        (ibp_w == IB_WORD) ? IB_BYTE : IB_EMPTY;
			end
			lastop_w = op_now;
			nia = {nia[11:8], op_now};
		end
		taken_v_w = 1'b0;
	end

	disp_bit = 4'd0;
	if (sel_y == 2'd1 && fY == FY_IBDISP) begin
		pend_v_w = 1'b1;
		pend_a_w = (sel_z == 2'd0 && fZ == FZ_IBPTR_1);
		if (prev_page_cross) begin
			pend_v_w = 1'b0;
			bump_pxcancel = 1'b1;
		end
	end
	else if (sel_y == 2'd0) begin
		case (fY)
		DB_NEGBR:      disp_bit = {3'd0, alu_f[15]};
		DB_ZEROBR:     disp_bit = {3'd0, (alu_f == 16'd0)};
		DB_NZEROBR:    disp_bit = {3'd0, (alu_f != 16'd0)};
		DB_MESAINTBR:  disp_bit = {3'd0, mint};
		DB_PGCARRYBR:  disp_bit = {3'd0, pgc};
		DB_CARRYBR:    disp_bit = {3'd0, carry};
		DB_NIBCARRYBR: disp_bit = {3'd0, nibc};
		DB_XREFBR:     disp_bit = {3'd0, x[7]};
		DB_XDISP:      disp_bit = x[3:0];
		DB_YDISP:      disp_bit = yb[3:0];
		DB_XC2NPCDISP: disp_bit = {x[3:2], (phase == 2'd1), ~pc16};
		DB_XWTOKDISP:  disp_bit = {2'b11, (x[7] & x[6] & ~x[5]), 1'b0};
		DB_XWDDISP:    disp_bit = {2'd0, x[6], x[5]};
		DB_XHDISP:     disp_bit = {2'd0, x[11], x[15]};
		DB_XLDISP:     disp_bit = {2'd0, x[7],  x[0]};
		DB_PGDROVDISP: disp_bit = {2'd0, (aF <= 3'd2) ? (pgc ^ aF[0]) : 1'b0, ovr};
		endcase
		por_w = disp_bit;
	end

	if (page_cross) por_w = por_w | 4'd2;

	if (fX < 4'd8) begin
		if (nia[4]) begin
			por_w = por_w | links[fX[2:0]];
			bump_linkr = 1'b1;
		end
		else bump_linkw = 1'b1;
	end

	if (sel_z == 2'd0 && (fZ == FZ_IBPTR_1 || fZ == FZ_IBPTR_0)
	    && !(sel_y == 2'd1 && (fY == FY_IBDISP || fY == FY_IB))) begin
		if (fZ == FZ_IBPTR_1) begin ibf_w = ib1_w; ibp_w = IB_BYTE; end
		else                  begin ibf_w = ib0_w; ibp_w = IB_WORD; end
	end

	if (sel_y == 2'd1 && fY == FY_STACKP) begin
		sp_w = yb[3:0];
		bump_spload = 1'b1;
	end

	pop_f  = (fX == FX_POP) || (sel_z == 2'd0 && fZ == FZ_POP);
	push_f = (fX == FX_PUSH) || (sel_y == 2'd1 && fY == FY_PUSH)
	         || (sel_z == 2'd0 && fZ == FZ_PUSH);
	if (push_f != pop_f) begin
		sp_w = push_f ? (sp_w + 4'd1) : (sp_w - 4'd1);
		bump_stackop = 1'b1;
	end

	if (tcd_w != 3'd0) tcd_w = tcd_w - 3'd1;

	if (!pend_v_w)  pend_a_w = 1'b0;
	if (!taken_v_w) taken_w  = 8'd0;

	take_trap0 = (tcd_w == 3'd0) && (trap_cd == 3'd1);
	if (take_trap0) begin
		n_pc    = 12'd0;
		n_phase = 2'd0;
		cmar_w  = 1'b0;
		por_w   = 4'd0;
		pend_v_w = 1'b0;
	end
	else begin
		n_pc    = nia;
		n_phase = (phase == 2'd2) ? 2'd0 : (phase + 2'd1);
		if (phase == 2'd2) begin cmar_w = 1'b0; ioref_w = 1'b0; end
	end

	n_cycles = cycles + 32'd1;
end

always @(posedge clk) begin
	if (reset) begin
		pc <= 12'd0;  phase <= 2'd0;  Q <= 16'd0;  stackP <= 4'd0;
		MAR <= 24'd0; MD <= 16'd0;  pc16 <= 1'b0;  mint <= 1'b0;
		intstat <= 3'd0;  wdc_q <= 16'd0;
		trapcode <= 2'd1;
		click_mar <= 1'b0; io_ref <= 1'b0; pending_or <= 4'd0;
		pend_ibdisp <= 1'b0; pend_always <= 1'b0;
		ib_taken_v <= 1'b0; ib_taken <= 8'd0;
		prev_page_cross <= 1'b0; prev_y <= 16'd0; prev_altu <= 1'b0;
		ibPtr <= IB_EMPTY; ibFront <= 8'd0; IB0 <= 8'd0; IB1 <= 8'd0;
		trap_cd <= 3'd0;
		cycles <= 32'd0; last_op <= 8'd0; ibdisps <= 32'd0; refills <= 32'd0;
		ib_empty_errors <= 32'd0; rot_loops <= 32'd0; stale_mar <= 32'd0;
		stale_md <= 32'd0; map_refs <= 32'd0; map_writes <= 32'd0;
		io_refs <= 32'd0; writes <= 32'd0; pagecross_cancels <= 32'd0;
		stack_ops <= 32'd0; stackp_loads <= 32'd0;
		link_reads <= 32'd0; link_writes <= 32'd0; unmodelled <= 32'd0;
		for (i = 0; i < 8; i = i + 1) links[i] <= 4'd0;
	end
	else if (en) begin
		if (r_write)  R[rB]  <= r_data;
		if (q_write)  Q      <= q_data;
		if (rh_write) RH[rB] <= rh_data;
		if (u_write)  U[u_addr_w] <= u_data;
		if (u_write && u_addr_w == 8'h18) wdc_q <= u_data;
		if (fX < 4'd8 && !nia[4]) links[fX[2:0]] <= nia[3:0];

		pc      <= n_pc;
		phase   <= n_phase;
		pc16    <= n_pc16;
		stackP  <= sp_w;
		MAR     <= mar_w;
		MD      <= md_w;
		click_mar <= cmar_w;
		io_ref  <= ioref_w;
		trapcode <= trap_w;
		trap_cd <= tcd_w;
		mint    <= mint_w;
		intstat <= intstat_w;
		pending_or  <= por_w;
		pend_ibdisp <= pend_v_w;
		pend_always <= pend_a_w;
		ib_taken_v  <= taken_v_w;
		ib_taken    <= taken_w;
		ibPtr   <= ibp_w;
		ibFront <= ibf_w;
		IB0     <= ib0_w;
		IB1     <= ib1_w;
		last_op <= lastop_w;
		prev_y  <= yb;
		prev_altu <= (sel_z == 2'd0 && fZ == 4'd7);
		prev_page_cross <= take_trap0 ? prev_page_cross : page_cross;

		cycles  <= n_cycles;
		if (bump_ibdisp)   ibdisps   <= ibdisps + 1;
		if (bump_refill)   refills   <= refills + 1;
		if (bump_ibempty)  ib_empty_errors <= ib_empty_errors + 1;
		if (bump_rotloop)  rot_loops <= rot_loops + 1;
		if (bump_stalemar) stale_mar <= stale_mar + 1;
		if (bump_stalemd)  stale_md  <= stale_md + 1;
		if (bump_mapref)   map_refs  <= map_refs + 1;
		if (bump_mapwrite) map_writes<= map_writes + 1;
		if (bump_ioref)    io_refs   <= io_refs + 1;
		if (bump_write)    writes    <= writes + 1;
		if (bump_pxcancel) pagecross_cancels <= pagecross_cancels + 1;
		if (bump_stackop)  stack_ops <= stack_ops + 1;
		if (bump_spload)   stackp_loads <= stackp_loads + 1;
		if (bump_linkr)    link_reads  <= link_reads + 1;
		if (bump_linkw)    link_writes <= link_writes + 1;
		if (bump_unmodelled) unmodelled <= unmodelled + 1;
	end
	else if (iop_int) begin
		mint    <= 1'b1;
		intstat <= intstat | 3'b010;
	end

	if (ld_we) begin
		if (ld_a[9:8] == 2'b00)        U[ld_a[7:0]]  <= ld_d;
		if (ld_a == 10'h018)           wdc_q <= ld_d;
		else if (ld_a[9:4] == 6'h10)   R[ld_a[3:0]]  <= ld_d;
		else if (ld_a[9:4] == 6'h11)   RH[ld_a[3:0]] <= ld_d[7:0];
		else if (ld_a == 10'h120)      Q <= ld_d;
	end

	if (cs_we) cs[cs_a] <= cs_d;
end

endmodule
