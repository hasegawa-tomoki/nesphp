-- Dump compiled op_array from PRG-RAM bank 0 ($6000-$7FFF) after compile_and_emit.
-- Each zend_op = 24 bytes per nesphp.s convention.
--
-- Output: /tmp/dump_ops.txt — first 200 ops formatted as bytes + decoded opcode/types.

local OUT_PATH = "/tmp/dump_ops.txt"
local FRAMES   = 60   -- enough for compile to finish

for i = 1, FRAMES do emu.frameadvance() end

local f = assert(io.open(OUT_PATH, "w"))

-- nesphp opcode IDs (a few key ones from the spec)
local opnames = {
    [0]  = "NOP",     [1]  = "ADD",  [2]  = "SUB",  [3]  = "MUL", [4]  = "DIV", [5] = "MOD",
    [6]  = "SL",      [7]  = "SR",   [9]  = "BW_OR", [10] = "BW_AND",
    [16] = "IS_IDENT",[17] = "IS_NOT_IDENT",[18] = "IS_EQ",[19] = "IS_NEQ",
    [20] = "IS_SMALL",[21] = "IS_SOE",
    [22] = "ASSIGN",
    [31] = "QM_ASSIGN",
    [34] = "PRE_INC", [35] = "PRE_DEC",[36] = "POST_INC",[37] = "POST_DEC",
    [42] = "JMP",     [43] = "JMPZ", [44] = "JMPNZ",
    [62] = "RETURN",
    [71] = "INIT_ARRAY", [72] = "ADD_ARR_ELEM",
    [81] = "FETCH_DIM_R", [90] = "COUNT",
    [136] = "ECHO",
    [138] = "OP_DATA",
    [147] = "ASSIGN_DIM",
    [0xE8] = "PEEK_EXT",  [0xE9] = "PEEK16_EXT", [0xEA] = "POKE_EXT", [0xEB] = "POKESTR_EXT",
    [0xEC] = "PEEK",  [0xED] = "PEEK16", [0xEE] = "POKE", [0xEF] = "POKESTR",
    [0xF0] = "FGETS",
    [0xF1] = "PUT",   [0xF2] = "SPRITE",[0xF3] = "PUTS",[0xF4] = "CLS",
    [0xF5] = "CHR_SPR",[0xF6] = "CHR_BG",[0xF7] = "BG_COLOR",[0xF8] = "PALETTE",
    [0xF9] = "ATTR",  [0xFA] = "VSYNC",[0xFB] = "BTN",[0xFC] = "SPRITE_ATTR",
    [0xFD] = "RAND",  [0xFE] = "SRAND",[0xFF] = "PUTINT",
    -- INIT_FCALL_BY_NAME / SEND_VAL_EX / DO_FCALL_BY_NAME numbers vary by PHP version
}

local typenames = {
    [0] = "UNUSED", [1] = "CONST", [2] = "TMP", [4] = "VAR", [8] = "CV"
}

f:write(string.format("OPS_BASE = $6000 (current bank), dumping first 200 ops (24 bytes each)\n\n"))

-- The op_array starts at OPS_BASE = $6000. First op at OPS_FIRST_OP = $6010.
-- Header bytes 0..15 are op_array meta.
f:write("--- HEADER ($6000-$600F) ---\n")
local hdr = {}
for i = 0, 15 do hdr[#hdr+1] = string.format("%02X", memory.readbyte(0x6000 + i)) end
f:write(table.concat(hdr, " ") .. "\n\n")

f:write("--- OPS (starting $6010, 12B layout) ---\n")
for opi = 0, 499 do
    local addr = 0x6010 + opi * 12
    if addr + 12 > 0x8000 then break end
    local op    = memory.readbyte(addr + 8)
    local op1t  = memory.readbyte(addr + 9)
    local op2t  = memory.readbyte(addr + 10)
    local rt    = memory.readbyte(addr + 11)
    local op1lo = memory.readbyte(addr + 0)
    local op1hi = memory.readbyte(addr + 1)
    local op2lo = memory.readbyte(addr + 2)
    local op2hi = memory.readbyte(addr + 3)
    local rlo   = memory.readbyte(addr + 4)
    local rhi   = memory.readbyte(addr + 5)
    local extlo = memory.readbyte(addr + 6)
    local exthi = memory.readbyte(addr + 7)

    local opname = opnames[op] or string.format("?%d", op)
    local op1tn  = typenames[op1t] or string.format("?%d", op1t)
    local op2tn  = typenames[op2t] or string.format("?%d", op2t)
    local rtn    = typenames[rt]   or string.format("?%d", rt)

    -- if op = 0 and all types = 0, probably end of compiled code
    if op == 0 and op1t == 0 and op2t == 0 and rt == 0 and op1lo == 0 and op1hi == 0 then
        f:write(string.format("%04d  (end?)\n", opi))
        break
    end

    f:write(string.format("%04d  %-22s  op1=%s(%04X) op2=%s(%04X) r=%s(%04X) ext=%04X\n",
        opi, opname,
        op1tn, op1lo + op1hi*256,
        op2tn, op2lo + op2hi*256,
        rtn,   rlo   + rhi*256,
        extlo + exthi*256))
end

f:close()
emu.print("done -> " .. OUT_PATH)
os.exit(0)
