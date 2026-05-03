#!/bin/bash
# nesphp smoke test runner
#
# Usage:
#   tools/run_smoke.sh                 # 全 build/*.nes を実行
#   tools/run_smoke.sh hello tetris    # 指定 ROM のみ
#
# 各 ROM について fceux を起動 → Lua ハーネスが nametable を読出 → "ERR" 検出
# 結果を build/smoke_<NAME>.txt に保存、最後にサマリ表示。

set -u
cd "$(dirname "$0")/.."

LUA="$(pwd)/tools/test_smoke.lua"
TIMEOUT_SEC=8  # 1 ROM あたりの待機時間 (compile + 5sec render)

if [ $# -eq 0 ]; then
    ROMS=(build/*.nes)
else
    ROMS=()
    for n in "$@"; do
        ROMS+=("build/${n%.nes}.nes")
    done
fi

PASS=0
FAIL=0
ERRORS=()

for rom in "${ROMS[@]}"; do
    if [ ! -f "$rom" ]; then
        echo "  MISSING: $rom"
        continue
    fi
    name="$(basename "$rom" .nes)"
    out="build/smoke_${name}.txt"
    rm -f "$out"

    NESPHP_TEST_OUT="$(pwd)/$out" \
        fceux --no-config 1 --loadlua "$LUA" "$(pwd)/$rom" >/dev/null 2>&1 &
    PID=$!
    sleep $TIMEOUT_SEC
    kill -9 $PID 2>/dev/null
    killall -9 fceux 2>/dev/null
    sleep 0.5

    if [ -f "$out" ]; then
        if grep -q "RESULT: PASS" "$out"; then
            echo "  PASS: $name"
            PASS=$((PASS+1))
        else
            echo "  FAIL: $name (see $out)"
            FAIL=$((FAIL+1))
            ERRORS+=("$name")
        fi
    else
        echo "  TIMEOUT: $name (no result file)"
        FAIL=$((FAIL+1))
        ERRORS+=("$name (timeout)")
    fi
done

echo ""
echo "=== Summary ==="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
if [ ${#ERRORS[@]} -gt 0 ]; then
    echo "Failures: ${ERRORS[*]}"
fi
