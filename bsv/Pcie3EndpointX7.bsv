// Copyright (c) 2014-2015 Quanta Research Cambridge, Inc.

// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

package Pcie3EndpointX7;

import Clocks            ::*;
import Vector            ::*;
import Connectable       ::*;
import GetPut            ::*;
import Reserved          ::*;
import TieOff            ::*;
import DefaultValue      ::*;
import DReg              ::*;
import Gearbox           ::*;
import FIFO              ::*;
import FIFOF             ::*;
import SpecialFIFOs      ::*;
import ClientServer      ::*;
import Real              ::*;
import XilinxVirtex7PCIE ::*;
import BUtils            ::*;
import Probe             ::*;

import ConnectalConfig::*;
import ConnectalClocks   ::*;
import ConnectalXilinxCells   ::*;
import XilinxCells       ::*;
import PCIE              ::*;
import PCIEWRAPPER3      ::*;
import Bufgctrl           ::*;
import PcieGearbox       :: *;

interface PcieEndpointX7#(numeric type lanes);
   interface PciewrapPci_exp#(lanes)           pcie;
   interface PciewrapUser#(lanes)              user;
   interface PciewrapPipe#(lanes)              pipe;
   interface PciewrapCommon#(lanes)            common;
   interface Server#(TLPData#(16), TLPData#(16)) tlpr;
   interface Server#(TLPData#(16), TLPData#(16)) tlpc;
   interface Put#(Tuple2#(Bit#(64),Bit#(32)))  interruptRequest;
   interface Clock epPcieClock;
   interface Reset epPcieReset;
   interface Clock epPortalClock;
   interface Reset epPortalReset;
   interface Clock epDerivedClock;
   interface Reset epDerivedReset;
endinterface

typedef struct {
   Bit #(256)     data;
   Bool          sop;
   Bool          eop;
   Bit #(8)      keep;
   TLPFirstDWBE  first_be;
   TLPFirstDWBE  last_be;
} AxiStCq deriving (Bits, Eq);

typedef struct {
   Bit #(256)     data;
   Bit #(8)      keep;
   Bool          last;
} AxiStCc deriving (Bits, Eq);

typedef struct {
   Bit #(256)     data;
   Bool          last;
   Bit #(8)      keep;
   Bit #(4)      first_be;
   Bit #(4)      last_be;
} AxiStRq deriving (Bits, Eq);

typedef struct {
   Bit #(256)     data;
   Bool          sop;
   Bool          eop;
   Bit #(8)      keep;
   Bit #(8)      be;
} AxiStRc deriving (Bits, Eq);

function TLPData#(16) convertCQDescriptorToTLP16(CQDescriptor desc, Bit#(32) data, TLPFirstDWBE first, TLPLastDWBE last);
   TLPMemoryIO3DWHeader header = defaultValue;
   header.format     = tpl_1(convertCQReqTypeToTLPFmtType(desc.reqtype));
   header.pkttype    = tpl_2(convertCQReqTypeToTLPFmtType(desc.reqtype));
   header.tclass     = desc.tclass;
   header.relaxed    = desc.relaxed;
   header.nosnoop    = desc.nosnoop;
   header.length     = (desc.dwcount == 1024) ? 0 : truncate(desc.dwcount);
   header.reqid      = desc.reqid;
   header.tag        = desc.tag;
   header.lastbe     = last;
   header.firstbe    = first;
   header.addr       = truncate(desc.address);
   header.data       = convertDW(data);
   
   Bool is3DW = isReadReqType(desc.reqtype);
   Bool is3Or4DW = isReadReqType(desc.reqtype) || (desc.dwcount == 1);

   TLPData#(16) retval = defaultValue;
   retval.sof   = True;
   retval.eof   = is3Or4DW;
   retval.hit   = (1 << pack(desc.barid));
   retval.data  = pack(header);
   retval.be    = (is3DW ? 16'hFFF0 : 16'hFFFF);
   
   return retval;
endfunction

function TLPData#(16) convertRCDescriptorToTLP16(RCDescriptor desc, Bit#(32) data);
   TLPCompletionHeader header = defaultValue;
   header.tclass    = desc.tclass;
   header.relaxed   = desc.relaxed;
   header.nosnoop   = desc.nosnoop;
   header.cmplid    = desc.complid;
   header.tag       = desc.tag;
   header.reqid     = desc.reqid;
   header.poison    = desc.poisoned;
   header.cstatus   = desc.status;
   header.length    = (desc.dwcount == 1024) ? 0 : truncate(desc.dwcount);
   header.bytecount = (desc.bytecount == 4096) ? 0 : truncate(desc.bytecount);
   header.loweraddr = truncate(desc.loweraddr);
   header.data      = convertDW(data);

   Bool is3DW = (desc.dwcount == 0);
   Bool is3Or4DW = (desc.dwcount == 0) || (desc.dwcount == 1);
   TLPData#(16) retval = defaultValue;
   retval.sof   = True;
   retval.eof   = is3Or4DW;
   retval.hit   = 1; // XXX
   retval.data  = pack(header);
   retval.be    = (is3DW ? 16'hFFF0 : 16'hFFFF);
   
   return retval;
endfunction

(* synthesize *)
module mkPcieEndpointX7(PcieEndpointX7#(PcieLanes));

   PCIEParams params = defaultValue;
   Clock defaultClock <- exposeCurrentClock();
   Reset defaultReset <- exposeCurrentReset();
   Reset defaultResetInverted <- mkResetInverter(defaultReset, clocked_by defaultClock);
   PcieWrap#(PcieLanes) pcie_ep <- mkPcieWrap(defaultClock, defaultResetInverted);

   // The PCIe endpoint exports full (250MHz) and half-speed (125MHz) clocks
   Clock pcieClock250 = pcie_ep.user_clk;
   Reset user_reset_n <- mkResetInverter(pcie_ep.user_reset, clocked_by pcie_ep.user_clk);
   Reset pcieReset250 <- mkAsyncReset(4, user_reset_n, pcieClock250);

   ClockGenerator7Params     clkgenParams = defaultValue;
   clkgenParams.clkin1_period    = 4.000; //  250MHz
   clkgenParams.clkin1_period    = 4.000;
   clkgenParams.clkin_buffer     = False;
   clkgenParams.clkfbout_mult_f  = 4.000; // 1000MHz
   clkgenParams.clkout0_divide_f = derivedClockPeriod;
   clkgenParams.clkout1_divide     = round(mainClockPeriod);
   clkgenParams.clkout1_duty_cycle = 0.5;
   clkgenParams.clkout1_phase      = 0.0000;
   ClockGenerator7           clkgen <- mkClockGenerator7(clkgenParams, clocked_by pcieClock250, reset_by pcieReset250);
   Clock mainClock = clkgen.clkout1;
   Reset mainReset <- mkAsyncReset(4, pcieReset250, mainClock);
   Clock derivedClock = clkgen.clkout0;
   Reset derivedReset <- mkAsyncReset(4, pcieReset250, derivedClock);
   Reset user_reset <- mkAsyncReset(2, pcie_ep.user_reset, pcie_ep.user_clk);

   // FIFOS
   FIFOF#(AxiStCq) fAxiCq <- mkFIFOF(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   FIFOF#(AxiStRc) fAxiRc <- mkFIFOF(clocked_by pcie_ep.user_clk, reset_by user_reset_n);

   FIFOF#(AxiStRq) fAxiRq <- mkFIFOF(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   FIFOF#(AxiStCc) fAxiCc <- mkFIFOF(clocked_by pcie_ep.user_clk, reset_by user_reset_n);

   FIFOF#(TLPData#(16)) fcq <- mkFIFOF(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   FIFOF#(TLPData#(16)) frc <- mkFIFOF(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   FIFOF#(TLPData#(16)) fcc <- mkFIFOF(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   FIFOF#(TLPData#(16)) frq <- mkFIFOF(clocked_by pcie_ep.user_clk, reset_by user_reset_n);

   FIFOF#(Tuple2#(Bit#(64),Bit#(32))) intrFifo <- mkFIFOF(clocked_by pcie_ep.user_clk, reset_by user_reset_n);

   // Drive s_axis_rq
   let rq_txready = (pcie_ep.s_axis_rq.tready != 0 && fAxiRq.notEmpty);

   //(* fire_when_enabled, no_implicit_conditions *)
   rule drive_axi_rq if (rq_txready);
      let info = fAxiRq.first; fAxiRq.deq;
      pcie_ep.s_axis_rq.tvalid(1);
      pcie_ep.s_axis_rq.tlast(pack(info.last));
      pcie_ep.s_axis_rq.tdata(info.data);
      pcie_ep.s_axis_rq.tkeep(info.keep);
      pcie_ep.s_axis_rq.tuser({0, info.last_be, info.first_be});
   endrule

   (* fire_when_enabled, no_implicit_conditions *)
   rule drive_axi_rq2 if (!rq_txready);
      pcie_ep.s_axis_rq.tvalid(0);
      pcie_ep.s_axis_rq.tlast(0);
      pcie_ep.s_axis_rq.tdata(0);
      pcie_ep.s_axis_rq.tkeep(0);
      pcie_ep.s_axis_rq.tuser(0);
   endrule

   // Drive s_axis_cc
   let cc_txready = (pcie_ep.s_axis_cc.tready != 0 && fAxiCc.notEmpty);

   //(* fire_when_enabled, no_implicit_conditions *)
   rule drive_axi_cc if (cc_txready);
      let info = fAxiCc.first; fAxiCc.deq;
      $display("drive axi_cc, data: %h, keep: %h, last: %h", info.data, info.keep, info.last);
      pcie_ep.s_axis_cc.tvalid(1);
      pcie_ep.s_axis_cc.tlast(pack(info.last));
      pcie_ep.s_axis_cc.tdata(info.data);
      pcie_ep.s_axis_cc.tkeep(info.keep);
      pcie_ep.s_axis_cc.tuser(0);
   endrule

   (* fire_when_enabled, no_implicit_conditions *)
   rule drive_axi_cc2 if (!cc_txready);
      pcie_ep.s_axis_cc.tvalid(0);
      pcie_ep.s_axis_cc.tlast(0);
      pcie_ep.s_axis_cc.tdata(0);
      pcie_ep.s_axis_cc.tkeep(0);
      pcie_ep.s_axis_cc.tuser(0);
   endrule

   (* fire_when_enabled, no_implicit_conditions *)
   rule drive_axi_rc_ready;
      pcie_ep.m_axis_rc.tready (duplicate (pack (fAxiRc.notFull)));
   endrule
 
   // Drive m_axis_rc
   (* fire_when_enabled *)
   rule sink_axi_rc if (pcie_ep.m_axis_rc.tvalid != 0 && fAxiRc.notFull);
      let rc = AxiStRc {data:pcie_ep.m_axis_rc.tdata,
			sop: unpack (pcie_ep.m_axis_rc.tuser [32]),         // tuser.is_sof_0
			eop: unpack (pcie_ep.m_axis_rc.tlast),
			keep:pcie_ep.m_axis_rc.tkeep,
			be:  truncate (pcie_ep.m_axis_rc.tuser [31:0])};    // tuser.byte_en
      fAxiRc.enq (rc);
   endrule

   (* fire_when_enabled, no_implicit_conditions *)
   rule drive_axi_cq_ready;
      pcie_ep.m_axis_cq.tready (duplicate (pack (fAxiCq.notFull)));
   endrule

   (* fire_when_enabled *)
   rule sink_axi_cq if (pcie_ep.m_axis_cq.tvalid != 0 && fAxiCq.notFull);
      let cq = AxiStCq {data:     pcie_ep.m_axis_cq.tdata,
			sop:      unpack (pcie_ep.m_axis_cq.tuser [40]),  // tuser.sop
			eop:      unpack (pcie_ep.m_axis_cq.tlast),
			keep:     pcie_ep.m_axis_cq.tkeep,
			first_be: pcie_ep.m_axis_cq.tuser [3:0],    // tuser.first_be,
			last_be:  pcie_ep.m_axis_cq.tuser [7:4]};   // tuser.last_be
      fAxiCq.enq (cq);
   endrule

   // CQ.
   CQDescriptor cq_desc = unpack(fAxiCq.first.data [127:0]);

   rule rl_cq_wr_header (fAxiCq.first.sop && ((cq_desc.reqtype == MEMORY_WRITE) || (cq_desc.reqtype == IO_WRITE)));
      Bit#(32) data = fAxiCq.first.data[159:128];
      // get data;
      TLPData#(16) tlp16 = convertCQDescriptorToTLP16(cq_desc, data, fAxiCq.first.first_be, fAxiCq.first.last_be);
      $display("cq_desc.reqtype=%h", cq_desc.reqtype);
      // enqueue?
      fcq.enq(tlp16);
      fAxiCq.deq;
   endrule

   // Write data payload, no data remaining
   rule rl_cq_wr_payload((!fAxiCq.first.sop));
      fAxiCq.deq;
   endrule

   // Write data payload, 1 to 3 DWs remaining
   // Write data payload, 4 or more DWs remaining

   rule rl_cq_rd_header (fAxiCq.first.sop && ((cq_desc.reqtype == MEMORY_READ) || (cq_desc.reqtype == IO_READ)));
      Bit#(32) data = 0;
      TLPData#(16) tlp16 = convertCQDescriptorToTLP16(cq_desc, data, fAxiCq.first.first_be, fAxiCq.first.last_be);
      $display("rl_cq_rd_header: cq_desc = %16x", cq_desc);
      fcq.enq(tlp16);
      fAxiCq.deq;
   endrule

   // RC.
   Reg#(DWCount) rc_dwcount <- mkRegU(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   Reg#(Bool) rc_even <- mkReg(True, clocked_by pcie_ep.user_clk, reset_by user_reset_n);

   rule rl_rc_header (fAxiRc.first.sop && rc_even);
      RCDescriptor rc_desc = unpack(fAxiRc.first.data [95:0]);
      // RC descriptor always 96 bytes with first data word in bits 127:96                                                                                            
      Bit#(32) data = byteSwap(fAxiRc.first.data[127:96]);
      TLPData#(16) tlp16 = convertRCDescriptorToTLP16(rc_desc, data);
      rc_dwcount <= (rc_desc.dwcount == 0) ? 0 : rc_desc.dwcount - 1;
      frc.enq(tlp16);
      let even = False;
      if (rc_desc.dwcount == 0 || rc_desc.dwcount == 1) begin
        fAxiRc.deq;
        even = True;
      end
      rc_even <= even;
   endrule

   rule rl_rc_data ((!rc_even || !(fAxiRc.first.sop)) && (rc_dwcount != 0));
      Bit#(16) be16;
      case (rc_dwcount)
         1: be16 = 16'hF000;
         2: be16 = 16'hFF00;
         3: be16 = 16'hFFF0;
         default: be16 = 16'hFFFF;
      endcase
      let last = (rc_dwcount <= 4);
      let dwcount = rc_dwcount - 4;
      if (last) dwcount = 0;
      let data = (rc_even) ? fAxiRc.first.data[127:0]: fAxiRc.first.data[255:128];
      TLPData#(16) tlp16 = TLPData{sof: False,
                                   eof: last,
                                   hit: 0,
                                   be: be16,
                                   data: pack(data)};
      frc.enq(tlp16);
      if (last || !rc_even) begin
         fAxiRc.deq;
      end
      rc_dwcount <= dwcount;
      rc_even <= (last) ? True : !rc_even;
   endrule

   Reg#(DWCount) cc_dwcount <- mkReg(0, clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   FIFOF#(TLPData#(16)) fcc_tlps <- mkFIFOF (clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   // CC.
   rule get_cc_tlps;
      let tlp <- toGet(fcc).get;
      fcc_tlps.enq(tlp);
   endrule

   rule rl_cc_header(fcc_tlps.first.sof);
      match { .cc_desc, .dw} = convertTLP16ToCCDescriptor(fcc_tlps.first);
      cc_dwcount <= cc_desc.dwcount - 1;
      fAxiCc.enq(AxiStCc {data: zeroExtend({dw, pack(cc_desc)[95:0]}),
                       last: fcc_tlps.first.eof,
                       keep: 8'h0F});
      fcc_tlps.deq;
   endrule

   rule rl_cc_data((!fcc_tlps.first.sof) && (cc_dwcount != 0));
      Bit#(256) x = zeroExtend(fcc_tlps.first.data); //FIXME
      fAxiCc.enq(AxiStCc {data: {x},
                       last: cc_dwcount <= 4,
                       keep: (cc_dwcount == 3) ? 8'h0F : 8'hFF});
      fcc_tlps.deq;
   endrule

   // RQ.
   FIFOF#(TLPData#(16)) frq_tlps <- mkFIFOF (clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   Reg#(Bit#(4)) rq_first_be <- mkReg(0, clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   Reg#(Bit#(4)) rq_last_be <- mkReg(0, clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   Reg#(Bool)    rq_even    <- mkRegU(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   Reg#(DWCount) rq_dwcount <- mkReg(0, clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   Reg#(AxiStRq) rq_rq <- mkRegU(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   rule rl_rq_tlps;
      let tlp <- toGet(frq).get;
      frq_tlps.enq(tlp);
   endrule

   rule rl_rq_header if (frq_tlps.first.sof);
      TLPData#(16) tlp <- toGet(frq_tlps).get();
      match { .rq_desc, .first_be, .last_be, .mdata} = convertTLP16ToRQDescriptor(tlp);

      let dwcount = ((rq_desc.reqtype == MEMORY_WRITE) ? rq_desc.dwcount : 0);
      rq_dwcount <= dwcount;
      rq_even <= False;
      rq_first_be <= first_be;
      rq_last_be <= last_be;
      let last = (rq_desc.reqtype == MEMORY_WRITE) ? (dwcount <= 4) : True;
      let rq = AxiStRq {data: zeroExtend(pack(rq_desc)), //FIXME:
			last: last,
			keep: 8'h0F,
			first_be: first_be,
			last_be: last_be};
      if (rq_desc.reqtype == MEMORY_WRITE)
	 rq_rq <= rq;
      else
	 fAxiRq.enq(rq);
   endrule

   // more data
   rule rl_rq_data if (rq_dwcount != 0);
      TLPData#(16) tlp <- toGet(frq_tlps).get();
      let rq = rq_rq;
      let last = (rq_dwcount <= 4);
      let dwcount = rq_dwcount - 4;
      Bit#(8) keep;
      if (last)
	dwcount = 0;
      if (rq_even) begin
	 rq.data[127:0] = tlp.data;
	case (rq_dwcount)
	   1: keep = 8'h01;
	   2: keep = 8'h03;
	   3: keep = 8'h07;
	   default: keep = 8'h0f;
	endcase
      end
      else begin
	rq.data[255:128] = tlp.data;
	case (rq_dwcount)
	   1: keep = 8'h1f;
	   2: keep = 8'h3f;
	   3: keep = 8'h7f;
	   default: keep = 8'hff;
	endcase
      end
      rq.last = last;
      rq.first_be = rq_first_be;
      rq.last_be = rq_last_be;
      rq.keep = keep;
      if (!rq_even || last)
	 fAxiRq.enq(rq);
      if (rq_even)
	rq_rq <= rq;
      rq_dwcount <= dwcount;
      rq_even <= (last) ? False : !rq_even;
   endrule

   FIFO#(Bool) intrMutex <- mkFIFO1(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   Wire#(Bool) msix_int_enable <- mkDWire(False, clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   let probe_msix_enable <- mkProbe(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   let probe_msix_sent <- mkProbe(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   let probe_msix_fail <- mkProbe(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   let probe_msix_addr <- mkProbe(clocked_by pcie_ep.user_clk, reset_by user_reset_n);
   let probe_msix_data <- mkProbe(clocked_by pcie_ep.user_clk, reset_by user_reset_n);

   rule rl_intr;
      if (pcie_ep.cfg.interrupt_msix_enable[0] == 1) begin
	 match { .addr, .data } <- toGet(intrFifo).get();
	 pcie_ep.cfg.interrupt_msix_address(addr);
	 pcie_ep.cfg.interrupt_msix_data(data);
	 msix_int_enable <= True;
	 intrMutex.enq(True);

	 probe_msix_addr <= addr;
	 probe_msix_data <= data;
      end
   endrule: rl_intr
   rule rl_intr_enable;
      probe_msix_enable <= msix_int_enable;
      probe_msix_sent <= pcie_ep.cfg.interrupt_msix_sent;
      probe_msix_fail <= pcie_ep.cfg.interrupt_msix_fail;

      pcie_ep.cfg.interrupt_msix_int(pack(msix_int_enable));
   endrule

   rule rl_intr_sent if (pcie_ep.cfg.interrupt_msix_sent() == 1|| pcie_ep.cfg.interrupt_msix_fail() == 1);
      intrMutex.deq();
   endrule

   // The PCIE endpoint is processing Gen3 descriptors at 250MHz. The
   // AXI bridge is accepting TLPData#(16)s at 250 MHz. The
   // conversion uses half of Gen3 descriptor.
   //mkConnection(tlp8, gb.tlp, clocked_by portalClock, reset_by portalReset);

   let portalClock = (mainClockPeriod == pcieClockPeriod) ? pcieClock250 : mainClock;
   let portalReset = (mainClockPeriod == pcieClockPeriod) ? pcieReset250 : mainReset;

   interface Server tlpr;
      interface request = toPut(frq);
      interface response = toGet(frc);
   endinterface
   // Requests from other PCIe devices
   interface Server tlpc;
      interface request = toPut(fcc);
      interface response = toGet(fcq);
   endinterface
   interface interruptRequest = toPut(intrFifo);
   interface pcie    = pcie_ep.pci_exp;
   interface Pcie3wrapUser user = pcie_ep.user;
   interface PciewrapPipe pipe = pcie_ep.pipe;
   interface PciewrapCommon common= pcie_ep.common;
   interface Clock epPcieClock = pcieClock250;
   interface Reset epPcieReset = pcieReset250;
   interface Clock epPortalClock = portalClock;
   interface Reset epPortalReset = portalReset;
   interface Clock epDerivedClock = derivedClock;
   interface Reset epDerivedReset = derivedReset;
endmodule: mkPcieEndpointX7

endpackage: Pcie3EndpointX7
