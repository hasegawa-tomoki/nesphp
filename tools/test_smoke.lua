-- nesphp smoke test harness
--
-- 起動 → N フレーム待機 → nametable 読出 → "ERR" 検出 → 結果ファイル出力
--
-- 使い方 (絶対パス必須、FCEUX の cwd は launching shell と異なる):
--   fceux --no-config 1 --loadlua tools/test_smoke.lua build/foo.nes
--
-- 出力先: $NESPHP_TEST_OUT 環境変数 or "/tmp/nesphp_test_result.txt"

local FRAMES_TO_WAIT = 300  -- 5 sec at 60fps、compile + 初回 render に十分
local NAMETABLE = 0x2000
local OUT_PATH = os.getenv("NESPHP_TEST_OUT") or "/tmp/nesphp_test_result.txt"

local out = io.open(OUT_PATH, "w")
if not out then
    emu.exit()
    return
end

emu.speedmode("turbo")
for i = 1, FRAMES_TO_WAIT do
    emu.frameadvance()
end

-- "ERR" パターン検出 (E=0x45, R=0x52)
local found_err = false
local err_row, err_col = -1, -1

for y = 0, 29 do
    for x = 0, 29 do
        if ppu.readbyte(NAMETABLE + y * 32 + x) == 0x45 then
            local t1 = ppu.readbyte(NAMETABLE + y * 32 + x + 1)
            local t2 = ppu.readbyte(NAMETABLE + y * 32 + x + 2)
            if t1 == 0x52 and t2 == 0x52 then
                found_err = true
                err_row, err_col = y, x
            end
        end
    end
end

-- nametable 全 30 行を ASCII ダンプ
out:write("=== nametable rows 0-29 (ASCII) ===\n")
for y = 0, 29 do
    out:write(string.format("[%02d] |", y))
    for x = 0, 31 do
        local b = ppu.readbyte(NAMETABLE + y * 32 + x)
        if b >= 0x20 and b <= 0x7E then
            out:write(string.char(b))
        else
            out:write(".")
        end
    end
    out:write("|\n")
end

if found_err then
    out:write(string.format("RESULT: FAIL (ERR detected at row %d col %d)\n", err_row, err_col))
else
    out:write("RESULT: PASS\n")
end

out:close()
emu.exit()
