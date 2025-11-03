# FAQ

### Does this replace Microsoft Automatic Tuning?
No. It complements it. Microsoft handles plan correction in Azure SQL, but Index Advisor provides auditability, configurability, and works everywhere.

### Can it run on Standard Edition?
Yes — just keep `@Online = 0` in creation commands.

### What about duplicate or overlapping indexes?
The collector fingerprints recommendations. The implementor checks deterministic index names, avoiding duplication.

### Can I run it read-only?
Yes — set `@WhatIf = 1` in the implementor for advisory mode.

### Does it slow down production?
The collector is lightweight (reads DMVs only). Implementor and Tracker are manual or scheduled during maintenance windows.

### Will it work on Azure SQL?
Yes, in advisory (`@WhatIf=1`) mode. Azure SQL already has its own automatic tuning that may conflict if you apply indexes automatically.
