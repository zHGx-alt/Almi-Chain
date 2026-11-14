# Hardware budget

Reference prices from Spanish retailers at the time of the project; they need confirming before any purchase.

| Item | Model | Qty | Unit | Subtotal |
|---|---|---:|---:|---:|
| Manager's PC | Lenovo ThinkCentre Neo 50q Gen 4 | 1 | 792.67 € | 792.67 € |
| Manager's monitor | Xiaomi A24i 24" | 1 | 90.99 € | 90.99 € |
| Bar POS terminals | Iggual AIO B156.88.N100, touch screen | 2 | 538.99 € | 1,077.98 € |
| Windows licence for the tills | Windows 10 IoT Enterprise LTSC 2021 | 2 | 37.41 € | 74.82 € |
| Receipt printers | Epson TM-T20IV (Ethernet/USB/RS-232) | 2 | 199.86 € | 399.72 € |
| Main and WDS routers | TP-Link Archer C6 V3 AC1200 | 2 | 42.99 € | 85.98 € |
| ERP server | HP ProDesk 600 G5 MT, refurbished, i5, 16 GB, 512 GB SSD | 1 | 366.00 € | 366.00 € |
| RAID 1 disks | WD Red Plus 2 TB (24/7 NAS disk) | 2 | 329.11 € | 658.22 € |
| Off-site backup disk | WD Elements Portable 2 TB | 1 | 125.08 € | 125.08 € |
| Server UPS | APC Back-UPS BX750MI, 750 VA | 1 | 104.99 € | 104.99 € |
| Switch | TP-Link TL-SG108E, 8 × gigabit, managed | 1 | 31.90 € | 31.90 € |
| Network cable | Cat6 UTP, 100 m, copper | 1 | 49.49 € | 49.49 € |
| Arcade Wi-Fi adapter | TP-Link TL-WN725N (Linux driver) | 1 | 8.99 € | 8.99 € |
| Arcade stick lever | Sanwa JLF-TP-8YT, 4 microswitches | 1 | 22.73 € | 22.73 € |
| **Initial investment** | | | | **3,889.56 €** |
| Fibre internet, 1 Gb, 12 months | DIGI, 30 €/month | | | 360.00 € |
| **First year** | | | | **4,249.56 €** |

Not included: shipping, trunking, RJ45 connectors, receipt paper, the manager's keyboard and mouse, the lever's ball top, the arcade buttons and the Arduino board. The ERP adds no licence cost, because Odoo Community is free.

**Why these choices:** the tills are all-in-ones with a touch screen, so there are fewer cables behind the bar. LTSC means long-term support on a locked-down till. The receipt printers are the restaurant standard, with drivers everywhere. The two identical routers keep WDS compatible between them. The server is refurbished because the load is small, but the RAID uses NAS-grade disks and the server sits behind a UPS, so a power cut cannot corrupt the database.
