///////////////////////////////////////////
// cacheway
//
// Written: Rose Thompson ross1728@gmail.com 
// Created: 7 July 2021
// Modified: 20 January 2023
//
// Purpose: Storage and read/write access to data cache data, tag valid, dirty, and replacement.
// 
// Documentation: RISC-V System on Chip Design Chapter 7 (Figure 7.11)
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// 
// Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file 
// except in compliance with the License, or, at your option, the Apache License version 2.0. You 
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the 
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
// either express or implied. See the License for the specific language governing permissions 
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

module cacheway import cvw::*; #(parameter cvw_t P, 
                  parameter PA_BITS, XLEN, NUMLINES=512, LINELEN = 256, TAGLEN = 26,
                  OFFSETLEN = 5, INDEXLEN = 9, READ_ONLY_CACHE = 0) (
  input  logic                        clk,
  input  logic                        reset,
  input  logic                        FlushStage,     // Pipeline flush of second stage (prevent writes and bus operations)
  input  logic                        CacheEn,        // Enable the cache memory arrays.  Disable hold read data constant
  input  logic [$clog2(NUMLINES)-1:0] CacheSetData,       // Cache address, the output of the address select mux, NextAdr, PAdr, or FlushAdr
  input  logic [$clog2(NUMLINES)-1:0] CacheSetTag,       // Cache address, the output of the address select mux, NextAdr, PAdr, or FlushAdr
  input  logic [PA_BITS-1:0]          PAdr,           // Physical address 
  input  logic [LINELEN-1:0]          LineWriteData,  // Final data written to cache (D$ only)
  input  logic                        SetValid,       // Set the valid bit in the selected way and set
  input  logic                        ClearValid,     // Clear the valid bit in the selected way and set
  input  logic                        SetDirty,       // Set the dirty bit in the selected way and set
  input  logic                        SelWay,         // Controls which way to select a way data and tag, 00 = hitway, 10 = victimway, 11 = flushway
  input  logic                        ClearDirty,     // Clear the dirty bit in the selected way and set
  input  logic                        FlushCache,       // [0] Use SelAdr, [1] SRAM reads/writes from FlushAdr
  input  logic                        VictimWay,      // LRU selected this way as victim to evict
  input  logic                        FlushWay,       // This way is selected for flush and possible writeback if dirty
  input  logic                        InvalidateCache,// Clear all valid bits
  input  logic [LINELEN/8-1:0]        LineByteMask,   // Final byte enables to cache (D$ only)

  output logic [LINELEN-1:0]          ReadDataLineWay,// This way's read data if valid
  output logic                        HitWay,         // This way hits
  output logic                        ValidWay,       // This way is valid
  output logic                        HitDirtyWay, // The hit way is dirty
  output logic                        DirtyWay   ,    // The selected way is dirty
  output logic [TAGLEN-1:0]           TagWay);        // This way's tag if valid

  localparam                          WORDSPERLINE = LINELEN/XLEN;
  localparam                          BYTESPERLINE = LINELEN/8;
  localparam                          LOGWPL = $clog2(WORDSPERLINE);
  localparam                          LOGXLENBYTES = $clog2(XLEN/8);
  localparam                          BYTESPERWORD = XLEN/8;

  logic [NUMLINES-1:0]                ValidBits;
  logic [NUMLINES-1:0]                DirtyBits;
  logic [LINELEN-1:0]                 ReadDataLine;
  logic [TAGLEN-1:0]                  ReadTag;
  logic                               Dirty;
  logic                               SelDirty;
  logic                               SelectedWriteWordEn;
  logic [LINELEN/8-1:0]               FinalByteMask;
  logic                               SetValidEN, ClearValidEN;
  logic                               SetValidWay;
  logic                               ClearValidWay;
  logic                               SetDirtyWay;
  logic                               ClearDirtyWay;
  logic                               SelNonHit;
  logic                               SelData;
  logic                               InvalidateCacheDelay;
  
  if (!READ_ONLY_CACHE) begin:flushlogic
    logic                               FlushWayEn;
    mux2 #(1) seltagmux(VictimWay, FlushWay, FlushCache, SelDirty);

    // FlushWay is part of a one hot way selection. Must clear it if FlushWay not selected.
    // coverage off -item e 1 -fecexprrow 3
    // nonzero ways will never see FlushCache=0 while FlushWay=1 since FlushWay only advances on a subset of FlushCache assertion cases.
    assign FlushWayEn = FlushWay & FlushCache;
    assign SelNonHit = FlushWayEn | SelWay; 
  end else begin:flushlogic // no flush operation for read-only caches.
    assign SelDirty = VictimWay;
    assign SelNonHit = SelWay;
  end

  mux2 #(1) selectedwaymux(HitWay, SelDirty, SelNonHit , SelData);

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Write Enable demux
  /////////////////////////////////////////////////////////////////////////////////////////////

  assign SetValidWay = SetValid & SelData;
  assign ClearValidWay = ClearValid & SelData;
  assign SetDirtyWay = SetDirty & SelData;                                 // exclusion-tag: icache SetDirtyWay
  assign ClearDirtyWay = ClearDirty & SelData;
  assign SelectedWriteWordEn = (SetValidWay | SetDirtyWay) & ~FlushStage;  // exclusion-tag: icache SelectedWiteWordEn
  assign SetValidEN = SetValidWay & ~FlushStage;                           // exclusion-tag: cache SetValidEN
  assign ClearValidEN = ClearValidWay & ~FlushStage;                           // exclusion-tag: cache SetValidEN

  // If writing the whole line set all write enables to 1, else only set the correct word.
  assign FinalByteMask = SetValidWay ? '1 : LineByteMask; // OR

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Tag Array
  /////////////////////////////////////////////////////////////////////////////////////////////

  ram1p1rwe #(.USE_SRAM(P.USE_SRAM), .DEPTH(NUMLINES), .WIDTH(TAGLEN)) CacheTagMem(.clk, .ce(CacheEn),
    .addr(CacheSetTag), .dout(ReadTag),
    .din(PAdr[PA_BITS-1:OFFSETLEN+INDEXLEN]), .we(SetValidEN));

  // AND portion of distributed tag multiplexer
  assign TagWay = SelData ? ReadTag : '0; // AND part of AOMux
  assign HitDirtyWay = Dirty & ValidWay;
  assign DirtyWay = SelDirty & HitDirtyWay;
  assign HitWay = ValidWay & (ReadTag == PAdr[PA_BITS-1:OFFSETLEN+INDEXLEN]) & ~InvalidateCacheDelay;

  flop #(1) InvalidateCacheReg(clk, InvalidateCache, InvalidateCacheDelay);

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Data Array
  /////////////////////////////////////////////////////////////////////////////////////////////

  genvar               words;

  localparam           NUMSRAM = LINELEN/P.CACHE_SRAMLEN;
  localparam           SRAMLENINBYTES = P.CACHE_SRAMLEN/8;
  localparam           LOGNUMSRAM = $clog2(NUMSRAM);
  
  for(words = 0; words < NUMSRAM; words++) begin: word
    if (!READ_ONLY_CACHE) begin:wordram
      ram1p1rwbe #(.USE_SRAM(P.USE_SRAM), .DEPTH(NUMLINES), .WIDTH(P.CACHE_SRAMLEN)) CacheDataMem(.clk, .ce(CacheEn), .addr(CacheSetData),
      .dout(ReadDataLine[P.CACHE_SRAMLEN*(words+1)-1:P.CACHE_SRAMLEN*words]),
      .din(LineWriteData[P.CACHE_SRAMLEN*(words+1)-1:P.CACHE_SRAMLEN*words]),
      .we(SelectedWriteWordEn), .bwe(FinalByteMask[SRAMLENINBYTES*(words+1)-1:SRAMLENINBYTES*words]));
    end else begin:wordram // no byte-enable needed for i$.
      ram1p1rwe #(.USE_SRAM(P.USE_SRAM), .DEPTH(NUMLINES), .WIDTH(P.CACHE_SRAMLEN)) CacheDataMem(.clk, .ce(CacheEn), .addr(CacheSetData),
      .dout(ReadDataLine[P.CACHE_SRAMLEN*(words+1)-1:P.CACHE_SRAMLEN*words]),
      .din(LineWriteData[P.CACHE_SRAMLEN*(words+1)-1:P.CACHE_SRAMLEN*words]),
      .we(SelectedWriteWordEn));
    end
  end

  // AND portion of distributed read multiplexers
  assign ReadDataLineWay = SelData ? ReadDataLine : '0;  // AND part of AO mux.

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Valid Bits
  /////////////////////////////////////////////////////////////////////////////////////////////
  
  always_ff @(posedge clk) begin // Valid bit array, 
    if (reset) ValidBits        <= #1 '0;
    if(CacheEn) begin 
      ValidWay <= #1 ValidBits[CacheSetTag];
      if(InvalidateCache)                    ValidBits <= #1 '0; // exclusion-tag: dcache invalidateway
      else if (SetValidEN) ValidBits[CacheSetData] <= #1 SetValidWay;
      else if (ClearValidEN) ValidBits[CacheSetData] <= #1 '0;
    end
  end

  /////////////////////////////////////////////////////////////////////////////////////////////
  // Dirty Bits
  /////////////////////////////////////////////////////////////////////////////////////////////

  // Dirty bits
  if (!READ_ONLY_CACHE) begin:dirty
    always_ff @(posedge clk) begin
      // reset is optional.  Consider merging with TAG array in the future.
      //if (reset) DirtyBits <= #1 {NUMLINES{1'b0}}; 
      if(CacheEn) begin
        Dirty <= #1 DirtyBits[CacheSetTag];
        if((SetDirtyWay | ClearDirtyWay) & ~FlushStage) DirtyBits[CacheSetData] <= #1 SetDirtyWay;
      end
    end
  end else assign Dirty = 1'b0;
endmodule
