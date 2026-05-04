-- Dump op_array header to check usage of bank 0 PRG-RAM ($6000-$7FFF, 8192 bytes)
-- Header layout (spec/01-rom-format.md):
--   $6000 + 0: NUM_OPS (u16)
--   $6000 + 2: LITERALS_OFF (u16, byte offset from OPS_BASE)
--   $6000 + 4: NUM_LITERALS (u16)
--   $6000 + 6: NUM_CVS (u16)
--   $6000 + 8: NUM_TMPS (u16)

for i = 1, 240 do emu.frameadvance() end  -- let compile + prologue finish (tetris is large)

local f = assert(io.open("/tmp/op_array_size.txt", "w"))

local function rd16(addr) return memory.readbyte(addr) + memory.readbyte(addr+1)*256 end

local num_ops      = rd16(0x6000)
local literals_off = rd16(0x6002)
local num_literals = rd16(0x6004)
local num_cvs      = rd16(0x6006)
local num_tmps     = rd16(0x6008)

local first_op   = 0x6010
local ops_size   = num_ops * 12
local lits_size  = num_literals * 16
local lits_start = 0x6000 + literals_off
local lits_end   = lits_start + lits_size
local used_total = lits_end - 0x6000

f:write(string.format("num_ops      = %d (×12 = %d bytes)\n", num_ops, ops_size))
f:write(string.format("num_literals = %d (×16 = %d bytes)\n", num_literals, lits_size))
f:write(string.format("num_cvs      = %d\n", num_cvs))
f:write(string.format("num_tmps     = %d\n", num_tmps))
f:write(string.format("\n"))
f:write(string.format("op_array     : $6010 - $%04X (%d bytes)\n", first_op + ops_size - 1, ops_size))
f:write(string.format("literals     : $%04X - $%04X (%d bytes)\n", lits_start, lits_end - 1, lits_size))
f:write(string.format("\n"))
f:write(string.format("bank 0 used  : %d / 8192 bytes (%.1f%%)\n", used_total, used_total * 100.0 / 8192))
f:write(string.format("bank 0 free  : %d bytes (%.1f%%)\n", 8192 - used_total, (8192 - used_total) * 100.0 / 8192))
f:write(string.format("\n--- DEBUG ---\n"))
f:write(string.format("CPU PC = %04X\n", memory.getregister("pc")))
f:write("$6000 first 16 bytes: ")
for i = 0, 15 do f:write(string.format("%02X ", memory.readbyte(0x6000 + i))) end
f:write("\n")

f:close()
emu.print("done")
os.exit(0)
