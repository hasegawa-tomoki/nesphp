<?php
$x = 2;
$y = 8;

nes_cls();
nes_chr_bg(0);
nes_puts($x, $y, "SLIDE 1");
nes_puts($x, 14, "USING CV VARS");
fgets(STDIN);

nes_cls();
nes_chr_bg(1);
nes_puts($x, $y, "SLIDE 2");
nes_puts($x, 14, "X AND Y ARE CVS");
fgets(STDIN);

$y = $y + 2;
nes_cls();
nes_chr_bg(0);
nes_puts($x, $y, "SLIDE 3");
nes_puts($x, 14, "Y SHIFTED DOWN");
fgets(STDIN);
