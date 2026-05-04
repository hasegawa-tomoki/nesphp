-- Run ROM for N frames, dump nametable + key memory to /tmp/probe_out.txt, then exit.
--
-- Usage: fceux --loadlua tools/probe.lua build/<rom>.nes
--
-- Output rows: 30 lines × 32 cols of nametable 0 ($2000-$23BF), printable ASCII or '.'

local OUT_PATH = "/tmp/probe_out.txt"
local FRAMES   = 180   -- ~3 sec NTSC

-- Run for FRAMES frames so program initializes + reaches steady state.
for i = 1, FRAMES do
    emu.frameadvance()
end

local f = assert(io.open(OUT_PATH, "w"))

f:write(string.format("=== after %d frames ===\n", FRAMES))

-- nametable 0: $2000-$23BF (30 rows * 32 cols = 960 tiles)
f:write("--- NAMETABLE 0 ---\n")
for row = 0, 29 do
    local line = {}
    for col = 0, 31 do
        local b = ppu.readbyte(0x2000 + row * 32 + col)
        if b >= 0x20 and b < 0x7F then
            line[#line+1] = string.char(b)
        else
            line[#line+1] = "."
        end
    end
    f:write(string.format("%02d: %s\n", row, table.concat(line)))
end

-- attribute table: $23C0-$23FF (8 rows * 8 cols)
f:write("--- ATTR 0 ---\n")
for row = 0, 7 do
    local line = {}
    for col = 0, 7 do
        line[#line+1] = string.format("%02X", ppu.readbyte(0x23C0 + row * 8 + col))
    end
    f:write(string.format("%d: %s\n", row, table.concat(line, " ")))
end

-- palette: $3F00-$3F1F
f:write("--- PALETTE ---\n")
local pal = {}
for i = 0, 31 do
    pal[#pal+1] = string.format("%02X", ppu.readbyte(0x3F00 + i))
end
f:write(table.concat(pal, " ") .. "\n")

-- key VM state (from nesphp.s zero-page / RAM)
f:write("--- KEY MEM ---\n")
f:write(string.format("vblank_frame   = %02X\n", memory.readbyte(0x10)))   -- placeholder, see below
f:write(string.format("PPUCTRL_shadow = %02X\n", memory.readbyte(0x11)))
-- Note: actual addresses depend on .res order; we just dump some likely ranges
f:write("ZP $00-$1F: ")
for i = 0, 31 do f:write(string.format("%02X ", memory.readbyte(i))) end
f:write("\n")

-- 6502 PC (where is the CPU stuck?)
f:write(string.format("CPU PC = %04X  A=%02X X=%02X Y=%02X SP=%02X\n",
    memory.getregister("pc"),
    memory.getregister("a"),
    memory.getregister("x"),
    memory.getregister("y"),
    memory.getregister("s")))

f:close()

emu.print("probe done -> " .. OUT_PATH)
os.exit(0)
