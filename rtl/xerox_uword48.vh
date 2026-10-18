localparam UW48_BITS = 48;

localparam UW48_RA_LSB = 44;
localparam UW48_RA_W   = 4;
`define u48_rA(w) w[47:44]
localparam UW48_RB_LSB = 40;
localparam UW48_RB_W   = 4;
`define u48_rB(w) w[43:40]
localparam UW48_AS_LSB = 37;
localparam UW48_AS_W   = 3;
`define u48_aS(w) w[39:37]
localparam UW48_AF_LSB = 34;
localparam UW48_AF_W   = 3;
`define u48_aF(w) w[36:34]
localparam UW48_AD_LSB = 32;
localparam UW48_AD_W   = 2;
`define u48_aD(w) w[33:32]
localparam UW48_EP_LSB = 31;
localparam UW48_EP_W   = 1;
`define u48_eP(w) w[31]
localparam UW48_CIN_LSB = 30;
localparam UW48_CIN_W   = 1;
`define u48_Cin(w) w[30]
localparam UW48_ENU_LSB = 29;
localparam UW48_ENU_W   = 1;
`define u48_enU(w) w[29]
localparam UW48_MEM_LSB = 28;
localparam UW48_MEM_W   = 1;
`define u48_mem(w) w[28]
localparam UW48_FS_LSB = 24;
localparam UW48_FS_W   = 4;
`define u48_fS(w) w[27:24]
localparam UW48_FX_LSB = 20;
localparam UW48_FX_W   = 4;
`define u48_fX(w) w[23:20]
localparam UW48_FY_LSB = 16;
localparam UW48_FY_W   = 4;
`define u48_fY(w) w[19:16]
localparam UW48_FZ_LSB = 12;
localparam UW48_FZ_W   = 4;
`define u48_fZ(w) w[15:12]
localparam UW48_INIA_LSB = 0;
localparam UW48_INIA_W   = 12;
`define u48_INIA_raw(w) w[11:0]

`define u48_inia(w) (w[11:0] ^ 12'h00F)

`define u48_sel_y(w) w[27:26]
`define u48_sel_z(w) w[25:24]

localparam [3:0] FX_PCALL_RET0 = 4'd0;
localparam [3:0] FX_PCALL_RET1 = 4'd1;
localparam [3:0] FX_PCALL_RET2 = 4'd2;
localparam [3:0] FX_PCALL_RET3 = 4'd3;
localparam [3:0] FX_PCALL_RET4 = 4'd4;
localparam [3:0] FX_PCALL_RET5 = 4'd5;
localparam [3:0] FX_PCALL_RET6 = 4'd6;
localparam [3:0] FX_PCALL_RET7 = 4'd7;
localparam [3:0] FX_NOOP = 4'd8;
localparam [3:0] FX_RH = 4'd9;
localparam [3:0] FX_SHIFT = 4'd10;
localparam [3:0] FX_CYCLE = 4'd11;
localparam [3:0] FX_CIN_PC16 = 4'd12;
localparam [3:0] FX_MAP = 4'd13;
localparam [3:0] FX_POP = 4'd14;
localparam [3:0] FX_PUSH = 4'd15;

localparam [3:0] FY_CLRMPINTIOP = 4'd0;
localparam [3:0] FY_SETMPINTIOP = 4'd1;
localparam [3:0] FY_CLRINTERR = 4'd2;
localparam [3:0] FY_IBDISP = 4'd3;
localparam [3:0] FY_MESAINTRQ = 4'd4;
localparam [3:0] FY_STACKP = 4'd5;
localparam [3:0] FY_IB = 4'd6;
localparam [3:0] FY_CYCLE = 4'd7;
localparam [3:0] FY_NOOP = 4'd8;
localparam [3:0] FY_MAP = 4'd9;
localparam [3:0] FY_MAPA = 4'd10;
localparam [3:0] FY_PUSH = 4'd11;
localparam [3:0] FY_IO = 4'd12;
localparam [3:0] FY_BANK = 4'd13;
localparam [3:0] FY_CLRIE = 4'd14;
localparam [3:0] FY_SETIE = 4'd15;

localparam [3:0] FZ_IBPTR_1 = 4'd1;
localparam [3:0] FZ_IBPTR_0 = 4'd2;
localparam [3:0] FZ_CIN_PC16 = 4'd3;
localparam [3:0] FZ_POP = 4'd5;
localparam [3:0] FZ_PUSH = 4'd6;
localparam [3:0] FZ_ALTUADDR = 4'd7;
localparam [3:0] FZ_NOOP = 4'd8;
localparam [3:0] FZ_CLRLOCK = 4'd10;
localparam [3:0] FZ_SETLOCK = 4'd11;
localparam [3:0] FZ_LROT0 = 4'd12;
localparam [3:0] FZ_LROT12 = 4'd13;
localparam [3:0] FZ_LROT8 = 4'd14;
localparam [3:0] FZ_LROT4 = 4'd15;

localparam [3:0] DB_NEGBR = 4'd0;
localparam [3:0] DB_ZEROBR = 4'd1;
localparam [3:0] DB_NZEROBR = 4'd2;
localparam [3:0] DB_MESAINTBR = 4'd3;
localparam [3:0] DB_PGCARRYBR = 4'd4;
localparam [3:0] DB_CARRYBR = 4'd5;
localparam [3:0] DB_XREFBR = 4'd6;
localparam [3:0] DB_NIBCARRYBR = 4'd7;
localparam [3:0] DB_XDISP = 4'd8;
localparam [3:0] DB_YDISP = 4'd9;
localparam [3:0] DB_XC2NPCDISP = 4'd10;
localparam [3:0] DB_XWTOKDISP = 4'd11;
localparam [3:0] DB_XWDDISP = 4'd12;
localparam [3:0] DB_XHDISP = 4'd13;
localparam [3:0] DB_XLDISP = 4'd14;
localparam [3:0] DB_PGDROVDISP = 4'd15;
