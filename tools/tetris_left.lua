-- Test: hold LEFT continuously while piece falls. With buggy code, piece
-- would lock-stick at left edge when auto-fall coincides with left press.
-- With fix, piece should fall to floor without sticking sideways.

-- press start
for i = 1, 120 do emu.frameadvance() end
for i = 1, 30 do
    joypad.set(1, {start = true})
    emu.frameadvance()
end
joypad.set(1, {})
for i = 1, 30 do emu.frameadvance() end

-- Hold LEFT for entire game (until piece reaches floor)
-- 1 piece auto-fall every 30 frames, ~20 cells = 600 frames per piece.
for i = 1, 1800 do
    joypad.set(1, {left = true})
    emu.frameadvance()
end
joypad.set(1, {})

-- Let it settle a bit
for i = 1, 30 do emu.frameadvance() end

local f = assert(io.open("/tmp/tetris_left.txt", "w"))
f:write("=== held LEFT for 700 frames, then released ===\n")
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
