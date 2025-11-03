![Views](https://hits.sh/github.com/jfigg007/Justin-s_SQL_Index_Advisor.svg?style=flat-square&label=views&color=blue)


# Justin's SQL Index Advisor

Instance-wide missing index advisor for SQL Server:
- Collects and ranks missing index recommendations (DMVs) across all user DBs
- Optional safe auto-create with deterministic naming & guardrails
- Tracks usage; can auto-drop low-value indexes
- Redgate SQL Monitor integration (custom metric + details view)

> Works on SQL Server 2017+ (on-prem or IaaS). Azure SQL supported in advisory mode.

## Quick start
1. Open SSMS → run `install.sql` in your maintenance DB (default `DBA_Maint`).
2. Drive workload (HammerDB TPC-C or your app).
3. Collect & review:
   ```sql
   EXEC IndexAdvisor.usp_CollectMissingIndexes @TargetDb = N'tpcc', @MinSeeks=1, @MinImpactScore=1;
   SELECT TOP 20 * FROM IndexAdvisor.vHighImpactMissingIndexDetails ORDER BY ImpactScore DESC;
   ```
4. Preview create (WHATIF):
   ```sql
   EXEC IndexAdvisor.usp_ImplementTopMissingIndexes @TopN=3, @ImpactThreshold=2000000, @WhatIf=1, @Online=0;
   ```

## Why not just “automatic tuning”?
Microsoft’s automatic tuning is strongest in Azure SQL and is intentionally opaque. Justin's SQL Index Advisor gives you:
- **Control** (thresholds, bands, caps, WHATIF)
- **Auditability** (tables, views, logs)
- **Integration** (Redgate alerts) and **governance** (CAB-friendly)
- **Works anywhere** you can run SQL Server

## Support
Best-effort only; no SLAs. Please open an Issue with:
- SQL Server version/edition
- Exact error text
- Minimal repro (schema + query)
