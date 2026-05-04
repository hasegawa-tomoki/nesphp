-- Take a screenshot after N frames
local out = "/tmp/tetris.png"
for i = 1, 600 do emu.frameadvance() end
gui.savescreenshotas(out)
emu.print("saved " .. out)
os.exit(0)
