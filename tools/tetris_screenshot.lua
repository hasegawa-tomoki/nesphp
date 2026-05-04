-- Run tetris for ~10 sec, dump nametable + attribute table + palette
-- to see how the colored pieces actually render.

for i = 1, 2400 do emu.frameadvance() end  -- 40 sec

local f = assert(io.open("/tmp/tetris_render.txt", "w"))

f:write("=== after 600 frames (10 sec) ===\n")
f:write("--- NAMETABLE 0 ($2000-$23BF) ---\n")
for row = 0, 29 do
    local line = {}
    for col = 0, 31 do
        local b = ppu.readbyte(0x2000 + row * 32 + col)
        if b >= 0x20 and b < 0x7F then
            line[#line+1] = string.char(b)
        elseif b >= 0x05 and b <= 0x0B then
            line[#line+1] = string.format("%X", b)  -- piece tile shown as hex 5-B
        else
            line[#line+1] = "."
        end
    end
    f:write(string.format("%02d: %s\n", row, table.concat(line)))
end

f:write("\n--- ATTRIBUTE TABLE 0 ($23C0-$23FF) ---\n")
f:write("    col0  col1  col2  col3  col4  col5  col6  col7\n")
for row = 0, 7 do
    f:write(string.format("row%d ", row))
    for col = 0, 7 do
        local b = ppu.readbyte(0x23C0 + row * 8 + col)
        f:write(string.format("  %02X ", b))
    end
    f:write("\n")
end

f:write("\n--- PALETTE 1 ($3F04-$3F07) ---\n")
local p = {}
for i = 4, 7 do p[#p+1] = string.format("%02X", ppu.readbyte(0x3F00 + i)) end
f:write("colors 0..3: " .. table.concat(p, " ") .. "\n")

f:close()
emu.print("done")
os.exit(0)
