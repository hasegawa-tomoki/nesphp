-- Run for a few seconds, dump the first 5 visible nametable rows that have content
-- to /tmp/regression_<rom>.txt for quick visual sanity check.

for i = 1, 90 do emu.frameadvance() end

local out = io.open("/tmp/regression.txt", "w")

-- find first 8 non-empty rows
local printed = 0
for row = 0, 29 do
    local line = {}
    local has_content = false
    for col = 0, 31 do
        local b = ppu.readbyte(0x2000 + row * 32 + col)
        if b >= 0x20 and b < 0x7F then
            line[#line+1] = string.char(b)
            if b ~= 0x20 then has_content = true end
        else
            line[#line+1] = "."
        end
    end
    if has_content and printed < 12 then
        out:write(string.format("%02d: %s\n", row, table.concat(line)))
        printed = printed + 1
    end
end

out:write(string.format("PC=%04X\n", memory.getregister("pc")))
out:close()
emu.print("done")
os.exit(0)
