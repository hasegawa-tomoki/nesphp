-- Simulate user pressing START after a few frames, then capture nametable.

-- Wait for "PRESS START" screen to render
for i = 1, 120 do emu.frameadvance() end

-- Press start (hold for several frames)
for i = 1, 20 do
    joypad.set(1, {start = true})
    emu.frameadvance()
end
joypad.set(1, {})

-- Let game run for 30 sec to see piece variety
for i = 1, 1800 do emu.frameadvance() end

local f = assert(io.open("/tmp/tetris_play.txt", "w"))
f:write("=== after start press + 30 sec ===\n")
for row = 0, 29 do
    local line = {}
    for col = 0, 31 do
        local b = ppu.readbyte(0x2000 + row * 32 + col)
        if b >= 0x20 and b < 0x7F then
            line[#line+1] = string.char(b)
        elseif b >= 0x05 and b <= 0x0C then
            line[#line+1] = string.format("%X", b)
        else
            line[#line+1] = "."
        end
    end
    f:write(string.format("%02d: %s\n", row, table.concat(line)))
end
f:close()
emu.print("done")
os.exit(0)
