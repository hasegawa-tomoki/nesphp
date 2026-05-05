-- Test piece variety with different start press timings.
-- Press start after 73, 150, 300 frames in 3 separate runs.

local wait_frames = 73

for i = 1, wait_frames do emu.frameadvance() end
for i = 1, 30 do
    joypad.set(1, {start = true})
    emu.frameadvance()
end
joypad.set(1, {})
for i = 1, 1800 do emu.frameadvance() end  -- 30 sec game

local f = assert(io.open("/tmp/test_random.txt", "w"))
f:write(string.format("=== wait %d frames before start ===\n", wait_frames))

-- look at what tile types are in user RAM (offset 64-263 = locked tiles)
-- but user RAM is at $0700+ which is internal RAM, accessible via memory.readbyte
local types_seen = {}
for idx = 0, 199 do
    local t = memory.readbyte(0x0700 + 56 + idx)  -- tile grid offset = 56 (after shape table)
    if t ~= 0 then
        types_seen[t] = (types_seen[t] or 0) + 1
    end
end

f:write("locked tile counts:\n")
for t = 5, 11 do
    if types_seen[t] then
        f:write(string.format("  0x%02X: %d cells\n", t, types_seen[t]))
    end
end

f:close()
emu.print("done")
os.exit(0)
