<?php
nes_cls();
nes_chr_bg(0);
nes_puts(10, 8, "SLIDE 1");
nes_puts(4, 14, "PRESS A BUTTON TO GO");
fgets(STDIN);

nes_cls();
nes_chr_bg(1);
nes_puts(10, 8, "SLIDE 2");
nes_puts(4, 14, "INVERTED FONT BANK");
fgets(STDIN);

nes_cls();
nes_chr_bg(0);
nes_puts(10, 8, "SLIDE 3");
nes_puts(5, 14, "LAST ONE, THANKS");
fgets(STDIN);

nes_cls();
nes_puts(12, 14, "FIN");
fgets(STDIN);
