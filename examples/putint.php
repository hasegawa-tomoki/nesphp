<?php
// nes_putint テスト: 5-char 右詰め unsigned int 表示
nes_putint(10, 12, 0);       // expect "    0"
nes_putint(10, 13, 5);       // expect "    5"
nes_putint(10, 14, 99);      // expect "   99"
nes_putint(10, 15, 1234);    // expect " 1234"
nes_putint(10, 16, 65535);   // expect "65535"
nes_putint(10, 17, 30000);   // expect "30000" (内部 0 を含むが non-leading)
